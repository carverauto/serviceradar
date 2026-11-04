defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild.Conflicts do
  @moduledoc false

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  def competing_edge_demotions(edges) when is_list(edges) do
    edge_map = Map.new(edges, &{canonical_edge_key(&1), &1})

    edges
    |> Enum.flat_map(&edge_port_conflicts/1)
    |> Enum.group_by(fn {port_key, _edge_key} -> port_key end, fn {_port_key, edge_key} ->
      edge_key
    end)
    |> Enum.flat_map(fn {_port_key, edge_keys} ->
      demotions_for_port_group(edge_keys, edge_map)
    end)
    |> Enum.uniq()
  end

  defp edge_port_conflicts(%{} = edge) do
    edge_key = canonical_edge_key(edge)

    [
      canonical_port_key(
        Map.get(edge, "src_id"),
        Map.get(edge, "local_if_index_ab"),
        Map.get(edge, "local_if_name_ab")
      ),
      canonical_port_key(
        Map.get(edge, "dst_id"),
        Map.get(edge, "local_if_index_ba"),
        Map.get(edge, "local_if_name_ba")
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&{&1, edge_key})
  end

  defp edge_port_conflicts(_), do: []

  defp demotions_for_port_group(edge_keys, edge_map)
       when is_list(edge_keys) and is_map(edge_map) do
    group =
      edge_keys
      |> Enum.uniq()
      |> Enum.map(&Map.get(edge_map, &1))
      |> Enum.reject(&is_nil/1)

    if length(group) > 1 and Enum.any?(group, &(pair_support_rank(&1) > 0)) do
      group
      |> Enum.filter(&(pair_support_rank(&1) == 0))
      |> Enum.map(&canonical_edge_key/1)
    else
      []
    end
  end

  defp demotions_for_port_group(_edge_keys, _edge_map), do: []

  defp canonical_edge_key(%{} = edge) do
    src_id = Map.get(edge, "src_id")
    dst_id = Map.get(edge, "dst_id")

    if is_binary(src_id) and is_binary(dst_id), do: {src_id, dst_id}
  end

  defp canonical_edge_key(_), do: nil

  defp canonical_port_key(device_id, if_index, if_name) do
    device_id = Utils.non_blank(device_id)
    if_name = Utils.non_blank(if_name)
    if_index = Utils.value_to_non_negative_int(if_index)

    cond do
      is_binary(device_id) and is_integer(if_index) and if_index > 0 ->
        {device_id, {:ifindex, if_index}}

      is_binary(device_id) and is_binary(if_name) ->
        {device_id, {:ifname, if_name}}

      true ->
        nil
    end
  end

  defp pair_support_rank(%{} = edge) do
    edge
    |> Map.get("pair_support_rank")
    |> Utils.value_to_non_negative_int()
    |> Kernel.||(0)
  end

  defp pair_support_rank(_), do: 0
end
