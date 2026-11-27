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
  alias ServiceRadar.NATS.Connection

  require Logger

  @status_ttl_secs 900

  @doc """
  Projects any Horizon OCSF rows in `rows` into StarRocks and forwards
  `horizon.outage` and `horizon.bgp_anomaly` status updates onto local NATS
  for `HorizonTopologyConsumer`.

  Always returns `:ok` (fail-open). Test options:

    * `:starrocks_enabled` - boolean override for `Destination.enabled?/0`
    * `:load` - `(dataset, rows -> {:ok, map()} | {:error, term()})`, defaults to
      `&Destination.persist_warehouse/2`
    * `:publish_nats` - `(subject, payload, opts -> :ok | {:error, term()})`, defaults to
      `&ServiceRadar.NATS.Connection.publish/3`
  """
  @spec project_rows([map()], keyword()) :: :ok
  def project_rows(rows, opts \\ []) when is_list(rows) do
    horizon_rows = Enum.filter(rows, &horizon_event?/1)

    if horizon_rows != [] do
      if starrocks_enabled?(opts) do
        safe_do_project(horizon_rows, opts)
      end

      forward_status_events(horizon_rows, opts)
    end

    :ok
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

  defp safe_do_project(horizon_rows, opts) do
    do_project(horizon_rows, opts)
  rescue
    error ->
      Logger.warning("Horizon OCSF projection failed (fail-open): #{Exception.message(error)}")
      :ok
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

  defp forward_status_events(horizon_rows, opts) do
    publish_fn = Keyword.get(opts, :publish_nats, &Connection.publish/3)

    Enum.each(horizon_rows, fn row ->
      case build_nats_status_event(row) do
        {:ok, subject, payload, msg_id} ->
          publish_status_event(publish_fn, subject, payload, msg_id)

        :ignore ->
          :ok
      end
    end)
  rescue
    error ->
      Logger.warning(
        "Horizon NATS status forwarding failed (fail-open): #{Exception.message(error)}"
      )

      :ok
  end

  defp publish_status_event(publish_fn, subject, payload, msg_id) do
    encoded = Jason.encode!(payload)
    headers = [{"Nats-Msg-Id", msg_id}]

    case publish_fn.(subject, encoded, headers: headers) do
      :ok ->
        :ok

      {:error, {:nats_not_connected, _reason}} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Horizon NATS status publish failed for #{subject} (fail-open): #{inspect(reason)}"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "Horizon NATS status publish raised for #{subject} (fail-open): #{Exception.message(error)}"
      )

      :ok
  end

  defp build_nats_status_event(%{log_name: "horizon.outage", time: time} = row) do
    unmapped = unmapped_map(row)
    outage_id = non_empty_string(unmapped["outage_id"])
    entity_type = non_empty_string(unmapped["entity_type"])
    raw_status = non_empty_string(unmapped["status"])
    outage_state = normalize_outage_status(raw_status)
    {entity_id, node_kind, origin_asn} = map_outage_entity(entity_type, unmapped)

    if is_binary(outage_id) and is_binary(entity_id) and is_binary(outage_state) do
      timestamp = time |> normalize_time() |> DateTime.to_iso8601()
      subject = "serviceradar.horizon.outages.#{subject_token(entity_type || "unknown")}"
      msg_id = status_msg_id("outage", outage_id, timestamp, outage_state)

      payload =
        %{
          "entity_id" => entity_id,
          "kind" => node_kind,
          "outage_state" => outage_state,
          "covering_prefix" => non_empty_string(unmapped["covering_prefix"]),
          "origin_asn" => origin_asn,
          "event_type" => "horizon.outage",
          "timestamp" => timestamp,
          "ttl_secs" => @status_ttl_secs
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      {:ok, subject, payload, msg_id}
    else
      :ignore
    end
  end

  defp build_nats_status_event(%{log_name: "horizon.bgp_anomaly", time: time} = row) do
    unmapped = unmapped_map(row)
    event_id = non_empty_string(unmapped["event_id"])
    kind = non_empty_string(unmapped["kind"]) || "anomaly"
    covering_prefix = non_empty_string(unmapped["covering_prefix"])
    origin_asn = parse_asn(unmapped["origin_asn"])

    entity_id =
      cond do
        is_binary(covering_prefix) -> covering_prefix
        is_integer(origin_asn) and origin_asn > 0 -> "asn:#{origin_asn}"
        true -> nil
      end

    if is_binary(event_id) and is_binary(entity_id) do
      timestamp = time |> normalize_time() |> DateTime.to_iso8601()
      subject = "serviceradar.horizon.bgp.#{subject_token(kind)}"
      msg_id = status_msg_id("bgp", event_id, timestamp, kind)
      node_kind = if(String.contains?(entity_id, "/"), do: "Prefix", else: "ASN")
      rtbh_active = parse_bool(unmapped["rtbh_blackhole"]) or kind == "rtbh_blackhole"

      payload =
        %{
          "entity_id" => entity_id,
          "kind" => node_kind,
          "covering_prefix" => covering_prefix,
          "origin_asn" => origin_asn,
          "rpki_state" => non_empty_string(unmapped["rpki_status"]),
          "rtbh_active" => rtbh_active,
          "event_type" => kind,
          "timestamp" => timestamp,
          "ttl_secs" => @status_ttl_secs
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      {:ok, subject, payload, msg_id}
    else
      :ignore
    end
  end

  defp build_nats_status_event(_row), do: :ignore

  defp map_outage_entity(entity_type, unmapped) do
    entity_type_down = entity_type && String.downcase(entity_type)
    entity_key = non_empty_string(unmapped["entity_key"])
    affected_asn = parse_asn(unmapped["affected_asn"])

    case entity_type_down do
      "asn" ->
        asn = affected_asn || parse_asn(entity_key)
        if is_integer(asn) and asn > 0, do: {"asn:#{asn}", "ASN", asn}, else: {nil, nil, nil}

      "saas" ->
        id = non_empty_string(unmapped["saas_service"]) || entity_key
        {prefix_entity_id("saas:", id), "SaasTarget", affected_asn}

      "ixp" ->
        id = non_empty_string(unmapped["ixp"]) || entity_key
        {prefix_entity_id("ixp:", id), "IXP", affected_asn}

      type when type in ["pop", "vantage"] ->
        {prefix_entity_id("vantage:", entity_key), "Vantage", affected_asn}

      "prefix" ->
        cidr = non_empty_string(unmapped["covering_prefix"]) || entity_key
        {cidr, "Prefix", affected_asn}

      _ ->
        {entity_key, entity_type, affected_asn}
    end
  end

  defp prefix_entity_id(_prefix, nil), do: nil

  defp prefix_entity_id(prefix, id) do
    if String.starts_with?(id, prefix), do: id, else: prefix <> id
  end

  defp normalize_outage_status(nil), do: nil

  defp normalize_outage_status(status) do
    case String.downcase(status) do
      "cleared" -> "up"
      _ -> status
    end
  end

  defp subject_token(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "unknown"
      token -> token
    end
  end

  defp status_msg_id(kind, id, timestamp, state) do
    digest =
      :sha256
      |> :crypto.hash("horizon.status:" <> kind <> ":" <> id <> ":" <> timestamp <> ":" <> state)
      |> Base.encode16(case: :lower)

    "horizon-status-" <> digest
  end

  defp list_or_empty(list) when is_list(list), do: list
  defp list_or_empty(_), do: []
end
