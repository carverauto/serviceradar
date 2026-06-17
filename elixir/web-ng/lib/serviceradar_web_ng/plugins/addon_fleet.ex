defmodule ServiceRadarWebNG.Plugins.AddonFleet do
  @moduledoc """
  Read-only fleet view of native agent add-ons (issue 3425).

  Joins the desired state (`addon_packages` catalog + `addon_assignments`) against
  the observed runtime state (`addon_statuses`) so operators can see, across the
  whole fleet, which agent runs which add-on at which version/hash and whether it
  is actually running. This is the visibility gap that let a fleet of
  broken/disabled/undelivered add-ons go unnoticed (endpoint-inventory stopped on
  pve04, netprobe unhealthy on cp3 workers, scalibr-endpoint-inventory staged with
  zero assignments).

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

  require Ash.Query

  @collector_addon_ids MapSet.new(["scalibr-endpoint-inventory"])

  @max_rows 2000

  @type row :: %{
          agent_uid: String.t() | nil,
          agent_label: String.t(),
          addon_id: String.t(),
          addon_name: String.t(),
          assigned_version: String.t() | nil,
          content_hash: String.t() | nil,
          package_status: atom() | nil,
          verification_status: String.t() | nil,
          approved?: boolean(),
          assigned?: boolean(),
          enabled?: boolean(),
          running_state: String.t() | nil,
          running_version: String.t() | nil,
          active?: boolean(),
          degradation_reason: String.t() | nil,
          reported_at: DateTime.t() | nil,
          last_scan_at: DateTime.t() | nil,
          collector?: boolean(),
          attention: [atom()],
          attention?: boolean()
        }

  @doc """
  Build the full fleet matrix as a list of rows, one per (agent, add-on) pair.

  A row exists when there is an assignment, an observed status, or both. A staged
  catalog package with zero assignments and zero statuses (e.g.
  `scalibr-endpoint-inventory`) is surfaced as a catalog-only row so the
  not-yet-deployed / staged-not-approved case is visible too.
  """
  @spec rows(keyword()) :: [row()]
  def rows(opts \\ []) do
    scope = Keyword.get(opts, :scope)

    packages = list_packages(scope)
    assignments = scope |> list_assignments() |> reject_retired_addon_ids()
    statuses = scope |> list_statuses() |> reject_retired_addon_ids()
    scans_by_agent = list_collector_scans(scope)
    agent_labels = agent_labels(scope)
    package_index = index_packages(packages)

    assigned_rows =
      Enum.map(assignments, fn assignment ->
        package = Map.get(package_index.by_id, assignment.addon_package_id)
        status = find_status(statuses, assignment.agent_uid, assignment.addon_id)

        build_row(
          assignment.agent_uid,
          assignment.addon_id,
          package,
          assignment,
          status,
          scans_by_agent,
          agent_labels
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
          scans_by_agent,
          agent_labels
        )
      end)

    catalog_only_rows = catalog_only_rows(packages, assignments, statuses)

    Enum.sort_by(
      assigned_rows ++ observed_only_rows ++ catalog_only_rows,
      &{String.downcase(&1.agent_label), &1.addon_id}
    )
  end

  @doc """
  Distinct add-on ids present in the matrix, for the add-on filter dropdown.
  """
  @spec addon_ids([row()]) :: [String.t()]
  def addon_ids(rows) do
    rows |> Enum.map(& &1.addon_id) |> Enum.uniq() |> Enum.sort()
  end

  @doc """
  Distinct agents present in the matrix, for the agent filter dropdown.
  Returns `{label, agent_uid}` tuples; catalog-only rows (nil agent) are excluded.
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

  defp maybe_filter(rows, nil, _fun), do: rows
  defp maybe_filter(rows, _value, fun), do: Enum.filter(rows, fun)

  # --- row construction -----------------------------------------------------

  defp build_row(agent_uid, addon_id, package, assignment, status, scans_by_agent, agent_labels) do
    collector? = MapSet.member?(@collector_addon_ids, addon_id)
    last_scan_at = if collector?, do: Map.get(scans_by_agent, agent_uid)

    attention = attention_flags(package, assignment, status)

    %{
      agent_uid: agent_uid,
      agent_label: Map.get(agent_labels, agent_uid, agent_uid || "—"),
      addon_id: addon_id,
      addon_name: package_name(package, addon_id),
      assigned_version: package && package.version,
      content_hash: package && package.source_oci_digest,
      package_status: package && package.status,
      verification_status: package && package.verification_status,
      approved?: package_approved?(package),
      assigned?: not is_nil(assignment),
      enabled?: assignment != nil and assignment.enabled,
      running_state: status && status.state,
      running_version: status && status.version,
      active?: status != nil and status.active,
      degradation_reason: status && present(status.degradation_reason),
      reported_at: status && status.reported_at,
      last_scan_at: last_scan_at,
      collector?: collector?,
      attention: attention,
      attention?: attention != []
    }
  end

  defp catalog_only_rows(packages, assignments, statuses) do
    assigned_addon_ids = MapSet.new(assignments, & &1.addon_id)
    observed_addon_ids = MapSet.new(statuses, & &1.addon_id)
    seen = MapSet.union(assigned_addon_ids, observed_addon_ids)

    packages
    |> Enum.group_by(& &1.addon_id)
    |> Enum.reject(fn {addon_id, _pkgs} -> MapSet.member?(seen, addon_id) end)
    |> Enum.map(fn {addon_id, pkgs} ->
      package = latest_package(pkgs)
      attention = attention_flags(package, nil, nil)

      %{
        agent_uid: nil,
        agent_label: "— (catalog only)",
        addon_id: addon_id,
        addon_name: package_name(package, addon_id),
        assigned_version: package.version,
        content_hash: package.source_oci_digest,
        package_status: package.status,
        verification_status: package.verification_status,
        approved?: package_approved?(package),
        assigned?: false,
        enabled?: false,
        running_state: nil,
        running_version: nil,
        active?: false,
        degradation_reason: nil,
        reported_at: nil,
        last_scan_at: nil,
        collector?: MapSet.member?(@collector_addon_ids, addon_id),
        attention: attention,
        attention?: attention != []
      }
    end)
  end

  # --- "needs attention" classification -------------------------------------
  #
  # Mirrors the per-agent drift semantics in AgentLive.Show so the fleet view and
  # the agent detail page agree on what counts as a problem.

  defp attention_flags(package, assignment, status) do
    []
    |> staged_not_approved(package, assignment)
    |> assigned_not_running(assignment, status)
    |> stopped_or_inactive(assignment, status)
    |> version_drift(package, status)
    |> observed_unassigned(assignment, status)
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

  defp version_drift(flags, %AddonPackage{version: assigned}, %AddonStatus{version: running})
       when is_binary(assigned) and is_binary(running) and assigned != running do
    [:version_drift | flags]
  end

  defp version_drift(flags, _package, _status), do: flags

  defp observed_unassigned(flags, nil, %AddonStatus{}), do: [:observed_unassigned | flags]
  defp observed_unassigned(flags, _assignment, _status), do: flags

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

  # Prefer the newest approved import; fall back to the newest import overall so a
  # status-only row (observed but no assignment) still shows a content hash.
  defp latest_package([]), do: nil

  defp latest_package(packages) do
    approved = Enum.filter(packages, &(&1.status == :approved))
    pool = if approved == [], do: packages, else: approved
    Enum.max_by(pool, &package_sort_key/1)
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
