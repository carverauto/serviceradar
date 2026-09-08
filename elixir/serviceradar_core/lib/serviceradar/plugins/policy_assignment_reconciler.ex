defmodule ServiceRadar.Plugins.PolicyAssignmentReconciler do
  @moduledoc """
  Reconciles policy-derived plugin assignments from SRQL inputs.

  This module resolves inputs server-side, plans deterministic chunked
  assignments, upserts desired rows by `source_key`, and disables stale policy
  assignments for the same `policy_id`.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Plugins.PolicyAssignmentPlanner
  alias ServiceRadar.Plugins.SRQLInputResolver

  require Ash.Query

  @type reconcile_result :: %{
          resolved_inputs: non_neg_integer(),
          desired_assignments: non_neg_integer(),
          upserted: non_neg_integer(),
          unchanged: non_neg_integer(),
          disabled: non_neg_integer()
        }

  @type assignment_store :: module()

  @callback list_policy_assignments(String.t(), map(), keyword()) ::
              {:ok, [map()]} | {:error, term()}
  @callback create_assignment(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback update_assignment(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  @callback disable_assignment(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback find_enabled_assignment(String.t(), String.t(), String.t(), map()) ::
              {:ok, map() | nil} | {:error, term()}

  @spec reconcile(map(), [map()], keyword()) :: {:ok, reconcile_result()} | {:error, [String.t()]}
  def reconcile(policy, input_defs, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:plugin_target_policy_reconciler))
    resolver = Keyword.get(opts, :resolver, SRQLInputResolver)
    planner = Keyword.get(opts, :planner, PolicyAssignmentPlanner)
    store = Keyword.get(opts, :store, __MODULE__.AshStore)
    partition_resolver = Keyword.get(opts, :partition_resolver, &authenticated_partition/1)

    agent_scope = normalize_agent_scope(Keyword.get(opts, :agent_scope))

    with {:ok, expected_partition_id} <- expected_partition_id(opts),
         {:ok, resolved_inputs} <- resolver.resolve(input_defs, opts),
         {:ok, %{assignments: desired}} <- planner.plan(policy, resolved_inputs, opts),
         {:ok, desired} <-
           bind_desired_partitions(desired, partition_resolver, expected_partition_id),
         {:ok, policy_id} <- policy_id(policy),
         {:ok, existing} <-
           store.list_policy_assignments(policy_id, actor, partition_id: expected_partition_id),
         {:ok, stats} <-
           apply_plan(desired, existing, actor, store, agent_scope, expected_partition_id) do
      {:ok,
       %{
         resolved_inputs: length(resolved_inputs),
         desired_assignments: length(desired),
         upserted: stats.upserted,
         unchanged: stats.unchanged,
         disabled: stats.disabled
       }}
    else
      {:error, errors} when is_list(errors) -> {:error, errors}
      {:error, reason} -> {:error, [inspect(reason)]}
    end
  end

  # Recovery passes the mTLS partition observed immediately before its guarded
  # transaction. Re-resolve the partition here rather than trusting that
  # preflight value; if the live session changed, do not hand a spec to an
  # assignment store. The caller's transaction then also rolls back a change
  # that occurs after this resolution but before its postflight check.
  defp bind_desired_partitions(desired, resolver, expected_partition_id)
       when is_list(desired) and is_function(resolver, 1) do
    desired
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, acc} ->
      case resolver.(spec.agent_uid) do
        {:ok, partition_id} when is_binary(partition_id) ->
          partition_id = String.trim(partition_id)

          cond do
            partition_id == "" ->
              {:halt, {:error, :authenticated_agent_partition_unavailable}}

            is_binary(expected_partition_id) and partition_id != expected_partition_id ->
              {:halt, {:error, :authenticated_agent_partition_changed}}

            true ->
              {:cont, {:ok, [Map.put(spec, :partition_id, partition_id) | acc]}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}

        _other ->
          {:halt, {:error, :authenticated_agent_partition_unavailable}}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, Enum.reverse(specs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bind_desired_partitions(_desired, _resolver, _expected_partition_id),
    do: {:error, :authenticated_agent_partition_unavailable}

  defp expected_partition_id(opts) do
    case Keyword.get(opts, :expected_partition_id) do
      nil ->
        {:ok, nil}

      partition_id when is_binary(partition_id) ->
        partition_id = String.trim(partition_id)

        if partition_id == "" do
          {:error, :authenticated_agent_partition_unavailable}
        else
          {:ok, partition_id}
        end

      _other ->
        {:error, :authenticated_agent_partition_unavailable}
    end
  end

  defp authenticated_partition(agent_id) do
    case AgentCommandBus.resolve_control_session_evidence(agent_id) do
      {:ok, %{agent_id: ^agent_id, partition_id: partition_id}}
      when is_binary(partition_id) and partition_id != "" ->
        {:ok, String.trim(partition_id)}

      {:ok, _evidence} ->
        {:error, :authenticated_agent_partition_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp policy_id(policy) when is_map(policy) do
    policy_id = Map.get(policy, :policy_id) || Map.get(policy, "policy_id")

    if is_binary(policy_id) and String.trim(policy_id) != "" do
      {:ok, policy_id}
    else
      {:error, ["missing required policy field: policy_id"]}
    end
  end

  defp apply_plan(desired_specs, existing_rows, actor, store, agent_scope, partition_scope) do
    desired_by_key = Map.new(desired_specs, &{{&1.partition_id, &1.assignment_key}, &1})

    existing_by_key =
      existing_rows
      |> Enum.filter(&is_binary(&1.source_key))
      # The assignment store applies this filter at query time. Keep this
      # in-memory filter as a fail-closed backstop for injected stores: a
      # recovery that authenticated `farm01` must not update or retract a row
      # for the same agent UID in `tonka01`.
      |> scope_existing_partition(partition_scope)
      |> Map.new(&{{&1.partition_id, &1.source_key}, &1})

    # In a per-agent reconcile (agent_scope set), retraction is restricted to
    # the reconciled agent(s): existing rows owned by OTHER agents must be left
    # enabled — a single-agent desired set would otherwise disable the whole
    # fleet's assignments. A full reconcile (agent_scope == nil) retracts across
    # every agent.
    stale_candidates = scope_existing(existing_by_key, agent_scope)

    with {:ok, upsert_stats} <- upsert_desired(desired_by_key, existing_by_key, actor, store),
         {:ok, disabled_count} <- disable_stale(desired_by_key, stale_candidates, actor, store) do
      {:ok,
       %{
         upserted: upsert_stats.upserted,
         unchanged: upsert_stats.unchanged,
         disabled: disabled_count
       }}
    end
  end

  defp upsert_desired(desired_by_key, existing_by_key, actor, store) do
    Enum.reduce_while(desired_by_key, {:ok, %{upserted: 0, unchanged: 0}}, fn {key, spec},
                                                                              {:ok, stats} ->
      existing = Map.get(existing_by_key, key)
      upsert_one(spec, existing, stats, actor, store)
    end)
  end

  defp disable_stale(desired_by_key, existing_by_key, actor, store) do
    existing_by_key
    |> Enum.reject(fn {key, _} -> Map.has_key?(desired_by_key, key) end)
    |> Enum.reduce_while({:ok, 0}, fn {_key, assignment}, {:ok, count} ->
      disable_one(assignment, count, actor, store)
    end)
  end

  # nil => full sweep across all agents; a list of agent_uids => restrict
  # retraction to those agents only.
  defp normalize_agent_scope(nil), do: nil

  defp normalize_agent_scope(scope) when is_list(scope) do
    scope
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalize_agent_scope(scope) when is_binary(scope), do: normalize_agent_scope([scope])

  defp scope_existing(existing_by_key, nil), do: existing_by_key

  defp scope_existing(existing_by_key, %MapSet{} = scope) do
    Map.filter(existing_by_key, fn {_key, assignment} ->
      MapSet.member?(scope, to_string(assignment.agent_uid))
    end)
  end

  # `expected_partition_id` is only supplied by the recovery path after a
  # fresh mTLS evidence lookup. Normal reconciliation retains its existing
  # cross-partition behavior by passing `nil` here.
  defp scope_existing_partition(rows, nil), do: rows

  defp scope_existing_partition(rows, partition_id) when is_binary(partition_id) do
    Enum.filter(rows, &(&1.partition_id == partition_id))
  end

  defp upsert_one(spec, nil, stats, actor, store) do
    case store.create_assignment(spec, actor) do
      {:ok, _} ->
        {:cont, {:ok, %{stats | upserted: stats.upserted + 1}}}

      {:error, reason} ->
        if duplicate_enabled_assignment?(reason) do
          adopt_existing_assignment(spec, stats, actor, store, reason)
        else
          {:halt, {:error, reason}}
        end
    end
  end

  defp upsert_one(spec, existing, stats, actor, store) do
    if assignment_matches_spec?(existing, spec) do
      {:cont, {:ok, %{stats | unchanged: stats.unchanged + 1}}}
    else
      case store.update_assignment(existing, spec, actor) do
        {:ok, _} -> {:cont, {:ok, %{stats | upserted: stats.upserted + 1}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end
  end

  # Converge instead of duplicating. The plugin is already enabled for this
  # agent under a drifted assignment — an older policy_id/source_key whose row
  # `list_policy_assignments/3` no longer matches for the current policy. Adopt
  # that single row (update it to the desired policy spec) so there is exactly
  # one enabled assignment per (agent, package), owned by the current rule. This
  # is the golden path: no orphaned enabled rows are left behind, and the next
  # reconcile is a clean matching no-op.
  defp adopt_existing_assignment(spec, stats, actor, store, create_reason) do
    case store.find_enabled_assignment(
           spec.partition_id,
           spec.agent_uid,
           spec.plugin_package_id,
           actor
         ) do
      {:ok, nil} ->
        {:halt, {:error, create_reason}}

      {:ok, existing} ->
        case store.update_assignment(existing, spec, actor) do
          {:ok, _} -> {:cont, {:ok, %{stats | upserted: stats.upserted + 1}}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp duplicate_enabled_assignment?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &duplicate_enabled_assignment?/1)
  end

  defp duplicate_enabled_assignment?(%Ash.Error.Changes.InvalidAttribute{
         field: :plugin_package_id,
         message: message
       }) do
    is_binary(message) and String.contains?(message, "already enabled")
  end

  defp duplicate_enabled_assignment?(_), do: false

  defp disable_one(assignment, count, _actor, _store) when not assignment.enabled do
    {:cont, {:ok, count}}
  end

  defp disable_one(assignment, count, actor, store) do
    case store.disable_assignment(assignment, actor) do
      {:ok, _} -> {:cont, {:ok, count + 1}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp assignment_matches_spec?(existing, spec) do
    existing.partition_id == spec.partition_id and
      existing.enabled == spec.enabled and
      existing.interval_seconds == spec.interval_seconds and
      existing.timeout_seconds == spec.timeout_seconds and
      existing.plugin_package_id == spec.plugin_package_id and
      existing.source == :policy and
      existing.source_key == spec.assignment_key and
      existing.policy_id == spec.metadata["policy_id"] and
      params_equivalent?(existing.params, spec.params)
  end

  # Every reconcile regenerates the assignment params with fresh, per-generation
  # values: a `generated_at` timestamp and a re-minted credential-broker grant
  # (grant_id / expires_at / issued_at). A naive `existing.params == spec.params`
  # is therefore never true for a credentialed assignment, so the row is
  # rewritten every reconcile cycle (~60s), which re-delivers the plugin config
  # and RESTARTS the plugin on the agent — a proxmox/AWX/camera inventory run
  # that takes longer than the reconcile interval could never finish (observed:
  # only the first node batch emitting, then `module closed with context
  # canceled`, forever).
  #
  # Compare params with those volatile, per-generation fields stripped (at any
  # depth) so only a real change (secret, purpose, targets, schedule, package)
  # rewrites the assignment. The stable fields (secret_id, grant_type, purpose,
  # base_url, allow-lists, inputs) still participate, and the config-generation
  # layer re-stamps a fresh generated_at / grant at delivery time regardless of
  # what is stored here.
  @volatile_param_keys ~w(
    generated_at grant_id expires_at issued_at not_before
    issued_at_unix expires_at_unix
  )

  defp params_equivalent?(a, b), do: strip_volatile_params(a) == strip_volatile_params(b)

  defp strip_volatile_params(%{} = map) do
    map
    |> Map.drop(@volatile_param_keys)
    |> Map.new(fn {key, value} -> {key, strip_volatile_params(value)} end)
  end

  defp strip_volatile_params(list) when is_list(list),
    do: Enum.map(list, &strip_volatile_params/1)

  defp strip_volatile_params(other), do: other

  defmodule AshStore do
    @moduledoc false
    @behaviour ServiceRadar.Plugins.PolicyAssignmentReconciler

    alias ServiceRadar.Plugins.PluginAssignment
    alias ServiceRadar.Plugins.PluginPackage
    alias ServiceRadar.Repo

    require Ash.Query

    @impl true
    def list_policy_assignments(policy_id, actor, opts) do
      query =
        PluginAssignment
        |> Ash.Query.for_read(:all_partitions_for_policy, %{policy_id: policy_id}, actor: actor)
        |> Ash.Query.filter(source == :policy)
        |> maybe_scope_partition(Keyword.get(opts, :partition_id))

      Ash.read(query, actor: actor)
    end

    @impl true
    def create_assignment(spec, actor) do
      params = %{
        agent_uid: spec.agent_uid,
        plugin_package_id: spec.plugin_package_id,
        source: :policy,
        source_key: spec.assignment_key,
        policy_id: spec.metadata["policy_id"],
        enabled: spec.enabled,
        interval_seconds: spec.interval_seconds,
        timeout_seconds: spec.timeout_seconds,
        params: spec.params
      }

      fn ->
        case PluginAssignment
             |> Ash.Changeset.for_create(:create, params)
             |> Ash.create(actor: actor, authorize?: true) do
          {:ok, %{partition_id: partition_id} = assignment}
          when partition_id == spec.partition_id ->
            assignment

          {:ok, _assignment} ->
            Repo.rollback(:authenticated_agent_partition_changed)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end
      |> Repo.transaction()
      |> case do
        {:ok, assignment} -> disable_manual_duplicate({:ok, assignment}, spec, actor)
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def update_assignment(existing, spec, actor) do
      params = %{
        source: :policy,
        source_key: spec.assignment_key,
        policy_id: spec.metadata["policy_id"],
        plugin_package_id: spec.plugin_package_id,
        enabled: spec.enabled,
        interval_seconds: spec.interval_seconds,
        timeout_seconds: spec.timeout_seconds,
        params: spec.params
      }

      existing
      |> Ash.Changeset.for_update(:update, params)
      |> Ash.update(actor: actor, authorize?: true)
      |> disable_manual_duplicate(spec, actor)
    end

    @impl true
    def disable_assignment(assignment, actor) do
      assignment
      |> Ash.Changeset.for_update(:update, %{enabled: false})
      |> Ash.update(actor: actor, authorize?: true)
    end

    @impl true
    def find_enabled_assignment(partition_id, agent_uid, plugin_package_id, actor) do
      with {:ok, plugin_id} <- plugin_id_for_package(plugin_package_id, actor) do
        PluginAssignment
        |> Ash.Query.for_read(
          :by_edge_principal,
          %{agent_uid: agent_uid, partition_id: partition_id},
          actor: actor
        )
        |> Ash.Query.filter(plugin_id == ^plugin_id and enabled == true)
        |> Ash.read(actor: actor)
        |> case do
          {:ok, [assignment | _]} -> {:ok, assignment}
          {:ok, []} -> {:ok, nil}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    defp disable_manual_duplicate({:ok, assignment}, spec, actor) do
      _ =
        spec
        |> manual_duplicates(actor)
        |> case do
          {:ok, manual_assignments} ->
            Enum.each(manual_assignments, fn manual_assignment ->
              _ = disable_assignment(manual_assignment, actor)
            end)

          {:error, _reason} ->
            :ok
        end

      {:ok, assignment}
    end

    defp disable_manual_duplicate(result, _spec, _actor), do: result

    defp manual_duplicates(spec, actor) do
      with {:ok, plugin_id} <- plugin_id_for_package(spec.plugin_package_id, actor) do
        PluginAssignment
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(
          source == :manual and enabled == true and partition_id == ^spec.partition_id and
            agent_uid == ^spec.agent_uid and
            plugin_id == ^plugin_id
        )
        |> Ash.read(actor: actor)
      end
    end

    defp plugin_id_for_package(package_id, actor) do
      PluginPackage
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^package_id)
      |> Ash.read_one(actor: actor)
      |> case do
        {:ok, %PluginPackage{plugin_id: plugin_id}} when is_binary(plugin_id) -> {:ok, plugin_id}
        {:ok, nil} -> {:error, :plugin_package_not_found}
        {:error, reason} -> {:error, reason}
      end
    end

    defp maybe_scope_partition(query, nil), do: query

    defp maybe_scope_partition(query, partition_id) when is_binary(partition_id) do
      Ash.Query.filter(query, partition_id == ^partition_id)
    end
  end
end
