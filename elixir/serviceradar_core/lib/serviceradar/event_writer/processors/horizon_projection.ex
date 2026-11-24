defmodule ServiceRadar.EventWriter.Processors.HorizonProjection do
  @moduledoc """
  Fail-open StarRocks projection from Horizon OCSF `log_activity` event rows
  into `serviceradar.horizon_outages`, `serviceradar.horizon_bgp_events`,
  `serviceradar.horizon_bgp_zombies`, and `serviceradar.horizon_path_hops`.

  Called by `ServiceRadar.EventWriter.Processors.Events` after OCSF rows are
  persisted. Batches containing no `horizon.*` `log_name` values—or running on
  an installation without StarRocks enabled—short-circuit with zero loads.
  Each table load is isolated and fail-open so a projection error never fails
  primary OCSF event ingestion or blocks sibling Horizon tables.
  """

  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.EventWriter.FieldParser

  require Logger

  @doc """
  Projects any Horizon OCSF rows in `rows` into StarRocks.

  Always returns `:ok` (fail-open). Test options:

    * `:starrocks_enabled` - boolean override for `Destination.enabled?/0`
    * `:load` - `(dataset, rows -> {:ok, map()} | {:error, term()})`, defaults to
      `&Destination.persist_warehouse/2`
  """
  @spec project_rows([map()], keyword()) :: :ok
  def project_rows(rows, opts \\ []) when is_list(rows) do
    horizon_rows = Enum.filter(rows, &horizon_event?/1)

    if horizon_rows == [] or not starrocks_enabled?(opts) do
      :ok
    else
      do_project(horizon_rows, opts)
    end
  rescue
    error ->
      Logger.warning("Horizon OCSF projection failed (fail-open): #{Exception.message(error)}")
      :ok
  end

  @doc """
  Builds typed row lists for each Horizon StarRocks table from OCSF event rows.
  """
  @spec build_projections([map()]) :: %{
          outages: [map()],
          bgp_events: [map()],
          bgp_zombies: [map()],
          path_hops: [map()]
        }
  def build_projections(rows) when is_list(rows) do
    initial = %{outages: [], bgp_events: [], bgp_zombies: [], path_hops: []}

    grouped =
      Enum.reduce(rows, initial, fn row, acc ->
        case project_row(row) do
          {:outage, projected} -> %{acc | outages: [projected | acc.outages]}
          {:bgp_event, projected} -> %{acc | bgp_events: [projected | acc.bgp_events]}
          {:bgp_zombie, projected} -> %{acc | bgp_zombies: [projected | acc.bgp_zombies]}
          {:path_hop, projected} -> %{acc | path_hops: [projected | acc.path_hops]}
          :ignore -> acc
        end
      end)

    %{
      outages: grouped.outages |> Enum.reverse() |> dedupe_by_key(&{&1.time, &1.outage_id}),
      bgp_events: grouped.bgp_events |> Enum.reverse() |> dedupe_by_key(&{&1.time, &1.event_id}),
      bgp_zombies:
        grouped.bgp_zombies |> Enum.reverse() |> dedupe_by_key(&{&1.time, &1.episode_id}),
      path_hops:
        grouped.path_hops
        |> Enum.reverse()
        |> dedupe_by_key(&{&1.time, &1.round_id, &1.target_id, &1.pop_id, &1.hop_ttl})
    }
  end

  defp starrocks_enabled?(opts) do
    Keyword.get_lazy(opts, :starrocks_enabled, &Destination.enabled?/0)
  end

  defp do_project(horizon_rows, opts) do
    load_fn = Keyword.get(opts, :load, &Destination.persist_warehouse/2)
    projections = build_projections(horizon_rows)

    load_table(load_fn, :horizon_outages, projections.outages)
    load_table(load_fn, :horizon_bgp_events, projections.bgp_events)
    load_table(load_fn, :horizon_bgp_zombies, projections.bgp_zombies)
    load_table(load_fn, :horizon_path_hops, projections.path_hops)

    :ok
  end

  defp load_table(_load_fn, _dataset, []), do: :ok

  defp load_table(load_fn, dataset, rows) do
    case load_fn.(dataset, rows) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Horizon StarRocks projection failed for #{dataset} (fail-open): #{inspect(reason)}"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "Horizon StarRocks projection raised for #{dataset} (fail-open): #{Exception.message(error)}"
      )

      :ok
  end

  defp horizon_event?(%{log_name: log_name}) when is_binary(log_name) do
    String.starts_with?(log_name, "horizon.")
  end

  defp horizon_event?(_row), do: false

  # Exact unmapped key names emitted by plugins/horizon-feed/src/ocsf.rs.
  defp project_row(%{log_name: "horizon.outage", time: time} = row) do
    unmapped = unmapped_map(row)
    outage_id = non_empty_string(unmapped["outage_id"])

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
         severity: non_empty_string(unmapped["severity"]) || "warning",
         entity_type: entity_type,
         entity_key: entity_key,
         region: non_empty_string(unmapped["region"]),
         covering_prefix: non_empty_string(unmapped["covering_prefix"]),
         origin_asn: parse_asn(unmapped["affected_asn"]),
         corroborating_pop_count: parse_int(unmapped["corroborating_pop_count"]) || 0,
         avg_forwarding_loss_pct: parse_float(unmapped["avg_forwarding_loss_pct"]),
         avg_synthetic_failure_pct: parse_float(unmapped["avg_synthetic_failure_pct"]),
         window_start_ms: parse_int(unmapped["window_start_unix_ms"]),
         window_end_ms: parse_int(unmapped["window_end_unix_ms"]),
         correlated_bgp_event_ids: list_or_empty(unmapped["correlated_bgp_event_ids"]),
         raw_data: unmapped
       }}
    end
  end

  defp project_row(%{log_name: "horizon.bgp_anomaly", time: time} = row) do
    unmapped = unmapped_map(row)
    event_id = non_empty_string(unmapped["event_id"])
    prefix = non_empty_string(unmapped["covering_prefix"])

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
         rpki_status: non_empty_string(unmapped["rpki_status"]),
         caida_leak_inference: non_empty_string(unmapped["caida_leak_inference"]),
         watchlist_id: nil,
         client_label: nil,
         raw_data: unmapped
       }}
    end
  end

  defp project_row(%{log_name: "horizon.bgp_watchlist", time: time} = row) do
    unmapped = unmapped_map(row)
    event_id = non_empty_string(unmapped["event_id"])
    prefix = non_empty_string(unmapped["observed_prefix"])

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
         origin_asn: parse_int(unmapped["observed_origin_asn"]),
         as_path: list_or_empty(unmapped["observed_as_path"]),
         rpki_status: nil,
         caida_leak_inference: nil,
         watchlist_id: non_empty_string(unmapped["watchlist_id"]),
         client_label: non_empty_string(unmapped["label"]),
         raw_data: unmapped
       }}
    end
  end

  defp project_row(%{log_name: "horizon.bgp_zombie", time: time} = row) do
    unmapped = unmapped_map(row)
    episode_id = non_empty_string(unmapped["episode_id"])
    prefix = non_empty_string(unmapped["covering_prefix"])

    if is_nil(episode_id) or is_nil(prefix) do
      :ignore
    else
      status = non_empty_string(unmapped["status"]) || "active"
      event_time = normalize_time(time)

      resolved_at =
        if String.downcase(status) in ["resolved", "cleared"], do: event_time

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
         first_seen_at: parse_optional_timestamp(unmapped["first_seen"]),
         resolved_at: resolved_at,
         raw_data: unmapped
       }}
    end
  end

  defp project_row(%{log_name: "horizon.path_hop", time: time} = row) do
    unmapped = unmapped_map(row)
    round_id = non_empty_string(unmapped["round_id"])
    target_id = non_empty_string(unmapped["target_id"])
    pop_id = non_empty_string(unmapped["pop_id"])
    hop_ttl = parse_int(unmapped["hop_ttl"])

    if is_nil(round_id) or is_nil(target_id) or is_nil(pop_id) or not is_integer(hop_ttl) or
         hop_ttl < 0 do
      :ignore
    else
      {:path_hop,
       %{
         time: normalize_time(time),
         round_id: round_id,
         target_id: target_id,
         pop_id: pop_id,
         hop_ttl: hop_ttl,
         hop_ip: non_empty_string(unmapped["hop_ip"]),
         router_alias_id: non_empty_string(unmapped["router_alias_id"]),
         alias_confidence: parse_float(unmapped["alias_confidence"]),
         asn: parse_asn(unmapped["asn"]),
         as_org: non_empty_string(unmapped["as_org"]),
         is_cloud: parse_bool(unmapped["is_cloud"]),
         cloud_provider: non_empty_string(unmapped["cloud_provider"]),
         cloud_region: non_empty_string(unmapped["cloud_region"]),
         forwarding_loss_pct: parse_float(unmapped["forwarding_loss_pct"]),
         avg_rtt_ms: parse_float(unmapped["avg_rtt_ms"]),
         effective_path_mtu: parse_int(unmapped["effective_path_mtu"]),
         mtu_blackhole_detected: parse_bool(unmapped["mtu_blackhole_detected"]),
         blackhole_hop_ttl: parse_int(unmapped["blackhole_hop_ttl"]),
         raw_data: unmapped
       }}
    end
  end

  defp project_row(_row), do: :ignore

  defp unmapped_map(%{unmapped: map}) when is_map(map), do: map
  defp unmapped_map(_row), do: %{}

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
