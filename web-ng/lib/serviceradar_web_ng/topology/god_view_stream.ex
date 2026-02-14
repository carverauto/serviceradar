defmodule ServiceRadarWebNG.Topology.GodViewStream do
  @moduledoc """
  Builds God-View snapshot payloads backed by the Rust Arrow encoder.
  """

  import Ecto.Query

  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.NetworkDiscovery.TopologyLink
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Topology.GodViewSnapshot
  alias ServiceRadarWebNG.Topology.Native

  @max_link_rows 5_000
  @max_device_rows 250
  @max_interface_rows 2_000
  @default_real_time_budget_ms 2_000
  @drop_counter_key {__MODULE__, :dropped_updates}
  @packet_metric_names ["ifInUcastPkts", "ifOutUcastPkts", "ifHCInUcastPkts", "ifHCOutUcastPkts"]
  @octet_metric_names ["ifInOctets", "ifOutOctets", "ifHCInOctets", "ifHCOutOctets"]

  @spec latest_snapshot() ::
          {:ok, %{snapshot: GodViewSnapshot.snapshot(), payload: binary()}} | {:error, term()}
  def latest_snapshot do
    started_at = System.monotonic_time()
    revision = System.system_time(:millisecond)
    actor = SystemActor.system(:god_view_stream)
    budget_ms = real_time_budget_ms()

    with {:ok, projection} <- build_projection(actor),
         snapshot = %{
           schema_version: GodViewSnapshot.schema_version(),
           revision: revision,
           generated_at: DateTime.utc_now(),
           nodes: projection.nodes,
           edges: projection.edges,
           causal_bitmaps: projection.causal_bitmaps,
           bitmap_metadata: projection.bitmap_metadata
         },
         :ok <- GodViewSnapshot.validate(snapshot),
         payload <- encode_payload(snapshot) do
      build_ms = duration_ms(started_at)

      if build_ms > budget_ms do
        dropped = increment_dropped_updates()

        emit_snapshot_drop_telemetry(snapshot, build_ms, budget_ms, dropped)
        emit_snapshot_built_telemetry(snapshot, payload, build_ms, budget_ms)
        {:ok, %{snapshot: snapshot, payload: payload}}
      else
        emit_snapshot_built_telemetry(snapshot, payload, build_ms, budget_ms)
        {:ok, %{snapshot: snapshot, payload: payload}}
      end
    else
      {:error, reason} ->
        emit_snapshot_error_telemetry(reason)
        {:error, reason}
    end
  end

  defp encode_payload(snapshot) do
    root = Map.get(snapshot.causal_bitmaps, :root_cause, <<>>)
    affected = Map.get(snapshot.causal_bitmaps, :affected, <<>>)
    healthy = Map.get(snapshot.causal_bitmaps, :healthy, <<>>)
    unknown = Map.get(snapshot.causal_bitmaps, :unknown, <<>>)
    node_index = snapshot.nodes |> Enum.with_index() |> Map.new(fn {n, idx} -> {n.id, idx} end)

    nodes =
      Enum.map(snapshot.nodes, fn node ->
        {
          normalize_u16(Map.get(node, :x, 0)),
          normalize_u16(Map.get(node, :y, 0)),
          normalize_u8(Map.get(node, :state, 3)),
          normalize_label(Map.get(node, :label) || Map.get(node, :id) || "node"),
          normalize_u32(Map.get(node, :pps, 0)),
          normalize_u8(node_oper_up_value(Map.get(node, :oper_up))),
          normalize_label(Map.get(node, :details_json) || "{}")
        }
      end)

    edges =
      Enum.map(snapshot.edges, fn edge ->
        {
          Map.fetch!(node_index, edge.source),
          Map.fetch!(node_index, edge.target),
          normalize_u32(Map.get(edge, :flow_pps, 0)),
          normalize_u64(Map.get(edge, :flow_bps, 0)),
          normalize_u64(Map.get(edge, :capacity_bps, 0)),
          normalize_label(Map.get(edge, :label) || edge_label(edge))
        }
      end)

    Native.encode_snapshot(
      snapshot.schema_version,
      snapshot.revision,
      nodes,
      edges,
      byte_size(root),
      byte_size(affected),
      byte_size(healthy),
      byte_size(unknown)
    )
  end

  defp build_projection(actor) do
    with {:ok, links} <- fetch_topology_links(actor),
         {:ok, pairs} <- unique_pairs(links),
         {:ok, nodes, edges} <- build_nodes_and_edges(actor, pairs) do
      nodes = apply_causal_states(nodes, edges)
      {causal_bitmaps, bitmap_metadata} = build_bitmaps(nodes)

      {:ok,
       %{
         nodes: nodes,
         edges: edges,
         causal_bitmaps: causal_bitmaps,
         bitmap_metadata: bitmap_metadata
       }}
    end
  end

  defp fetch_topology_links(actor) do
    query =
      TopologyLink
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.sort(timestamp: :desc)
      |> Ash.Query.limit(@max_link_rows)

    case Ash.read(query, actor: actor) do
      {:ok, links} when is_list(links) -> {:ok, links}
      {:ok, page} -> {:ok, page_results(page)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unique_pairs(links) when is_list(links) do
    pairs =
      Enum.reduce(links, %{}, fn link, acc ->
        local_id = normalize_local_id(link) || fallback_local_id(link)
        neighbor_id = normalize_neighbor_id(link) || fallback_neighbor_id(link)

        cond do
          is_nil(local_id) or is_nil(neighbor_id) or local_id == neighbor_id ->
            acc

          true ->
            {a, b} = canonical_pair(local_id, neighbor_id)

            Map.put_new(acc, {a, b}, %{
              source: local_id,
              target: neighbor_id,
              kind: "topology",
              protocol: Map.get(link, :protocol),
              confidence_tier: confidence_tier(link),
              local_if_index: Map.get(link, :local_if_index),
              local_if_name: Map.get(link, :local_if_name),
              metadata: Map.get(link, :metadata) || %{}
            })
        end
      end)

    {:ok, pairs}
  end

  defp build_nodes_and_edges(actor, pairs) do
    pair_edges = Map.values(pairs)
    edge_node_ids = pairs |> Map.keys() |> Enum.flat_map(&Tuple.to_list/1) |> Enum.uniq()

    with {:ok, devices} <- fetch_devices(actor, edge_node_ids),
         {:ok, interfaces} <- fetch_interfaces(actor, edge_node_ids) do
      device_by_id = Map.new(devices, &{&1.uid, &1})
      interface_index = index_interfaces(interfaces)
      pps_by_if = load_interface_pps(interface_index)
      bps_by_if = load_interface_bps(interface_index)
      node_ids = node_ids(edge_node_ids, devices)
      nodes = build_nodes(node_ids, device_by_id, interface_index, pps_by_if)
      edges = enrich_edges(pair_edges, interface_index, pps_by_if, bps_by_if)
      {:ok, nodes, edges}
    end
  end

  defp fetch_devices(actor, []), do: fetch_recent_devices(actor)

  defp fetch_devices(actor, node_ids) when is_list(node_ids) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: false}, actor: actor)
      |> Ash.Query.filter(uid in ^node_ids)
      |> Ash.Query.sort(uid: :asc)

    case Ash.read(query, actor: actor) do
      {:ok, devices} when is_list(devices) -> {:ok, devices}
      {:ok, page} -> {:ok, page_results(page)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_recent_devices(actor) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: false}, actor: actor)
      |> Ash.Query.sort(last_seen_time: :desc, uid: :asc)
      |> Ash.Query.limit(@max_device_rows)

    case Ash.read(query, actor: actor) do
      {:ok, devices} when is_list(devices) -> {:ok, devices}
      {:ok, page} -> {:ok, page_results(page)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_interfaces(_actor, []), do: {:ok, []}

  defp fetch_interfaces(actor, node_ids) when is_list(node_ids) do
    query =
      Interface
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(device_id in ^node_ids)
      |> Ash.Query.sort(timestamp: :desc)
      |> Ash.Query.limit(@max_interface_rows)

    case Ash.read(query, actor: actor) do
      {:ok, interfaces} when is_list(interfaces) -> {:ok, interfaces}
      {:ok, page} -> {:ok, page_results(page)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp node_ids([], devices), do: devices |> Enum.map(& &1.uid) |> Enum.sort()
  defp node_ids(edge_node_ids, _devices), do: Enum.sort(edge_node_ids)

  defp build_nodes(node_ids, device_by_id, interface_index, pps_by_if) do
    total = max(length(node_ids), 1)

    node_ids
    |> Enum.with_index()
    |> Enum.map(fn {id, idx} ->
      {x, y} = layout_xy(idx, total)
      device = Map.get(device_by_id, id)
      interface_rows = Map.get(interface_index.by_device, id, [])
      {pps, oper_up} = node_telemetry(interface_rows, pps_by_if)

      %{
        id: id,
        label: node_label(device, id),
        kind: node_kind(device),
        x: x,
        y: y,
        state: 3,
        pps: pps,
        oper_up: oper_up,
        details_json: node_details_json(device, id),
        geo_lat: node_geo_lat(device),
        geo_lon: node_geo_lon(device),
        health_signal: health_signal(device)
      }
    end)
  end

  defp layout_xy(idx, total) do
    radius = 120.0 + total * 0.8
    angle = idx * (2 * :math.pi() / total)
    x = Float.round(320 + radius * :math.cos(angle), 2)
    y = Float.round(160 + radius * :math.sin(angle), 2)
    {x, y}
  end

  defp node_label(nil, id), do: id

  defp node_label(device, id) do
    Map.get(device, :name) ||
      Map.get(device, :hostname) ||
      id
  end

  defp node_kind(nil), do: "external"
  defp node_kind(device), do: Map.get(device, :type) || "device"

  defp node_details_json(device, id) do
    details = %{
      id: id,
      name: Map.get(device || %{}, :name),
      hostname: Map.get(device || %{}, :hostname),
      ip: Map.get(device || %{}, :ip),
      type: Map.get(device || %{}, :type),
      vendor: Map.get(device || %{}, :vendor_name),
      model: Map.get(device || %{}, :model),
      last_seen:
        case Map.get(device || %{}, :last_seen_time) do
          %DateTime{} = dt -> DateTime.to_iso8601(dt)
          %NaiveDateTime{} = ndt -> NaiveDateTime.to_iso8601(ndt)
          value when is_binary(value) -> value
          _ -> nil
        end,
      asn: node_meta_value(device, ["asn", "geo_asn", "armis_asn"]),
      geo_country: node_meta_value(device, ["country", "geo_country", "geoip_country"]),
      geo_city: node_meta_value(device, ["city", "geo_city", "geoip_city"]),
      geo_lat: node_geo_lat(device),
      geo_lon: node_geo_lon(device)
    }

    case Jason.encode(details) do
      {:ok, json} -> json
      _ -> "{}"
    end
  end

  defp node_geo_lat(device) do
    node_meta_float(device, ["latitude", "geo_lat", "geoip_lat", "lat"])
  end

  defp node_geo_lon(device) do
    node_meta_float(device, ["longitude", "geo_lon", "geoip_lon", "lon"])
  end

  defp node_meta_value(nil, _keys), do: nil

  defp node_meta_value(device, keys) when is_map(device) and is_list(keys) do
    metadata = Map.get(device, :metadata) || %{}

    keys
    |> Enum.find_value(fn key ->
      case Map.get(metadata, key) do
        value when is_binary(value) and value != "" -> value
        value when is_integer(value) -> Integer.to_string(value)
        value when is_float(value) -> Float.to_string(value)
        _ -> nil
      end
    end)
  end

  defp node_meta_float(nil, _keys), do: nil

  defp node_meta_float(device, keys) when is_map(device) and is_list(keys) do
    metadata = Map.get(device, :metadata) || %{}

    keys
    |> Enum.find_value(fn key ->
      case Map.get(metadata, key) do
        value when is_float(value) ->
          value

        value when is_integer(value) ->
          value * 1.0

        value when is_binary(value) ->
          case Float.parse(value) do
            {parsed, _} -> parsed
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp health_signal(%{is_available: true}), do: :healthy
  defp health_signal(%{is_available: false}), do: :unhealthy
  defp health_signal(_), do: :unknown

  defp index_interfaces(interfaces) when is_list(interfaces) do
    Enum.reduce(interfaces, %{by_device: %{}, by_device_if: %{}}, fn iface, acc ->
      device_id = normalize_id(Map.get(iface, :device_id))
      if_name = normalize_id(Map.get(iface, :if_name))
      if_index = Map.get(iface, :if_index)

      if is_nil(device_id) do
        acc
      else
        by_device = Map.update(acc.by_device, device_id, [iface], &[iface | &1])

        by_device_if =
          case interface_lookup_key(device_id, if_name, if_index) do
            nil -> acc.by_device_if
            key -> Map.put_new(acc.by_device_if, key, iface)
          end

        %{acc | by_device: by_device, by_device_if: by_device_if}
      end
    end)
  end

  defp interface_lookup_key(device_id, if_name, if_index) when is_binary(device_id) do
    cond do
      is_integer(if_index) -> {:if_index, device_id, if_index}
      is_binary(if_name) and if_name != "" -> {:if_name, device_id, String.downcase(if_name)}
      true -> nil
    end
  end

  defp interface_lookup_key(_, _, _), do: nil

  defp node_telemetry(interface_rows, pps_by_if) when is_list(interface_rows) do
    pps =
      interface_rows
      |> Enum.map(&interface_packets_per_second(&1, pps_by_if))
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    oper_values =
      interface_rows
      |> Enum.map(&Map.get(&1, :if_oper_status))
      |> Enum.filter(&is_integer/1)

    oper_up =
      cond do
        oper_values == [] -> nil
        Enum.any?(oper_values, &(&1 == 1)) -> true
        true -> false
      end

    {pps, oper_up}
  end

  defp node_telemetry(_, _), do: {0, nil}

  defp enrich_edges(edges, interface_index, pps_by_if, bps_by_if) when is_list(edges) do
    Enum.map(edges, fn edge ->
      iface =
        find_interface(
          interface_index,
          normalize_id(Map.get(edge, :source)),
          Map.get(edge, :local_if_name),
          Map.get(edge, :local_if_index)
        )

      flow_pps =
        interface_packets_per_second(iface, pps_by_if) ||
          metadata_number(Map.get(edge, :metadata), [
            "flow_pps",
            "pps",
            "packets_per_sec",
            "packets_per_second",
            "tx_pps",
            "rx_pps"
          ]) || 0

      capacity_bps =
        interface_capacity_bps(iface) ||
          metadata_number(Map.get(edge, :metadata), [
            "capacity_bps",
            "if_speed_bps",
            "if_speed",
            "speed_bps"
          ]) || 0

      flow_bps =
        interface_bits_per_second(iface, bps_by_if) ||
          metadata_number(Map.get(edge, :metadata), [
            "flow_bps",
            "bps",
            "bits_per_sec",
            "bits_per_second",
            "tx_bps",
            "rx_bps"
          ]) || 0

      Map.merge(edge, %{
        flow_pps: flow_pps,
        flow_bps: flow_bps,
        capacity_bps: capacity_bps,
        label: edge_label(edge, flow_pps, capacity_bps)
      })
    end)
  end

  defp find_interface(interface_index, device_id, if_name, if_index)
       when is_binary(device_id) and is_map(interface_index) do
    key = interface_lookup_key(device_id, normalize_id(if_name), if_index)

    case key && Map.get(interface_index.by_device_if, key) do
      nil ->
        cond do
          is_binary(if_name) and if_name != "" ->
            fallback_name = String.split(if_name, ":") |> List.first()
            fallback_key = interface_lookup_key(device_id, normalize_id(fallback_name), nil)
            if fallback_key, do: Map.get(interface_index.by_device_if, fallback_key), else: nil

          true ->
            nil
        end

      iface ->
        iface
    end
  end

  defp find_interface(_, _, _, _), do: nil

  defp interface_packets_per_second(nil, _pps_by_if), do: nil

  defp interface_packets_per_second(iface, pps_by_if) do
    metadata = Map.get(iface, :metadata) || %{}
    metric_value = interface_pps_value(pps_by_if, iface)

    pick_number([
      metric_value,
      Map.get(iface, :pps),
      metadata["pps"],
      metadata["packets_per_sec"],
      metadata["packets_per_second"],
      metadata["tx_pps"],
      metadata["rx_pps"],
      metadata["if_in_pps"],
      metadata["if_out_pps"],
      sum_numbers([metadata["tx_pps"], metadata["rx_pps"]]),
      sum_numbers([metadata["if_in_pps"], metadata["if_out_pps"]])
    ])
  end

  defp interface_pps_value(pps_by_if, iface) when is_map(pps_by_if) do
    device_id = normalize_id(Map.get(iface, :device_id))
    if_index = Map.get(iface, :if_index)

    if is_binary(device_id) and is_integer(if_index) do
      Map.get(pps_by_if, {device_id, if_index})
    end
  end

  defp interface_pps_value(_, _), do: nil

  defp interface_bits_per_second(nil, _bps_by_if), do: nil

  defp interface_bits_per_second(iface, bps_by_if) do
    metadata = Map.get(iface, :metadata) || %{}
    metric_value = interface_bps_value(bps_by_if, iface)

    pick_number([
      metric_value,
      metadata["bps"],
      metadata["bits_per_sec"],
      metadata["bits_per_second"],
      metadata["tx_bps"],
      metadata["rx_bps"],
      metadata["if_in_bps"],
      metadata["if_out_bps"],
      sum_numbers([metadata["tx_bps"], metadata["rx_bps"]]),
      sum_numbers([metadata["if_in_bps"], metadata["if_out_bps"]])
    ])
  end

  defp interface_bps_value(bps_by_if, iface) when is_map(bps_by_if) do
    device_id = normalize_id(Map.get(iface, :device_id))
    if_index = Map.get(iface, :if_index)

    if is_binary(device_id) and is_integer(if_index) do
      Map.get(bps_by_if, {device_id, if_index})
    end
  end

  defp interface_bps_value(_, _), do: nil

  defp load_interface_pps(interface_index) when is_map(interface_index) do
    keys =
      interface_index.by_device_if
      |> Map.keys()
      |> Enum.flat_map(fn
        {:if_index, device_id, if_index} when is_binary(device_id) and is_integer(if_index) ->
          [{device_id, if_index}]

        _ ->
          []
      end)
      |> Enum.uniq()

    device_ids = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    if_indexes = keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    if device_ids == [] or if_indexes == [] do
      %{}
    else
      query =
        from(m in "timeseries_metrics",
          where: m.device_id in ^device_ids,
          where: m.if_index in ^if_indexes,
          where: m.metric_name in ^@packet_metric_names,
          where: m.timestamp > ago(10, "minute"),
          distinct: [m.device_id, m.if_index, m.metric_name],
          order_by: [asc: m.device_id, asc: m.if_index, asc: m.metric_name, desc: m.timestamp],
          select: {m.device_id, m.if_index, m.metric_name, m.value}
        )

      query
      |> Repo.all()
      |> Enum.reduce(%{}, fn {device_id, if_index, metric_name, value}, acc ->
        dir = packet_metric_direction(metric_name)
        numeric_value = value_to_non_negative_int(value)

        if is_nil(dir) or is_nil(numeric_value) do
          acc
        else
          key = {normalize_id(device_id), if_index}

          Map.update(acc, key, %{dir => numeric_value}, fn current ->
            current
            |> Map.update(dir, numeric_value, &max(&1, numeric_value))
          end)
        end
      end)
      |> Enum.reduce(%{}, fn {{device_id, if_index}, values}, acc ->
        in_pps = Map.get(values, :in, 0)
        out_pps = Map.get(values, :out, 0)
        Map.put(acc, {device_id, if_index}, in_pps + out_pps)
      end)
    end
  rescue
    _ -> %{}
  end

  defp load_interface_pps(_), do: %{}

  defp load_interface_bps(interface_index) when is_map(interface_index) do
    keys =
      interface_index.by_device_if
      |> Map.keys()
      |> Enum.flat_map(fn
        {:if_index, device_id, if_index} when is_binary(device_id) and is_integer(if_index) ->
          [{device_id, if_index}]

        _ ->
          []
      end)
      |> Enum.uniq()

    device_ids = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    if_indexes = keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    if device_ids == [] or if_indexes == [] do
      %{}
    else
      query =
        from(m in "timeseries_metrics",
          where: m.device_id in ^device_ids,
          where: m.if_index in ^if_indexes,
          where: m.metric_name in ^@octet_metric_names,
          where: m.timestamp > ago(10, "minute"),
          distinct: [m.device_id, m.if_index, m.metric_name],
          order_by: [asc: m.device_id, asc: m.if_index, asc: m.metric_name, desc: m.timestamp],
          select: {m.device_id, m.if_index, m.metric_name, m.value}
        )

      query
      |> Repo.all()
      |> Enum.reduce(%{}, fn {device_id, if_index, metric_name, value}, acc ->
        dir = octet_metric_direction(metric_name)
        bytes_per_second = value_to_non_negative_int(value)

        if is_nil(dir) or is_nil(bytes_per_second) do
          acc
        else
          key = {normalize_id(device_id), if_index}
          bits_per_second = bytes_per_second * 8

          Map.update(acc, key, %{dir => bits_per_second}, fn current ->
            current
            |> Map.update(dir, bits_per_second, &max(&1, bits_per_second))
          end)
        end
      end)
      |> Enum.reduce(%{}, fn {{device_id, if_index}, values}, acc ->
        in_bps = Map.get(values, :in, 0)
        out_bps = Map.get(values, :out, 0)
        Map.put(acc, {device_id, if_index}, in_bps + out_bps)
      end)
    end
  rescue
    _ -> %{}
  end

  defp load_interface_bps(_), do: %{}

  defp packet_metric_direction(metric_name)
       when metric_name in ["ifInUcastPkts", "ifHCInUcastPkts"],
       do: :in

  defp packet_metric_direction(metric_name)
       when metric_name in ["ifOutUcastPkts", "ifHCOutUcastPkts"],
       do: :out

  defp packet_metric_direction(_), do: nil

  defp octet_metric_direction(metric_name) when metric_name in ["ifInOctets", "ifHCInOctets"],
    do: :in

  defp octet_metric_direction(metric_name) when metric_name in ["ifOutOctets", "ifHCOutOctets"],
    do: :out

  defp octet_metric_direction(_), do: nil

  defp value_to_non_negative_int(value) when is_integer(value) and value >= 0, do: value
  defp value_to_non_negative_int(value) when is_float(value) and value >= 0, do: trunc(value)

  defp value_to_non_negative_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n >= 0 -> n
      _ -> nil
    end
  end

  defp value_to_non_negative_int(_), do: nil

  defp interface_capacity_bps(nil), do: nil

  defp interface_capacity_bps(iface) do
    metadata = Map.get(iface, :metadata) || %{}

    pick_number([
      Map.get(iface, :speed_bps),
      Map.get(iface, :if_speed),
      metadata["if_speed_bps"],
      metadata["if_speed"],
      metadata["speed_bps"],
      metadata["capacity_bps"]
    ])
  end

  defp metadata_number(metadata, keys) when is_map(metadata) and is_list(keys) do
    keys
    |> Enum.map(&Map.get(metadata, &1))
    |> pick_number()
  end

  defp metadata_number(_, _), do: nil

  defp pick_number(values) when is_list(values) do
    values
    |> Enum.find_value(fn
      value when is_integer(value) and value >= 0 ->
        value

      value when is_float(value) and value >= 0 ->
        trunc(Float.round(value))

      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, _} when n >= 0 -> n
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp sum_numbers(values) when is_list(values) do
    parsed =
      values
      |> Enum.map(fn
        value when is_integer(value) and value >= 0 -> value
        value when is_float(value) and value >= 0 -> trunc(Float.round(value))
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    if parsed == [], do: nil, else: Enum.sum(parsed)
  end

  defp node_oper_up_value(true), do: 1
  defp node_oper_up_value(false), do: 2
  defp node_oper_up_value(_), do: 0

  defp edge_label(edge),
    do: edge_label(edge, Map.get(edge, :flow_pps), Map.get(edge, :capacity_bps))

  defp edge_label(edge, flow_pps, capacity_bps) do
    protocol =
      edge
      |> Map.get(:protocol)
      |> to_string()
      |> String.trim()
      |> String.upcase()
      |> case do
        "" -> "LINK"
        value -> value
      end

    "#{protocol} #{format_rate(flow_pps || 0)} / #{format_capacity(capacity_bps || 0)}"
  end

  defp format_rate(value) when is_integer(value) do
    cond do
      value >= 1_000_000 -> "#{Float.round(value / 1_000_000, 1)}Mpps"
      value >= 1_000 -> "#{Float.round(value / 1_000, 1)}Kpps"
      true -> "#{value}pps"
    end
  end

  defp format_rate(_), do: "0pps"

  defp format_capacity(value) when is_integer(value) do
    cond do
      value >= 1_000_000_000 -> "#{trunc(value / 1_000_000_000)}G"
      value >= 100_000_000 -> "#{trunc(value / 1_000_000)}M"
      value > 0 -> "#{trunc(value / 1_000_000)}M"
      true -> "UNK"
    end
  end

  defp format_capacity(_), do: "UNK"

  defp apply_causal_states(nodes, edges) do
    node_index =
      nodes
      |> Enum.with_index()
      |> Map.new(fn {node, idx} -> {node.id, idx} end)

    signals =
      Enum.map(nodes, fn node ->
        case Map.get(node, :health_signal, :unknown) do
          :healthy -> 0
          :unhealthy -> 1
          _ -> 2
        end
      end)

    indexed_edges =
      Enum.map(edges, fn edge ->
        {Map.fetch!(node_index, edge.source), Map.fetch!(node_index, edge.target)}
      end)

    states = Native.evaluate_causal_states(signals, indexed_edges)

    Enum.zip(nodes, states)
    |> Enum.map(fn {node, state} ->
      node
      |> Map.put(:state, state)
      |> Map.delete(:health_signal)
    end)
  end

  defp build_bitmaps(nodes) do
    states = Enum.map(nodes, &Map.get(&1, :state, 3))

    {root, affected, healthy, unknown, {root_count, affected_count, healthy_count, unknown_count}} =
      Native.build_roaring_bitmaps(states)

    bitmaps = %{root_cause: root, affected: affected, healthy: healthy, unknown: unknown}

    metadata = %{
      root_cause: %{bytes: byte_size(root), count: root_count},
      affected: %{bytes: byte_size(affected), count: affected_count},
      healthy: %{bytes: byte_size(healthy), count: healthy_count},
      unknown: %{bytes: byte_size(unknown), count: unknown_count}
    }

    {bitmaps, metadata}
  end

  defp canonical_pair(a, b) when a <= b, do: {a, b}
  defp canonical_pair(a, b), do: {b, a}

  defp normalize_neighbor_id(link) do
    normalize_id(Map.get(link, :neighbor_device_id)) ||
      normalize_id(Map.get(link, :neighbor_mgmt_addr)) ||
      normalize_id(Map.get(link, :neighbor_system_name)) ||
      normalize_id(Map.get(link, :neighbor_chassis_id))
  end

  defp normalize_local_id(link) do
    normalize_id(Map.get(link, :local_device_id)) ||
      normalize_id(Map.get(link, :local_device_ip))
  end

  defp fallback_local_id(link) do
    normalize_id(Map.get(link, :local_device_ip)) ||
      normalize_id(Map.get(link, :local_if_name)) ||
      normalize_id(Map.get(link, :agent_id)) ||
      normalize_id(Map.get(link, :gateway_id))
  end

  defp fallback_neighbor_id(link) do
    normalize_id(Map.get(link, :neighbor_mgmt_addr)) ||
      normalize_id(Map.get(link, :neighbor_system_name)) ||
      normalize_id(Map.get(link, :neighbor_chassis_id)) ||
      normalize_id(Map.get(link, :neighbor_port_id)) ||
      normalize_id(Map.get(link, :neighbor_port_descr))
  end

  defp normalize_id(value) when is_binary(value) do
    trimmed = String.trim(value)

    if invalid_identifier_token?(trimmed) do
      nil
    else
      trimmed
    end
  end

  defp normalize_id(_), do: nil

  defp invalid_identifier_token?(value) when is_binary(value) do
    lowered = String.downcase(value)
    lowered in ["", "nil", "null", "undefined", "unknown", "n/a", "na", "-"]
  end

  defp confidence_tier(link) do
    (Map.get(link, :metadata) || %{})
    |> Map.get("confidence_tier", Map.get(link, :confidence_tier, "unknown"))
  end

  defp page_results(%{results: results}) when is_list(results), do: results
  defp page_results(_), do: []

  defp normalize_u16(value) when is_integer(value), do: clamp(value, 0, 65_535)

  defp normalize_u16(value) when is_float(value),
    do: value |> Float.round() |> trunc() |> normalize_u16()

  defp normalize_u16(_), do: 0

  defp normalize_u8(value) when is_integer(value), do: clamp(value, 0, 255)
  defp normalize_u8(_), do: 0
  defp normalize_u32(value) when is_integer(value), do: clamp(value, 0, 4_294_967_295)
  defp normalize_u32(_), do: 0
  defp normalize_u64(value) when is_integer(value), do: max(value, 0)
  defp normalize_u64(_), do: 0

  defp normalize_label(value) when is_binary(value) do
    trimmed = String.trim(value)
    lowered = String.downcase(trimmed)

    cond do
      trimmed == "" -> "node"
      lowered in ["nil", "null", "undefined"] -> "node"
      byte_size(trimmed) > 96 -> binary_part(trimmed, 0, 96)
      true -> trimmed
    end
  end

  defp normalize_label(_), do: "node"

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  defp real_time_budget_ms do
    Application.get_env(
      :serviceradar_web_ng,
      :god_view_snapshot_budget_ms,
      @default_real_time_budget_ms
    )
  end

  defp duration_ms(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp emit_snapshot_built_telemetry(snapshot, payload, build_ms, budget_ms) do
    :telemetry.execute(
      [:serviceradar, :god_view, :snapshot, :built],
      %{
        build_ms: build_ms,
        payload_bytes: byte_size(payload),
        node_count: length(snapshot.nodes),
        edge_count: length(snapshot.edges)
      },
      %{
        schema_version: snapshot.schema_version,
        revision: snapshot.revision,
        budget_ms: budget_ms
      }
    )
  end

  defp emit_snapshot_drop_telemetry(snapshot, build_ms, budget_ms, dropped_count) do
    :telemetry.execute(
      [:serviceradar, :god_view, :snapshot, :dropped],
      %{build_ms: build_ms, dropped_count: dropped_count},
      %{
        schema_version: snapshot.schema_version,
        revision: snapshot.revision,
        budget_ms: budget_ms
      }
    )
  end

  defp emit_snapshot_error_telemetry(reason) do
    :telemetry.execute(
      [:serviceradar, :god_view, :snapshot, :error],
      %{count: 1},
      %{reason: inspect(reason)}
    )
  end

  defp increment_dropped_updates do
    counter = dropped_counter()
    :counters.add(counter, 1, 1)
    :counters.get(counter, 1)
  end

  defp dropped_counter do
    case :persistent_term.get(@drop_counter_key, nil) do
      nil ->
        counter = :counters.new(1, [])
        :persistent_term.put(@drop_counter_key, counter)
        counter

      counter ->
        counter
    end
  end
end
