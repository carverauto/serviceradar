defmodule ServiceRadarWebNG.Plugins.PluginFleet do
  @moduledoc """
  Safe WASM assignment and current runtime evidence.

  `rows/1` returns one row per owner of a plugin on a partition and agent
  (the `in:plugin_fleet` SRQL entity).
  Success/failure timestamps describe the latest result, not a history scan.
  Neither assignment parameters nor raw result messages/payloads are returned.

  `summaries/2` is keyed by logical plugin (`plugin_id`): one summary per
  plugin, paginated on the server, for the Installed plugins view.
  """

  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginStateContract
  alias ServiceRadar.Observability.ServiceStateRegistry.StatusNormalizer
  alias ServiceRadar.Plugins.AssignmentOwner
  alias ServiceRadar.Plugins.LatestApprovedPluginPackage
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PluginTargetPolicy

  require Ash.Query

  @default_page_size 50
  @max_page_size 200

  @summary_package_fields [
    :plugin_id,
    :name,
    :version,
    :status,
    :content_hash,
    :runtime,
    :outputs,
    :manifest,
    :approved_capabilities,
    :approved_at,
    :imported_at,
    :inserted_at
  ]

  @summary_assignment_fields [
    :agent_uid,
    :partition_id,
    :plugin_id,
    :plugin_package_id,
    :rollout_plugin_package_id,
    :enabled,
    :source,
    :policy_id,
    :update_policy,
    :interval_seconds,
    :timeout_seconds,
    :updated_at
  ]

  def rows(scope) do
    assignments =
      PluginAssignment
      |> Ash.Query.for_read(:read)
      |> Ash.Query.select([
        :agent_uid,
        :partition_id,
        :plugin_id,
        :plugin_package_id,
        :rollout_plugin_package_id,
        :enabled,
        :source,
        :policy_id,
        :interval_seconds,
        :timeout_seconds,
        :updated_at
      ])
      |> Ash.read!(scope: scope)

    packages =
      PluginPackage
      |> Ash.Query.for_read(:read)
      |> Ash.Query.select([
        :plugin_id,
        :name,
        :version,
        :status,
        :content_hash,
        :runtime,
        :outputs,
        :manifest,
        :approved_capabilities
      ])
      |> Ash.read!(scope: scope)

    states =
      ServiceState
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(service_type == "plugin")
      |> Ash.read!(scope: scope)

    build_rows(assignments, packages, states, DateTime.utc_now())
  end

  @doc false
  def build_rows(assignments, packages, states, now) do
    packages_by_id = Map.new(packages, &{&1.id, &1})
    states_by_agent = Enum.group_by(states, &{&1.partition, &1.agent_id})

    assignments =
      assignments
      |> Enum.reject(&is_nil(&1.partition_id))
      |> Enum.group_by(&{&1.partition_id, &1.agent_uid, &1.plugin_id})
      |> Enum.flat_map(fn {_key, group} -> desired_assignments(group) end)

    names =
      packages
      |> Enum.group_by(& &1.name)
      |> Map.new(fn {name, group} -> {name, MapSet.new(group, & &1.plugin_id)} end)

    enabled_ids =
      assignments
      |> Enum.filter(& &1.enabled)
      |> Enum.group_by(&{&1.partition_id, &1.agent_uid, &1.plugin_id}, & &1.id)

    assigned =
      Enum.map(assignments, fn assignment ->
        # The package the agent runs: a rollout candidate while one holds the
        # assignment, so its results are not mistaken for version drift.
        package = Map.get(packages_by_id, PluginAssignment.effective_package_id(assignment))

        state =
          states_by_agent
          |> Map.get({assignment.partition_id, assignment.agent_uid}, [])
          |> Enum.filter(&matches_package?(&1, package, names))
          |> assignment_state(assignment, package)

        # Owners of one plugin on an agent shared a service state before
        # each assignment got its own result identity (#6006), so a legacy
        # result another owner's assignment reported is not drift for this
        # one.
        siblings =
          enabled_ids
          |> Map.get({assignment.partition_id, assignment.agent_uid, assignment.plugin_id}, [])
          |> List.delete(assignment.id)

        row(assignment, package, state, now, siblings)
      end)

    keys = MapSet.new(assignments, &{&1.partition_id, &1.agent_uid, &1.plugin_id})

    observed_only =
      states
      |> Enum.filter(fn state ->
        id = PluginStateContract.state_plugin_id(state)
        is_binary(id) and not MapSet.member?(keys, {state.partition, state.agent_id, id})
      end)
      |> Enum.group_by(&{&1.partition, &1.agent_id, PluginStateContract.state_plugin_id(&1)})
      |> Enum.map(fn {_key, group} -> row(nil, nil, winner(group), now, []) end)

    assigned ++ observed_only
  end

  # One agent's assignments of one plugin: the newest enabled assignment of each
  # owner (owners of different credential rules coexist, see AssignmentOwner),
  # or the newest disabled one when none is enabled.
  defp desired_assignments(group) do
    [newest | rest] =
      Enum.sort_by(
        group,
        &{&1.enabled, DateTime.to_unix(&1.updated_at, :microsecond), &1.id},
        :desc
      )

    rest
    |> Enum.reduce([newest], fn assignment, kept ->
      if assignment.enabled and
           not Enum.any?(kept, &AssignmentOwner.conflict?(&1.policy_id, assignment.policy_id)),
         do: [assignment | kept],
         else: kept
    end)
    |> Enum.reverse()
  end

  @doc """
  One summary per logical plugin, a page at a time.

  Every plugin with at least one imported package is listed, sorted by name and
  then `plugin_id`. Only the page's plugins, their packages, assignments and
  target policies, and the plugin service states of their agents are read, so
  the cost of a page does not grow with the number of plugins.

  Options: `:page` (1-based, clamped to the last page) and `:page_size`
  (default #{@default_page_size}, at most #{@max_page_size}).
  """
  @spec summaries(term(), keyword()) :: %{
          entries: [map()],
          total: non_neg_integer(),
          page: pos_integer(),
          page_size: pos_integer()
        }
  def summaries(scope, opts \\ []) do
    page_size = opts |> Keyword.get(:page_size, @default_page_size) |> clamp(1, @max_page_size)

    plugins_query =
      Plugin
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(exists(packages, true))

    total = Ash.count!(plugins_query, scope: scope)
    page = opts |> Keyword.get(:page, 1) |> clamp(1, max(div(total + page_size - 1, page_size), 1))

    plugins =
      plugins_query
      |> Ash.Query.select([:plugin_id, :name])
      |> Ash.Query.sort(name: :asc, plugin_id: :asc)
      |> Ash.Query.offset((page - 1) * page_size)
      |> Ash.Query.limit(page_size)
      |> Ash.read!(scope: scope)

    %{entries: page_entries(plugins, scope), total: total, page: page, page_size: page_size}
  end

  defp page_entries([], _scope), do: []

  defp page_entries(plugins, scope) do
    plugin_ids = Enum.map(plugins, & &1.plugin_id)

    packages =
      PluginPackage
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(plugin_id in ^plugin_ids)
      |> Ash.Query.select(@summary_package_fields)
      |> Ash.read!(scope: scope)

    assignments =
      PluginAssignment
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(plugin_id in ^plugin_ids)
      |> Ash.Query.select(@summary_assignment_fields)
      |> Ash.read!(scope: scope)

    fleet_rows = page_fleet_rows(plugin_ids, packages, assignments, scope)

    build_summaries(plugins, packages, assignments, target_policies(assignments, scope), fleet_rows)
  end

  # Runtime evidence for the page's assignments. Packages of other plugins that
  # share a display name are included only so legacy name-only evidence stays
  # ambiguous exactly as it is in `rows/1`.
  defp page_fleet_rows(plugin_ids, packages, assignments, scope) do
    agent_uids = assignments |> Enum.map(& &1.agent_uid) |> Enum.uniq()
    names = packages |> Enum.map(& &1.name) |> Enum.uniq()

    states =
      if agent_uids == [] do
        []
      else
        ServiceState
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(service_type == "plugin" and agent_id in ^agent_uids)
        |> Ash.read!(scope: scope)
      end

    same_name_packages =
      PluginPackage
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(name in ^names)
      |> Ash.Query.select([:plugin_id, :name])
      |> Ash.read!(scope: scope)

    # The page's fully loaded packages come last so they win the id lookup.
    build_rows(assignments, same_name_packages ++ packages, states, DateTime.utc_now())
  end

  defp target_policies(assignments, scope) do
    policy_ids =
      assignments
      |> Enum.flat_map(fn assignment ->
        with {:policy, id} <- AssignmentOwner.owner(assignment.policy_id),
             {:ok, uuid} <- Ecto.UUID.cast(id) do
          [uuid]
        else
          _ -> []
        end
      end)
      |> Enum.uniq()

    if policy_ids == [] do
      []
    else
      PluginTargetPolicy
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id in ^policy_ids)
      |> Ash.Query.select([:id, :name, :update_policy])
      |> Ash.read!(scope: scope)
    end
  end

  @doc false
  def build_summaries(plugins, packages, assignments, target_policies, fleet_rows) do
    packages_by_plugin = Enum.group_by(packages, & &1.plugin_id)
    packages_by_id = Map.new(packages, &{&1.id, &1})
    policies_by_id = Map.new(target_policies, &{to_string(&1.id), &1})

    assignments_by_plugin =
      assignments
      |> Enum.reject(&blank?(&1.partition_id))
      |> Enum.group_by(& &1.plugin_id)

    rows_by_plugin =
      fleet_rows
      |> Enum.filter(&(&1["assigned"] and &1["enabled"]))
      |> Enum.group_by(& &1["plugin_id"])

    Enum.map(plugins, fn plugin ->
      plugin_packages = Map.get(packages_by_plugin, plugin.plugin_id, [])
      plugin_assignments = Map.get(assignments_by_plugin, plugin.plugin_id, [])

      summary(
        plugin,
        plugin_packages,
        plugin_assignments,
        packages_by_id,
        policies_by_id,
        Map.get(rows_by_plugin, plugin.plugin_id, [])
      )
    end)
  end

  defp summary(plugin, packages, assignments, packages_by_id, policies_by_id, fleet_rows) do
    latest_approved = packages |> Enum.filter(&(&1.status == :approved)) |> LatestApprovedPluginPackage.latest()
    newest_staged = packages |> Enum.filter(&(&1.status == :staged)) |> newest()
    {enabled, disabled} = Enum.split_with(assignments, & &1.enabled)
    owners = owners(enabled)

    %{
      plugin_id: plugin.plugin_id,
      name: plugin.name,
      latest_approved: package_ref(latest_approved),
      newest_staged: package_ref(newest_staged),
      primary_package_id: package_id(latest_approved || newest_staged || newest(packages)),
      awaiting_review?: newer?(newest_staged, latest_approved),
      running_versions: running_versions(enabled, packages_by_id),
      assignments: %{
        enabled: length(enabled),
        disabled: length(disabled),
        behind_latest: Enum.count(enabled, &behind_latest?(&1, packages_by_id, latest_approved))
      },
      owners: owner_breakdown(owners, policies_by_id),
      update_policies: update_policy_mix(owners, policies_by_id),
      health: health(fleet_rows)
    }
  end

  defp newest([]), do: nil
  defp newest(packages), do: packages |> LatestApprovedPluginPackage.newest_first() |> hd()

  defp newer?(nil, _package), do: false
  defp newer?(_candidate, nil), do: true

  defp newer?(candidate, package) do
    candidate.id != package.id and LatestApprovedPluginPackage.latest([package, candidate]).id == candidate.id
  end

  defp package_ref(nil), do: nil
  defp package_ref(package), do: %{id: package.id, version: package.version}

  defp package_id(nil), do: nil
  defp package_id(package), do: package.id

  # Newest version first; an assignment whose package is gone sorts last.
  defp running_versions(assignments, packages_by_id) do
    counts = Enum.frequencies_by(assignments, &PluginAssignment.effective_package_id/1)
    {known, missing} = counts |> Map.keys() |> Enum.split_with(&Map.has_key?(packages_by_id, &1))

    known_packages =
      known
      |> Enum.map(&Map.fetch!(packages_by_id, &1))
      |> LatestApprovedPluginPackage.newest_first()

    Enum.map(known_packages, &%{package_id: &1.id, version: &1.version, assignments: Map.fetch!(counts, &1.id)}) ++
      Enum.map(missing, &%{package_id: &1, version: nil, assignments: Map.fetch!(counts, &1)})
  end

  defp behind_latest?(_assignment, _packages_by_id, nil), do: false

  defp behind_latest?(assignment, packages_by_id, latest_approved) do
    case Map.get(packages_by_id, PluginAssignment.effective_package_id(assignment)) do
      nil -> false
      package -> newer?(latest_approved, package)
    end
  end

  # Every enabled assignment has exactly one owner: itself when it is manual, or
  # the target policy or credential rule named by its policy id.
  defp owners(assignments) do
    Enum.group_by(assignments, fn assignment ->
      case AssignmentOwner.owner(assignment.policy_id) do
        :manual -> {:manual, assignment.id}
        {:rule, rule_id} -> {:credential_rule, rule_id}
        {:policy, policy_id} -> {:target_policy, policy_id}
      end
    end)
  end

  defp owner_breakdown(owners, policies_by_id) do
    grouped = Enum.group_by(owners, fn {{kind, _id}, _assignments} -> kind end)

    %{
      manual: grouped |> Map.get(:manual, []) |> length(),
      target_policies:
        grouped
        |> Map.get(:target_policy, [])
        |> Enum.map(fn {{_kind, id}, assignments} ->
          policy = Map.get(policies_by_id, id)

          %{
            id: id,
            name: policy && policy.name,
            update_policy: owner_update_policy({:target_policy, id}, assignments, policies_by_id),
            assignments: length(assignments)
          }
        end)
        |> Enum.sort_by(&{&1.name || "", &1.id}),
      credential_rules:
        grouped
        |> Map.get(:credential_rule, [])
        |> Enum.map(fn {{_kind, id}, assignments} ->
          %{id: id, href: "/settings/networks/credentials/#{URI.encode(id)}/edit", assignments: length(assignments)}
        end)
        |> Enum.sort_by(& &1.id)
    }
  end

  defp update_policy_mix(owners, policies_by_id) do
    Enum.reduce(owners, %{track_latest_approved: 0, pinned: 0}, fn {owner, assignments}, mix ->
      Map.update!(mix, owner_update_policy(owner, assignments, policies_by_id), &(&1 + 1))
    end)
  end

  # Credential rules always resolve the latest approved package. A target policy
  # whose record is gone keeps the package it stored, so it counts as pinned.
  defp owner_update_policy({:manual, _id}, [assignment], _policies_by_id), do: assignment.update_policy || :pinned
  defp owner_update_policy({:credential_rule, _id}, _assignments, _policies_by_id), do: :track_latest_approved

  defp owner_update_policy({:target_policy, id}, _assignments, policies_by_id) do
    case Map.get(policies_by_id, id) do
      %{update_policy: policy} when policy in [:track_latest_approved, :pinned] -> policy
      _ -> :pinned
    end
  end

  defp health([]), do: %{status: "unassigned", counts: %{}}

  defp health(rows) do
    counts = Enum.frequencies_by(rows, & &1["category"])

    status =
      Enum.find(["action_required", "unavailable"], "healthy", &Map.has_key?(counts, &1))

    %{status: status, counts: counts}
  end

  defp blank?(value), do: not (is_binary(value) and String.trim(value) != "")

  defp clamp(value, low, high) when is_integer(value), do: value |> max(low) |> min(high)

  defp clamp(value, low, high) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> clamp(parsed, low, high)
      _ -> low
    end
  end

  defp clamp(_value, low, _high), do: low

  defp matches_package?(_state, nil, _names), do: false

  defp matches_package?(state, package, names) do
    # Legacy name-only evidence is usable only for an unambiguous plugin name.
    explicit_id? = is_binary(PluginStateContract.state_plugin_id(state))
    unique_name? = MapSet.size(Map.get(names, package.name, MapSet.new())) == 1

    (explicit_id? or unique_name?) and
      PluginStateContract.package_matches_state?(state, package.name, package.plugin_id)
  end

  defp winner([]), do: nil
  defp winner(states), do: Enum.max_by(states, &PluginStateContract.state_rank/1)

  # A state that names its assignment is that assignment's evidence first.
  # A coexisting assignment's own disambiguated state never counts for
  # this one. States under the bare package name that name no assignment,
  # or that a sibling last stamped into the formerly shared row, remain
  # shared legacy evidence until each assignment reports into its own
  # state.
  defp assignment_state(states, assignment, package) do
    assignment_id = assignment && to_string(assignment.id)

    {own, rest} =
      Enum.split_with(states, fn state ->
        PluginStateContract.state_assignment_id(state) == assignment_id
      end)

    if own == [] do
      rest
      |> Enum.filter(fn state ->
        PluginStateContract.state_assignment_id(state) == nil or
          state.service_name == package.name
      end)
      |> winner()
    else
      winner(own)
    end
  end

  defp row(assignment, package, state, now, sibling_assignment_ids) do
    placeholder? = not is_nil(state) and PluginStateContract.placeholder_state?(state)
    reported_at = if state && not placeholder?, do: observed_at(state)
    age = if reported_at, do: max(DateTime.diff(now, reported_at, :second), 0)
    interval = if assignment, do: assignment.interval_seconds, else: 60
    stale? = not is_nil(age) and age > max(180, interval * 3)
    details = decode_details(state)
    result_status = if reported_at, do: reported_status(details)
    observed_version = if not placeholder?, do: reported_version(details)
    assigned_version = if package, do: package.version
    available = if reported_at, do: state.available
    {category, reason} = classify(assignment, package, state, reported_at, stale?)
    drift = known_drift(assigned_version, observed_version)
    observed_assignment_id = if reported_at, do: PluginStateContract.state_assignment_id(state)

    # Another enabled assignment of this plugin, agent, and partition shares
    # this service state, so its id is not drift.
    assignment_drift =
      if observed_assignment_id in sibling_assignment_ids,
        do: false,
        else: known_drift(if(assignment, do: assignment.id), observed_assignment_id)

    {category, reason} =
      cond do
        category == "healthy" and (drift == true or assignment_drift == true) ->
          {"action_required", "desired_state_not_converged"}

        category == "healthy" and result_status in ["WARNING", "CRITICAL", "UNKNOWN"] ->
          {"action_required", "runtime_reported_non_ok"}

        true ->
          {category, reason}
      end

    %{
      "partition_id" => if(assignment, do: assignment.partition_id, else: state.partition),
      "agent_uid" => if(assignment, do: assignment.agent_uid, else: state.agent_id),
      "plugin_id" => if(assignment, do: assignment.plugin_id, else: PluginStateContract.state_plugin_id(state)),
      "plugin_name" => if(package, do: package.name),
      "assignment_id" => if(assignment, do: assignment.id),
      "observed_assignment_id" => observed_assignment_id,
      "assignment_drift" => assignment_drift,
      "assigned" => not is_nil(assignment),
      "enabled" => not is_nil(assignment) and assignment.enabled,
      "source" => if(assignment, do: to_string(assignment.source)),
      "policy_id" => if(assignment, do: assignment.policy_id),
      "interval_seconds" => if(assignment, do: assignment.interval_seconds),
      "timeout_seconds" => if(assignment, do: assignment.timeout_seconds),
      "package_id" => if(package, do: package.id),
      "package_status" => if(package, do: to_string(package.status)),
      "content_hash" => if(package, do: package.content_hash),
      "runtime" => if(package, do: package.runtime),
      "outputs" => if(package, do: package.outputs),
      "assigned_version" => assigned_version,
      "observed_version" => observed_version,
      "version_drift" => drift,
      "observed_state" => runtime_state(state, placeholder?),
      "available" => available,
      "result_status" => result_status,
      "reported_at" => reported_at,
      "evidence_age_seconds" => age,
      "stale" => stale?,
      "last_success_at" => if(available == true, do: reported_at),
      "last_failure_at" => if(available == false, do: reported_at),
      "last_error" => if(available == false, do: "plugin_result_unavailable"),
      "category" => category,
      "reason_code" => reason
    }
  end

  defp classify(nil, _package, _state, _reported_at, true), do: {"observed_only", "observed_only_stale"}
  defp classify(nil, _package, _state, _reported_at, false), do: {"observed_only", "no_managed_assignment"}

  defp classify(%{enabled: false}, _package, _state, _reported_at, _stale),
    do: {"expected_inactive", "assignment_disabled"}

  defp classify(_assignment, nil, _state, _reported_at, _stale), do: {"action_required", "desired_package_missing"}

  defp classify(_assignment, %{status: status}, _state, _reported_at, _stale) when status != :approved,
    do: {"action_required", "desired_package_not_approved"}

  # Runtime evidence is expected only for an assignment the service-state
  # registry tracks. An action-only package that does not ingest action results
  # has no scheduled runner on the agent, so any state it still has predates
  # that package and must not read as a failing runtime.
  defp classify(assignment, package, state, reported_at, stale) do
    if StatusNormalizer.should_track_assignment_service?(assignment, package),
      do: classify_runtime(state, reported_at, stale),
      else: {"expected_inactive", "runtime_results_not_expected"}
  end

  defp classify_runtime(_state, nil, _stale), do: {"unavailable", "runtime_not_reported"}
  defp classify_runtime(_state, _reported_at, true), do: {"unavailable", "runtime_observation_stale"}
  defp classify_runtime(%{state: "inactive"}, _reported_at, false), do: {"unavailable", "runtime_inactive"}
  defp classify_runtime(%{available: false}, _reported_at, false), do: {"action_required", "runtime_reported_unhealthy"}
  defp classify_runtime(_state, _reported_at, false), do: {"healthy", "latest_result_available"}

  defp runtime_state(nil, _placeholder), do: "not_reported"
  defp runtime_state(%{message: "streaming plugin ready"}, true), do: "ready"
  defp runtime_state(_state, true), do: "pending"
  defp runtime_state(%{state: "inactive"}, false), do: "inactive"
  defp runtime_state(%{available: true}, false), do: "available"
  defp runtime_state(_state, false), do: "unavailable"

  defp observed_at(state) do
    state
    |> Map.take([:agent_id, :gateway_id, :partition, :service_type, :service_name, :details])
    |> Map.put(:timestamp, state.last_observed_at)
    |> PluginStateContract.snapshot_logical_observed_at()
  end

  defp decode_details(nil), do: %{}

  defp decode_details(%{details: details}) do
    case Jason.decode(details || "{}") do
      {:ok, value} when is_map(value) ->
        result = Map.get(value, "reported_result")
        result = if is_map(result), do: result, else: %{}
        labels = Map.get(value, "labels") || Map.get(result, "labels")

        %{
          "labels" => if(is_map(labels), do: labels, else: %{}),
          "package_version" => Map.get(value, "package_version") || Map.get(result, "package_version"),
          "status" => Map.get(value, "status") || Map.get(result, "status")
        }

      _ ->
        %{}
    end
  end

  defp reported_version(details) do
    # There is no version in the host-authored result envelope today. Only use
    # an explicitly reported package version; never infer it from desired state.
    value = get_in(details, ["labels", "package_version"]) || Map.get(details, "package_version")
    if is_binary(value) and byte_size(value) <= 64 and Regex.match?(~r/\A[0-9A-Za-z.+_-]+\z/, value), do: value
  end

  defp reported_status(%{"status" => status}) when is_binary(status) do
    normalized = String.upcase(status)
    if normalized in ["OK", "WARNING", "CRITICAL", "UNKNOWN"], do: normalized
  end

  defp reported_status(_details), do: nil

  defp known_drift(left, right) when is_binary(left) and is_binary(right), do: left != right
  defp known_drift(_left, _right), do: nil
end
