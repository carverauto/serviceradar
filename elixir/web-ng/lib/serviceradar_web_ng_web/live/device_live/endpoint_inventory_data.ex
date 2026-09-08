defmodule ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryData do
  @moduledoc false

  alias ServiceRadar.Inventory.AdvisoryFeeds.CvePriority
  alias ServiceRadar.Inventory.AdvisoryFeeds.Cwes
  alias ServiceRadar.Inventory.EndpointInventoryArtifact
  alias ServiceRadar.Inventory.EndpointInventoryPackage
  alias ServiceRadar.Inventory.EndpointInventoryScan
  alias ServiceRadar.Inventory.EndpointVulnerabilityAssessment
  alias ServiceRadar.Inventory.EndpointVulnerabilityMatch
  alias ServiceRadar.Inventory.VulnerabilityAdvisory

  require Ash.Query
  require Logger

  @scan_limit 8
  @assessment_limit 50
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
      vulnerability_assessments = read_assessment_pages(scope, device_uid)

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
        vulnerability_assessments: vulnerability_assessments,
        cpe_catalog_current: CvePriority.cpe_catalog_current?(),
        error: nil,
        has_inventory:
          scans != [] or package_page.packages != [] or
            assessment_total(vulnerability_assessments) > 0
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
  Loads every persisted assessment state for one package plus a separately
  bounded set of supporting raw matches/advisories. Raw rows enrich the modal;
  they never determine applicability or multiply assessment rows.
  """
  def load_package_vulnerabilities(scope, device_uid, endpoint_package_ref)
      when is_binary(device_uid) and is_binary(endpoint_package_ref) do
    if device_uid == "" or endpoint_package_ref == "" do
      empty_package_assessment_details()
    else
      assessments = read_package_assessments(scope, device_uid, endpoint_package_ref)
      {supporting_matches, supporting_total} = read_package_supporting_matches(scope, device_uid, endpoint_package_ref)

      %{
        assessments: assessments,
        supporting_matches: enrich_matches(supporting_matches, scope),
        supporting_matches_total: supporting_total,
        supporting_matches_truncated?: supporting_total > length(supporting_matches)
      }
    end
  end

  def load_package_vulnerabilities(_scope, _device_uid, _endpoint_package_ref), do: empty_package_assessment_details()

  @doc "Loads bounded raw match/advisory enrichment for the supplied assessments."
  def load_supporting_matches(scope, assessments) when is_list(assessments) do
    assessments
    |> Enum.group_by(&field(&1, :endpoint_package_ref))
    |> Enum.flat_map(fn
      {package_ref, rows} when not is_nil(package_ref) ->
        device_uid = rows |> List.first() |> field(:device_uid)

        case {device_uid, to_string(package_ref)} do
          {uid, ref} when is_binary(uid) and uid != "" and ref != "" ->
            {matches, _total} = read_package_supporting_matches(scope, uid, ref)
            matches

          _ ->
            []
        end

      _ ->
        []
    end)
    |> Enum.uniq_by(&(&1 |> field(:id) |> to_string()))
    |> enrich_matches(scope)
  end

  def load_supporting_matches(_scope, _assessments), do: []

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

  defp read_package_assessments(scope, device_uid, endpoint_package_ref) do
    EndpointVulnerabilityAssessment
    |> Ash.Query.for_read(
      :by_device_and_package,
      %{device_uid: device_uid, endpoint_package_ref: endpoint_package_ref},
      scope: scope
    )
    |> Ash.read(scope: scope)
    |> case do
      {:ok, assessments} ->
        assessments

      {:error, reason} ->
        Logger.warning(
          "Failed to load package vulnerability assessments for #{device_uid}/#{endpoint_package_ref}: #{inspect(reason)}"
        )

        []
    end
  end

  defp read_package_supporting_matches(scope, device_uid, endpoint_package_ref) do
    query =
      Ash.Query.for_read(
        EndpointVulnerabilityMatch,
        :current_by_device_and_package,
        %{device_uid: device_uid, endpoint_package_ref: endpoint_package_ref},
        scope: scope
      )

    total =
      case Ash.count(query, scope: scope) do
        {:ok, count} -> count
        _ -> 0
      end

    query
    |> Ash.Query.limit(@match_limit)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, matches} ->
        {matches, total}

      {:error, reason} ->
        Logger.warning(
          "Failed to load supporting vulnerability matches for #{device_uid}/#{endpoint_package_ref}: #{inspect(reason)}"
        )

        {[], total}
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
      vulnerability_assessments: empty_assessment_pages(),
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

  @doc false
  def empty_assessment_pages do
    %{
      confirmed: empty_assessment_page(),
      candidates: empty_assessment_page(),
      history: empty_assessment_page()
    }
  end

  defp empty_package_assessment_details do
    %{
      assessments: [],
      supporting_matches: [],
      supporting_matches_total: 0,
      supporting_matches_truncated?: false
    }
  end

  defp read_assessment_pages(scope, device_uid) do
    %{
      confirmed: read_assessment_page(scope, device_uid, :actionable_by_device),
      candidates: read_assessment_page(scope, device_uid, :candidates_by_device),
      history: read_assessment_page(scope, device_uid, :history_by_device)
    }
  end

  defp read_assessment_page(scope, device_uid, action) do
    query = Ash.Query.for_read(EndpointVulnerabilityAssessment, action, %{device_uid: device_uid}, scope: scope)

    with {:ok, total} <- Ash.count(query, scope: scope),
         {:ok, rows} <- query |> Ash.Query.limit(@assessment_limit) |> Ash.read(scope: scope) do
      %{
        rows: rows,
        total: total,
        limit: @assessment_limit,
        truncated?: total > length(rows)
      }
    else
      {:error, reason} ->
        Logger.warning("Failed to load endpoint vulnerability assessment #{action} for #{device_uid}: #{inspect(reason)}")

        empty_assessment_page()
    end
  end

  defp empty_assessment_page do
    %{rows: [], total: 0, limit: @assessment_limit, truncated?: false}
  end

  defp assessment_total(pages) do
    pages
    |> Map.values()
    |> Enum.sum_by(&(field(&1, :total) || 0))
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
