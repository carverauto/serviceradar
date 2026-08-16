defmodule ServiceRadar.Inventory.AdvisoryFeeds.Parsers.Kev do
  @moduledoc """
  Parser for CISA-KEV-shaped records.

  Two feeds share this shape:

    * **CISA KEV** — `{"vulnerabilities" => [%{"cveID" => "CVE-...", ...}]}`,
      one CVE per entry, vendor/product strings, no CPEs.
    * **VulnCheck KEV** — a top-level **array** of CISA-KEV-shaped entries where
      `cve` is a **list** of CVE ids (e.g. `["CVE-2024-1", "CVE-2024-2"]`),
      `vendorProject`/`product` present, no CPEs. Enrichment only (`kev: true`).

  Each entry maps to one advisory plus a single `vendor_product` coordinate. CVE
  ids are recorded on the advisory; when an entry carries multiple CVE ids (the
  VulnCheck list shape) the first is used as the primary `cve_id` and the full
  list is preserved under metadata.

  Pure module — no DB, no IO.
  """

  alias ServiceRadar.Inventory.AdvisoryFeeds.Cwes

  @doc """
  Map one KEV entry to `%{advisory: map, coordinates: [map]}`.

  `opts` must carry `:provider` and `:feed_key`. Returns `:skip` for entries with
  no usable identifier.
  """
  @spec parse_record(map(), keyword()) :: {:ok, map()} | :skip
  def parse_record(entry, opts) when is_map(entry) do
    provider = Keyword.fetch!(opts, :provider)
    feed_key = Keyword.fetch!(opts, :feed_key)

    cve_ids = cve_ids(entry)
    primary_cve = List.first(cve_ids)
    source_object_id = primary_cve || get(entry, ["cveID", "id"])

    case source_object_id do
      id when is_binary(id) and id != "" ->
        vendor = get(entry, ["vendorProject", "vendor_project", "vendor"])
        product = get(entry, ["product"])

        advisory = %{
          provider: provider,
          feed_key: feed_key,
          source_object_id: id,
          advisory_id: id,
          cve_id: primary_cve,
          title: get(entry, ["vulnerabilityName", "name", "shortDescription"]) || id,
          description: get(entry, ["shortDescription", "description"]),
          severity: nil,
          cvss_score: nil,
          cvss_vector: nil,
          published_at: get(entry, ["dateAdded", "date_added"]),
          modified_at: nil,
          kev: true,
          exploit_available: true,
          references: references(entry),
          metadata: %{"cwes" => Cwes.from_kev_entry(entry)},
          raw: Map.put(entry, "_cve_ids", cve_ids)
        }

        {:ok,
         %{
           advisory: advisory,
           coordinates: vendor_product_coordinates(provider, feed_key, vendor, product)
         }}

      _ ->
        :skip
    end
  end

  def parse_record(_entry, _opts), do: :skip

  # VulnCheck: `cve` is a list. CISA: `cveID` is a single string.
  defp cve_ids(entry) do
    cond do
      is_list(entry["cve"]) -> Enum.filter(entry["cve"], &is_binary/1)
      is_binary(entry["cve"]) -> [entry["cve"]]
      is_binary(entry["cveID"]) -> [entry["cveID"]]
      true -> []
    end
  end

  defp vendor_product_coordinates(_provider, _feed_key, _vendor, nil), do: []

  defp vendor_product_coordinates(_provider, _feed_key, vendor, product)
       when is_binary(product) do
    if String.trim(product) == "" do
      []
    else
      [
        %{
          coordinate_type: "vendor_product",
          value: String.downcase(String.trim(product)),
          cpe_part: nil,
          cpe_vendor: normalize(vendor),
          cpe_product: normalize(product),
          cpe_version: nil,
          version_start: nil,
          version_start_inclusive: nil,
          version_end: nil,
          version_end_inclusive: nil,
          metadata: %{"vendor" => vendor, "product" => product}
        }
      ]
    end
  end

  defp references(entry) do
    refs =
      entry
      |> Map.get("vulncheck_xdb", [])
      |> List.wrap()

    notes = get(entry, ["notes"])

    (refs ++ List.wrap(notes))
    |> Enum.map(fn
      %{"url" => url} when is_binary(url) -> url
      url when is_binary(url) -> url
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize(nil), do: nil

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp get(_entry, []), do: nil

  defp get(entry, [key | rest]) do
    case Map.get(entry, key) do
      value when is_binary(value) and value != "" -> value
      _ -> get(entry, rest)
    end
  end
end
