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

  alias ServiceRadar.Inventory.AdvisoryFeeds.Cwes
  alias ServiceRadar.Inventory.AdvisoryFeeds.NvdApplicability

  @provider "nvd"

  @doc "Version of the normalized NVD content written by this parser."
  @spec normalization_version() :: pos_integer()
  def normalization_version, do: NvdApplicability.expression_version()

  @doc """
  Map one NVD 2.0 `{"cve" => ...}` element to the loader record contract.

  Returns `:skip` when the record has no usable CVE id.
  """
  @spec parse_record(map(), keyword()) :: {:ok, map()} | :skip
  def parse_record(%{"cve" => cve} = record, opts) when is_map(cve) do
    feed_key = Keyword.get(opts, :feed_key, "nist-nvd2")
    provider = Keyword.get(opts, :provider, @provider)

    case cve["id"] do
      cve_id when is_binary(cve_id) and cve_id != "" ->
        {:ok, normalized} = NvdApplicability.normalize(Map.get(cve, "configurations", []))

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
          metadata: %{
            "cwes" => Cwes.from_nvd_cve(cve),
            "normalization_version" => normalized.expression_version
          },
          raw: record
        }

        {:ok, %{advisory: advisory, coordinates: normalized.coordinates, assertions: []}}

      _ ->
        :skip
    end
  end

  def parse_record(_record, _opts), do: :skip

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
