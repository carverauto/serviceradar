defmodule ServiceRadar.Automation.CallbackGrants.Lifecycle do
  @moduledoc """
  Purely orchestrated callback-grant lifecycle.

  Persistence, current authorization, keyed verification, time, and external
  cleanup are injected adapters. The store owns all row locks and atomic state,
  idempotency, budget, and audit commits.
  """

  alias ServiceRadar.Automation.Ansible.SafeFailureEvidence
  alias ServiceRadar.Automation.CallbackGrants.ActionContract
  alias ServiceRadar.Automation.CallbackGrants.Audit
  alias ServiceRadar.Automation.CallbackGrants.Authority
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Automation.CallbackGrants.HMACKeyedVerifier
  alias ServiceRadar.Automation.CallbackGrants.NoopCleanup
  alias ServiceRadar.Automation.CallbackGrants.SshCaBundleResponse
  alias ServiceRadar.Automation.CallbackGrants.Token

  @audience "serviceradar.awx.callback/v1"
  @grant_states ~w(pending active revoked expired consumed)a
  @terminal_job_states [
    "successful",
    "failed",
    "error",
    "canceled",
    :successful,
    :failed,
    :error,
    :canceled
  ]

  @scope_required MapSet.new(
                    ~w(controller_id inventory_id job_template_id project_id scm_revision content_sha256 execution_environment_id machine_credential_id credential_ids ask_credential_on_launch callback_credential_type_id callback_credential_organization_id callback_credential_injector_digest host_limit target_count target_digest snapshot_digest targets binding_id awx_created_by_id)
                  )

  @scope_optional MapSet.new()

  @type opts :: keyword()

  @doc "Creates an unusable pending grant and returns its bearer exactly once."
  @spec prepare(map(), opts()) :: {:ok, map()} | {:error, term()}
  def prepare(attrs, opts) when is_map(attrs) and is_list(opts) do
    now = now(opts)
    action = value(attrs, :action)

    with {:ok, contract} <- ActionContract.fetch(action),
         :ok <- ActionContract.validate_deployment(contract, value(attrs, :response_snapshot)),
         {:ok, draft} <- prepare_draft(attrs, contract, now),
         {:ok, current} <- current_authority(:issue, draft, opts),
         :ok <- Authority.validate_issue(draft, current, contract),
         :ok <- validate_response_snapshot(draft),
         {:ok, issued} <- issue_token(opts),
         {:ok, issued_idempotency} <- issue_idempotency_key(opts),
         grant_attrs =
           draft
           |> Map.put(:verifier_key_id, issued.verifier_key_id)
           |> Map.put(:verifier_digest, issued.verifier_digest)
           |> Map.put(:idempotency_verifier_key_id, issued_idempotency.verifier_key_id)
           |> Map.put(:idempotency_verifier_digest, issued_idempotency.verifier_digest),
         {:ok, audit} <- Audit.attrs(:grant_pending, grant_attrs),
         {:ok, grant} <- store(opts).create_pending(grant_attrs, audit, store_context(opts)) do
      {:ok,
       %{
         grant: pending_result(grant),
         bearer: issued.bearer,
         idempotency_key: issued_idempotency.idempotency_key
       }}
    end
  end

  def prepare(_attrs, _opts), do: {:error, :invalid_callback_grant}

  @doc "Binds the externally created ephemeral AWX credential to a pending grant."
  @spec bind_credential(binary(), pos_integer(), opts()) :: {:ok, map()} | {:error, term()}
  def bind_credential(grant_id, credential_id, opts)
      when is_binary(grant_id) and is_integer(credential_id) and credential_id > 0 and
             is_list(opts) do
    now = now(opts)

    with {:ok, grant} <- store(opts).fetch(grant_id, store_context(opts)),
         :ok <- not_expired(grant, now),
         {:ok, contract} <- ActionContract.fetch(value(grant, :action)),
         authorize = credential_binding_hook(contract, opts),
         {:ok, audit} <- Audit.attrs(:credential_bound, grant),
         {:ok, outcome, bound} <-
           store(opts).bind_credential(
             grant_id,
             credential_id,
             authorize,
             audit,
             now,
             store_context(opts)
           ) do
      {:ok, public_result(bound, %{outcome: outcome, credential_bound: true})}
    else
      {:error, :grant_expired} -> expire_and_deny(grant_id, opts)
      {:error, reason} -> handle_valid_denial(grant_id, reason, opts)
    end
  end

  def bind_credential(_grant_id, _credential_id, _opts),
    do: {:error, :invalid_callback_credential}

  @doc "Reauthorizes a pending grant immediately before creating its AWX credential."
  @spec reauthorize_credential_creation(binary(), opts()) ::
          {:ok, map()} | {:error, term()}
  def reauthorize_credential_creation(grant_id, opts)
      when is_binary(grant_id) and is_list(opts) do
    now = now(opts)

    with {:ok, grant} <- store(opts).fetch(grant_id, store_context(opts)),
         :ok <- not_expired(grant, now),
         :ok <- credential_creation_ready(grant),
         {:ok, contract} <- ActionContract.fetch(value(grant, :action)),
         {:ok, current} <- current_authority(:bind_credential, grant, opts),
         :ok <- Authority.validate_issue(grant, current, contract) do
      {:ok, public_result(grant, %{credential_creation_authorized: true})}
    else
      {:error, :grant_expired} -> expire_and_deny(grant_id, opts)
      {:error, reason} -> handle_valid_denial(grant_id, reason, opts)
    end
  end

  def reauthorize_credential_creation(_grant_id, _opts),
    do: {:error, :invalid_callback_credential_creation}

  @doc "Reauthorizes a pending, credential-bound grant immediately before AWX launch."
  @spec authorize_launch_dispatch(binary(), opts()) :: {:ok, map()} | {:error, term()}
  def authorize_launch_dispatch(grant_id, opts) when is_binary(grant_id) and is_list(opts) do
    now = now(opts)

    with {:ok, grant} <- store(opts).fetch(grant_id, store_context(opts)),
         :ok <- not_expired(grant, now),
         :ok <- launch_dispatch_ready(grant),
         {:ok, contract} <- ActionContract.fetch(value(grant, :action)),
         {:ok, current} <- current_authority(:bind_job, grant, opts),
         :ok <- Authority.validate_issue(grant, current, contract) do
      {:ok, public_result(grant, %{launch_dispatch_authorized: true})}
    else
      {:error, :grant_expired} -> expire_and_deny(grant_id, opts)
      {:error, reason} -> handle_valid_denial(grant_id, reason, opts)
    end
  end

  def authorize_launch_dispatch(_grant_id, _opts), do: {:error, :invalid_callback_launch_dispatch}

  @doc "Reauthorizes a known, pending AWX child before pre-activation scope work."
  @spec reauthorize_pending_job(binary(), opts()) :: {:ok, map()} | {:error, term()}
  def reauthorize_pending_job(grant_id, opts) when is_binary(grant_id) and is_list(opts) do
    now = now(opts)

    with {:ok, grant} <- store(opts).fetch(grant_id, store_context(opts)),
         :ok <- not_expired(grant, now),
         :ok <- pending_bound_grant_ready(grant),
         {:ok, contract} <- ActionContract.fetch(value(grant, :action)),
         {:ok, current} <- current_authority(:bind_job, grant, opts),
         :ok <- Authority.validate_issue(grant, current, contract) do
      {:ok, public_result(grant, %{reauthorized: true, binding_pending: true})}
    else
      {:error, :grant_expired} -> expire_and_deny(grant_id, opts)
      {:error, reason} -> handle_valid_denial(grant_id, reason, opts)
    end
  end

  def reauthorize_pending_job(_grant_id, _opts),
    do: {:error, :invalid_callback_pending_job_reauthorization}

  @doc "Reauthorizes one active callback child before a watchdog continuation."
  @spec reauthorize_active(binary(), opts()) :: {:ok, map()} | {:error, term()}
  def reauthorize_active(grant_id, opts) when is_binary(grant_id) and is_list(opts) do
    reauthorize_bound(grant_id, [:active], opts)
  end

  def reauthorize_active(_grant_id, _opts), do: {:error, :invalid_callback_reauthorization}

  @doc """
  Reauthorizes a bound callback child before a watchdog continuation.

  A successful callback consumes the one-use response budget while its AWX job
  can still be running. Watchdog observation therefore accepts both `:active`
  and `:consumed` grants without changing grant state or restoring callback
  budget. Callback request consumption remains governed by `consume/5`.
  """
  @spec reauthorize_watchdog(binary(), opts()) :: {:ok, map()} | {:error, term()}
  def reauthorize_watchdog(grant_id, opts) when is_binary(grant_id) and is_list(opts) do
    reauthorize_bound(grant_id, [:active, :consumed], opts)
  end

  def reauthorize_watchdog(_grant_id, _opts),
    do: {:error, :invalid_callback_watchdog_reauthorization}

  defp reauthorize_bound(grant_id, allowed_states, opts) do
    now = now(opts)

    with {:ok, grant} <- store(opts).fetch(grant_id, store_context(opts)),
         :ok <- not_expired(grant, now),
         :ok <- bound_grant_ready(grant, allowed_states),
         {:ok, contract} <- ActionContract.fetch(value(grant, :action)),
         {:ok, current} <- current_authority(:use, grant, opts),
         :ok <- Authority.reauthorize(:use, grant, current, contract) do
      {:ok, public_result(grant, %{reauthorized: true})}
    else
      {:error, :grant_expired} -> expire_and_deny(grant_id, opts)
      {:error, reason} -> handle_valid_denial(grant_id, reason, opts)
    end
  end

  @doc "Binds a verified AWX job while callback authority remains pending."
  @spec bind_job(binary(), map(), opts()) :: {:ok, map()} | {:error, term()}
  def bind_job(grant_id, job_binding, opts)
      when is_binary(grant_id) and is_map(job_binding) and is_list(opts) do
    now = now(opts)

    with {:ok, grant} <- store(opts).fetch(grant_id, store_context(opts)),
         :ok <- not_expired(grant, now),
         {:ok, contract} <- ActionContract.fetch(value(grant, :action)),
         {:ok, binding} <- validate_job_binding(grant, job_binding),
         authorize = pending_job_binding_hook(contract, opts),
         {:ok, audit} <- Audit.attrs(:job_bound_pending, grant, %{job_id: binding["job_id"]}),
         {:ok, outcome, bound} <-
           store(opts).bind_job(
             grant_id,
             binding,
             authorize,
             audit,
             now,
             store_context(opts)
           ) do
      {:ok, public_result(bound, %{outcome: outcome, binding_pending: true})}
    else
      {:error, :grant_expired} -> expire_and_deny(grant_id, opts)
      {:error, reason} -> handle_valid_denial(grant_id, reason, opts)
    end
  end

  def bind_job(_grant_id, _job_binding, _opts), do: {:error, :invalid_job_binding}

  @doc "Rebuilds the full grant binding from immutable scope and a verified job snapshot."
  @spec job_binding_from_accepted(map(), map()) :: {:ok, map()} | {:error, term()}
  def job_binding_from_accepted(grant, accepted_snapshot)
      when is_map(grant) and is_map(accepted_snapshot) do
    scope = value(grant, :awx_scope_snapshot) || %{}
    job_id = value(accepted_snapshot, :awx_job_id)
    credential_ids = List.wrap(value(accepted_snapshot, :credential_ids))

    binding =
      scope
      |> stringify_keys()
      |> Map.put("credential_ids", credential_ids)
      |> Map.put("job_id", job_id)

    with true <-
           to_string(value(accepted_snapshot, :controller_id)) ==
             to_string(value(scope, :controller_id)) || {:error, :accepted_controller_mismatch},
         true <-
           value(accepted_snapshot, :ephemeral_credential_id) ==
             value(grant, :ephemeral_credential_id) ||
             {:error, :accepted_credentials_mismatch} do
      validate_job_binding(grant, binding)
    else
      false -> {:error, :invalid_accepted_job_binding}
      {:error, _reason} = error -> error
    end
  end

  def job_binding_from_accepted(_grant, _accepted_snapshot),
    do: {:error, :invalid_accepted_job_binding}

  @doc """
  Builds the least pending binding needed to make a just-launched AWX job
  cancel-capable before its fetched job snapshot is accepted.

  Every scope field and credential ID is reconstructed from the immutable
  grant. Only the positive controller-local job ID comes from the launch
  result; this does not activate callback authority.
  """
  @spec pending_job_binding(map(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def pending_job_binding(grant, job_id)
      when is_map(grant) and is_integer(job_id) and job_id > 0 do
    scope = value(grant, :awx_scope_snapshot) || %{}
    base_ids = List.wrap(value(scope, :credential_ids))
    ephemeral_id = value(grant, :ephemeral_credential_id)

    binding =
      scope
      |> stringify_keys()
      |> Map.put("credential_ids", base_ids ++ [ephemeral_id])
      |> Map.put("job_id", job_id)

    validate_job_binding(grant, binding)
  end

  def pending_job_binding(_grant, _job_id), do: {:error, :invalid_job_binding}

  @doc "Binds a pending grant to one verified controller-local AWX job."
  @spec activate(binary(), map(), opts()) :: {:ok, map()} | {:error, term()}
  def activate(grant_id, job_binding, opts)
      when is_binary(grant_id) and is_map(job_binding) and is_list(opts) do
    now = now(opts)

    with {:ok, grant} <- store(opts).fetch(grant_id, store_context(opts)),
         :ok <- not_expired(grant, now),
         {:ok, contract} <- ActionContract.fetch(value(grant, :action)),
         {:ok, binding} <- validate_job_binding(grant, job_binding),
         authorize = activation_hook(binding, contract, opts),
         {:ok, audit} <-
           Audit.attrs(:grant_activated, grant, %{job_id: binding["job_id"]}),
         {:ok, outcome, activated} <-
           store(opts).activate(
             grant_id,
             binding,
             authorize,
             audit,
             now,
             store_context(opts)
           ) do
      {:ok, public_result(activated, %{outcome: outcome})}
    else
      {:error, :grant_expired} -> expire_and_deny(grant_id, opts)
      {:error, reason} -> handle_valid_denial(grant_id, reason, opts)
    end
  end

  def activate(_grant_id, _job_binding, _opts), do: {:error, :invalid_activation}

  @doc "Consumes or same-key replays a callback response after current reauthorization."
  @spec consume(binary(), binary(), binary(), map(), opts()) ::
          {:ok, map()} | {:retry, map()} | {:error, term()}
  def consume(grant_id, bearer, idempotency_key, request, opts)
      when is_binary(grant_id) and is_binary(bearer) and is_binary(idempotency_key) and
             is_map(request) and is_list(opts) do
    now = now(opts)

    with {:ok, grant} <- store(opts).fetch(grant_id, store_context(opts)),
         :ok <- verify_token(bearer, grant, opts),
         :ok <- not_expired(grant, now) do
      consume_by_state(grant, idempotency_key, request, now, opts)
    else
      {:error, :invalid_callback_grant} = error ->
        audit_denial(grant_id, :invalid_callback_grant, opts)
        error

      {:error, :grant_expired} ->
        expire_and_deny(grant_id, opts)

      {:error, _} = error ->
        error
    end
  end

  def consume(_grant_id, _bearer, _idempotency_key, _request, _opts),
    do: {:error, :invalid_callback_request}

  @doc "Revokes a grant before attempting external cancellation/credential cleanup."
  @spec revoke(binary(), binary() | atom(), opts()) :: {:ok, map()} | {:error, term()}
  def revoke(grant_id, reason, opts), do: terminate(grant_id, :revoked, reason, :revoked, opts)

  @doc "Atomically records directly verified AWX cleanup selectors while revoking authority."
  @spec revoke_verified_cleanup(binary(), map(), binary() | atom(), opts()) ::
          {:ok, map()} | {:error, term()}
  def revoke_verified_cleanup(grant_id, cleanup_binding, reason, opts)
      when is_binary(grant_id) and is_map(cleanup_binding) and is_list(opts) do
    now = now(opts)
    reason = safe_reason(reason)
    adapter = store(opts)

    with true <-
           function_exported?(adapter, :transition_terminal_with_cleanup_binding, 7) ||
             {:error, :verified_cleanup_binding_unavailable},
         {:ok, grant} <- adapter.fetch(grant_id, store_context(opts)),
         {:ok, audit} <- Audit.attrs(:revoked, grant, %{reason: reason}),
         {:ok, terminal_grant} <-
           adapter.transition_terminal_with_cleanup_binding(
             grant_id,
             :revoked,
             reason,
             cleanup_binding,
             audit,
             now,
             store_context(opts)
           ),
         :ok <- run_cleanup(terminal_grant, :revoked, opts) do
      {:ok, public_result(terminal_grant)}
    else
      false -> {:error, :verified_cleanup_binding_unavailable}
      {:error, _reason} = error -> error
    end
  end

  def revoke_verified_cleanup(_grant_id, _cleanup_binding, _reason, _opts),
    do: {:error, :invalid_verified_cleanup_binding}

  @doc "Expires a grant before attempting external cancellation/credential cleanup."
  @spec expire(binary(), opts()) :: {:ok, map()} | {:error, term()}
  def expire(grant_id, opts), do: terminate(grant_id, :expired, :ttl_elapsed, :expired, opts)

  @doc "Revokes callback authority when the bound AWX child becomes terminal."
  @spec job_terminal(binary(), binary() | atom(), opts()) :: {:ok, map()} | {:error, term()}
  def job_terminal(grant_id, job_status, opts),
    do: terminate(grant_id, :revoked, {:job_terminal, job_status}, :job_terminal, opts)

  @doc """
  Queues deletion of the ephemeral AWX credential after exact job and host-scope
  proof has activated the grant. The active callback grant remains usable by
  the already-running execution environment, and this function never waits for
  the asynchronous agent-command result.
  """
  @spec delete_activated_credential(binary(), opts()) :: {:ok, map()} | {:error, term()}
  def delete_activated_credential(grant_id, opts) when is_binary(grant_id) and is_list(opts) do
    cleanup = Keyword.get(opts, :cleanup, NoopCleanup)
    context = Keyword.get(opts, :cleanup_context)

    with {:ok, grant} <- store(opts).fetch(grant_id, store_context(opts)),
         true <- value(grant, :state) == :active || {:error, :grant_not_active},
         true <- value(grant, :binding_verified) == true || {:error, :awx_binding_not_verified},
         true <-
           cleanup_exported?(cleanup, :delete_activated, 2) ||
             {:error, :activated_credential_cleanup_unavailable},
         {result, cleanup_attrs} <- activated_delete_result(cleanup, grant, context),
         :ok <- record_cleanup(grant, cleanup_attrs, opts) do
      case result do
        :ok ->
          {:ok,
           public_result(grant, %{
             cleanup_status: cleanup_attrs.cleanup_status,
             credential_status: cleanup_attrs.credential_status
           })}

        :error ->
          {:error, :callback_credential_cleanup_dispatch_failed}
      end
    else
      false -> {:error, :activated_credential_cleanup_unavailable}
      {:error, _} = error -> error
    end
  end

  def delete_activated_credential(_grant_id, _opts),
    do: {:error, :invalid_activated_credential_cleanup}

  defp prepare_draft(attrs, contract, now) do
    actor = value(attrs, :actor_snapshot) || %{}
    response_snapshot = value(attrs, :response_snapshot) || %{}
    targets = value(response_snapshot, :targets)
    awx_scope = value(attrs, :awx_scope_snapshot) || %{}

    with :ok <- required_id(value(attrs, :id), :grant_id_required),
         :ok <- required_id(value(attrs, :tenant_id), :tenant_required),
         :ok <- required_id(value(attrs, :parent_run_id), :parent_run_required),
         :ok <- required_id(value(attrs, :execution_id), :execution_required),
         true <- value(attrs, :audience) == @audience || {:error, :invalid_callback_audience},
         {:ok, expires_at} <- datetime(value(attrs, :expires_at)),
         :ok <- validate_ttl(now, expires_at, contract.max_ttl_seconds),
         true <-
           value(attrs, :budget) == contract.max_budget ||
             {:error, :invalid_callback_budget},
         {:ok, target_keys} <- Authority.target_keys(List.wrap(targets)),
         {:ok, scope_digest} <- validate_scope(awx_scope),
         {:ok, approval_digest} <- snapshot_digest(value(attrs, :approval_snapshot)),
         {:ok, policy_digest} <- snapshot_digest(value(attrs, :policy_snapshot)),
         true <-
           to_string(value(actor, :tenant_id)) == to_string(value(attrs, :tenant_id)) ||
             {:error, :actor_tenant_mismatch} do
      {:ok,
       %{
         id: value(attrs, :id),
         state: :pending,
         tenant_id: value(attrs, :tenant_id),
         parent_run_id: value(attrs, :parent_run_id),
         execution_id: value(attrs, :execution_id),
         principal_type: value(actor, :principal_type),
         principal_id: value(actor, :principal_id),
         principal_owner_id: value(actor, :owner_id),
         authorization_version: value(actor, :authorization_version),
         issuance_ceiling: value(attrs, :issuance_ceiling),
         action: contract.action,
         action_version: contract.version,
         audience: @audience,
         issued_at: now,
         expires_at: expires_at,
         budget_total: contract.max_budget,
         budget_remaining: contract.max_budget,
         target_keys: target_keys,
         scope_digest: scope_digest,
         approval_digest: approval_digest,
         policy_digest: policy_digest,
         approval_snapshot: value(attrs, :approval_snapshot),
         policy_snapshot: value(attrs, :policy_snapshot),
         policy_version: value(value(attrs, :policy_snapshot) || %{}, :version),
         awx_scope_snapshot: awx_scope,
         response_snapshot: response_snapshot,
         binding_verified: false,
         job_binding: nil,
         ephemeral_credential_id: nil,
         dispatch_agent_id: value(attrs, :dispatch_agent_id),
         dispatch_partition_id: value(attrs, :dispatch_partition_id),
         launch_envelope_ref: value(attrs, :launch_envelope_ref)
       }}
    else
      false -> {:error, :invalid_callback_grant}
      {:error, _} = error -> error
    end
  end

  defp validate_response_snapshot(draft) do
    hypothetical =
      draft
      |> Map.put(:binding_verified, true)
      |> Map.put(:job_binding, %{"job_id" => 1})

    with {:ok, request} <- SshCaBundleResponse.expected_request(hypothetical, 1),
         {:ok, _built} <- SshCaBundleResponse.build(hypothetical, request) do
      :ok
    end
  end

  defp consume_by_state(grant, idempotency_key, request, now, opts) do
    case value(grant, :state) do
      :pending ->
        with :ok <- validate_idempotency_key(idempotency_key),
             :ok <- verify_idempotency_key(idempotency_key, grant, opts),
             {:ok, request} <- SshCaBundleResponse.validate_request(request),
             {:ok, expected_request} <-
               SshCaBundleResponse.expected_request(grant, request["job_id"]),
             true <- request == expected_request || {:error, :callback_request_mismatch},
             :ok <- audit_pending(grant, opts) do
          {:retry,
           %{
             status: 409,
             code: "grant_pending",
             retryable: true,
             retry_after_seconds: 1
           }}
        else
          false -> handle_valid_denial(value(grant, :id), :callback_request_mismatch, opts)
          {:error, reason} -> handle_valid_denial(value(grant, :id), reason, opts)
        end

      state when state in [:active, :consumed] ->
        consume_active(grant, idempotency_key, request, now, opts)

      state ->
        handle_valid_denial(value(grant, :id), {:grant_not_active, state}, opts)
    end
  end

  defp consume_active(grant, idempotency_key, request, now, opts) do
    case do_consume_active(grant, idempotency_key, request, now, opts) do
      {:error, reason} -> handle_valid_denial(value(grant, :id), reason, opts)
      result -> result
    end
  end

  defp do_consume_active(grant, idempotency_key, request, now, opts) do
    with :ok <- validate_idempotency_key(idempotency_key),
         :ok <- verify_idempotency_key(idempotency_key, grant, opts),
         {:ok, built} <- SshCaBundleResponse.build(grant, request),
         {:ok, request_digest} <- CanonicalJSON.digest(request),
         {:ok, contract} <- ActionContract.fetch(value(grant, :action)),
         {:ok, idempotency} <- keyed_idempotency(idempotency_key, grant, opts),
         consume_attrs = %{
           idempotency_key_verifier: idempotency.verifier,
           idempotency_pepper_version: idempotency.key_id,
           request_digest: request_digest,
           response_digest: built.digest,
           action: value(grant, :action)
         },
         authorize = use_hook(contract, opts),
         {:ok, audit} <-
           Audit.attrs(:callback_consumed, grant, %{
             request_digest: request_digest,
             response_digest: built.digest
           }),
         {:ok, outcome, response_bytes, committed_grant} <-
           store(opts).consume_once(
             value(grant, :id),
             consume_attrs,
             built.bytes,
             authorize,
             audit,
             now,
             store_context(opts)
           ),
         true <- response_bytes == built.bytes || {:error, :committed_response_mismatch},
         :ok <- maybe_cleanup_consumed(outcome, committed_grant, opts) do
      {:ok,
       %{
         status: 200,
         content_type: "application/json",
         body: response_bytes,
         response_digest: built.digest,
         replay: outcome == :replay
       }}
    else
      false -> {:error, :committed_response_mismatch}
      {:error, _} = error -> error
    end
  end

  defp activation_hook(binding, contract, opts) do
    fn locked_grant ->
      candidate =
        locked_grant
        |> Map.put(:job_binding, binding)
        |> Map.put(:binding_verified, true)

      with {:ok, current} <- current_authority(:activate, candidate, opts) do
        Authority.reauthorize(:activate, candidate, current, contract)
      end
    end
  end

  defp credential_binding_hook(contract, opts) do
    fn locked_grant ->
      with {:ok, current} <- current_authority(:bind_credential, locked_grant, opts) do
        Authority.validate_issue(locked_grant, current, contract)
      end
    end
  end

  defp pending_job_binding_hook(contract, opts) do
    fn locked_grant ->
      with {:ok, current} <- current_authority(:bind_job, locked_grant, opts) do
        Authority.validate_issue(locked_grant, current, contract)
      end
    end
  end

  defp use_hook(contract, opts) do
    fn locked_grant ->
      with {:ok, current} <- current_authority(:use, locked_grant, opts) do
        Authority.reauthorize(:use, locked_grant, current, contract)
      end
    end
  end

  defp validate_scope(scope) when is_map(scope) do
    with {:ok, scope} <- string_map(scope),
         keys = MapSet.new(Map.keys(scope)),
         true <- MapSet.subset?(@scope_required, keys) || {:error, :incomplete_awx_scope},
         true <-
           MapSet.subset?(keys, MapSet.union(@scope_required, @scope_optional)) ||
             {:error, :unexpected_awx_scope_field},
         true <-
           (is_list(scope["targets"]) and scope["targets"] != []) ||
             {:error, :awx_targets_required},
         true <-
           scope["target_count"] == length(scope["targets"]) ||
             {:error, :awx_target_count_mismatch},
         true <- is_list(scope["credential_ids"] || []) || {:error, :invalid_credential_ids},
         true <-
           scope["ask_credential_on_launch"] == true ||
             {:error, :callback_credential_prompt_required},
         :ok <- required_id(scope["controller_id"], :controller_id_required),
         :ok <- required_id(scope["inventory_id"], :inventory_id_required),
         :ok <- required_id(scope["job_template_id"], :job_template_id_required),
         :ok <- required_id(scope["project_id"], :project_id_required),
         :ok <- required_id(scope["execution_environment_id"], :execution_environment_required),
         :ok <- required_id(scope["machine_credential_id"], :machine_credential_required),
         :ok <- required_id(scope["callback_credential_type_id"], :callback_credential_required),
         :ok <-
           required_id(
             scope["callback_credential_organization_id"],
             :callback_credential_organization_required
           ),
         true <-
           digest?(scope["callback_credential_injector_digest"], 64) ||
             {:error, :invalid_callback_injector_digest},
         true <- digest?(scope["scm_revision"], 40..64) || {:error, :invalid_scm_revision},
         true <- digest?(scope["content_sha256"], 64) || {:error, :invalid_content_digest},
         true <- digest?(scope["target_digest"], 64) || {:error, :invalid_target_digest},
         true <- digest?(scope["snapshot_digest"], 64) || {:error, :invalid_snapshot_digest},
         true <-
           (is_binary(scope["host_limit"]) and scope["host_limit"] != "") ||
             {:error, :host_limit_required},
         {:ok, digest} <- CanonicalJSON.digest(scope) do
      {:ok, digest}
    else
      false -> {:error, :invalid_awx_scope}
      {:error, _} = error -> error
    end
  end

  defp validate_scope(_scope), do: {:error, :invalid_awx_scope}

  defp validate_job_binding(grant, binding) do
    with {:ok, expected_scope} <- string_map(value(grant, :awx_scope_snapshot)),
         {:ok, binding} <- string_map(binding),
         true <-
           MapSet.new(Map.keys(binding)) ==
             MapSet.put(MapSet.new(Map.keys(expected_scope)), "job_id") ||
             {:error, :incomplete_job_binding},
         :ok <- required_id(binding["job_id"], :job_id_required),
         :ok <- exact_accepted_credentials(grant, expected_scope, binding),
         scope =
           binding
           |> Map.delete("job_id")
           |> Map.put("credential_ids", expected_scope["credential_ids"]),
         {:ok, digest} <- validate_scope(scope),
         true <-
           secure_equal(digest, value(grant, :scope_digest)) ||
             {:error, :awx_scope_mismatch} do
      {:ok, binding}
    else
      false -> {:error, :invalid_job_binding}
      {:error, _} = error -> error
    end
  end

  defp exact_accepted_credentials(grant, expected_scope, binding) do
    credential_id = value(grant, :ephemeral_credential_id)
    base = List.wrap(expected_scope["credential_ids"])
    accepted = List.wrap(binding["credential_ids"])

    cond do
      not is_integer(credential_id) or credential_id <= 0 ->
        {:error, :callback_credential_not_bound}

      Enum.uniq(base) != base or Enum.uniq(accepted) != accepted ->
        {:error, :credential_binding_mismatch}

      Enum.sort(accepted) != Enum.sort(base ++ [credential_id]) ->
        {:error, :credential_binding_mismatch}

      true ->
        :ok
    end
  end

  defp terminate(grant_id, state, reason, cleanup_mode, opts)
       when is_binary(grant_id) and is_list(opts) do
    now = now(opts)
    reason = safe_reason(reason)

    with {:ok, grant} <- store(opts).fetch(grant_id, store_context(opts)),
         {:ok, audit} <- Audit.attrs(state, grant, %{reason: reason}),
         {:ok, terminal_grant} <-
           store(opts).transition_terminal(
             grant_id,
             state,
             reason,
             audit,
             now,
             store_context(opts)
           ),
         :ok <- run_cleanup(terminal_grant, cleanup_mode, opts) do
      {:ok, public_result(terminal_grant)}
    end
  end

  defp terminate(_grant_id, _state, _reason, _cleanup_mode, _opts),
    do: {:error, :invalid_terminal_transition}

  defp expire_and_deny(grant_id, opts) do
    case expire(grant_id, opts) do
      {:ok, _grant} -> {:error, :grant_expired}
      {:error, _} = error -> error
    end
  end

  defp maybe_cleanup_consumed(:committed, grant, opts), do: run_cleanup(grant, :consumed, opts)
  defp maybe_cleanup_consumed(:replay, _grant, _opts), do: :ok

  defp run_cleanup(grant, mode, opts) do
    cleanup = Keyword.get(opts, :cleanup, NoopCleanup)
    context = Keyword.get(opts, :cleanup_context)
    safe_grant = Audit.safe_grant(grant)

    cleanup_attrs =
      case call_cleanup(cleanup, :cleanup, [safe_grant, mode, context]) do
        {:ok, attrs} when is_map(attrs) -> sanitize_cleanup(attrs, :ok)
        {:error, attrs} when is_map(attrs) -> sanitize_cleanup(attrs, :cancel_failed)
        _ -> cleanup_dispatch_failure(mode, grant)
      end

    record_cleanup(grant, cleanup_attrs, opts)
  end

  defp activated_delete_result(cleanup, grant, context) do
    safe_grant = Audit.safe_grant(grant)

    case call_cleanup(cleanup, :delete_activated, [safe_grant, context]) do
      {:ok, attrs} when is_map(attrs) ->
        {:ok, sanitize_cleanup(attrs, :ok)}

      {:error, attrs} when is_map(attrs) ->
        {:error, sanitize_cleanup(attrs, :delete_failed)}

      _ ->
        {:error,
         %{
           cleanup_status: :failed,
           cancel_status: :not_required,
           credential_status: :delete_failed
         }}
    end
  end

  defp cleanup_exported?(cleanup, function, arity) when is_atom(cleanup),
    do: Code.ensure_loaded?(cleanup) and function_exported?(cleanup, function, arity)

  defp cleanup_exported?(_cleanup, _function, _arity), do: false

  defp call_cleanup(cleanup, function, args) do
    apply(cleanup, function, args)
  rescue
    _exception -> :cleanup_dispatch_failed
  catch
    _kind, _reason -> :cleanup_dispatch_failed
  end

  defp cleanup_dispatch_failure(mode, grant) do
    %{
      cleanup_status: :failed,
      cancel_status:
        case mode do
          :consumed ->
            :not_required

          :job_terminal ->
            if exact_terminal_job_binding?(grant), do: :cancel_confirmed, else: :cancel_failed

          _mode ->
            :cancel_failed
        end,
      credential_status: :delete_failed
    }
  end

  defp exact_terminal_job_binding?(grant) do
    scope = value(grant, :awx_scope_snapshot)
    binding = value(grant, :job_binding)
    controller_id = value(scope, :controller_id)
    bound_controller_id = value(binding, :controller_id)
    job_id = value(binding, :job_id)

    controller_id not in [nil, ""] and bound_controller_id not in [nil, ""] and
      to_string(controller_id) == to_string(bound_controller_id) and
      is_integer(job_id) and job_id > 0 and job_id <= 2_147_483_647
  end

  defp record_cleanup(grant, cleanup_attrs, opts) do
    adapter = store(opts)

    if function_exported?(adapter, :record_cleanup, 4) do
      with {:ok, audit} <-
             Audit.attrs(:grant_cleanup, grant, %{
               cleanup_status: cleanup_attrs.cleanup_status,
               cancel_status: cleanup_attrs.cancel_status,
               credential_status: cleanup_attrs.credential_status
             }) do
        adapter.record_cleanup(value(grant, :id), cleanup_attrs, audit, store_context(opts))
      end
    else
      :ok
    end
  end

  defp sanitize_cleanup(attrs, fallback) do
    %{
      cleanup_status: value(attrs, :cleanup_status) || fallback,
      cancel_status: value(attrs, :job_cleanup) || value(attrs, :cancel_status) || :unknown,
      credential_status:
        value(attrs, :credential_cleanup) || value(attrs, :credential_status) || :unknown
    }
  end

  defp verify_token(bearer, grant, opts) do
    verifier = Keyword.get(opts, :verifier, HMACKeyedVerifier)
    Token.verify(bearer, grant, verifier, Keyword.fetch!(opts, :verifier_config))
  end

  defp issue_token(opts) do
    verifier = Keyword.get(opts, :verifier, HMACKeyedVerifier)
    Token.issue(verifier, Keyword.fetch!(opts, :verifier_config), opts)
  end

  defp issue_idempotency_key(opts) do
    verifier = Keyword.get(opts, :verifier, HMACKeyedVerifier)
    Token.issue_idempotency_key(verifier, Keyword.fetch!(opts, :verifier_config), opts)
  end

  defp verify_idempotency_key(idempotency_key, grant, opts) do
    verifier = Keyword.get(opts, :verifier, HMACKeyedVerifier)

    Token.verify_idempotency_key(
      idempotency_key,
      grant,
      verifier,
      Keyword.fetch!(opts, :verifier_config)
    )
  end

  defp current_authority(stage, grant, opts) do
    authorizer = Keyword.fetch!(opts, :authorizer)

    authorizer.current_authority(
      stage,
      Audit.authorization_grant(grant),
      Keyword.get(opts, :authority_context)
    )
  end

  defp audit_denial(grant_id, reason, opts) do
    adapter = store(opts)

    if function_exported?(adapter, :record_audit, 2) do
      case adapter.fetch(grant_id, store_context(opts)) do
        {:ok, grant} ->
          with {:ok, audit} <-
                 Audit.attrs(:callback_denied, grant, %{reason: safe_reason(reason)}) do
            adapter.record_audit(audit, store_context(opts))
          end

        {:error, :grant_not_found} ->
          :ok

        {:error, _} = error ->
          error
      end
    else
      {:error, :callback_audit_unavailable}
    end
  end

  defp audit_pending(grant, opts) do
    adapter = store(opts)

    if function_exported?(adapter, :record_audit, 2) do
      with {:ok, audit} <-
             Audit.attrs(:callback_pending, grant, %{
               reason: "grant_pending",
               retryable: true
             }) do
        adapter.record_audit(audit, store_context(opts))
      end
    else
      {:error, :callback_audit_unavailable}
    end
  end

  defp handle_valid_denial(grant_id, reason, opts) do
    if authority_contraction?(reason) do
      revoke_authority_contraction(grant_id, reason, opts)
    else
      case audit_denial(grant_id, reason, opts) do
        :ok -> {:error, reason}
        {:error, audit_reason} -> {:error, {:denial_audit_failed, audit_reason}}
      end
    end
  end

  defp revoke_authority_contraction(grant_id, reason, opts) do
    with {:ok, _grant} <- terminate(grant_id, :revoked, reason, :revoked, opts),
         :ok <- audit_denial(grant_id, reason, opts) do
      {:error, reason}
    end
  end

  defp authority_contraction?(reason)
       when reason in [
              :principal_disabled,
              :principal_changed,
              :tenant_changed,
              :service_principal_owner_changed,
              :system_actor_has_no_authority,
              :current_permission_denied,
              :action_no_longer_authorized,
              :target_no_longer_authorized,
              :approval_changed,
              :target_policy_changed,
              :awx_binding_changed,
              :run_not_active,
              :job_not_active,
              :job_binding_changed,
              :awx_binding_not_verified
            ],
       do: true

  defp authority_contraction?(_reason), do: false

  defp pending_result(grant) do
    %{
      id: value(grant, :id),
      state: :pending,
      action: value(grant, :action),
      expires_at: value(grant, :expires_at),
      retryable: true
    }
  end

  defp public_result(grant, extra \\ %{}) do
    binding = value(grant, :job_binding) || %{}

    Map.merge(
      %{
        id: value(grant, :id),
        state: value(grant, :state),
        action: value(grant, :action),
        expires_at: value(grant, :expires_at),
        job_id: value(binding, :job_id)
      },
      extra
    )
  end

  defp validate_ttl(now, expires_at, maximum_seconds) do
    seconds = DateTime.diff(expires_at, now, :second)
    if seconds in 1..maximum_seconds, do: :ok, else: {:error, :invalid_callback_ttl}
  end

  defp not_expired(grant, now) do
    case datetime(value(grant, :expires_at)) do
      {:ok, expires_at} ->
        if DateTime.after?(expires_at, now), do: :ok, else: {:error, :grant_expired}

      _ ->
        {:error, :grant_expired}
    end
  end

  defp launch_dispatch_ready(grant) do
    cond do
      value(grant, :state) != :pending ->
        {:error, {:grant_not_active, value(grant, :state)}}

      not (is_integer(value(grant, :ephemeral_credential_id)) and
               value(grant, :ephemeral_credential_id) > 0) ->
        {:error, :callback_credential_not_bound}

      value(grant, :credential_cleanup_state) != :pending ->
        {:error, :callback_credential_unavailable}

      value(grant, :binding_verified) == true or not is_nil(value(grant, :job_binding)) ->
        {:error, :job_binding_conflict}

      true ->
        :ok
    end
  end

  defp credential_creation_ready(grant) do
    cond do
      value(grant, :state) != :pending ->
        {:error, {:grant_not_active, value(grant, :state)}}

      not is_nil(value(grant, :ephemeral_credential_id)) ->
        {:error, :callback_credential_already_bound}

      value(grant, :credential_cleanup_state) not in [nil, :pending] ->
        {:error, :callback_credential_unavailable}

      value(grant, :binding_verified) == true or not is_nil(value(grant, :job_binding)) ->
        {:error, :job_binding_conflict}

      true ->
        :ok
    end
  end

  defp pending_bound_grant_ready(grant) do
    binding = value(grant, :job_binding)
    job_id = value(binding || %{}, :job_id)

    cond do
      value(grant, :state) != :pending ->
        {:error, {:grant_not_active, value(grant, :state)}}

      value(grant, :binding_verified) == true ->
        {:error, :job_binding_conflict}

      not is_map(binding) or not (is_integer(job_id) and job_id > 0) ->
        {:error, :job_binding_required}

      true ->
        :ok
    end
  end

  defp bound_grant_ready(grant, allowed_states) do
    cond do
      value(grant, :state) not in allowed_states ->
        {:error, {:grant_not_active, value(grant, :state)}}

      value(grant, :binding_verified) != true or not is_map(value(grant, :job_binding)) ->
        {:error, :awx_binding_not_verified}

      true ->
        :ok
    end
  end

  defp validate_idempotency_key(key) when is_binary(key) and byte_size(key) in 32..128 do
    if Regex.match?(~r/\A[A-Za-z0-9._~-]+\z/, key),
      do: :ok,
      else: {:error, :invalid_idempotency_key}
  end

  defp validate_idempotency_key(_key), do: {:error, :invalid_idempotency_key}

  defp keyed_idempotency(idempotency_key, grant, opts) do
    verifier = Keyword.get(opts, :verifier, HMACKeyedVerifier)
    key_id = value(grant, :idempotency_verifier_key_id)
    material = "serviceradar-callback-idempotency-v1\0" <> idempotency_key

    with {:ok, digest} <-
           verifier.digest(key_id, material, Keyword.fetch!(opts, :verifier_config)) do
      {:ok, %{key_id: key_id, verifier: digest}}
    end
  end

  defp snapshot_digest(snapshot) when is_map(snapshot) and map_size(snapshot) > 0,
    do: CanonicalJSON.digest(snapshot)

  defp snapshot_digest(_snapshot), do: {:error, :authorization_snapshot_required}

  defp datetime(%DateTime{} = value), do: {:ok, value}
  defp datetime(_value), do: {:error, :invalid_expiry}

  defp required_id(value, _reason) when is_binary(value) and value != "", do: :ok
  defp required_id(value, _reason) when is_integer(value) and value > 0, do: :ok
  defp required_id(_value, reason), do: {:error, reason}

  defp string_map(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      cond do
        not is_binary(key) -> {:halt, {:error, :map_keys_must_be_strings}}
        Map.has_key?(acc, key) -> {:halt, {:error, {:duplicate_map_key, key}}}
        true -> {:cont, {:ok, Map.put(acc, key, value)}}
      end
    end)
  end

  defp string_map(_map), do: {:error, :object_required}

  defp digest?(value, length) when is_integer(length),
    do: is_binary(value) and byte_size(value) == length and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp digest?(value, %Range{} = range),
    do: is_binary(value) and byte_size(value) in range and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp secure_equal(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal(_left, _right), do: false

  defp now(opts), do: Keyword.get(opts, :now, DateTime.utc_now())
  defp store(opts), do: Keyword.fetch!(opts, :store)
  defp store_context(opts), do: Keyword.get(opts, :store_context)

  defp safe_reason({:grant_not_active, state}) when state in @grant_states,
    do: "grant_not_active:#{state}"

  defp safe_reason({:job_terminal, status}) when status in @terminal_job_states,
    do: "job_terminal:#{status}"

  defp safe_reason(reason), do: SafeFailureEvidence.code(reason)

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_map, _key), do: nil

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), stringify_keys(item)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
