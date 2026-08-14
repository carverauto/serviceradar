defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry.Metrics do
  @moduledoc false

  import Ecto.Query

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry.Identity
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils
  alias ServiceRadar.Repo

  @telemetry_window_minutes 30

  def telemetry_metric_keys(edges) when is_list(edges) do
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

  def metric_key(device_id, if_index)
      when is_binary(device_id) and is_integer(if_index) and if_index > 0,
      do: {device_id, if_index}

  def metric_key(_, _), do: nil

  def load_packet_pps(keys) when is_list(keys) do
    load_directional_metric(
      keys,
      Utils.packet_metric_names(),
      &packet_metric_direction/1,
      &Utils.value_to_non_negative_int/1,
      fn value -> value end
    )
  end

  def load_octet_bps(keys) when is_list(keys) do
    load_directional_metric(
      keys,
      Utils.octet_metric_names(),
      &octet_metric_direction/1,
      &Utils.value_to_non_negative_int/1,
      fn value -> value * 8 end
    )
  end

  def load_interface_capacity(keys) when is_list(keys) do
    device_ids = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    if_indexes = keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    device_identity = Identity.build_device_identity(device_ids)
    accepted_device_ids = Identity.telemetry_metric_device_ids(device_identity)

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
        where:
          fragment(
            "split_part(?, '::', 1) = ANY(?)",
            m.metric_name,
            type(^metric_names, {:array, :string})
          ),
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
    device_identity = Identity.build_device_identity(device_ids)

    {
      device_identity,
      Identity.telemetry_metric_device_ids(device_identity),
      Identity.telemetry_metric_ips(device_identity),
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
           Identity.canonical_metric_device_id(device_id, target_ip, device_identity) do
      mapped_value = transform_fun.(numeric_value)

      Map.update(acc, {canonical_device_id, if_index}, %{dir => mapped_value}, fn current ->
        Map.update(current, dir, mapped_value, &max(&1, mapped_value))
      end)
    else
      _ -> acc
    end
  end

  defp reduce_capacity_row({device_id, if_index, speed_bps, if_speed}, acc, device_identity) do
    canonical_device_id = Identity.canonical_metric_device_id(device_id, nil, device_identity)

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

  defp packet_metric_direction(metric_name) do
    case Utils.base_metric_name(metric_name) do
      name when name in ["ifInUcastPkts", "ifHCInUcastPkts"] -> :in
      name when name in ["ifOutUcastPkts", "ifHCOutUcastPkts"] -> :out
      _ -> nil
    end
  end

  defp octet_metric_direction(metric_name) do
    case Utils.base_metric_name(metric_name) do
      name when name in ["ifInOctets", "ifHCInOctets"] -> :in
      name when name in ["ifOutOctets", "ifHCOutOctets"] -> :out
      _ -> nil
    end
  end
end
