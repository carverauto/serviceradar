defmodule ServiceRadar.Plugins.AddonProfileReconciler do
  @moduledoc """
  Reconciles add-on profile target queries into profile-owned assignments.

  The reconciler executes a profile's SRQL query, extracts target agent IDs from
  the result rows, loads authoritative agent compatibility metadata, and
  materializes deterministic `AddonAssignment` rows with `source: :profile`.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonRolloutEligibility, as: Eligibility
  alias ServiceRadar.Plugins.MapUtils
  alias ServiceRadar.Plugins.SRQLInputResolver
  alias ServiceRadar.Plugins.ValueUtils

  require Ash.Query

  @seasonal_baselines_key "seasonal_baselines"

  @type reconcile_result :: %{
          matched_rows: non_neg_integer(),
          resolved_devices: non_neg_integer(),
          resolved_agents: non_neg_integer(),
          target_agents: non_neg_integer(),
          eligible_agents: non_neg_integer(),
          desired_assignments: non_neg_integer(),
          skipped_without_agent: non_neg_integer(),
          skipped_manual_overrides: non_neg_integer(),
          skipped_targets: [map()],
          skip_counts: map(),
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
         {:ok, targets} <- attach_agent_compatibility(targets, opts, actor),
         {:ok, eligibility} <- evaluate_target_eligibility(normalized, targets.targets),
         {:ok, manual_assignments} <-
           store.list_manual_assignments(normalized.addon_id, eligibility.agent_uids, actor) do
      manual_agent_uids = MapSet.new(manual_assignments, & &1.agent_uid)

      manual_skips =
        eligibility.targets
        |> Enum.filter(&MapSet.member?(manual_agent_uids, &1.agent_uid))
        |> Enum.map(&skip_target(&1, "manual_override", "manual add-on assignment exists"))

      assignments =
        eligibility.agent_uids
        |> Enum.reject(&MapSet.member?(manual_agent_uids, &1))
        |> Enum.map(&assignment_spec(normalized, &1, now))

      skipped_targets = targets.skipped_targets ++ eligibility.skipped_targets ++ manual_skips

      {:ok,
       %{
         assignments: assignments,
         summary: %{
           matched_rows: targets.matched_rows,
           resolved_devices: targets.resolved_devices,
           resolved_agents: targets.resolved_agents,
           target_agents: length(targets.agent_uids),
           eligible_agents: length(assignments),
           desired_assignments: length(assignments),
           skipped_without_agent: targets.skipped_without_agent,
           skipped_manual_overrides: MapSet.size(manual_agent_uids),
           skipped_targets: skipped_targets,
           skip_counts: skip_counts(skipped_targets),
           target_samples: targets.targets |> Enum.take(20) |> Enum.map(&target_report/1),
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
          spec = %{spec | params: assignment_params_for_spec(existing, spec.params)}

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
      if assignment.enabled == false or not is_nil(Map.get(assignment, :rollout_id)) do
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
      existing.params == assignment_params_for_spec(existing, spec.params) and
      existing.args == spec.args
  end

  # Edge seasonal baselines are profile-wide for host metrics but assignment-
  # scoped for interface metrics. Preserve the scoped 3-segment interface keys
  # that `EdgeBaselineProducer` writes onto an assignment, while still applying
  # the profile's current params and letting profile-owned baselines override.
  defp assignment_params_for_spec(existing, spec_params) do
    existing_params = ValueUtils.map_value(existing, [:params, "params"]) || %{}
    spec_params = spec_params || %{}

    existing_scoped =
      existing_params
      |> seasonal_baselines()
      |> Enum.filter(fn {key, _value} -> interface_baseline_key?(key) end)
      |> Map.new()

    spec_seasonal = seasonal_baselines(spec_params)
    merged_seasonal = Map.merge(existing_scoped, spec_seasonal)

    cond do
      map_size(merged_seasonal) > 0 ->
        Map.put(spec_params, @seasonal_baselines_key, merged_seasonal)

      Map.has_key?(stringify_keys(spec_params), @seasonal_baselines_key) ->
        Map.put(spec_params, @seasonal_baselines_key, %{})

      true ->
        spec_params
    end
  end

  defp seasonal_baselines(params) when is_map(params) do
    case Map.get(params, @seasonal_baselines_key) || Map.get(params, :seasonal_baselines) do
      baselines when is_map(baselines) -> baselines
      _ -> %{}
    end
  end

  defp seasonal_baselines(_params), do: %{}

  defp interface_baseline_key?(key) when is_binary(key) do
    key |> String.split("|") |> length() >= 3
  end

  defp interface_baseline_key?(_key), do: false

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp extract_targets(resolved_inputs, max_targets) do
    rows =
      Enum.flat_map(resolved_inputs, fn input ->
        entity = ValueUtils.string_value(input, [:entity, "entity"]) || "devices"

        input
        |> ValueUtils.list_value([:rows, "rows"])
        |> List.wrap()
        |> Enum.map(&{entity, &1})
      end)

    {targets, skipped_targets} =
      rows
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {{entity, row}, index}, {target_acc, skipped_acc} ->
        case agent_uid_for_row(entity, row) do
          nil ->
            skip =
              skip_target(
                %{entity: entity, row: row, row_index: index},
                "no_enrolled_agent",
                "target row has no enrolled agent"
              )

            {target_acc, [skip | skipped_acc]}

          uid ->
            target = %{
              entity: entity,
              row: row,
              row_index: index,
              agent_uid: uid,
              device_uid: device_uid_for_row(entity, row)
            }

            {[target | target_acc], skipped_acc}
        end
      end)

    targets =
      targets
      |> Enum.reverse()
      |> unique_targets()
      |> Enum.take(max_targets)

    unique_agent_uids =
      targets
      |> Enum.map(& &1.agent_uid)
      |> Enum.uniq()

    skipped_targets = Enum.reverse(skipped_targets)

    {:ok,
     %{
       matched_rows: length(rows),
       agent_uids: unique_agent_uids,
       targets: targets,
       resolved_devices: count_entity(targets, "devices"),
       resolved_agents: count_entity(targets, "agents"),
       skipped_without_agent: length(skipped_targets),
       skipped_targets: skipped_targets
     }}
  end

  defp attach_agent_compatibility(targets, opts, actor) do
    loader = Keyword.get(opts, :agent_loader, __MODULE__.AshAgentLoader)

    case loader.load(targets.agent_uids, actor) do
      {:ok, agents} when is_list(agents) ->
        agents_by_uid =
          Enum.reduce(agents, %{}, fn agent, acc ->
            case ValueUtils.string_value(agent, [:uid, "uid", :agent_uid, "agent_uid"]) do
              nil -> acc
              uid -> Map.put(acc, uid, agent)
            end
          end)

        enriched_targets =
          Enum.map(targets.targets, fn target ->
            Map.put(target, :compatibility_row, Map.get(agents_by_uid, target.agent_uid))
          end)

        unresolved_count = Enum.count(enriched_targets, &is_nil(&1.compatibility_row))

        {:ok,
         %{
           targets
           | targets: enriched_targets,
             skipped_without_agent: targets.skipped_without_agent + unresolved_count
         }}

      {:error, reason} ->
        {:error, ["failed to load target agent compatibility: #{inspect(reason)}"]}

      other ->
        {:error, ["invalid target agent compatibility result: #{inspect(other)}"]}
    end
  end

  defp agent_uid_for_row("agents", row) do
    ValueUtils.string_value(row, [:agent_uid, "agent_uid", :agent_id, "agent_id", :uid, "uid"])
  end

  defp agent_uid_for_row(_entity, row) do
    ValueUtils.string_value(row, [:agent_uid, "agent_uid", :agent_id, "agent_id"])
  end

  defp device_uid_for_row("devices", row), do: ValueUtils.string_value(row, [:uid, "uid"])
  defp device_uid_for_row(_entity, _row), do: nil

  defp unique_targets(targets) do
    {_seen, unique} =
      Enum.reduce(targets, {MapSet.new(), []}, fn target, {seen, acc} ->
        if MapSet.member?(seen, target.agent_uid) do
          {seen, acc}
        else
          {MapSet.put(seen, target.agent_uid), [target | acc]}
        end
      end)

    Enum.reverse(unique)
  end

  defp count_entity(targets, entity), do: Enum.count(targets, &(&1.entity == entity))

  defp evaluate_target_eligibility(profile, targets) do
    {eligible, skipped} =
      Enum.reduce(targets, {[], []}, fn target, {eligible_acc, skipped_acc} ->
        case target_skip(profile, target) do
          nil -> {[target | eligible_acc], skipped_acc}
          {reason, detail} -> {eligible_acc, [skip_target(target, reason, detail) | skipped_acc]}
        end
      end)

    eligible = Enum.reverse(eligible)

    {:ok,
     %{
       targets: eligible,
       agent_uids: Enum.map(eligible, & &1.agent_uid),
       skipped_targets: Enum.reverse(skipped)
     }}
  end

  defp target_skip(profile, target) do
    compatibility_row = target.compatibility_row
    missing_agent_capabilities = missing_required_agent_capabilities(profile, compatibility_row)

    cond do
      profile.enabled == false ->
        {"disabled_package_config", "profile is disabled"}

      package_revoked_or_unapproved?(profile) ->
        {"revoked_or_unapproved_package", "add-on package is not approved"}

      is_nil(compatibility_row) ->
        {"no_enrolled_agent", "referenced agent is not enrolled"}

      unsupported_platform?(profile, compatibility_row) ->
        {"unsupported_platform", "target platform has no package artifact"}

      incompatible_base_agent_version?(profile, compatibility_row) ->
        {"incompatible_base_agent_version",
         "target base agent version does not satisfy package requirement"}

      missing_agent_capabilities != [] ->
        {"missing_required_capability",
         "target is missing package-required agent capabilities: #{Enum.join(missing_agent_capabilities, ", ")}"}

      not Eligibility.hostable_addon?(package_supervision(profile), compatibility_row) ->
        {"cannot_host_native_addons",
         "target does not accept native add-on assignments (containerized agent)"}

      true ->
        nil
    end
  end

  defp package_revoked_or_unapproved?(profile) do
    case package_status(profile) do
      nil -> false
      "approved" -> false
      :approved -> false
      _ -> true
    end
  end

  defp package_status(profile) do
    package = profile_package(profile)

    ValueUtils.raw_value(profile, [:package_status, "package_status", :status, "status"]) ||
      if is_map(package), do: ValueUtils.raw_value(package, [:status, "status"])
  end

  defp unsupported_platform?(profile, row) do
    artifacts = package_artifacts(profile)
    supported_os = package_platforms(profile)
    target_os = target_os(row)
    target_platform = target_platform(row)

    cond do
      supported_os != [] and (is_nil(target_os) or target_os not in supported_os) ->
        true

      map_size(artifacts) > 0 and
          (is_nil(target_platform) or not Map.has_key?(artifacts, target_platform)) ->
        true

      true ->
        false
    end
  end

  defp package_platforms(profile) do
    profile
    |> package_requires()
    |> ValueUtils.list_value([:platforms, "platforms"])
    |> List.wrap()
    |> Enum.map(&normalize_platform_component/1)
    |> Enum.reject(&is_nil/1)
  end

  defp target_os(row) do
    row
    |> nested_string([
      [:os],
      ["os"],
      [:platform_os],
      ["platform_os"],
      [:metadata, :os],
      [:metadata, "os"],
      ["metadata", :os],
      ["metadata", "os"]
    ])
    |> normalize_platform_component()
  end

  defp target_platform(row) do
    os = target_os(row)

    arch =
      row
      |> nested_string([
        [:arch],
        ["arch"],
        [:platform_arch],
        ["platform_arch"],
        [:metadata, :arch],
        [:metadata, "arch"],
        ["metadata", :arch],
        ["metadata", "arch"]
      ])
      |> normalize_platform_component()

    if os && arch, do: "#{os}/#{arch}"
  end

  defp normalize_platform_component(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_platform_component(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_platform_component()

  defp normalize_platform_component(_value), do: nil

  defp incompatible_base_agent_version?(profile, row) do
    case base_agent_requirement(profile) do
      nil ->
        false

      requirement ->
        version = target_agent_version(row)
        not version_matches_requirement?(version, requirement)
    end
  end

  defp base_agent_requirement(profile) do
    requires = package_requires(profile)

    ValueUtils.string_value(requires, [
      :base_agent,
      "base_agent",
      :baseAgent,
      "baseAgent",
      :base_agent_version,
      "base_agent_version"
    ])
  end

  defp target_agent_version(row) do
    nested_string(row, [
      [:base_agent_version],
      ["base_agent_version"],
      [:agent_version],
      ["agent_version"],
      [:version],
      ["version"],
      [:metadata, :base_agent_version],
      [:metadata, "base_agent_version"],
      ["metadata", :base_agent_version],
      ["metadata", "base_agent_version"],
      [:metadata, :agent_version],
      [:metadata, "agent_version"],
      ["metadata", :agent_version],
      ["metadata", "agent_version"],
      [:metadata, :version],
      [:metadata, "version"],
      ["metadata", :version],
      ["metadata", "version"]
    ])
  end

  defp version_matches_requirement?(version, requirement)
       when is_binary(version) and is_binary(requirement) do
    with {:ok, parsed_version} <- parse_version(version),
         {:ok, parsed_requirement} <- Version.parse_requirement(requirement) do
      Version.match?(parsed_version, parsed_requirement)
    else
      _ -> false
    end
  end

  defp version_matches_requirement?(_, _), do: false

  defp parse_version(version) do
    version
    |> String.trim()
    |> String.trim_leading("v")
    |> Version.parse()
    |> case do
      {:ok, parsed} -> {:ok, parsed}
      :error -> :error
    end
  end

  defp missing_required_agent_capabilities(profile, row) do
    actual = row |> target_agent_capabilities() |> MapSet.new()

    profile
    |> required_agent_capabilities()
    |> Enum.reject(&MapSet.member?(actual, &1))
  end

  defp required_agent_capabilities(profile) do
    requires = package_requires(profile)

    direct = ValueUtils.list_value(requires, [:agent_capabilities, "agent_capabilities"]) || []

    Enum.map(direct, &to_string/1)
  end

  defp target_agent_capabilities(row) when is_map(row) do
    row
    |> nested_list([
      [:capabilities],
      ["capabilities"],
      [:metadata, :capabilities],
      [:metadata, "capabilities"],
      ["metadata", :capabilities],
      ["metadata", "capabilities"]
    ])
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp target_agent_capabilities(_row), do: []

  defp package_artifacts(profile) do
    profile
    |> profile_package()
    |> case do
      package when is_map(package) ->
        ValueUtils.map_value(package, [:artifacts, "artifacts"]) || %{}

      _ ->
        ValueUtils.map_value(profile, [:artifacts, "artifacts"]) || %{}
    end
  end

  defp package_supervision(profile) do
    profile
    |> profile_package()
    |> case do
      package when is_map(package) ->
        ValueUtils.string_value(package, [:supervision, "supervision"])

      _ ->
        ValueUtils.string_value(profile, [:supervision, "supervision"])
    end
  end

  defp package_requires(profile) do
    profile
    |> profile_package()
    |> case do
      package when is_map(package) ->
        ValueUtils.map_value(package, [:requires, "requires"]) || %{}

      _ ->
        ValueUtils.map_value(profile, [:requires, "requires"]) || %{}
    end
  end

  defp profile_package(profile) do
    ValueUtils.map_value(profile, [
      :addon_package,
      "addon_package",
      :package,
      "package"
    ])
  end

  defp nested_string(map, paths) do
    Enum.find_value(paths, fn path ->
      case nested_value(map, path) do
        nil -> nil
        value when is_binary(value) -> String.trim(value)
        value when is_atom(value) -> Atom.to_string(value)
        value when is_integer(value) -> Integer.to_string(value)
        _ -> nil
      end
    end)
  end

  defp nested_list(map, paths) do
    Enum.find_value(paths, fn path ->
      case nested_value(map, path) do
        value when is_list(value) -> value
        _ -> nil
      end
    end)
  end

  defp nested_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.reduce_while(keys, map, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp skip_target(target, reason, detail) do
    %{
      reason: reason,
      detail: detail,
      entity: Map.get(target, :entity),
      row_index: Map.get(target, :row_index),
      agent_uid: Map.get(target, :agent_uid),
      device_uid:
        Map.get(target, :device_uid) ||
          device_uid_for_row(Map.get(target, :entity), Map.get(target, :row, %{})),
      row: target_row_report(Map.get(target, :row, %{}))
    }
  end

  defp target_report(target) do
    %{
      entity: target.entity,
      row_index: target.row_index,
      agent_uid: target.agent_uid,
      device_uid: target.device_uid,
      row: target_row_report(target.row)
    }
  end

  defp target_row_report(row) do
    keys = [
      "uid",
      "agent_id",
      "agent_uid",
      "hostname",
      "name",
      "os",
      "arch",
      "version",
      "agent_version",
      "base_agent_version",
      "status",
      "control_stream_status"
    ]

    row
    |> MapUtils.stringify_keys_or_empty()
    |> Map.take(keys)
  end

  defp skip_counts(skipped_targets) do
    skipped_targets
    |> Enum.map(& &1.reason)
    |> Enum.frequencies()
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
           required_value(profile, [:addon_package_id, "addon_package_id"], "addon_package_id") do
      query = target_query(profile)

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
         enabled: ValueUtils.bool_value(profile, [:enabled, "enabled"], true),
         package_status: ValueUtils.raw_value(profile, [:package_status, "package_status"]),
         addon_package: profile_package(profile),
         artifacts: ValueUtils.map_value(profile, [:artifacts, "artifacts"]) || %{},
         requires: ValueUtils.map_value(profile, [:requires, "requires"]) || %{}
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

  defp target_query(profile) do
    case ValueUtils.string_value(profile, [:target_query, "target_query"]) do
      # Default to the `agents` entity: the reconciler materializes one assignment
      # per enrolled agent, and the `agents` projection has a usable `uid` for
      # every enrolled agent. `in:devices` only carries a denormalized `agent_id`
      # on the subset of device rows that have one, silently dropping the rest as
      # `no_enrolled_agent`.
      nil -> "in:agents"
      "" -> "in:agents"
      query -> query
    end
  end

  defp target_entity(profile) do
    case Regex.run(~r/^\s*in:([a-zA-Z0-9_]+)/, target_query(profile)) do
      [_, entity] -> ValueUtils.normalize_entity(entity)
      _ -> "agents"
    end
  end

  defp profile_id(profile), do: ValueUtils.string_value(profile, [:id, "id"])

  defp assignment_key(profile_id, addon_id, agent_uid) do
    %{profile_id: profile_id, addon_id: addon_id, agent_uid: agent_uid}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defmodule AshAgentLoader do
    @moduledoc false

    alias ServiceRadar.Infrastructure.Agent

    require Ash.Query

    def load([], _actor), do: {:ok, []}

    def load(agent_uids, actor) do
      Agent
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(uid in ^agent_uids)
      |> Ash.read(actor: actor)
    end
  end

  defmodule AshStore do
    @moduledoc false
    @behaviour ServiceRadar.Plugins.AddonProfileReconciler

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
        source == :manual and enabled == true and addon_id == ^addon_id and
          agent_uid in ^agent_uids
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
      # agent_uid is create-only identity on AddonAssignment (the existing row is
      # already matched by assignment_key, which includes agent_uid); the :update
      # action rejects it (NoSuchInput), so drop it from the update changeset.
      attrs = Map.delete(spec_to_attrs(spec), :agent_uid)

      existing
      |> Ash.Changeset.for_update(:update, attrs)
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
