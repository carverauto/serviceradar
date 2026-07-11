defmodule ServiceRadarWebNG.Plugins.AddonFleet do
  @moduledoc """
  Read-only fleet view of native agent add-ons (issue 3425, reworked for 4384).

  Joins the desired state (`addon_packages` catalog + `addon_assignments`) against
  the observed runtime state (`addon_statuses`) so operators can see, across the
  whole fleet, which agent runs which add-on and whether the effective state is
  healthy. The model is one row per (agent, add-on): the effective assignment
  (enabled first, then newest package version) wins the row and every other
  assignment for the same pair is kept as drill-in detail instead of a peer row.

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
  alias ServiceRadar.Plugins.AddonStatus
  alias ServiceRadar.Plugins.RetiredNativeAddons
  alias ServiceRadarWebNG.Plugins.AddonRuntimePolicy

  require Ash.Query

  @collector_addon_ids MapSet.new(["scalibr-endpoint-inventory"])

  @max_rows 2000

  @typedoc """
  Version comparison state for a fleet row. Computed only from values that are
  actually present — a missing side never fabricates a comparison:

    * `{:up_to_date, version, latest?}` — running == assigned; `latest?` is true
      when that version is also the latest approved version of the add-on
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
    agent_labels = agent_labels(scope)
    package_index = index_packages(packages)

    row_context = %{
      agent_labels: agent_labels,
      package_index: package_index,
      scans_by_agent: scans_by_agent
    }

    assigned_rows =
      assignments
      |> Enum.group_by(&{&1.agent_uid, &1.addon_id})
      |> Enum.map(fn {{agent_uid, addon_id}, group} ->
        {assignment, stale} = effective_assignment(group, package_index)
        package = assignment.addon_package_id && Map.get(package_index.by_id, assignment.addon_package_id)
        status = find_status(statuses, agent_uid, addon_id)

        build_row(
          agent_uid,
          addon_id,
          package,
          assignment,
          status,
          stale_assignment_infos(stale, package_index),
          row_context
        )
      end)

    assigned_keys = MapSet.new(assignments, &{&1.agent_uid, &1.addon_id})

    observed_only_rows =
      statuses
      |> Enum.reject(&MapSet.member?(assigned_keys, {&1.agent_uid, &1.addon_id}))
      |> Enum.map(fn status ->
        package = latest_package_for_addon(package_index, status.addon_id)

        build_row(
          status.agent_uid,
          status.addon_id,
          package,
          nil,
          status,
          [],
          row_context
        )
      end)

    rows =
      Enum.sort_by(
        assigned_rows ++ observed_only_rows,
        &{String.downcase(&1.agent_label), &1.addon_id}
      )

    %{rows: rows, catalog_only: catalog_only_entries(packages, assignments, statuses)}
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
  @spec summary([row()]) :: %{
          total: non_neg_integer(),
          attention: non_neg_integer(),
          running: non_neg_integer(),
          staged: non_neg_integer()
        }
  def summary(rows) do
    %{
      total: length(rows),
      attention: Enum.count(rows, & &1.attention?),
      running: Enum.count(rows, & &1.active?),
      staged: Enum.count(rows, &(&1.package_status == :staged))
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
    attention_only? = Map.get(filters, "attention_only") in [true, "true", "on"]

    rows
    |> maybe_filter(agent_uid, fn row -> row.agent_uid == agent_uid end)
    |> maybe_filter(addon_id, fn row -> row.addon_id == addon_id end)
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
      {:up_to_date, running, running == Map.get(row, :latest_approved_version)}
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
    attention = attention_flags(package, assignment, status, version_status, management_mode)

    base
    |> Map.put(:version_status, version_status)
    |> Map.put(:attention, attention)
    |> Map.put(:attention?, attention != [])
  end

  # The effective assignment for an (agent, add-on) pair: enabled beats disabled,
  # then the newest package version (semver), then the most recently updated row.
  # Everything else becomes drill-in detail instead of a peer fleet row.
  defp effective_assignment(group, package_index) do
    [effective | stale] = Enum.sort_by(group, &assignment_rank(&1, package_index), :desc)
    {effective, stale}
  end

  defp assignment_rank(assignment, package_index) do
    package = assignment.addon_package_id && Map.get(package_index.by_id, assignment.addon_package_id)

    {
      if(assignment.enabled, do: 1, else: 0),
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

  # --- "needs attention" classification -------------------------------------

  defp attention_flags(package, assignment, status, version_status, management_mode) do
    []
    |> staged_not_approved(package, assignment)
    |> assigned_not_running(assignment, status)
    |> stopped_or_inactive(assignment, status)
    |> version_drift(version_status)
    |> observed_unassigned(assignment, status, management_mode)
  end

  defp staged_not_approved(flags, %AddonPackage{status: status}, _assignment)
       when status in [:staged, :denied, :revoked] do
    [:staged_not_approved | flags]
  end

  defp staged_not_approved(flags, _package, _assignment), do: flags

  defp assigned_not_running(flags, %AddonAssignment{enabled: true}, nil) do
    [:assigned_not_running | flags]
  end

  defp assigned_not_running(flags, _assignment, _status), do: flags

  defp stopped_or_inactive(flags, %AddonAssignment{enabled: true}, %AddonStatus{active: false}) do
    [:stopped_or_inactive | flags]
  end

  defp stopped_or_inactive(flags, _assignment, _status), do: flags

  # Drift is only flagged when the read model produced a real comparison — an
  # absent assignment or an unreported running version never counts as drift.
  defp version_drift(flags, {:drift, _running, _assigned}), do: [:version_drift | flags]
  defp version_drift(flags, _version_status), do: flags

  defp observed_unassigned(flags, nil, %AddonStatus{}, :observed), do: [:observed_unassigned | flags]

  defp observed_unassigned(flags, _assignment, _status, _management_mode), do: flags

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

  defp agent_labels(scope) do
    Agent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.limit(@max_rows)
    |> read(scope)
    |> Map.new(fn agent -> {agent.uid, agent_label(agent)} end)
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
