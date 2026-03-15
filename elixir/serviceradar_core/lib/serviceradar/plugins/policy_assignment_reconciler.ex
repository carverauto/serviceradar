defmodule ServiceRadar.Plugins.PolicyAssignmentReconciler do
  @moduledoc """
  Reconciles policy-derived plugin assignments from SRQL inputs.

  This module resolves inputs server-side, plans deterministic chunked
  assignments, upserts desired rows by `source_key`, and disables stale policy
  assignments for the same `policy_id`.
  """

  alias ServiceRadar.Actors.SystemActor
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

  @callback list_policy_assignments(String.t(), map()) :: {:ok, [map()]} | {:error, term()}
  @callback create_assignment(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback update_assignment(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  @callback disable_assignment(map(), map()) :: {:ok, map()} | {:error, term()}

  @spec reconcile(map(), [map()], keyword()) :: {:ok, reconcile_result()} | {:error, [String.t()]}
  def reconcile(policy, input_defs, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:plugin_target_policy_reconciler))
    resolver = Keyword.get(opts, :resolver, SRQLInputResolver)
    planner = Keyword.get(opts, :planner, PolicyAssignmentPlanner)
    store = Keyword.get(opts, :store, __MODULE__.AshStore)

    with {:ok, resolved_inputs} <- resolver.resolve(input_defs, opts),
         {:ok, %{assignments: desired}} <- planner.plan(policy, resolved_inputs, opts),
         {:ok, policy_id} <- policy_id(policy),
         {:ok, existing} <- store.list_policy_assignments(policy_id, actor),
         {:ok, stats} <- apply_plan(desired, existing, actor, store) do
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

  defp policy_id(policy) when is_map(policy) do
    policy_id = Map.get(policy, :policy_id) || Map.get(policy, "policy_id")

    if is_binary(policy_id) and String.trim(policy_id) != "" do
      {:ok, policy_id}
    else
      {:error, ["missing required policy field: policy_id"]}
    end
  end

  defp apply_plan(desired_specs, existing_rows, actor, store) do
    desired_by_key = Map.new(desired_specs, &{&1.assignment_key, &1})

    existing_by_key =
      existing_rows
      |> Enum.filter(&is_binary(&1.source_key))
      |> Map.new(&{&1.source_key, &1})

    with {:ok, upsert_stats} <- upsert_desired(desired_by_key, existing_by_key, actor, store),
         {:ok, disabled_count} <- disable_stale(desired_by_key, existing_by_key, actor, store) do
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

  defp upsert_one(spec, nil, stats, actor, store) do
    case store.create_assignment(spec, actor) do
      {:ok, _} -> {:cont, {:ok, %{stats | upserted: stats.upserted + 1}}}
      {:error, reason} -> {:halt, {:error, reason}}
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
    existing.enabled == spec.enabled and
      existing.interval_seconds == spec.interval_seconds and
      existing.timeout_seconds == spec.timeout_seconds and
      existing.plugin_package_id == spec.plugin_package_id and
      existing.source == :policy and
      existing.source_key == spec.assignment_key and
      existing.policy_id == spec.metadata["policy_id"] and
      existing.params == spec.params
  end

  defmodule AshStore do
    @moduledoc false
    @behaviour ServiceRadar.Plugins.PolicyAssignmentReconciler

    alias ServiceRadar.Plugins.PluginAssignment

    require Ash.Query

    @impl true
    def list_policy_assignments(policy_id, actor) do
      PluginAssignment
      |> Ash.Query.for_read(:by_policy, %{policy_id: policy_id}, actor: actor)
      |> Ash.Query.filter(source == :policy)
      |> Ash.read(actor: actor)
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

      PluginAssignment
      |> Ash.Changeset.for_create(:create, params)
      |> Ash.create(actor: actor, authorize?: true)
    end

    @impl true
    def update_assignment(existing, spec, actor) do
      params = %{
        source: :policy,
        source_key: spec.assignment_key,
        policy_id: spec.metadata["policy_id"],
        enabled: spec.enabled,
        interval_seconds: spec.interval_seconds,
        timeout_seconds: spec.timeout_seconds,
        params: spec.params
      }

      existing
      |> Ash.Changeset.for_update(:update, params)
      |> Ash.update(actor: actor, authorize?: true)
    end

    @impl true
    def disable_assignment(assignment, actor) do
      assignment
      |> Ash.Changeset.for_update(:update, %{enabled: false})
      |> Ash.update(actor: actor, authorize?: true)
    end
  end
end
