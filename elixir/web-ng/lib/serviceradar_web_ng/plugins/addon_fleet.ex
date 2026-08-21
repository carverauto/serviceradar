defmodule ServiceRadarWebNG.Plugins.AddonFleet do
  @moduledoc """
  Read-only fleet view of native agent add-ons (issue 3425, reworked for 4384).

  Joins the desired state (`addon_packages` catalog + `addon_assignments`) against
  the observed runtime state (`addon_statuses`) so operators can see, across the
  whole fleet, which agent runs which add-on and whether the effective state is
  healthy. The model is one row per (agent, add-on): only an enabled assignment
  can define current desired state. Disabled assignments remain drill-in audit
  history and never masquerade as a current assignment.

  Catalog-only inventory (packages imported but assigned to no agent and reported
  by no agent) is returned separately via `overview/1` so the fleet table never
  contains agentless rows.

  Everything here goes through the existing `ServiceRadar.Plugins.Addon*` Ash
  resources (scoped reads, same authorizers as the rest of web-ng) plus the
  `ServiceRadar.Inventory.EndpointInventoryScan` resource for collector add-ons.
  No new writes and no bypass of the resource layer.
  """

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.EndpointInventoryScan
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonRollout
  alias ServiceRadar.Plugins.AddonRolloutEligibility
  alias ServiceRadar.Plugins.AddonRolloutTarget
  alias ServiceRadar.Plugins.AddonStatus
  alias ServiceRadar.Plugins.RetiredNativeAddons
  alias ServiceRadarWebNG.Plugins.AddonRolloutView
  alias ServiceRadarWebNG.Plugins.AddonRuntimePolicy

  require Ash.Query

  @collector_addon_ids MapSet.new(["scalibr-endpoint-inventory"])

  @max_rows 2000
  @default_freshness_seconds 180
  @default_convergence_seconds 900

  @typedoc """
  Version comparison state for a fleet row. Computed only from values that are
  actually present — a missing side never fabricates a comparison:

    * `{:up_to_date, version, current?}` — running == assigned; `current?` is true
      when no newer approved version of the add-on exists
    * `{:drift, running, assigned}` — both sides present and different
    * `{:required_runtime, version_or_nil}` — platform-required runtime without
      an explicit assignment row
    * `{:running_unassigned, version_or_nil}` — observed running with no assignment
    * `{:not_reported, assigned_version_or_nil}` — assigned but no observed status
    * `nil` — nothing meaningful to say
  """
  @type version_status ::
          {:up_to_date, String.t(), boolean()}
          | {:drift, String.t(), String.t()}
          | {:required_runtime, String.t() | nil}
          | {:running_unassigned, String.t() | nil}
          | {:not_reported, String.t() | nil}
          | nil

  @type stale_assignment :: %{
          version: String.t() | nil,
          enabled: boolean(),
          source: atom() | nil,
          updated_at: DateTime.t() | nil
        }

  @type row :: %{
          agent_uid: String.t() | nil,
          agent_label: String.t(),
          addon_id: String.t(),
          addon_name: String.t(),
          package_id: String.t() | nil,
          assigned_version: String.t() | nil,
          latest_approved_version: String.t() | nil,
          content_hash: String.t() | nil,
          package_status: atom() | nil,
          verification_status: String.t() | nil,
          approved?: boolean(),
          assigned?: boolean(),
          enabled?: boolean(),
          management_mode: AddonRuntimePolicy.management_mode(),
          running_state: String.t() | nil,
          running_version: String.t() | nil,
          active?: boolean(),
          degradation_reason: String.t() | nil,
          reported_at: DateTime.t() | nil,
          last_scan_at: DateTime.t() | nil,
          collector?: boolean(),
          version_status: version_status(),
          stale_assignments: [stale_assignment()],
          category: atom(),
          reason_code: String.t(),
          evidence_age_seconds: non_neg_integer() | nil,
          rollout_id: String.t() | nil,
          rollout_state: atom() | nil,
          rollout_candidate_version: String.t() | nil,
          rollout_previous_version: String.t() | nil,
          health: map(),
          attention: [atom()],
          attention?: boolean()
        }

  @type catalog_entry :: %{
          addon_id: String.t(),
          addon_name: String.t(),
          package_id: String.t(),
          version: String.t() | nil,
          latest_approved_version: String.t() | nil,
          package_status: atom() | nil,
          verification_status: String.t() | nil,
          approved?: boolean(),
          versions: non_neg_integer()
        }

  @doc """
  Build the fleet overview: `rows` (one per (agent, add-on) with an assignment or
  an observed status) plus `catalog_only` inventory (imported packages neither
  assigned to nor reported by any agent). Catalog-only add-ons are never fleet
  rows.
  """
  @spec overview(keyword()) :: %{rows: [row()], catalog_only: [catalog_entry()]}
  def overview(opts \\ []) do
    scope = Keyword.get(opts, :scope)

    packages = list_packages(scope)
    assignments = scope |> list_assignments() |> reject_retired_addon_ids()
    statuses = scope |> list_statuses() |> reject_retired_addon_ids()
    scans_by_agent = list_collector_scans(scope)
    agents_by_uid = agents_by_uid(scope)
    agent_labels = Map.new(agents_by_uid, fn {uid, agent} -> {uid, agent_label(agent)} end)
    package_index = index_packages(packages)
    rollout_index = rollout_index(scope)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    row_context = %{
      agent_labels: agent_labels,
      agents_by_uid: agents_by_uid,
      package_index: package_index,
      scans_by_agent: scans_by_agent,
      rollout_index: rollout_index,
      now: now
    }

    assignment_groups = Enum.group_by(assignments, &{&1.agent_uid, &1.addon_id})

    enabled_assignment_groups =
      Map.new(assignment_groups, fn {key, group} ->
        {key, Enum.filter(group, & &1.enabled)}
      end)

    assigned_rows =
      enabled_assignment_groups
      |> Enum.reject(fn {_key, enabled} -> enabled == [] end)
      |> Enum.map(fn {{agent_uid, addon_id}, enabled} ->
        {assignment, superseded_enabled} = effective_assignment(enabled, package_index)
        history = Map.fetch!(assignment_groups, {agent_uid, addon_id}) -- [assignment]
        package_id = assignment.rollout_package_id || assignment.addon_package_id
        package = package_id && Map.get(package_index.by_id, package_id)
        status = find_status(statuses, agent_uid, addon_id)

        build_row(
          agent_uid,
          addon_id,
          package,
          assignment,
          status,
          stale_assignment_infos(
            Enum.uniq_by(superseded_enabled ++ history, & &1.id),
            package_index
          ),
          row_context
        )
      end)

    assigned_keys =
      enabled_assignment_groups
      |> Enum.reject(fn {_key, enabled} -> enabled == [] end)
      |> MapSet.new(fn {key, _enabled} -> key end)

    observed_only_rows =
      statuses
      |> Enum.reject(&MapSet.member?(assigned_keys, {&1.agent_uid, &1.addon_id}))
      |> Enum.map(fn status ->
        package = latest_package_for_addon(package_index, status.addon_id)
        history = Map.get(assignment_groups, {status.agent_uid, status.addon_id}, [])

        build_row(
          status.agent_uid,
          status.addon_id,
          package,
          nil,
          status,
          stale_assignment_infos(history, package_index),
          row_context
        )
      end)

    rows =
      Enum.sort_by(
        assigned_rows ++ observed_only_rows,
        &{String.downcase(&1.agent_label), &1.addon_id}
      )

    enabled_assignments = Enum.filter(assignments, & &1.enabled)

    %{
      rows: rows,
      catalog_only: catalog_only_entries(packages, enabled_assignments, statuses)
    }
  end

  @doc """
  Fleet rows only (see `overview/1`). One row per (agent, add-on); catalog-only
  inventory is not included.
  """
  @spec rows(keyword()) :: [row()]
  def rows(opts \\ []), do: overview(opts).rows

  @doc """
  Distinct add-on ids present in the matrix, for the add-on filter dropdown.
  """
  @spec addon_ids([row()]) :: [String.t()]
  def addon_ids(rows) do
    rows |> Enum.map(& &1.addon_id) |> Enum.uniq() |> Enum.sort()
  end

  @doc """
  Distinct agents present in the matrix, for the agent filter dropdown.
  Returns `{label, agent_uid}` tuples; rows without an agent are excluded.
  """
  @spec agents([row()]) :: [{String.t(), String.t()}]
  def agents(rows) do
    rows
    |> Enum.reject(&is_nil(&1.agent_uid))
    |> Enum.map(&{&1.agent_label, &1.agent_uid})
    |> Enum.uniq()
    |> Enum.sort_by(fn {label, _uid} -> String.downcase(label) end)
  end

  @doc """
  Aggregate counts for the summary stat strip.
  """
  @spec summary([row()]) :: map()
  def summary(rows) do
    %{
      managed: Enum.count(rows, &(&1.assigned? and &1.enabled?)),
      healthy: Enum.count(rows, &(&1.category == :healthy)),
      updating: Enum.count(rows, &(&1.category == :updating)),
      action_required: Enum.count(rows, &(&1.category == :action_required)),
      unavailable: Enum.count(rows, &(&1.category == :unavailable)),
      expected_inactive: Enum.count(rows, &(&1.category == :expected_inactive)),
      observed_only: Enum.count(rows, &(&1.category == :observed_only))
    }
  end

  @doc """
  Apply UI filters (agent, add-on, and "needs attention" toggle) to the rows.
  Filters arrive as a plain string map from the LiveView form.
  """
  @spec filter([row()], map()) :: [row()]
  def filter(rows, filters) when is_map(filters) do
    agent_uid = present(Map.get(filters, "agent_uid"))
    addon_id = present(Map.get(filters, "addon_id"))
    category = present(Map.get(filters, "category"))
    attention_only? = Map.get(filters, "attention_only") in [true, "true", "on"]

    rows
    |> maybe_filter(agent_uid, fn row -> row.agent_uid == agent_uid end)
    |> maybe_filter(addon_id, fn row -> row.addon_id == addon_id end)
    |> maybe_filter(category, fn row -> to_string(row.category) == category end)
    |> then(fn rows ->
      if attention_only?, do: Enum.filter(rows, & &1.attention?), else: rows
    end)
  end

  @doc """
  Version comparison state for a row-shaped map; see `t:version_status/0`.

  Drift is only ever a comparison of two present values. An unassigned-but-
  running add-on reports `{:running_unassigned, version}` and an assigned-but-
  unreported one reports `{:not_reported, version}` — never a fabricated
  comparison against a missing/zero version.
  """
  @spec version_status(map()) :: version_status()
  def version_status(%{assigned?: true, assigned_version: assigned, running_version: running} = row)
      when is_binary(assigned) and is_binary(running) do
    if assigned == running do
      latest = Map.get(row, :latest_approved_version)
      {:up_to_date, running, compare_versions(latest, running) != :gt}
    else
      {:drift, running, assigned}
    end
  end

  def version_status(%{assigned?: true, running_version: running, running_state: state})
      when is_binary(running) or is_binary(state) do
    # Assigned and observed, but the assigned version is unknown (e.g. package
    # row missing) — there is nothing meaningful to compare, so say nothing
    # rather than fabricate a drift or an "unassigned" label.
    nil
  end

  def version_status(%{assigned?: true} = row), do: {:not_reported, Map.get(row, :assigned_version)}

  def version_status(%{management_mode: :required, running_version: running, running_state: state} = row)
      when is_binary(running) or is_binary(state) do
    {:required_runtime, running_version_or_nil(row)}
  end

  def version_status(%{running_version: running, running_state: state} = row)
      when is_binary(running) or is_binary(state) do
    {:running_unassigned, running_version_or_nil(row)}
  end

  def version_status(_row), do: nil

  defp running_version_or_nil(row) do
    case Map.get(row, :running_version) do
      version when is_binary(version) -> version
      _other -> nil
    end
  end

  @doc """
  The latest package in a list, preferring approved packages and comparing by
  semantic version (so a re-import of an older version never wins "latest").
  Non-semver version strings fall back to import/insert timestamps.
  """
  @spec latest_package([AddonPackage.t()]) :: AddonPackage.t() | nil
  def latest_package([]), do: nil

  def latest_package(packages) do
    approved = Enum.filter(packages, &(&1.status == :approved))
    pool = if approved == [], do: packages, else: approved
    Enum.reduce(pool, nil, &pick_newer_package/2)
  end

  @doc """
  The latest approved version string for a list of packages of one add-on, or
  nil when no package is approved. Semver-compared (timestamp fallback for
  non-semver strings).
  """
  @spec latest_approved_version([AddonPackage.t()]) :: String.t() | nil
  def latest_approved_version(packages) do
    case Enum.filter(packages, &(&1.status == :approved)) do
      [] -> nil
      approved -> approved |> Enum.reduce(nil, &pick_newer_package/2) |> Map.get(:version)
    end
  end

  @doc """
  Semver comparison tolerant of invalid version strings: `:gt`/`:lt`/`:eq` when
  both sides parse as semver, `:incomparable` otherwise (never raises).
  """
  @spec compare_versions(term(), term()) :: :gt | :lt | :eq | :incomparable
  def compare_versions(left, right) when is_binary(left) and is_binary(right) do
    with {:ok, left_version} <- Version.parse(left),
         {:ok, right_version} <- Version.parse(right) do
      Version.compare(left_version, right_version)
    else
      _ -> :incomparable
    end
  end

  def compare_versions(_left, _right), do: :incomparable

  defp maybe_filter(rows, nil, _fun), do: rows
  defp maybe_filter(rows, _value, fun), do: Enum.filter(rows, fun)

  # --- row construction -----------------------------------------------------

  defp build_row(agent_uid, addon_id, package, assignment, status, stale_assignments, row_context) do
    collector? = MapSet.member?(@collector_addon_ids, addon_id)
    last_scan_at = if collector?, do: Map.get(row_context.scans_by_agent, agent_uid)
    management_mode = AddonRuntimePolicy.management_mode(addon_id, not is_nil(assignment))
    agent = Map.get(row_context.agents_by_uid, agent_uid)
    rollout = rollout_for(assignment, row_context.rollout_index)

    base = %{
      agent_uid: agent_uid,
      agent_label: Map.get(row_context.agent_labels, agent_uid, agent_uid || "—"),
      addon_id: addon_id,
      addon_name: package_name(package, addon_id),
      package_id: package && package.id,
      assigned_version: if(assignment, do: package && package.version),
      latest_approved_version: latest_approved_for_addon(row_context.package_index, addon_id),
      content_hash: package && package.source_oci_digest,
      package_status: package && package.status,
      verification_status: package && package.verification_status,
      approved?: package_approved?(package),
      assigned?: not is_nil(assignment),
      enabled?: assignment != nil and assignment.enabled,
      management_mode: management_mode,
      running_state: status && status.state,
      running_version: status && status.version,
      active?: status != nil and status.active,
      degradation_reason: status && present(status.degradation_reason),
      reported_at: status && status.reported_at,
      last_scan_at: last_scan_at,
      collector?: collector?,
      stale_assignments: stale_assignments
    }

    version_status = version_status(base)

    {category, reason_code} =
      classify(base, package, assignment, status, agent, rollout, row_context.now)

    attention = if category == :action_required, do: [reason_code], else: []

    row =
      base
      |> Map.put(:version_status, version_status)
      |> Map.put(:category, category)
      |> Map.put(:reason_code, reason_code)
      |> Map.put(:evidence_age_seconds, evidence_age(status, row_context.now))
      |> Map.put(:rollout_id, rollout && rollout.id)
      |> Map.put(:rollout_state, rollout && rollout.rollout_state)
      |> Map.put(:rollout_candidate_version, rollout && rollout.candidate_version)
      |> Map.put(:rollout_previous_version, rollout && rollout.previous_version)
      |> Map.put(:update_policy, assignment && assignment.update_policy)
      |> Map.put(:attention, attention)
      |> Map.put(:attention?, category == :action_required)

    Map.put(row, :health, AddonRolloutView.fleet_health(row))
  end

  # The effective assignment for an (agent, add-on) pair. Callers pass enabled
  # assignments only; disabled rows are historical evidence, never desired state.
  # Newest package version (semver), then most recently updated, wins.
  defp effective_assignment(group, package_index) do
    [effective | stale] = Enum.sort_by(group, &assignment_rank(&1, package_index), :desc)
    {effective, stale}
  end

  defp assignment_rank(assignment, package_index) do
    package = assignment.addon_package_id && Map.get(package_index.by_id, assignment.addon_package_id)

    {
      version_rank(package && package.version),
      timestamp_rank(Map.get(assignment, :updated_at))
    }
  end

  defp version_rank(version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, parsed} -> {1, parsed.major, parsed.minor, parsed.patch}
      :error -> {0, 0, 0, 0}
    end
  end

  defp version_rank(_version), do: {0, 0, 0, 0}

  defp timestamp_rank(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)
  defp timestamp_rank(_other), do: 0

  defp stale_assignment_infos(stale, package_index) do
    Enum.map(stale, fn assignment ->
      package = assignment.addon_package_id && Map.get(package_index.by_id, assignment.addon_package_id)

      %{
        version: package && package.version,
        enabled: assignment.enabled,
        source: Map.get(assignment, :source),
        updated_at: Map.get(assignment, :updated_at)
      }
    end)
  end

  defp catalog_only_entries(packages, assignments, statuses) do
    assigned_addon_ids = MapSet.new(assignments, & &1.addon_id)
    observed_addon_ids = MapSet.new(statuses, & &1.addon_id)
    seen = MapSet.union(assigned_addon_ids, observed_addon_ids)

    packages
    |> Enum.group_by(& &1.addon_id)
    |> Enum.reject(fn {addon_id, _pkgs} -> MapSet.member?(seen, addon_id) end)
    |> Enum.map(fn {addon_id, pkgs} ->
      package = latest_package(pkgs)

      %{
        addon_id: addon_id,
        addon_name: package_name(package, addon_id),
        package_id: package.id,
        version: package.version,
        latest_approved_version: latest_approved_version(pkgs),
        package_status: package.status,
        verification_status: package.verification_status,
        approved?: package_approved?(package),
        versions: length(pkgs)
      }
    end)
    |> Enum.sort_by(&String.downcase(&1.addon_name))
  end

  # --- mutually exclusive fleet health classification -----------------------

  @doc false
  def classify(base, package, assignment, status, agent, rollout, now \\ DateTime.utc_now()) do
    cond do
      invalid_desired_package?(assignment, package) ->
        {:action_required, "desired_package_not_approved"}

      incompatible_rollout_target?(rollout) ->
        {:action_required, rollout.reason_code || "rollout_target_incompatible"}

      active_rollout?(rollout) ->
        {:updating, rollout.reason_code || "rollout_in_progress"}

      not is_nil(assignment) and assignment.enabled == false ->
        {:expected_inactive, "assignment_disabled"}

      is_nil(assignment) ->
        classify_observed_only(status, now)

      agent_unavailable?(agent, now) ->
        {:unavailable, "agent_unavailable_or_stale"}

      is_nil(status) ->
        {:unavailable, "desired_runtime_not_yet_reported"}

      stale_observation?(status, now) ->
        {:unavailable, "runtime_observation_stale"}

      explicitly_unhealthy?(status) ->
        {:action_required, "runtime_reported_unhealthy"}

      expected_inactive?(package, status) ->
        {:expected_inactive, "ephemeral_helper_ready"}

      # Live desired-vs-running wins over a finished canary. A Failed/Paused
      # rollout is history on the fleet list; it must not paint a healthy,
      # up-to-date agent as "Update blocked".
      converged?(base, package, status) ->
        {:healthy, "desired_runtime_healthy"}

      paused_rollout?(rollout) ->
        {:action_required, rollout.reason_code || "rollout_failed"}

      convergence_grace?(assignment, now) ->
        {:updating, "desired_state_converging"}

      true ->
        {:action_required, "desired_state_not_converged"}
    end
  end

  defp classify_observed_only(nil, _now), do: {:observed_only, "no_managed_assignment"}

  defp classify_observed_only(status, now) do
    cond do
      stale_observation?(status, now) ->
        {:observed_only, "observed_only_stale"}

      explicitly_unhealthy?(status) ->
        {:action_required, "runtime_reported_unhealthy"}

      true ->
        {:observed_only, "healthy_observed_only_runtime"}
    end
  end

  defp explicitly_unhealthy?(nil), do: false

  defp explicitly_unhealthy?(status) do
    state = status.state |> to_string() |> String.downcase()

    present(status.degradation_reason) != nil or
      state in ["circuit_open", "failed", "unhealthy", "verification_failed"]
  end

  defp invalid_desired_package?(%AddonAssignment{enabled: true}, package),
    do: is_nil(package) or package.status != :approved

  defp invalid_desired_package?(_assignment, _package), do: false

  # An incompatible target is a desired-state error established during rollout
  # snapshotting. It remains actionable even if the agent goes offline before a
  # status report arrives; classifying it as merely unavailable hides an error
  # an operator can resolve without waiting for more runtime evidence.
  defp incompatible_rollout_target?(%{classification: :incompatible}), do: true
  defp incompatible_rollout_target?(_rollout), do: false

  defp active_rollout?(%{rollout_state: rollout_state, state: state})
       when rollout_state in [:pending, :running, :rolling_back] and
              state in [:pending, :waiting_health, :healthy_soak, :succeeded, :rollback_pending], do: true

  defp active_rollout?(_), do: false

  defp paused_rollout?(%{rollout_state: state}) when state in [:paused], do: true
  defp paused_rollout?(_), do: false

  defp agent_unavailable?(nil, _now), do: true

  defp agent_unavailable?(agent, now) do
    agent.status != :connected or agent.is_healthy == false or
      is_nil(agent.last_seen_time) or
      stale_timestamp?(agent.last_seen_time, now, freshness_seconds())
  end

  defp stale_observation?(status, now), do: stale_timestamp?(status.reported_at, now, freshness_seconds())

  defp stale_timestamp?(nil, _now, _seconds), do: false

  defp stale_timestamp?(%DateTime{} = observed_at, %DateTime{} = now, seconds),
    do: DateTime.diff(now, observed_at, :second) > seconds

  defp expected_inactive?(%AddonPackage{supervision: :ephemeral_helper} = package, status),
    do: AddonRolloutEligibility.supervision_ready?(package, status)

  defp expected_inactive?(_package, _status), do: false

  defp converged?(base, %AddonPackage{} = package, status) do
    base.assigned_version == status.version and
      AddonRolloutEligibility.supervision_ready?(package, status)
  end

  defp converged?(_base, _package, _status), do: false

  defp convergence_grace?(assignment, now) do
    changed_at = assignment.rollout_started_at || assignment.updated_at || assignment.inserted_at

    match?(%DateTime{}, changed_at) and
      DateTime.diff(now, changed_at, :second) <= convergence_seconds()
  end

  defp freshness_seconds do
    Application.get_env(:serviceradar_web_ng, :addon_status_freshness_seconds, @default_freshness_seconds)
  end

  defp convergence_seconds do
    Application.get_env(
      :serviceradar_web_ng,
      :addon_convergence_grace_seconds,
      @default_convergence_seconds
    )
  end

  defp evidence_age(nil, _now), do: nil

  defp evidence_age(%AddonStatus{reported_at: %DateTime{} = reported_at}, now),
    do: max(DateTime.diff(now, reported_at, :second), 0)

  defp evidence_age(_status, _now), do: nil

  # --- data loading ---------------------------------------------------------

  defp list_packages(scope) do
    AddonPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.limit(@max_rows)
    |> read(scope)
    |> reject_retired_addon_ids()
  end

  defp list_assignments(scope) do
    AddonAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.limit(@max_rows)
    |> read(scope)
  end

  defp list_statuses(scope) do
    AddonStatus
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(reported_at: :desc)
    |> Ash.Query.limit(@max_rows)
    |> read(scope)
  end

  defp rollout_index(scope) do
    rollouts =
      AddonRollout
      |> Ash.Query.for_read(:read)
      |> Ash.Query.sort(updated_at: :desc)
      |> Ash.Query.limit(@max_rows)
      |> Ash.Query.load([:previous_package, :candidate_package])
      |> read(scope)
      |> Map.new(&{&1.id, &1})

    targets =
      AddonRolloutTarget
      |> Ash.Query.for_read(:read)
      |> Ash.Query.sort(updated_at: :desc)
      |> Ash.Query.limit(@max_rows)
      |> read(scope)

    targets
    |> Enum.uniq_by(& &1.assignment_id)
    |> Map.new(fn target ->
      rollout = Map.get(rollouts, target.rollout_id)

      value = %{
        id: target.rollout_id,
        state: target.state,
        classification: target.classification,
        reason_code: (rollout && rollout.blocked_reason) || target.reason_code,
        rollout_state: rollout && rollout.state,
        candidate_version: rollout && rollout.candidate_package && rollout.candidate_package.version,
        previous_version: rollout && rollout.previous_package && rollout.previous_package.version,
        updated_at: target.updated_at
      }

      {target.assignment_id, value}
    end)
  rescue
    _ -> %{}
  end

  defp rollout_for(nil, _rollout_index), do: nil

  defp rollout_for(assignment, rollout_index), do: Map.get(rollout_index, assignment.id)

  defp list_collector_scans(scope) do
    EndpointInventoryScan
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(current == true)
    |> Ash.Query.limit(@max_rows)
    |> read(scope)
    |> Enum.reduce(%{}, fn scan, acc ->
      agent_id = scan.agent_id
      scanned_at = scan.last_scan_at

      cond do
        is_nil(agent_id) or is_nil(scanned_at) -> acc
        not Map.has_key?(acc, agent_id) -> Map.put(acc, agent_id, scanned_at)
        DateTime.after?(scanned_at, Map.get(acc, agent_id)) -> Map.put(acc, agent_id, scanned_at)
        true -> acc
      end
    end)
  end

  defp agents_by_uid(scope) do
    Agent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.limit(@max_rows)
    |> read(scope)
    |> Map.new(fn agent -> {agent.uid, agent} end)
  rescue
    _ -> %{}
  end

  defp read(query, nil), do: Ash.read!(query)
  defp read(query, scope), do: Ash.read!(query, scope: scope)

  # --- helpers --------------------------------------------------------------

  defp index_packages(packages) do
    %{
      by_id: Map.new(packages, &{&1.id, &1}),
      by_addon: Enum.group_by(packages, & &1.addon_id)
    }
  end

  defp latest_package_for_addon(%{by_addon: by_addon}, addon_id) do
    by_addon |> Map.get(addon_id, []) |> latest_package()
  end

  defp latest_approved_for_addon(%{by_addon: by_addon}, addon_id) do
    by_addon |> Map.get(addon_id, []) |> latest_approved_version()
  end

  defp pick_newer_package(package, nil), do: package

  defp pick_newer_package(package, best) do
    case compare_versions(package.version, best.version) do
      :gt -> package
      :lt -> best
      _eq_or_incomparable -> if newer_by_timestamp?(package, best), do: package, else: best
    end
  end

  defp newer_by_timestamp?(left, right) do
    timestamp_rank(package_sort_key(left)) > timestamp_rank(package_sort_key(right))
  end

  defp package_sort_key(%AddonPackage{imported_at: nil, inserted_at: inserted_at}), do: inserted_at
  defp package_sort_key(%AddonPackage{imported_at: imported_at}), do: imported_at

  defp find_status(statuses, agent_uid, addon_id) do
    Enum.find(statuses, &(&1.agent_uid == agent_uid and &1.addon_id == addon_id))
  end

  defp package_approved?(%AddonPackage{status: :approved}), do: true
  defp package_approved?(_package), do: false

  defp reject_retired_addon_ids(items) do
    Enum.reject(items, &RetiredNativeAddons.retired?(&1.addon_id))
  end

  defp package_name(%AddonPackage{name: name}, _addon_id) when is_binary(name) and name != "", do: name
  defp package_name(_package, addon_id), do: addon_id

  defp agent_label(agent) do
    name = present(Map.get(agent, :name)) || present(Map.get(agent, :host))

    case name do
      nil -> agent.uid
      name -> "#{name} (#{agent.uid})"
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
