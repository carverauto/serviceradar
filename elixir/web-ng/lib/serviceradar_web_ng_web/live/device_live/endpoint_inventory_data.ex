defmodule ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryData do
  @moduledoc false

  alias ServiceRadar.Inventory.AdvisoryFeeds.CvePriority
  alias ServiceRadar.Inventory.AdvisoryFeeds.Cwes
  alias ServiceRadar.Inventory.EndpointInventoryArtifact
  alias ServiceRadar.Inventory.EndpointInventoryPackage
  alias ServiceRadar.Inventory.EndpointInventoryScan
  alias ServiceRadar.Inventory.EndpointVulnerabilityMatch
  alias ServiceRadar.Inventory.VulnerabilityAdvisory

  require Ash.Query
  require Logger

  @scan_limit 8
  @match_limit 50
  @default_page_size 100
  @max_page_size 500

  def default_page_size, do: @default_page_size

  def load(scope, device_uid, package_opts \\ [])

  def load(scope, device_uid, package_opts) when is_binary(device_uid) and device_uid != "" do
    with {:ok, scans} <- read_current_scans(scope, device_uid),
         latest_scan = List.first(scans),
         {:ok, package_page} <- read_current_packages(scope, device_uid, package_opts),
         {:ok, artifacts} <- read_artifacts(scope, latest_scan) do
      vulnerability_matches =
        scope
        |> read_vulnerability_matches_optional(device_uid)
        |> enrich_matches(scope)

      stored_package_count = read_stored_package_count(scope, device_uid)

      %{
        scan: latest_scan,
        scans: scans,
        packages: package_page.packages,
        package_total: package_page.total,
        package_page: package_page.page,
        package_page_size: package_page.page_size,
        package_filters_active: package_page.filters_active,
        stored_package_count: stored_package_count,
        artifacts: artifacts,
        vulnerability_matches: vulnerability_matches,
        cpe_catalog_current: CvePriority.cpe_catalog_current?(),
        error: nil,
        has_inventory: scans != [] or package_page.packages != [] or vulnerability_matches != []
      }
    else
      {:error, reason} ->
        Logger.warning("Failed to load endpoint inventory for #{device_uid}: #{inspect(reason)}")

        Map.merge(empty(), %{
          error: "Failed to load endpoint software inventory.",
          has_inventory: true
        })
    end
  end

  def load(_scope, _device_uid, _package_opts), do: empty()

  @doc """
  Reloads only the paginated/filterable package page for a device, leaving the
  rest of the inventory snapshot untouched. Used when the user changes the
  package search filters or pages through the list.

  Returns `{:ok, page}` where `page` carries `:packages`, `:total` (matching
  rows), `:page`, `:page_size`, `:filters_active` and `:stored_package_count`
  (all current rows, unfiltered), or `:error`.
  """
  def load_packages(scope, device_uid, package_opts \\ [])

  def load_packages(scope, device_uid, package_opts) when is_binary(device_uid) and device_uid != "" do
    case read_current_packages(scope, device_uid, package_opts) do
      {:ok, page} ->
        {:ok, Map.put(page, :stored_package_count, read_stored_package_count(scope, device_uid))}

      {:error, reason} ->
        Logger.warning("Failed to load endpoint inventory packages for #{device_uid}: #{inspect(reason)}")

        :error
    end
  end

  def load_packages(_scope, _device_uid, _package_opts), do: :error

  @doc """
  Loads every vulnerability match (any status) for a single endpoint package on a
  device, with the advisory relationship preloaded so the package-detail modal can
  link out to references. Returns a list (empty when no matches or on failure).
  """
  def load_package_vulnerabilities(scope, device_uid, endpoint_package_ref)
      when is_binary(device_uid) and is_binary(endpoint_package_ref) do
    if device_uid == "" or endpoint_package_ref == "" do
      []
    else
      scope
      |> read_package_vulnerabilities(device_uid, endpoint_package_ref)
      |> enrich_matches(scope)
    end
  end

  def load_package_vulnerabilities(_scope, _device_uid, _endpoint_package_ref), do: []

  @doc """
  Loads the advisory relationship onto a match so the match-detail modal can
  show description and reference URLs. Returns the original match on failure.
  """
  def load_match_advisory(scope, %EndpointVulnerabilityMatch{} = match) do
    case Ash.load(match, [:advisory], scope: scope) do
      {:ok, loaded} ->
        loaded

      {:error, reason} ->
        Logger.warning("Failed to load advisory for vulnerability match: #{inspect(reason)}")
        match
    end
  end

  def load_match_advisory(_scope, match), do: match

  @doc """
  Overlay NVD CVSS/CWE onto KEV (and other) matches. KEV rows store no score;
  nist-nvd2 has it, even when that generation is not yet `current`.
  """
  def enrich_matches(matches, scope) when is_list(matches) do
    metrics = nvd_metrics_by_cve(scope, cve_ids(matches))

    Enum.map(matches, fn match ->
      apply_nvd_metrics(match, metrics)
    end)
  end

  def enrich_matches(matches, _scope), do: matches

  def apply_nvd_metrics(match, metrics_by_cve) when is_map(metrics_by_cve) do
    cve = field(match, :cve_id)
    nvd = if is_binary(cve), do: Map.get(metrics_by_cve, cve)
    advisory = match_advisory(match)
    cwes = merge_cwes(advisory, nvd)
    cvss = field(match, :cvss_score) || field(nvd, :cvss_score)
    vector = field(nvd, :cvss_vector)
    severity = field(match, :severity) || field(nvd, :severity)
    metadata = overlay_metadata(field(match, :metadata), cwes, vector)

    match
    |> put_display_field(:cvss_score, cvss)
    |> put_display_field(:severity, severity)
    |> put_display_field(:metadata, metadata)
    |> put_display_field(:cwes, cwes)
    |> overlay_loaded_advisory(nvd, cwes)
  end

  def apply_nvd_metrics(match, _metrics_by_cve), do: match

  defp read_package_vulnerabilities(scope, device_uid, endpoint_package_ref) do
    EndpointVulnerabilityMatch
    |> Ash.Query.for_read(
      :current_by_device_and_package,
      %{device_uid: device_uid, endpoint_package_ref: endpoint_package_ref},
      scope: scope
    )
    |> Ash.Query.limit(@match_limit)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, matches} ->
        matches

      {:error, reason} ->
        Logger.warning(
          "Failed to load package vulnerabilities for #{device_uid}/#{endpoint_package_ref}: #{inspect(reason)}"
        )

        []
    end
  end

  defp empty do
    %{
      scan: nil,
      scans: [],
      packages: [],
      package_total: 0,
      package_page: 1,
      package_page_size: @default_page_size,
      package_filters_active: false,
      stored_package_count: 0,
      artifacts: [],
      vulnerability_matches: [],
      cpe_catalog_current: true,
      error: nil,
      has_inventory: false
    }
  end

  defp read_current_scans(scope, device_uid) do
    EndpointInventoryScan
    |> Ash.Query.for_read(:current_by_device, %{device_uid: device_uid}, scope: scope)
    |> Ash.Query.limit(@scan_limit)
    |> Ash.read(scope: scope)
  end

  defp read_current_packages(scope, device_uid, package_opts) do
    filters = package_filters(package_opts)
    page_size = page_size(package_opts)
    page = page_number(package_opts)
    offset = (page - 1) * page_size
    args = Map.merge(%{device_uid: device_uid}, filters)

    EndpointInventoryPackage
    |> Ash.Query.for_read(:current_by_device_paged, args, scope: scope)
    |> Ash.read(scope: scope, page: [limit: page_size, offset: offset, count: true])
    |> case do
      {:ok, %Ash.Page.Offset{results: results, count: count}} ->
        {:ok,
         %{
           packages: results,
           total: count || length(results),
           page: page,
           page_size: page_size,
           filters_active: filters != %{}
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_stored_package_count(scope, device_uid) do
    EndpointInventoryPackage
    |> Ash.Query.for_read(:count_current_by_device, %{device_uid: device_uid}, scope: scope)
    |> Ash.count(scope: scope)
    |> case do
      {:ok, count} -> count
      _ -> 0
    end
  end

  defp package_filters(package_opts) do
    package_opts
    |> Keyword.get(:filters, %{})
    |> Map.take([:q, :package_manager, :version, :purl, :cpe])
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case clean(value) do
        nil -> acc
        cleaned -> Map.put(acc, key, cleaned)
      end
    end)
  end

  defp page_size(package_opts) do
    package_opts
    |> Keyword.get(:page_size, @default_page_size)
    |> clamp(1, @max_page_size, @default_page_size)
  end

  defp page_number(package_opts) do
    package_opts
    |> Keyword.get(:page, 1)
    |> clamp(1, nil, 1)
  end

  defp clamp(value, min, max, _default) when is_integer(value) do
    cond do
      value < min -> min
      is_integer(max) and value > max -> max
      true -> value
    end
  end

  defp clamp(_value, _min, _max, default), do: default

  defp clean(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp clean(_value), do: nil

  defp read_vulnerability_matches(scope, device_uid) do
    EndpointVulnerabilityMatch
    |> Ash.Query.for_read(:current_by_device, %{device_uid: device_uid}, scope: scope)
    |> Ash.Query.limit(@match_limit)
    |> Ash.read(scope: scope)
  end

  defp read_vulnerability_matches_optional(scope, device_uid) do
    case read_vulnerability_matches(scope, device_uid) do
      {:ok, matches} ->
        matches

      {:error, reason} ->
        Logger.warning("Failed to load endpoint vulnerability matches for #{device_uid}: #{inspect(reason)}")

        []
    end
  end

  defp read_artifacts(_scope, nil), do: {:ok, []}

  defp read_artifacts(scope, scan) do
    EndpointInventoryArtifact
    |> Ash.Query.for_read(:by_scan, %{scan_ref: scan.id}, scope: scope)
    |> Ash.Query.limit(12)
    |> Ash.read(scope: scope)
  end

  defp nvd_metrics_by_cve(nil, _cve_ids), do: %{}
  defp nvd_metrics_by_cve(_scope, []), do: %{}

  defp nvd_metrics_by_cve(scope, cve_ids) do
    VulnerabilityAdvisory
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.filter(provider == "nvd" and cve_id in ^cve_ids)
    |> Ash.Query.sort(generation: :desc)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, advisories} ->
        advisories
        |> Enum.group_by(& &1.cve_id)
        |> Map.new(fn {cve, rows} ->
          row = Enum.find(rows, & &1.cvss_score) || List.first(rows)
          {cve, metrics_from_advisory(row)}
        end)

      {:error, reason} ->
        Logger.warning("Failed to load NVD metrics for vulnerability matches: #{inspect(reason)}")
        %{}
    end
  end

  defp metrics_from_advisory(nil), do: %{}

  defp metrics_from_advisory(advisory) do
    %{
      cvss_score: field(advisory, :cvss_score),
      cvss_vector: field(advisory, :cvss_vector),
      severity: field(advisory, :severity),
      cwes: Cwes.from_advisory(advisory)
    }
  end

  defp cve_ids(matches) do
    matches
    |> Enum.map(&field(&1, :cve_id))
    |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, "CVE-")))
    |> Enum.uniq()
  end

  defp match_advisory(match) do
    case field(match, :advisory) do
      %{} = advisory -> advisory
      _ -> %{}
    end
  end

  defp merge_cwes(advisory, nvd) do
    Enum.uniq(Cwes.from_advisory(advisory) ++ List.wrap(field(nvd, :cwes)))
  end

  defp overlay_metadata(metadata, cwes, vector) do
    (metadata || %{})
    |> Map.put("cwes", cwes)
    |> then(fn map ->
      if is_binary(vector) and vector != "" do
        Map.put(map, "cvss_vector", vector)
      else
        map
      end
    end)
  end

  defp overlay_loaded_advisory(match, nvd, cwes) do
    case field(match, :advisory) do
      %{__struct__: _} = advisory ->
        put_display_field(match, :advisory, overlay_advisory(advisory, nvd, cwes))

      %{} = advisory ->
        put_display_field(match, :advisory, overlay_advisory(advisory, nvd, cwes))

      _ ->
        match
    end
  end

  defp overlay_advisory(advisory, nvd, cwes) when is_map(advisory) do
    advisory
    |> put_display_field(:cvss_score, field(advisory, :cvss_score) || field(nvd, :cvss_score))
    |> put_display_field(:cvss_vector, field(advisory, :cvss_vector) || field(nvd, :cvss_vector))
    |> put_display_field(:severity, field(advisory, :severity) || field(nvd, :severity))
    |> put_display_field(
      :metadata,
      overlay_metadata(field(advisory, :metadata), cwes, field(nvd, :cvss_vector))
    )
  end

  defp overlay_advisory(advisory, _nvd, _cwes), do: advisory

  defp put_display_field(row, :cwes, value) when is_struct(row) do
    metadata = overlay_metadata(field(row, :metadata), value, nil)
    put_display_field(row, :metadata, metadata)
  end

  defp put_display_field(row, key, value) when is_struct(row) do
    if Map.has_key?(row, key), do: Map.put(row, key, value), else: row
  end

  defp put_display_field(row, key, value) when is_map(row), do: Map.put(row, key, value)
  defp put_display_field(row, _key, _value), do: row

  defp field(nil, _key), do: nil

  defp field(%{} = row, key) do
    cond do
      Map.has_key?(row, key) -> Map.get(row, key)
      Map.has_key?(row, to_string(key)) -> Map.get(row, to_string(key))
      true -> nil
    end
  end

  defp field(_row, _key), do: nil
end
