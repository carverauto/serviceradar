defmodule ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery.Executor do
  @moduledoc false

  # This module is the sole constrained server-only fulfillment capability, not
  # an authorization actor. It consumes an immutable request ID, rebuilds the
  # original principal's current authority inside the guarded transaction,
  # revalidates the legacy row and live mTLS identity, and then delegates only
  # the request-bound owner/agent/partition tuple to authoritative
  # materializers/reconcilers. No bearer token, permission snapshot, caller
  # params, or caller-selected partition enters this path.

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.PluginAssignmentMaterializer
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Observability.ServiceStateRegistry
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PluginPolicyAssignmentRecoveryRequest
  alias ServiceRadar.Plugins.PluginTargetPolicy
  alias ServiceRadar.Plugins.PluginTargetPolicyOps
  alias ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery.Authority
  alias ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery.Lease
  alias ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery.OwnerReference
  alias ServiceRadar.Plugins.RecoveryConfigDispatch
  alias ServiceRadar.Repo

  require Ash.Query

  # Broker-grant persistence is intentionally server-only. This named actor is
  # used only after `Authority.reauthorize_request/1` succeeds; it is never
  # treated as authority evidence for the initiating principal.
  @actor SystemActor.system(:plugin_policy_assignment_recovery_executor)
  @lease_seconds 1_800

  @terminal_statuses [
    :reconciled,
    :no_longer_eligible,
    :owner_not_authoritative,
    :identity_unavailable,
    :identity_changed,
    :package_unapproved,
    :schema_invalid,
    :conflict,
    :denied,
    :failed
  ]

  @type outcome ::
          :reconciled
          | :no_longer_eligible
          | :owner_not_authoritative
          | :identity_unavailable
          | :identity_changed
          | :package_unapproved
          | :schema_invalid
          | :conflict
          | :denied
          | :failed

  @spec execute(String.t(), keyword()) :: {:ok, outcome() | :already_executing} | {:error, term()}
  def execute(request_id, opts \\ [])

  def execute(request_id, opts) when is_binary(request_id) and is_list(opts) do
    with {:ok, request} <- load_request(request_id, opts),
         {:ok, claim} <- claim_or_resume(request, opts) do
      case claim do
        {:terminal, status} -> {:ok, status}
        :already_executing -> {:ok, :already_executing}
        {:claimed, request, lease_token} -> execute_claimed(request, lease_token, opts)
      end
    end
  end

  def execute(_request_id, _opts), do: {:error, :invalid_recovery_request_id}

  defp execute_claimed(request, lease_token, opts) do
    case revalidate_and_materialize(request, lease_token, opts) do
      {:ok, outcome, assignment_ids, partition_id}
      when outcome in [:reconciled, :no_longer_eligible] ->
        finish_materialization_and_dispatch(
          request,
          lease_token,
          outcome,
          assignment_ids,
          partition_id,
          opts
        )

      {:ok, outcome, _assignment_ids} ->
        finish(request, lease_token, outcome, [], opts)

      # A worker that no longer owns a live lease must not write a terminal
      # result. In particular, finishing an expired-but-not-yet-reclaimed
      # request would prevent its next owner from doing the recovery. Treat it
      # like another worker is active; the durable dispatcher will enqueue it
      # again after its current lease becomes claimable.
      {:error, :recovery_lease_lost} ->
        {:ok, :already_executing}

      {:error, reason} ->
        finish(request, lease_token, terminal_outcome(reason), [], opts)
    end
  rescue
    _exception ->
      # Do not put exception text (which can contain external-provider detail)
      # in the request record. A retry after a failed terminal write is safe:
      # reconciliation is idempotent and all authority is rebuilt again.
      finish(request, lease_token, :failed, [], opts)
  end

  # Both writes are durable before the best-effort config push: first the
  # guarded materialization transaction, then the terminal recovery status.
  # A request whose terminal status write fails stays eligible for normal retry
  # and must not independently dispatch. `:no_longer_eligible` is included
  # because narrow reconciliation can disable a previously enabled row even
  # when no replacement remains eligible.
  defp finish_materialization_and_dispatch(
         request,
         lease_token,
         outcome,
         assignment_ids,
         partition_id,
         opts
       ) do
    case finish(request, lease_token, outcome, assignment_ids, opts) do
      {:ok, ^outcome} = result ->
        # Raw outer transactions deliberately suppress Ash notifications so an
        # identity flip can roll every assignment/grant write back together.
        # Once the recovery request is durably terminal, rebuild the normal
        # enabled-assignment service-state placeholders from freshly read,
        # still-current assignments. This must be after `finish/5`: a stale
        # lease must not make an observable service state appear.
        seed_recovered_service_states(request, assignment_ids, partition_id, opts)

        RecoveryConfigDispatch.dispatch_after_commit(
          request.legacy_agent_uid,
          partition_id,
          opts
        )

        result

      other ->
        other
    end
  end

  # Test-only seams retain real production defaults while allowing the executor
  # wiring to be exercised without a database-backed policy fixture.
  defp revalidate_and_materialize(request, lease_token, opts) do
    case Keyword.get(opts, :test_materializer) do
      materializer when is_function(materializer, 1) -> materializer.(request)
      _ -> revalidate_and_materialize(request, lease_token)
    end
  end

  defp revalidate_and_materialize(request, lease_token) do
    with true <- OwnerReference.matches_request?(request) || {:error, :owner_not_authoritative},
         {:ok, legacy} <- load_legacy_assignment(request.legacy_assignment_id),
         :ok <- legacy_matches_request(legacy, request),
         {:ok, preflight_partition} <- authenticated_partition(request.legacy_agent_uid) do
      materialize_under_partition_guard(request, preflight_partition, lease_token)
    else
      false -> {:error, :failed}
      {:error, _reason} = error -> error
    end
  end

  # Assignment materialization can issue grants and update/create/disable
  # assignments. Keep every such write and the postflight identity check in
  # one database transaction: a changed live edge identity must roll the whole
  # operation back before the terminal recovery outcome is recorded. The
  # expected partition is also passed into reconciliation, which rejects a
  # changed session before a store write is attempted.
  defp materialize_under_partition_guard(request, preflight_partition, lease_token) do
    case Repo.transaction(fn ->
           with {:ok, _principal} <- Authority.reauthorize_request(request),
                # Lock the durable request row immediately before any
                # materializer mutation. The lock is intentionally held for
                # the rest of this transaction so a competing executor cannot
                # reclaim the request between the lease check and a write.
                :ok <- fence_current_lease(request, lease_token),
                {:ok, materialization} <-
                  materialize_current_owner(request, preflight_partition),
                :ok <- materialization_authoritative?(materialization),
                {:ok, postflight_partition} <- authenticated_partition(request.legacy_agent_uid),
                true <-
                  preflight_partition == postflight_partition || {:error, :identity_changed},
                {:ok, assignment_ids} <- fresh_assignment_ids(request, postflight_partition),
                # The first lock fences a reclaim race; this second check also
                # rejects work whose bounded lease elapsed while materializing.
                # Returning an error rolls every assignment/grant change back
                # before an external config push can be considered.
                :ok <- fence_current_lease(request, lease_token) do
             if assignment_ids == [] do
               {:ok, :no_longer_eligible, [], postflight_partition}
             else
               {:ok, :reconciled, assignment_ids, postflight_partition}
             end
           else
             false -> Repo.rollback(:failed)
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp fence_current_lease(%{id: request_id}, lease_token)
       when is_binary(request_id) and is_binary(lease_token) do
    Lease.fence_current(request_id, lease_token, DateTime.utc_now())
  end

  defp fence_current_lease(_request, _lease_token), do: {:error, :recovery_lease_lost}

  defp load_request(request_id, opts) do
    case Keyword.get(opts, :test_request_loader) do
      loader when is_function(loader, 1) -> loader.(request_id)
      _ -> load_request(request_id)
    end
  end

  defp load_request(request_id) do
    case PluginPolicyAssignmentRecoveryRequest.get_by_id(request_id, actor: @actor) do
      {:ok, nil} -> {:error, :recovery_request_not_found}
      {:ok, request} -> {:ok, request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_or_resume(request, opts) do
    case Keyword.get(opts, :test_claimer) do
      claimer when is_function(claimer, 1) -> claimer.(request)
      _ -> claim_or_resume(request)
    end
  end

  defp claim_or_resume(%{status: status} = _request) when status in @terminal_statuses do
    {:ok, {:terminal, status}}
  end

  defp claim_or_resume(%{status: status} = request) when status in [:requested, :executing] do
    now = DateTime.utc_now()

    if Lease.claimable?(status, request.lease_expires_at, now) do
      lease_token = Ecto.UUID.generate()
      lease_expires_at = DateTime.add(now, @lease_seconds, :second)

      case Lease.claim_current(request.id, lease_token, now, lease_expires_at, actor: @actor) do
        :ok ->
          with {:ok, claimed} <- load_request(request.id) do
            {:ok, {:claimed, claimed, lease_token}}
          end

        {:error, :recovery_lease_lost} ->
          reload_after_claim_race(request.id)

        {:error, reason} ->
          {:error, reason}
      end
    else
      # An unexpired lease belongs to the worker that won the atomic claim.
      # Returning a no-op here prevents a second worker from materializing or
      # finishing the request with an arbitrary token.
      {:ok, :already_executing}
    end
  end

  defp claim_or_resume(_request), do: {:error, :recovery_request_not_active}

  defp reload_after_claim_race(request_id) do
    with {:ok, request} <- load_request(request_id) do
      case request.status do
        status when status in @terminal_statuses -> {:ok, {:terminal, status}}
        :executing -> {:ok, :already_executing}
        :requested -> claim_or_resume(request)
        _ -> {:error, :recovery_request_not_active}
      end
    end
  end

  defp load_legacy_assignment(id) do
    case Ash.get(PluginAssignment, id, actor: @actor) do
      {:ok, nil} -> {:error, :legacy_assignment_changed}
      {:ok, assignment} -> {:ok, assignment}
      {:error, _reason} -> {:error, :legacy_assignment_changed}
    end
  end

  defp legacy_matches_request(legacy, request) do
    if legacy.source == :policy and legacy.enabled == false and blank?(legacy.partition_id) and
         legacy.agent_uid == request.legacy_agent_uid and
         legacy.policy_id == request.legacy_policy_id and
         legacy.plugin_package_id == request.legacy_plugin_package_id do
      :ok
    else
      {:error, :legacy_assignment_changed}
    end
  end

  defp authenticated_partition(agent_uid) when is_binary(agent_uid) do
    case AgentCommandBus.resolve_control_session_evidence(agent_uid) do
      {:ok, %{agent_id: ^agent_uid, partition_id: partition_id}}
      when is_binary(partition_id) and partition_id != "" ->
        {:ok, String.trim(partition_id)}

      {:ok, _evidence} ->
        {:error, :identity_changed}

      {:error, _reason} ->
        {:error, :identity_unavailable}
    end
  end

  defp authenticated_partition(_agent_uid), do: {:error, :identity_unavailable}

  defp materialize_current_owner(%{owner_kind: :credential_rule} = request, expected_partition_id) do
    PluginAssignmentMaterializer.reconcile_current_rule_for_agent(
      request.owner_id,
      request.legacy_agent_uid,
      request.owner_purpose,
      actor: @actor,
      expected_partition_id: expected_partition_id
    )
  end

  defp materialize_current_owner(
         %{owner_kind: :plugin_target_policy} = request,
         expected_partition_id
       ) do
    with {:ok, policy} <- current_enabled_policy(request.owner_id),
         :ok <- approved_package(policy.plugin_package_id) do
      PluginTargetPolicyOps.reconcile_policy_for_agent(
        request.owner_id,
        request.legacy_agent_uid,
        actor: @actor,
        expected_partition_id: expected_partition_id
      )
    end
  end

  defp materialize_current_owner(_request, _expected_partition_id),
    do: {:error, :owner_not_authoritative}

  defp current_enabled_policy(policy_id) do
    case PluginTargetPolicy.get_by_id(policy_id, actor: @actor) do
      {:ok, %PluginTargetPolicy{enabled: true} = policy} -> {:ok, policy}
      {:ok, _policy} -> {:error, :owner_not_authoritative}
      {:error, _reason} -> {:error, :owner_not_authoritative}
    end
  end

  defp approved_package(package_id) do
    PluginPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^package_id)
    |> Ash.read_one(actor: @actor)
    |> case do
      {:ok, %PluginPackage{status: :approved}} -> :ok
      {:ok, _package} -> {:error, :package_unapproved}
      {:error, _reason} -> {:error, :package_unapproved}
    end
  end

  defp materialization_authoritative?(%{skips: skips}) when is_map(skips) do
    if Map.get(skips, :owner_not_authoritative, 0) > 0,
      do: {:error, :owner_not_authoritative},
      else: :ok
  end

  defp materialization_authoritative?(_materialization), do: :ok

  defp fresh_assignment_ids(request, partition_id) do
    PluginAssignment
    |> Ash.Query.for_read(:all_partitions_for_policy, %{policy_id: request.legacy_policy_id},
      actor: @actor
    )
    |> Ash.Query.filter(
      source == :policy and enabled == true and agent_uid == ^request.legacy_agent_uid and
        partition_id == ^partition_id
    )
    |> Ash.read(actor: @actor)
    |> case do
      {:ok, assignments} -> {:ok, assignments |> Enum.map(& &1.id) |> Enum.sort()}
      {:error, _reason} -> {:error, :fresh_assignment_lookup_failed}
    end
  end

  # The assignments returned by the guarded materialization transaction are
  # IDs only. Re-read them after the terminal request write so a concurrent
  # normal reconciliation that disabled or replaced one cannot resurrect an
  # obsolete service placeholder. The same narrow policy action used to build
  # the ID list retains the executor's exact system-actor boundary.
  defp seed_recovered_service_states(request, assignment_ids, partition_id, opts)
       when is_list(assignment_ids) do
    Enum.each(assignment_ids, fn assignment_id ->
      case load_current_recovered_assignment(assignment_id, request, partition_id, opts) do
        {:ok, assignment} -> invoke_service_state_upserter(assignment, opts)
        _ -> :ok
      end
    end)

    :ok
  end

  defp seed_recovered_service_states(_request, _assignment_ids, _partition_id, _opts), do: :ok

  # Test-only seam: executor wiring can be exercised without a database-backed
  # policy fixture. Production always re-reads through the constrained action
  # below.
  defp load_current_recovered_assignment(assignment_id, request, partition_id, opts) do
    case Keyword.get(opts, :test_recovered_assignment_loader) do
      loader when is_function(loader, 3) -> loader.(assignment_id, request, partition_id)
      _ -> load_current_recovered_assignment(assignment_id, request, partition_id)
    end
  end

  defp load_current_recovered_assignment(assignment_id, request, partition_id)
       when is_binary(assignment_id) and is_binary(partition_id) do
    PluginAssignment
    |> Ash.Query.for_read(:all_partitions_for_policy, %{policy_id: request.legacy_policy_id},
      actor: @actor
    )
    |> Ash.Query.filter(
      id == ^assignment_id and source == :policy and enabled == true and
        agent_uid == ^request.legacy_agent_uid and partition_id == ^partition_id
    )
    |> Ash.read_one(actor: @actor)
    |> case do
      {:ok, %PluginAssignment{} = assignment} -> {:ok, assignment}
      _ -> :not_found
    end
  end

  defp load_current_recovered_assignment(_assignment_id, _request, _partition_id), do: :not_found

  # State seeding is a post-commit repair side effect, just like the config
  # push. It must never turn a completed, durable recovery into a failed retry
  # if observability storage is temporarily unavailable.
  defp invoke_service_state_upserter(assignment, opts) do
    upserter =
      Keyword.get(opts, :service_state_upserter, &ServiceStateRegistry.upsert_for_assignment/1)

    _ = upserter.(assignment)
    :ok
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp finish(request, lease_token, outcome, assignment_ids, opts)
       when outcome in @terminal_statuses do
    case Keyword.get(opts, :test_finisher) do
      finisher when is_function(finisher, 4) ->
        finisher.(request, lease_token, outcome, assignment_ids)

      _ ->
        finish(request, lease_token, outcome, assignment_ids)
    end
  end

  defp finish(request, lease_token, outcome, assignment_ids) when outcome in @terminal_statuses do
    # The terminal write is a single conditional UPDATE rather than an Ash
    # record update. Ash action filters do not fence record-based updates, and
    # a stale worker must never terminalize an expired/stolen lease.
    case Lease.finish_current(
           request.id,
           lease_token,
           outcome,
           assignment_ids,
           DateTime.utc_now(),
           actor: @actor
         ) do
      :ok -> {:ok, outcome}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec terminal_outcome(term()) :: outcome()
  def terminal_outcome(reason) do
    case reason do
      :legacy_assignment_changed -> :no_longer_eligible
      :owner_not_authoritative -> :owner_not_authoritative
      :owner_not_found -> :owner_not_authoritative
      :rule_not_found -> :owner_not_authoritative
      :rule_purpose_mismatch -> :owner_not_authoritative
      :policy_not_found -> :owner_not_authoritative
      :policy_not_enabled -> :owner_not_authoritative
      :identity_unavailable -> :identity_unavailable
      :identity_changed -> :identity_changed
      :package_unapproved -> :package_unapproved
      :plugin_package_not_found -> :package_unapproved
      :restricted_rule_recovery_requires_recovery_executor -> :failed
      :restricted_policy_recovery_requires_recovery_executor -> :failed
      :current_permission_denied -> :denied
      :principal_disabled -> :denied
      :principal_not_found -> :denied
      :record_not_found -> :denied
      :role_profile_not_found -> :denied
      :no_profile -> :denied
      :principal_owner_changed -> :denied
      :initiating_principal_required -> :denied
      :service_principal_write_scope_required -> :denied
      :current_authorization_unavailable -> :denied
      {:equal_priority_credential_rule_conflict, _query, _priority} -> :conflict
      _ -> classify_materialization_error(reason)
    end
  end

  defp classify_materialization_error(reason) do
    text = inspect(reason)

    cond do
      String.contains?(text, "authenticated_agent_partition_changed") ->
        :identity_changed

      String.contains?(text, "authenticated_agent_partition") ->
        :identity_unavailable

      String.contains?(text, "equal_priority_credential_rule_conflict") ->
        :conflict

      String.contains?(text, "plugin_package") or String.contains?(text, "approved") ->
        :package_unapproved

      String.contains?(text, "missing required policy") or String.contains?(text, "schema") ->
        :schema_invalid

      true ->
        :failed
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
