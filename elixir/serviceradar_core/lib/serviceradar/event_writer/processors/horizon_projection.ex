defmodule ServiceRadar.EventWriter.Processors.HorizonProjection do
  @moduledoc """
  Fail-open projection from Horizon OCSF `log_activity` event rows into typed
  CNPG tables (`horizon_outages`, `horizon_bgp_events`, `horizon_bgp_zombies`).

  Called by `ServiceRadar.EventWriter.Processors.Events` on the CNPG events
  write path. Skipped when `:events` is routed to the StarRocks warehouse
  (`Destination.warehouse?(:events)`). Batches containing no `horizon.*`
  `log_name` values short-circuit with zero database calls, and each table's
  upsert fails open independently so primary OCSF event ingestion never fails.
  """

  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.EventWriter.BulkInsert
  alias ServiceRadar.EventWriter.FieldParser

  require Logger

  @outages_table "horizon_outages"
  @bgp_events_table "horizon_bgp_events"
  @bgp_zombies_table "horizon_bgp_zombies"

  @outage_replace_fields [
    :status,
    :severity,
    :entity_type,
    :entity_key,
    :region,
    :covering_prefix,
    :origin_asn,
    :corroborating_pop_count,
    :avg_forwarding_loss_pct,
    :avg_synthetic_failure_pct,
    :window_start_ms,
    :window_end_ms,
    :correlated_bgp_event_ids,
    :raw_data
  ]

  @bgp_event_replace_fields [
    :kind,
    :level,
    :prefix,
    :origin_asn,
    :as_path,
    :rpki_status,
    :caida_leak_inference,
    :watchlist_id,
    :client_label,
    :raw_data
  ]

  @bgp_zombie_replace_fields [
    :status,
    :prefix,
    :origin_asn,
    :divergence_pct,
    :is_beacon,
    :withdrawn_peers,
    :total_peers,
    :stuck_peer_asns,
    :first_seen_at,
    :resolved_at,
    :raw_data
  ]

  @doc """
  Projects any Horizon OCSF rows in `rows` into typed CNPG tables.

  Always returns `:ok` (fail-open). Accepts `insert_fn: fn table, rows, opts -> ... end`
  in `opts` for testing without a database connection.
  """
  @spec project_rows([map()], keyword()) :: :ok
  def project_rows(rows, opts \\ []) when is_list(rows) do
    if Destination.warehouse?(:events) do
      :ok
    else
      horizon_rows = Enum.filter(rows, &horizon_event?/1)

      if horizon_rows == [] do
        :ok
      else
        do_project(horizon_rows, opts)
      end
    end
  rescue
    error ->
      Logger.warning("Horizon OCSF projection failed (fail-open): #{Exception.message(error)}")

      :ok
  end

  @doc """
  Builds typed row lists for each Horizon table from OCSF event rows.
  """
  @spec build_projections([map()]) :: %{
          outages: [map()],
          bgp_events: [map()],
          bgp_zombies: [map()]
        }
  def build_projections(rows) when is_list(rows) do
    initial = %{outages: [], bgp_events: [], bgp_zombies: []}

    grouped =
      Enum.reduce(rows, initial, fn row, acc ->
        case project_row(row) do
          {:outage, projected} -> %{acc | outages: [projected | acc.outages]}
          {:bgp_event, projected} -> %{acc | bgp_events: [projected | acc.bgp_events]}
          {:bgp_zombie, projected} -> %{acc | bgp_zombies: [projected | acc.bgp_zombies]}
          :ignore -> acc
        end
      end)

    %{
      outages: dedupe_by_key(grouped.outages, &{&1.time, &1.outage_id}),
      bgp_events: dedupe_by_key(grouped.bgp_events, &{&1.time, &1.event_id}),
      bgp_zombies: dedupe_by_key(grouped.bgp_zombies, &{&1.time, &1.episode_id})
    }
  end

  defp do_project(horizon_rows, opts) do
    insert_fn = Keyword.get(opts, :insert_fn, &BulkInsert.insert_all/3)
    projections = build_projections(horizon_rows)

    upsert_table(
      insert_fn,
      @outages_table,
      projections.outages,
      [:time, :outage_id],
      @outage_replace_fields
    )

    upsert_table(
      insert_fn,
      @bgp_events_table,
      projections.bgp_events,
      [:time, :event_id],
      @bgp_event_replace_fields
    )

    upsert_table(
      insert_fn,
      @bgp_zombies_table,
      projections.bgp_zombies,
      [:time, :episode_id],
      @bgp_zombie_replace_fields
    )

    :ok
  end

  defp upsert_table(_insert_fn, _table, [], _conflict_target, _replace_fields), do: :ok

  defp upsert_table(insert_fn, table, rows, conflict_target, replace_fields) do
    insert_fn.(
      table,
      rows,
      on_conflict: {:replace, replace_fields},
      conflict_target: conflict_target,
      returning: false
    )

    :ok
  rescue
    error ->
      Logger.warning(
        "Horizon OCSF projection failed (fail-open) for #{table}: #{Exception.message(error)}",
        table: table
      )

      :ok
  end

  defp horizon_event?(%{log_name: log_name}) when is_binary(log_name) do
    String.starts_with?(log_name, "horizon.")
  end

  defp horizon_event?(_row), do: false

  defp project_row(%{log_name: "horizon.outage", time: time} = row) do
    unmapped = unmapped_map(row)
    outage_id = non_empty_string(unmapped["outage_id"] || unmapped["horizon_outage_id"])

    if is_nil(outage_id) do
      :ignore
    else
      entity_type = non_empty_string(unmapped["entity_type"]) || "unknown"
      entity_key = non_empty_string(unmapped["entity_key"]) || ""

      {:outage,
       %{
         time: normalize_time(time),
         outage_id: outage_id,
         status: non_empty_string(unmapped["status"]) || "active",
         severity: non_empty_string(unmapped["severity"] || unmapped["level"]) || "warning",
         entity_type: entity_type,
         entity_key: entity_key,
         region: non_empty_string(unmapped["region"]),
         covering_prefix: non_empty_string(unmapped["covering_prefix"]),
         origin_asn: parse_outage_asn(unmapped, entity_type, entity_key),
         corroborating_pop_count: parse_int(unmapped["corroborating_pop_count"]) || 0,
         avg_forwarding_loss_pct: parse_float(unmapped["avg_forwarding_loss_pct"]),
         avg_synthetic_failure_pct: parse_float(unmapped["avg_synthetic_failure_pct"]),
         window_start_ms:
           parse_int(unmapped["window_start_unix_ms"] || unmapped["window_start_ms"]),
         window_end_ms: parse_int(unmapped["window_end_unix_ms"] || unmapped["window_end_ms"]),
         correlated_bgp_event_ids: list_or_empty(unmapped["correlated_bgp_event_ids"]),
         raw_data: unmapped
       }}
    end
  end

  defp project_row(%{log_name: "horizon.bgp_anomaly", time: time} = row) do
    unmapped = unmapped_map(row)
    event_id = non_empty_string(unmapped["event_id"])
    prefix = non_empty_string(unmapped["prefix"] || unmapped["covering_prefix"])

    if is_nil(event_id) or is_nil(prefix) do
      :ignore
    else
      {:bgp_event,
       %{
         time: normalize_time(time),
         event_id: event_id,
         kind: non_empty_string(unmapped["kind"]) || "anomaly",
         level: non_empty_string(unmapped["level"]) || "warning",
         prefix: prefix,
         origin_asn: parse_int(unmapped["origin_asn"]),
         as_path: list_or_empty(unmapped["as_path"]),
         rpki_status: non_empty_string(unmapped["rpki_status"] || unmapped["roa_validity"]),
         caida_leak_inference: non_empty_string(unmapped["caida_leak_inference"]),
         watchlist_id: non_empty_string(unmapped["watchlist_id"]),
         client_label: non_empty_string(unmapped["client_label"] || unmapped["label"]),
         raw_data: unmapped
       }}
    end
  end

  defp project_row(%{log_name: "horizon.bgp_watchlist", time: time} = row) do
    unmapped = unmapped_map(row)
    event_id = non_empty_string(unmapped["event_id"])

    prefix =
      non_empty_string(
        unmapped["observed_prefix"] || unmapped["covering_prefix"] || unmapped["watched_prefix"]
      )

    if is_nil(event_id) or is_nil(prefix) do
      :ignore
    else
      {:bgp_event,
       %{
         time: normalize_time(time),
         event_id: event_id,
         kind: "watchlist",
         level: non_empty_string(unmapped["level"]) || "warning",
         prefix: prefix,
         origin_asn: parse_int(unmapped["observed_origin_asn"] || unmapped["origin_asn"]),
         as_path: list_or_empty(unmapped["observed_as_path"] || unmapped["as_path"]),
         rpki_status: non_empty_string(unmapped["rpki_status"]),
         caida_leak_inference: non_empty_string(unmapped["caida_leak_inference"]),
         watchlist_id: non_empty_string(unmapped["watchlist_id"]),
         client_label: non_empty_string(unmapped["label"] || unmapped["client_label"]),
         raw_data: unmapped
       }}
    end
  end

  defp project_row(%{log_name: "horizon.bgp_zombie", time: time} = row) do
    unmapped = unmapped_map(row)
    episode_id = non_empty_string(unmapped["episode_id"])
    prefix = non_empty_string(unmapped["prefix"] || unmapped["covering_prefix"])

    if is_nil(episode_id) or is_nil(prefix) do
      :ignore
    else
      status = non_empty_string(unmapped["status"]) || "active"
      event_time = normalize_time(time)

      resolved_at =
        case parse_optional_timestamp(unmapped["resolved_at"]) do
          %DateTime{} = ts ->
            ts

          nil ->
            if String.downcase(status) in ["resolved", "cleared"], do: event_time
        end

      {:bgp_zombie,
       %{
         time: event_time,
         episode_id: episode_id,
         status: status,
         prefix: prefix,
         origin_asn: parse_int(unmapped["origin_asn"]),
         divergence_pct: parse_float(unmapped["divergence_pct"]),
         is_beacon: parse_bool(unmapped["is_beacon"]),
         withdrawn_peers: parse_int(unmapped["withdrawn_peers"]),
         total_peers: parse_int(unmapped["total_peers"]),
         stuck_peer_asns: list_or_empty(unmapped["stuck_peer_asns"]),
         first_seen_at:
           parse_optional_timestamp(unmapped["first_seen_at"] || unmapped["first_seen"]),
         resolved_at: resolved_at,
         raw_data: unmapped
       }}
    end
  end

  defp project_row(_row), do: :ignore

  defp unmapped_map(%{unmapped: map}) when is_map(map), do: map
  defp unmapped_map(_row), do: %{}

  defp parse_outage_asn(unmapped, entity_type, entity_key) do
    case parse_asn(unmapped["origin_asn"] || unmapped["affected_asn"]) do
      nil when entity_type == "asn" -> parse_asn(entity_key)
      asn -> asn
    end
  end

  defp parse_asn(nil), do: nil
  defp parse_asn(val) when is_integer(val), do: val

  defp parse_asn(val) when is_binary(val) do
    val
    |> String.trim()
    |> String.replace_prefix("AS", "")
    |> String.replace_prefix("as", "")
    |> parse_int()
  end

  defp parse_asn(_), do: nil

  defp dedupe_by_key(rows, key_fn) do
    rows
    |> Enum.reduce(%{}, fn row, acc -> Map.put(acc, key_fn.(row), row) end)
    |> Map.values()
    |> Enum.sort_by(key_fn)
  end

  defp normalize_time(%DateTime{} = dt), do: dt
  defp normalize_time(other), do: FieldParser.parse_timestamp(other)

  defp parse_optional_timestamp(nil), do: nil
  defp parse_optional_timestamp(""), do: nil
  defp parse_optional_timestamp(%DateTime{} = dt), do: dt

  defp parse_optional_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_optional_timestamp(_), do: nil

  defp non_empty_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_empty_string(_), do: nil

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(value) when is_float(value), do: trunc(value)

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp parse_float(nil), do: nil
  defp parse_float(value) when is_float(value), do: value
  defp parse_float(value) when is_integer(value), do: value * 1.0

  defp parse_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {flt, ""} -> flt
      _ -> nil
    end
  end

  defp parse_float(_), do: nil

  defp parse_bool(true), do: true
  defp parse_bool(false), do: false
  defp parse_bool("true"), do: true
  defp parse_bool("1"), do: true
  defp parse_bool(_), do: false

  defp list_or_empty(list) when is_list(list), do: list
  defp list_or_empty(_), do: []
end
