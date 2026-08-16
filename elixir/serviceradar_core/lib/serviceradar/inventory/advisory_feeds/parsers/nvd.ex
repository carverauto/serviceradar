defmodule ServiceRadar.Inventory.AdvisoryFeeds.Parsers.Nvd do
  @moduledoc """
  Parser for NVD CVE 2.0 records (the shape inside VulnCheck `nist-nvd2` shards
  and the NVD CVE 2.0 REST API).

  Each input is one decoded `vulnerabilities[]` element: `%{"cve" => %{...}}`.
  This module maps that to a normalized advisory map plus a list of CPE
  coordinate maps (one per `cpeMatch`), extracting version bounds.

  Pure module — no DB, no IO. The streaming layer is responsible for decoding
  one record at a time off disk and handing it here.
  """

  alias ServiceRadar.Inventory.AdvisoryFeeds.Cpe
  alias ServiceRadar.Inventory.AdvisoryFeeds.Cwes
  alias ServiceRadar.Inventory.AdvisoryFeeds.VersionRange

  @provider "nvd"

  @doc """
  Map one NVD 2.0 `{"cve" => ...}` element to `%{advisory: map, coordinates: [map]}`.

  Returns `:skip` when the record has no usable CVE id.
  """
  @spec parse_record(map(), keyword()) :: {:ok, map()} | :skip
  def parse_record(%{"cve" => cve}, opts) when is_map(cve) do
    feed_key = Keyword.get(opts, :feed_key, "nist-nvd2")
    provider = Keyword.get(opts, :provider, @provider)

    case cve["id"] do
      cve_id when is_binary(cve_id) and cve_id != "" ->
        coordinates = configurations_coordinates(cve)

        advisory = %{
          provider: provider,
          feed_key: feed_key,
          source_object_id: cve_id,
          advisory_id: cve_id,
          cve_id: cve_id,
          title: cve_id,
          description: english_description(cve),
          severity: severity(cve),
          cvss_score: cvss_score(cve),
          cvss_vector: cvss_vector(cve),
          published_at: cve["published"],
          modified_at: cve["lastModified"],
          kev: false,
          exploit_available: false,
          references: references(cve),
          metadata: %{"cwes" => Cwes.from_nvd_cve(cve)},
          # Do not persist the full NVD object. Writing ~360k fat jsonb values
          # through a GIN index is what made a nist-nvd2 run take an hour.
          raw: slim_raw(cve_id, cve)
        }

        {:ok, %{advisory: advisory, coordinates: coordinates}}

      _ ->
        :skip
    end
  end

  def parse_record(_record, _opts), do: :skip

  defp configurations_coordinates(cve) do
    cve
    |> Map.get("configurations", [])
    |> List.wrap()
    |> Enum.flat_map(fn config ->
      config
      |> Map.get("nodes", [])
      |> List.wrap()
      |> Enum.flat_map(&node_coordinates/1)
    end)
    # Identity is CPE + version window. matchCriteriaId and inclusivity flags
    # can differ on otherwise identical NVD cpeMatch rows; those extras must
    # not survive or the coordinate upsert collides.
    |> Enum.uniq_by(&{&1.value, &1.version_start, &1.version_end})
  end

  defp node_coordinates(node) when is_map(node) do
    node
    |> Map.get("cpeMatch", [])
    |> List.wrap()
    |> Enum.filter(&vulnerable?/1)
    |> Enum.map(&cpe_match_coordinate/1)
    |> Enum.reject(&is_nil/1)
  end

  defp node_coordinates(_), do: []

  defp vulnerable?(%{"vulnerable" => false}), do: false
  defp vulnerable?(_), do: true

  defp cpe_match_coordinate(%{"criteria" => criteria} = match) when is_binary(criteria) do
    components = Cpe.parse_components(criteria)
    bounds = VersionRange.from_cpe_match(match)

    %{
      coordinate_type: "cpe",
      value: criteria,
      cpe_part: components.part,
      cpe_vendor: components.vendor,
      cpe_product: components.product,
      cpe_version: components.version,
      version_start: bounds.version_start,
      version_start_inclusive: bounds.version_start_inclusive,
      version_end: bounds.version_end,
      version_end_inclusive: bounds.version_end_inclusive,
      metadata: %{"match_criteria_id" => match["matchCriteriaId"]}
    }
  end

  defp cpe_match_coordinate(_), do: nil

  defp slim_raw(cve_id, cve) do
    %{"cve" => %{"id" => cve_id, "lastModified" => cve["lastModified"]}}
  end

  defp english_description(cve) do
    cve
    |> Map.get("descriptions", [])
    |> List.wrap()
    |> Enum.find_value(fn
      %{"lang" => "en", "value" => value} when is_binary(value) -> value
      _ -> nil
    end)
  end

  defp references(cve) do
    cve
    |> Map.get("references", [])
    |> List.wrap()
    |> Enum.map(fn
      %{"url" => url} when is_binary(url) -> url
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  # NVD 2.0 metrics: prefer CVSS v3.1 > v3.0 > v2.
  defp cvss_metric(cve) do
    metrics = Map.get(cve, "metrics", %{})

    primary(metrics["cvssMetricV31"]) || primary(metrics["cvssMetricV30"]) ||
      primary(metrics["cvssMetricV2"])
  end

  defp primary(nil), do: nil

  defp primary(list) when is_list(list) do
    Enum.find(list, fn m -> m["type"] == "Primary" end) || List.first(list)
  end

  defp cvss_score(cve) do
    case cvss_metric(cve) do
      %{"cvssData" => %{"baseScore" => score}} when is_number(score) -> score / 1
      _ -> nil
    end
  end

  defp cvss_vector(cve) do
    case cvss_metric(cve) do
      %{"cvssData" => %{"vectorString" => vector}} when is_binary(vector) -> vector
      _ -> nil
    end
  end

  defp severity(cve) do
    case cvss_metric(cve) do
      %{"cvssData" => %{"baseSeverity" => severity}} when is_binary(severity) ->
        String.downcase(severity)

      %{"baseSeverity" => severity} when is_binary(severity) ->
        String.downcase(severity)

      _ ->
        nil
    end
  end
end
