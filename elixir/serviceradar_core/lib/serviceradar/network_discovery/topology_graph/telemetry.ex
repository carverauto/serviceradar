defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry do
  @moduledoc false

  import Ecto.Query

  alias ServiceRadar.Graph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Queries
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils
  alias ServiceRadar.Repo

  require Logger

  @telemetry_window_minutes 10
  @default_canonical_edge_telemetry_batch_size 100

  @doc false
  @spec canonical_edge_telemetry_batch_size() :: pos_integer()
  def canonical_edge_telemetry_batch_size do
    :serviceradar_core
    |> Application.get_env(TopologyGraph, [])
    |> Keyword.get(
      :canonical_edge_telemetry_batch_size,
      @default_canonical_edge_telemetry_batch_size
    )
    |> Utils.normalize_positive_int(@default_canonical_edge_telemetry_batch_size)
  end

  def refresh_canonical_edge_telemetry(stale_cutoff) when is_binary(stale_cutoff) do
    case fetch_canonical_edges(stale_cutoff) do
      {:ok, edges} ->
        metric_keys = telemetry_metric_keys(edges)
        pps_by_if = load_packet_pps(metric_keys)
        bps_by_if = load_octet_bps(metric_keys)
        capacity_by_if = load_interface_capacity(metric_keys)
        observed_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

        {stats, updates} =
          Enum.reduce(
            edges,
            {%{
               total_edges: length(edges),
               interface_source: 0,
               none_source: 0,
               render_ready: 0,
               render_partial: 0,
               render_unattributed: 0
             }, []},
            fn edge, {acc, updates} ->
              telemetry =
                compute_edge_telemetry(edge, pps_by_if, bps_by_if, capacity_by_if, observed_at)

              acc = update_render_readiness_stats(acc, edge_render_readiness_class(edge))
              acc = update_telemetry_source_stats(acc, telemetry.telemetry_source)
              {acc, [canonical_edge_telemetry_update(edge, telemetry) | updates]}
            end
          )

        case persist_canonical_edge_telemetry_updates(Enum.reverse(updates)) do
          :ok ->
            Logger.info("canonical_edge_telemetry_stats #{inspect(stats)}")
            {:ok, stats}

          {:error, reason} ->
            Logger.warning("Canonical edge telemetry refresh failed: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Canonical edge telemetry refresh failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc false
  @spec extract_metric_device_ip(term()) :: String.t() | nil
  def extract_metric_device_ip(value) when is_binary(value) do
    normalized = normalize_ip(value)

    cond do
      valid_ip?(normalized) ->
        normalized

      String.contains?(value, ":") ->
        case String.split(String.trim(value), ":", parts: 2) do
          [partition, candidate] when partition != "sr" ->
            candidate = normalize_ip(candidate)
            if valid_ip?(candidate), do: candidate

          _ ->
            nil
        end

      true ->
        nil
    end
  end

  def extract_metric_device_ip(_), do: nil

  @doc false
  @spec edge_render_readiness_class(map()) ::
          :render_ready | :render_partial | :render_unattributed
  def edge_render_readiness_class(edge) when is_map(edge) do
    src_if_index =
      Utils.parse_ifindex(Map.get(edge, :local_if_index_ab) || Map.get(edge, :local_if_index))

    dst_if_index =
      Utils.parse_ifindex(Map.get(edge, :local_if_index_ba) || Map.get(edge, :neighbor_if_index))

    cond do
      is_integer(src_if_index) and is_integer(dst_if_index) ->
        :render_ready

      is_integer(src_if_index) or is_integer(dst_if_index) ->
        :render_partial

      true ->
        :render_unattributed
    end
  end

  def edge_render_readiness_class(_edge), do: :render_unattributed

  defp update_telemetry_source_stats(acc, "interface"),
    do: Map.update!(acc, :interface_source, &(&1 + 1))

  defp update_telemetry_source_stats(acc, _source), do: Map.update!(acc, :none_source, &(&1 + 1))

  defp fetch_canonical_edges(stale_cutoff) when is_binary(stale_cutoff) do
    cypher = """
    MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)
    WHERE r.ingestor = 'mapper_topology_v1'
      AND (r.last_observed_at IS NULL OR r.last_observed_at >= '#{Graph.escape(stale_cutoff)}')
      AND a.id IS NOT NULL
      AND b.id IS NOT NULL
      AND a.id STARTS WITH 'sr:'
      AND b.id STARTS WITH 'sr:'
    RETURN {
      src_id: a.id,
      dst_id: b.id,
      local_if_index: r.local_if_index,
      neighbor_if_index: r.neighbor_if_index,
      local_if_index_ab: r.local_if_index_ab,
      local_if_index_ba: r.local_if_index_ba
    }
    """

    case Graph.query(cypher) do
      {:ok, rows} when is_list(rows) -> {:ok, Enum.flat_map(rows, &parse_canonical_edge_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_canonical_edge_row(row) do
    src_id = Utils.map_value(row, :src_id)
    dst_id = Utils.map_value(row, :dst_id)

    with true <- is_binary(src_id),
         true <- is_binary(dst_id) do
      local_if_index_ab = Utils.parse_ifindex(Utils.map_value(row, :local_if_index_ab))
      local_if_index_ba = Utils.parse_ifindex(Utils.map_value(row, :local_if_index_ba))
      local_if_index = Utils.parse_ifindex(Utils.map_value(row, :local_if_index))
      neighbor_if_index = Utils.parse_ifindex(Utils.map_value(row, :neighbor_if_index))

      [
        %{
          src_id: src_id,
          dst_id: dst_id,
          local_if_index_ab: local_if_index_ab || local_if_index,
          local_if_index_ba: local_if_index_ba || neighbor_if_index,
          local_if_index: local_if_index,
          neighbor_if_index: neighbor_if_index
        }
      ]
    else
      _ -> []
    end
  end

  defp telemetry_metric_keys(edges) when is_list(edges) do
    edges
    |> Enum.flat_map(fn edge ->
      Enum.reject(
        [
          metric_key(
            Map.get(edge, :src_id),
            Map.get(edge, :local_if_index_ab) || Map.get(edge, :local_if_index)
          ),
          metric_key(
            Map.get(edge, :dst_id),
            Map.get(edge, :local_if_index_ba) || Map.get(edge, :neighbor_if_index)
          )
        ],
        &is_nil/1
      )
    end)
    |> Enum.uniq()
  end

  defp metric_key(device_id, if_index)
       when is_binary(device_id) and is_integer(if_index) and if_index > 0,
       do: {device_id, if_index}

  defp metric_key(_, _), do: nil

  defp load_packet_pps(keys) when is_list(keys) do
    load_directional_metric(
      keys,
      Utils.packet_metric_names(),
      &packet_metric_direction/1,
      &Utils.value_to_non_negative_int/1,
      fn value -> value end
    )
  end

  defp load_octet_bps(keys) when is_list(keys) do
    load_directional_metric(
      keys,
      Utils.octet_metric_names(),
      &octet_metric_direction/1,
      &Utils.value_to_non_negative_int/1,
      fn value -> value * 8 end
    )
  end

  defp load_interface_capacity(keys) when is_list(keys) do
    device_ids = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    if_indexes = keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    device_identity = build_device_identity(device_ids)
    accepted_device_ids = telemetry_metric_device_ids(device_identity)

    if accepted_device_ids == [] or if_indexes == [] do
      %{}
    else
      from(i in "discovered_interfaces",
        where:
          fragment(
            "? = ANY(?)",
            i.device_id,
            type(^accepted_device_ids, {:array, :string})
          ),
        where: fragment("? = ANY(?)", i.if_index, type(^if_indexes, {:array, :integer})),
        distinct: [i.device_id, i.if_index],
        order_by: [asc: i.device_id, asc: i.if_index, desc: i.timestamp],
        select: {i.device_id, i.if_index, i.speed_bps, i.if_speed}
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn row, acc -> reduce_capacity_row(row, acc, device_identity) end)
    end
  end

  defp build_device_identity(device_uids) when is_list(device_uids) do
    uid_set =
      device_uids
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> MapSet.new()

    ip_to_uid =
      case MapSet.size(uid_set) do
        0 ->
          %{}

        _ ->
          uid_list = MapSet.to_list(uid_set)

          from(d in "ocsf_devices",
            where: fragment("? = ANY(?)", d.uid, type(^uid_list, {:array, :string})),
            select: {d.uid, d.ip}
          )
          |> Repo.all()
          |> Enum.reduce(%{}, &reduce_device_ip_row/2)
      end

    %{uid_set: uid_set, ip_to_uid: ip_to_uid}
  end

  defp telemetry_metric_device_ids(%{uid_set: uid_set, ip_to_uid: ip_to_uid}) do
    Enum.uniq(MapSet.to_list(uid_set) ++ Map.keys(ip_to_uid))
  end

  defp telemetry_metric_ips(%{ip_to_uid: ip_to_uid}) when is_map(ip_to_uid),
    do: Map.keys(ip_to_uid)

  defp canonical_metric_device_id(device_id, target_ip, identity) do
    cond do
      is_binary(device_id) and
          MapSet.member?(Map.get(identity, :uid_set, MapSet.new()), device_id) ->
        device_id

      is_binary(device_id) ->
        ip = extract_metric_device_ip(device_id)
        Map.get(Map.get(identity, :ip_to_uid, %{}), ip)

      true ->
        nil
    end || Map.get(Map.get(identity, :ip_to_uid, %{}), extract_metric_device_ip(target_ip))
  end

  defp normalize_ip(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp valid_ip?(value) when is_binary(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp valid_ip?(_), do: false

  defp compute_edge_telemetry(edge, pps_by_if, bps_by_if, capacity_by_if, observed_at)
       when is_map(edge) and is_map(pps_by_if) and is_map(bps_by_if) and is_map(capacity_by_if) and
              is_binary(observed_at) do
    src_id = Map.get(edge, :src_id)
    dst_id = Map.get(edge, :dst_id)
    src_if_index = Map.get(edge, :local_if_index_ab) || Map.get(edge, :local_if_index)
    dst_if_index = Map.get(edge, :local_if_index_ba) || Map.get(edge, :neighbor_if_index)

    src_pps = directional_metrics(pps_by_if, src_id, src_if_index)
    dst_pps = directional_metrics(pps_by_if, dst_id, dst_if_index)
    src_bps = directional_metrics(bps_by_if, src_id, src_if_index)
    dst_bps = directional_metrics(bps_by_if, dst_id, dst_if_index)

    flow_pps_ab = directional_min_flow(src_pps, dst_pps)
    flow_pps_ba = directional_min_flow(dst_pps, src_pps)
    flow_bps_ab = directional_min_flow(src_bps, dst_bps)
    flow_bps_ba = directional_min_flow(dst_bps, src_bps)
    flow_pps = flow_pps_ab + flow_pps_ba
    flow_bps = flow_bps_ab + flow_bps_ba
    src_capacity = directional_capacity(capacity_by_if, src_id, src_if_index)
    dst_capacity = directional_capacity(capacity_by_if, dst_id, dst_if_index)
    capacity_bps = Utils.min_non_zero(src_capacity, dst_capacity)

    base = %{
      flow_pps: flow_pps,
      flow_bps: flow_bps,
      capacity_bps: capacity_bps,
      flow_pps_ab: flow_pps_ab,
      flow_pps_ba: flow_pps_ba,
      flow_bps_ab: flow_bps_ab,
      flow_bps_ba: flow_bps_ba
    }

    Map.merge(base, telemetry_status_fields(flow_pps, flow_bps, capacity_bps, observed_at))
  end

  defp load_directional_metric(keys, metric_names, direction_fun, value_fun, transform_fun) do
    {device_identity, accepted_metric_ids, accepted_metric_ips, if_indexes} =
      telemetry_metric_scope(keys)

    if accepted_metric_ids == [] or if_indexes == [] do
      %{}
    else
      from(m in "timeseries_metrics",
        where:
          fragment(
            "(? = ANY(?)) OR (? = ANY(?))",
            m.device_id,
            type(^accepted_metric_ids, {:array, :string}),
            m.target_device_ip,
            type(^accepted_metric_ips, {:array, :string})
          ),
        where: fragment("? = ANY(?)", m.if_index, type(^if_indexes, {:array, :integer})),
        where: fragment("? = ANY(?)", m.metric_name, type(^metric_names, {:array, :string})),
        where: m.timestamp > ago(@telemetry_window_minutes, "minute"),
        distinct: [m.device_id, m.target_device_ip, m.if_index, m.metric_name],
        order_by: [
          asc: m.device_id,
          asc: m.target_device_ip,
          asc: m.if_index,
          asc: m.metric_name,
          desc: m.timestamp
        ],
        select: {m.device_id, m.target_device_ip, m.if_index, m.metric_name, m.value}
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn row, acc ->
        reduce_directional_metric_row(
          row,
          acc,
          device_identity,
          direction_fun,
          value_fun,
          transform_fun
        )
      end)
    end
  end

  defp telemetry_metric_scope(keys) do
    device_ids = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    if_indexes = keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    device_identity = build_device_identity(device_ids)

    {
      device_identity,
      telemetry_metric_device_ids(device_identity),
      telemetry_metric_ips(device_identity),
      if_indexes
    }
  end

  defp reduce_directional_metric_row(
         {device_id, target_ip, if_index, metric_name, value},
         acc,
         device_identity,
         direction_fun,
         value_fun,
         transform_fun
       ) do
    with dir when not is_nil(dir) <- direction_fun.(metric_name),
         numeric_value when not is_nil(numeric_value) <- value_fun.(value),
         canonical_device_id when not is_nil(canonical_device_id) <-
           canonical_metric_device_id(device_id, target_ip, device_identity) do
      mapped_value = transform_fun.(numeric_value)

      Map.update(acc, {canonical_device_id, if_index}, %{dir => mapped_value}, fn current ->
        Map.update(current, dir, mapped_value, &max(&1, mapped_value))
      end)
    else
      _ -> acc
    end
  end

  defp reduce_capacity_row({device_id, if_index, speed_bps, if_speed}, acc, device_identity) do
    canonical_device_id = canonical_metric_device_id(device_id, nil, device_identity)

    capacity =
      Utils.value_to_non_negative_int(speed_bps) || Utils.value_to_non_negative_int(if_speed)

    with true <- is_binary(canonical_device_id),
         true <- is_integer(if_index) and if_index > 0,
         true <- is_integer(capacity) and capacity > 0 do
      Map.update(acc, {canonical_device_id, if_index}, capacity, &max(&1, capacity))
    else
      _ -> acc
    end
  end

  defp reduce_device_ip_row({uid, ip}, acc) do
    with true <- is_binary(uid),
         true <- is_binary(ip),
         trimmed when trimmed != "" <- String.trim(ip) do
      Map.put(acc, trimmed, uid)
    else
      _ -> acc
    end
  end

  defp directional_metrics(source, device_id, if_index),
    do: Map.get(source, metric_key(device_id, if_index), %{})

  defp directional_capacity(source, device_id, if_index),
    do: Map.get(source, metric_key(device_id, if_index), 0)

  defp directional_min_flow(primary, secondary),
    do: Utils.min_non_zero(Map.get(primary, :out, 0), Map.get(secondary, :in, 0))

  # Gap B (add-causal-engine): an edge is telemetry-eligible only when it carries
  # both observed flow AND a populated capacity denominator. `capacity_bps` comes
  # from `min_non_zero/2`, which is 0 when neither endpoint has speed_bps/if_speed,
  # so `capacity_bps > 0` is exactly the "populated capacity" predicate. Edges
  # without capacity are marked ineligible so the saturation causaloid (C6) skips
  # them rather than treating absent capacity as zero/infinite. This refines the
  # existing `telemetry_eligible` field; it adds no new schema column.
  defp telemetry_status_fields(flow_pps, flow_bps, capacity_bps, observed_at) do
    flow_present? = flow_pps > 0 or flow_bps > 0
    capacity_present? = capacity_bps > 0
    eligible? = flow_present? and capacity_present?

    %{
      telemetry_eligible: eligible?,
      telemetry_source: if(eligible?, do: "interface", else: "none"),
      telemetry_observed_at: observed_at
    }
  end

  defp canonical_edge_telemetry_update(edge, telemetry) when is_map(edge) and is_map(telemetry) do
    %{
      src_id: Map.get(edge, :src_id),
      dst_id: Map.get(edge, :dst_id),
      flow_pps: Map.get(telemetry, :flow_pps, 0),
      flow_bps: Map.get(telemetry, :flow_bps, 0),
      capacity_bps: Map.get(telemetry, :capacity_bps, 0),
      flow_pps_ab: Map.get(telemetry, :flow_pps_ab, 0),
      flow_pps_ba: Map.get(telemetry, :flow_pps_ba, 0),
      flow_bps_ab: Map.get(telemetry, :flow_bps_ab, 0),
      flow_bps_ba: Map.get(telemetry, :flow_bps_ba, 0),
      telemetry_eligible: Map.get(telemetry, :telemetry_eligible, false),
      telemetry_source: Map.get(telemetry, :telemetry_source, "none"),
      telemetry_observed_at: Map.get(telemetry, :telemetry_observed_at, "")
    }
  end

  defp canonical_edge_telemetry_update(_edge, _telemetry), do: %{}

  defp persist_canonical_edge_telemetry_updates([]), do: :ok

  defp persist_canonical_edge_telemetry_updates(updates) when is_list(updates) do
    updates
    |> Enum.chunk_every(canonical_edge_telemetry_batch_size())
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case Graph.execute(Queries.canonical_edge_telemetry_batch_query(batch)) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          Logger.warning(
            "Canonical edge telemetry upsert failed",
            reason: inspect(reason),
            batch_size: length(batch)
          )

          {:halt, {:error, reason}}
      end
    end)
  end

  defp update_render_readiness_stats(acc, :render_ready),
    do: Map.update!(acc, :render_ready, &(&1 + 1))

  defp update_render_readiness_stats(acc, :render_partial),
    do: Map.update!(acc, :render_partial, &(&1 + 1))

  defp update_render_readiness_stats(acc, _),
    do: Map.update!(acc, :render_unattributed, &(&1 + 1))

  defp packet_metric_direction(metric_name)
       when metric_name in ["ifInUcastPkts", "ifHCInUcastPkts"], do: :in

  defp packet_metric_direction(metric_name)
       when metric_name in ["ifOutUcastPkts", "ifHCOutUcastPkts"], do: :out

  defp packet_metric_direction(_), do: nil

  defp octet_metric_direction(metric_name) when metric_name in ["ifInOctets", "ifHCInOctets"],
    do: :in

  defp octet_metric_direction(metric_name) when metric_name in ["ifOutOctets", "ifHCOutOctets"],
    do: :out

  defp octet_metric_direction(_), do: nil
end
