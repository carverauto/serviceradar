defmodule ServiceRadar.Plugins.AddonProfileReconciler do
  @moduledoc """
  Reconciles add-on profile target queries into profile-owned assignments.

  The reconciler executes a profile's SRQL query, extracts target agent IDs from
  the result rows, and materializes deterministic `AddonAssignment` rows with
  `source: :profile`.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.SRQLInputResolver
  alias ServiceRadar.Plugins.ValueUtils

  require Ash.Query

  @type reconcile_result :: %{
          matched_rows: non_neg_integer(),
          target_agents: non_neg_integer(),
          desired_assignments: non_neg_integer(),
          skipped_without_agent: non_neg_integer(),
          skipped_manual_overrides: non_neg_integer(),
          upserted: non_neg_integer(),
          unchanged: non_neg_integer(),
          disabled: non_neg_integer()
        }

  @callback list_profile_assignments(String.t(), map()) :: {:ok, [map()]} | {:error, term()}
  @callback list_manual_assignments(String.t(), [String.t()], map()) ::
              {:ok, [map()]} | {:error, term()}
  @callback create_assignment(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback update_assignment(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  @callback disable_assignment(map(), map()) :: {:ok, map()} | {:error, term()}

  @spec preview(map(), keyword()) :: {:ok, map()} | {:error, [String.t()]}
  def preview(profile, opts \\ []) when is_map(profile) do
    with {:ok, resolved_inputs} <- resolve_profile(profile, opts),
         {:ok, planned} <- plan(profile, resolved_inputs, opts) do
      sample_limit = Keyword.get(opts, :sample_limit, 10)

      {:ok,
       %{
         profile_id: profile_id(profile),
         summary: Map.delete(planned.summary, :assignments),
         sample_assignments: Enum.take(planned.assignments, sample_limit)
       }}
    end
  end

  @spec reconcile(map(), keyword()) :: {:ok, reconcile_result()} | {:error, [String.t()]}
  def reconcile(profile, opts \\ []) when is_map(profile) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:addon_profile_reconciler))
    store = Keyword.get(opts, :store, __MODULE__.AshStore)

    with {:ok, resolved_inputs} <- resolve_profile(profile, opts),
         {:ok, planned} <- plan(profile, resolved_inputs, opts),
         {:ok, id} <- required_profile_id(profile),
         {:ok, existing} <- store.list_profile_assignments(id, actor),
         {:ok, stats} <- apply_plan(planned.assignments, existing, actor, store) do
      {:ok, Map.merge(Map.delete(planned.summary, :assignments), stats)}
    else
      {:error, errors} when is_list(errors) -> {:error, errors}
      {:error, reason} -> {:error, [inspect(reason)]}
    end
  end

  defp resolve_profile(profile, opts) do
    resolver = Keyword.get(opts, :resolver, SRQLInputResolver)

    input_defs = [
      %{
        name: "targets",
        entity: target_entity(profile),
        query: target_query(profile)
      }
    ]

    resolver.resolve(input_defs, opts)
  end

  defp plan(profile, resolved_inputs, opts) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:addon_profile_reconciler))
    store = Keyword.get(opts, :store, __MODULE__.AshStore)
    now = Keyword.get(opts, :reconciled_at, DateTime.utc_now())

    with {:ok, normalized} <- normalize_profile(profile),
         {:ok, targets} <- extract_targets(resolved_inputs, normalized.max_targets),
         {:ok, manual_assignments} <-
           store.list_manual_assignments(normalized.addon_id, targets.agent_uids, actor) do
      manual_agent_uids = MapSet.new(manual_assignments, & &1.agent_uid)

      assignments =
        targets.agent_uids
        |> Enum.reject(&MapSet.member?(manual_agent_uids, &1))
        |> Enum.map(&assignment_spec(normalized, &1, now))

      {:ok,
       %{
         assignments: assignments,
         summary: %{
           matched_rows: targets.matched_rows,
           target_agents: length(targets.agent_uids),
           desired_assignments: length(assignments),
           skipped_without_agent: targets.skipped_without_agent,
           skipped_manual_overrides: MapSet.size(manual_agent_uids),
           assignments: assignments
         }
       }}
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
    Enum.reduce_while(desired_by_key, {:ok, %{upserted: 0, unchanged: 0}}, fn {_key, spec},
                                                                              {:ok, stats} ->
      existing = Map.get(existing_by_key, spec.assignment_key)

      cond do
        is_nil(existing) ->
          case store.create_assignment(spec, actor) do
            {:ok, _} -> {:cont, {:ok, %{stats | upserted: stats.upserted + 1}}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        assignment_matches_spec?(existing, spec) ->
          {:cont, {:ok, %{stats | unchanged: stats.unchanged + 1}}}

        true ->
          case store.update_assignment(existing, spec, actor) do
            {:ok, _} -> {:cont, {:ok, %{stats | upserted: stats.upserted + 1}}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp disable_stale(desired_by_key, existing_by_key, actor, store) do
    existing_by_key
    |> Enum.reject(fn {key, _} -> Map.has_key?(desired_by_key, key) end)
    |> Enum.reduce_while({:ok, 0}, fn {_key, assignment}, {:ok, count} ->
      if assignment.enabled == false do
        {:cont, {:ok, count}}
      else
        case store.disable_assignment(assignment, actor) do
          {:ok, _} -> {:cont, {:ok, count + 1}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp assignment_matches_spec?(existing, spec) do
    existing.enabled == spec.enabled and
      existing.addon_package_id == spec.addon_package_id and
      existing.source == :profile and
      existing.source_key == spec.assignment_key and
      existing.addon_profile_id == spec.addon_profile_id and
      existing.params == spec.params and
      existing.args == spec.args
  end

  defp extract_targets(resolved_inputs, max_targets) do
    rows =
      resolved_inputs
      |> Enum.flat_map(fn input ->
        entity = ValueUtils.string_value(input, [:entity, "entity"]) || "devices"

        input
        |> ValueUtils.list_value([:rows, "rows"])
        |> List.wrap()
        |> Enum.map(&{entity, &1})
      end)

    {agent_uids, skipped_without_agent} =
      rows
      |> Enum.reduce({[], 0}, fn {entity, row}, {uids, skipped} ->
        case agent_uid_for_row(entity, row) do
          nil -> {uids, skipped + 1}
          uid -> {[uid | uids], skipped}
        end
      end)

    unique_agent_uids =
      agent_uids
      |> Enum.reverse()
      |> Enum.uniq()
      |> Enum.take(max_targets)

    {:ok,
     %{
       matched_rows: length(rows),
       agent_uids: unique_agent_uids,
       skipped_without_agent: skipped_without_agent
     }}
  end

  defp agent_uid_for_row("agents", row) do
    ValueUtils.string_value(row, [:agent_uid, "agent_uid", :agent_id, "agent_id", :uid, "uid"])
  end

  defp agent_uid_for_row(_entity, row) do
    ValueUtils.string_value(row, [:agent_uid, "agent_uid", :agent_id, "agent_id"])
  end

  defp assignment_spec(profile, agent_uid, reconciled_at) do
    key = assignment_key(profile.profile_id, profile.addon_id, agent_uid)

    %{
      assignment_key: key,
      agent_uid: agent_uid,
      addon_id: profile.addon_id,
      addon_package_id: profile.addon_package_id,
      addon_profile_id: profile.profile_id,
      enabled: profile.enabled,
      params: profile.params,
      args: profile.args,
      profile_reconcile_status: "matched",
      profile_reconcile_error: nil,
      profile_last_reconciled_at: reconciled_at,
      profile_metadata: %{
        "profile_id" => profile.profile_id,
        "profile_name" => profile.name,
        "priority" => profile.priority,
        "target_query" => profile.target_query
      }
    }
  end

  defp normalize_profile(profile) do
    with {:ok, profile_id} <- required_profile_id(profile),
         {:ok, addon_id} <- required_string(profile, [:addon_id, "addon_id"], "addon_id"),
         {:ok, addon_package_id} <-
           required_value(profile, [:addon_package_id, "addon_package_id"], "addon_package_id"),
         {:ok, query} <- required_string(profile, [:target_query, "target_query"], "target_query") do
      {:ok,
       %{
         profile_id: profile_id,
         name: ValueUtils.string_value(profile, [:name, "name"]) || profile_id,
         addon_id: addon_id,
         addon_package_id: addon_package_id,
         target_query: query,
         params: ValueUtils.map_value(profile, [:params, "params"]) || %{},
         args: ValueUtils.list_value(profile, [:args, "args"]) || [],
         priority: ValueUtils.int_value(profile, [:priority, "priority"], 100),
         max_targets: ValueUtils.int_value(profile, [:max_targets, "max_targets"], 10_000),
         enabled: ValueUtils.bool_value(profile, [:enabled, "enabled"], true)
       }}
    end
  end

  defp required_profile_id(profile), do: required_string(profile, [:id, "id"], "id")

  defp required_value(map, keys, label) do
    case Enum.find_value(keys, &Map.get(map, &1)) do
      nil -> {:error, ["missing required add-on profile field: #{label}"]}
      value -> {:ok, value}
    end
  end

  defp required_string(map, keys, label) do
    case ValueUtils.string_value(map, keys) do
      nil -> {:error, ["missing required add-on profile field: #{label}"]}
      "" -> {:error, ["missing required add-on profile field: #{label}"]}
      value -> {:ok, value}
    end
  end

  defp target_query(profile), do: ValueUtils.string_value(profile, [:target_query, "target_query"]) || ""

  defp target_entity(profile) do
    case Regex.run(~r/^\s*in:([a-zA-Z0-9_]+)/, target_query(profile)) do
      [_, entity] -> ValueUtils.normalize_entity(entity)
      _ -> "devices"
    end
  end

  defp profile_id(profile), do: ValueUtils.string_value(profile, [:id, "id"])

  defp assignment_key(profile_id, addon_id, agent_uid) do
    %{profile_id: profile_id, addon_id: addon_id, agent_uid: agent_uid}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defmodule AshStore do
    @moduledoc false
    @behaviour ServiceRadar.Plugins.AddonProfileReconciler

    alias ServiceRadar.Plugins.AddonAssignment

    require Ash.Query

    @impl true
    def list_profile_assignments(profile_id, actor) do
      AddonAssignment
      |> Ash.Query.for_read(:by_profile, %{addon_profile_id: profile_id}, actor: actor)
      |> Ash.read(actor: actor)
    end

    @impl true
    def list_manual_assignments(_addon_id, [], _actor), do: {:ok, []}

    def list_manual_assignments(addon_id, agent_uids, actor) do
      AddonAssignment
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(
        source == :manual and enabled == true and addon_id == ^addon_id and agent_uid in ^agent_uids
      )
      |> Ash.read(actor: actor)
    end

    @impl true
    def create_assignment(spec, actor) do
      AddonAssignment
      |> Ash.Changeset.for_create(:create, spec_to_attrs(spec))
      |> Ash.create(actor: actor, authorize?: true)
    end

    @impl true
    def update_assignment(existing, spec, actor) do
      existing
      |> Ash.Changeset.for_update(:update, spec_to_attrs(spec))
      |> Ash.update(actor: actor, authorize?: true)
    end

    @impl true
    def disable_assignment(assignment, actor) do
      assignment
      |> Ash.Changeset.for_update(:update, %{
        enabled: false,
        profile_reconcile_status: "stale",
        profile_last_reconciled_at: DateTime.utc_now()
      })
      |> Ash.update(actor: actor, authorize?: true)
    end

    defp spec_to_attrs(spec) do
      %{
        agent_uid: spec.agent_uid,
        addon_package_id: spec.addon_package_id,
        source: :profile,
        source_key: spec.assignment_key,
        addon_profile_id: spec.addon_profile_id,
        enabled: spec.enabled,
        params: spec.params,
        args: spec.args,
        profile_reconcile_status: spec.profile_reconcile_status,
        profile_reconcile_error: spec.profile_reconcile_error,
        profile_last_reconciled_at: spec.profile_last_reconciled_at,
        profile_metadata: spec.profile_metadata
      }
    end
  end
end
