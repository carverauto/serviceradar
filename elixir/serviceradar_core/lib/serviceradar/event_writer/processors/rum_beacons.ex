defmodule ServiceRadar.EventWriter.Processors.RumBeacons do
  @moduledoc """
  Persists Boomerang RUM beacons delivered on `rum.beacons.>`.

  Enforces strict single-active-store semantics:
  - When StarRocks is enabled, rows are Stream Loaded exclusively into
    `serviceradar.rum_beacons` (never written to CNPG).
  - When StarRocks is disabled, rows are bulk-inserted exclusively into the
    CNPG hypertable `platform.rum_beacons` with idempotent upsert conflict
    handling on `(web_property_id, beacon_id, observed_at)`.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.EventWriter.BulkInsert
  alias Serviceradar.Rum.V1.RumBeaconV1

  require Logger

  @impl true
  def table_name, do: "rum_beacons"

  @impl true
  def process_batch(messages), do: process_batch(messages, [])

  @doc false
  # `:starrocks_enabled` and `:load` allow deterministic DB-free unit testing.
  def process_batch(messages, opts) when is_list(messages) and is_list(opts) do
    {rows, rejected} = decode(messages)

    if rejected > 0 do
      Logger.warning("RumBeacons dropped undecodable messages", count: rejected)
    end

    cond do
      rows == [] ->
        {:ok, 0}

      Keyword.get_lazy(opts, :starrocks_enabled, &Destination.enabled?/0) ->
        load(rows, opts)

      true ->
        insert(rows)
    end
  end

  @impl true
  def parse_message(%{data: data}) when is_binary(data) do
    case decode_payload(data) do
      {:ok, row} -> row
      :error -> nil
    end
  end

  def parse_message(_message), do: nil

  defp decode(messages) do
    {rows, rejected} =
      Enum.reduce(messages, {[], 0}, fn message, {rows, rejected} ->
        case parse_message(message) do
          nil -> {rows, rejected + 1}
          row -> {[row | rows], rejected}
        end
      end)

    {Enum.reverse(rows), rejected}
  end

  defp decode_payload(data) do
    with :error <- decode_protobuf(data) do
      decode_json(data)
    end
  end

  defp decode_protobuf(data) do
    case RumBeaconV1.decode(data) do
      %RumBeaconV1{} = proto -> proto_to_row(proto)
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp decode_json(data) do
    with {:ok, %{} = map} <- Jason.decode(data),
         {:ok, row} <- map_to_row(map) do
      {:ok, row}
    else
      _ -> :error
    end
  end

  defp proto_to_row(%RumBeaconV1{} = p) do
    with true <- non_empty?(p.web_property_id),
         true <- non_empty?(p.beacon_id),
         true <- is_integer(p.observed_at_unix_ms) and p.observed_at_unix_ms > 0,
         {:ok, observed_at} <- DateTime.from_unix(p.observed_at_unix_ms, :millisecond),
         true <- valid_text?(p.url) and valid_text?(p.canonical_origin) do
      {:ok,
       %{
         web_property_id: p.web_property_id,
         observed_at: observed_at,
         beacon_id: p.beacon_id,
         canonical_origin: text(p.canonical_origin),
         environment: text(p.environment),
         url: text(p.url),
         host: text(p.host),
         path: text(p.path),
         metric_path: text(p.metric_path),
         referrer: text(p.referrer),
         page_group: text(p.page_group),
         initiator: text(p.initiator),
         trace_id: text(p.trace_id),
         span_id: text(p.span_id),
         session_id: text(p.session_id),
         user_agent: text(p.user_agent),
         device_type: text(p.device_type),
         browser: text(p.browser),
         os: text(p.os),
         lcp_ms: optional_float(p.lcp_ms),
         inp_ms: optional_float(p.inp_ms),
         cls: optional_float(p.cls),
         fcp_ms: optional_float(p.fcp_ms),
         ttfb_ms: optional_float(p.ttfb_ms),
         page_load_ms: optional_float(p.page_load_ms),
         dns_ms: optional_float(p.dns_ms),
         connect_ms: optional_float(p.connect_ms),
         tls_ms: optional_float(p.tls_ms),
         dom_ready_ms: optional_float(p.dom_ready_ms),
         rage_clicks: non_neg_int(p.rage_clicks),
         js_errors: non_neg_int(p.js_errors),
         http_status: non_neg_int(p.http_status),
         has_error: p.has_error == true,
         cdn_provider: text(p.cdn_provider),
         cdn_cache_status: text(p.cdn_cache_status),
         cdn_edge_rtt_ms: optional_float(p.cdn_edge_rtt_ms),
         cdn_origin_rtt_ms: optional_float(p.cdn_origin_rtt_ms),
         cdn_pop: text(p.cdn_pop),
         server_timing_raw: text(p.server_timing_raw),
         client_ip: text(p.client_ip),
         client_ip_anonymized: p.client_ip_anonymized != false,
         country: text(p.country),
         region: text(p.region),
         city: text(p.city),
         asn: positive_int(p.asn),
         as_org: text(p.as_org),
         prefix_tag: text(p.prefix_tag),
         attributes: normalize_attrs(p.attributes),
         created_at: DateTime.utc_now()
       }}
    else
      _ -> :error
    end
  end

  defp map_to_row(m) do
    with web_property_id when is_binary(web_property_id) and web_property_id != "" <-
           m["web_property_id"],
         beacon_id when is_binary(beacon_id) and beacon_id != "" <- m["beacon_id"],
         {:ok, observed_at} <- parse_observed_at(m) do
      {:ok,
       %{
         web_property_id: web_property_id,
         observed_at: observed_at,
         beacon_id: beacon_id,
         canonical_origin: text(m["canonical_origin"]),
         environment: text(m["environment"]),
         url: text(m["url"]),
         host: text(m["host"]),
         path: text(m["path"]),
         metric_path: text(m["metric_path"]),
         referrer: text(m["referrer"]),
         page_group: text(m["page_group"]),
         initiator: text(m["initiator"]),
         trace_id: text(m["trace_id"]),
         span_id: text(m["span_id"]),
         session_id: text(m["session_id"]),
         user_agent: text(m["user_agent"]),
         device_type: text(m["device_type"]),
         browser: text(m["browser"]),
         os: text(m["os"]),
         lcp_ms: optional_float(m["lcp_ms"]),
         inp_ms: optional_float(m["inp_ms"]),
         cls: optional_float(m["cls"]),
         fcp_ms: optional_float(m["fcp_ms"]),
         ttfb_ms: optional_float(m["ttfb_ms"]),
         page_load_ms: optional_float(m["page_load_ms"]),
         dns_ms: optional_float(m["dns_ms"]),
         connect_ms: optional_float(m["connect_ms"]),
         tls_ms: optional_float(m["tls_ms"]),
         dom_ready_ms: optional_float(m["dom_ready_ms"]),
         rage_clicks: non_neg_int(m["rage_clicks"]),
         js_errors: non_neg_int(m["js_errors"]),
         http_status: non_neg_int(m["http_status"]),
         has_error: m["has_error"] == true,
         cdn_provider: text(m["cdn_provider"]),
         cdn_cache_status: text(m["cdn_cache_status"]),
         cdn_edge_rtt_ms: optional_float(m["cdn_edge_rtt_ms"]),
         cdn_origin_rtt_ms: optional_float(m["cdn_origin_rtt_ms"]),
         cdn_pop: text(m["cdn_pop"]),
         server_timing_raw: text(m["server_timing_raw"]),
         client_ip: text(m["client_ip"]),
         client_ip_anonymized: m["client_ip_anonymized"] != false,
         country: text(m["country"]),
         region: text(m["region"]),
         city: text(m["city"]),
         asn: positive_int(m["asn"]),
         as_org: text(m["as_org"]),
         prefix_tag: text(m["prefix_tag"]),
         attributes: normalize_attrs(m["attributes"]),
         created_at: DateTime.utc_now()
       }}
    else
      _ -> :error
    end
  end

  defp parse_observed_at(%{"observed_at" => iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_observed_at(%{"observed_at_unix_ms" => ms}) when is_integer(ms) and ms > 0 do
    DateTime.from_unix(ms, :millisecond)
  end

  defp parse_observed_at(_), do: :error

  defp load(rows, opts) do
    load = Keyword.get(opts, :load, &Destination.persist_warehouse/2)

    case load.(:rum_beacons, rows) do
      {:ok, _result} -> {:ok, length(rows)}
      {:error, _reason} = error -> error
    end
  end

  defp insert(rows) do
    {count, _} =
      BulkInsert.insert_all(table_name(), rows,
        on_conflict: :nothing,
        conflict_target: [:web_property_id, :beacon_id, :observed_at],
        returning: false
      )

    {:ok, count}
  end

  defp non_empty?(v) when is_binary(v), do: String.trim(v) != "" and String.valid?(v)
  defp non_empty?(_), do: false

  defp valid_text?(v) when is_binary(v), do: String.valid?(v)
  defp valid_text?(nil), do: true
  defp valid_text?(_), do: false

  defp text(v) when is_binary(v) do
    trimmed = String.trim(v)
    if trimmed == "", do: nil, else: trimmed
  end

  defp text(_), do: nil

  defp optional_float(v) when is_float(v), do: v
  defp optional_float(v) when is_integer(v), do: v * 1.0
  defp optional_float(_), do: nil

  defp non_neg_int(v) when is_integer(v) and v >= 0, do: v
  defp non_neg_int(_), do: 0

  defp positive_int(v) when is_integer(v) and v > 0, do: v
  defp positive_int(_), do: nil

  defp normalize_attrs(%{} = map), do: map
  defp normalize_attrs(_), do: %{}
end
