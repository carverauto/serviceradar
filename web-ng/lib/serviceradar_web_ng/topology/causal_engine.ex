defmodule ServiceRadarWebNG.Topology.CausalEngine do
  @moduledoc """
  Deterministic causal classification for God-View graph snapshots.

  This engine consumes topology nodes/edges and node health signals and emits
  one causal class per node:
  - `:root_cause`
  - `:affected`
  - `:healthy`
  - `:unknown`

  Fallback behavior is deterministic when explicit unhealthy signals are absent.
  """

  @type graph_node :: %{required(:id) => String.t(), optional(:health_signal) => atom()}
  @type graph_edge :: %{required(:source) => String.t(), required(:target) => String.t()}

  @state_code %{
    root_cause: 0,
    affected: 1,
    healthy: 2,
    unknown: 3
  }

  @spec evaluate([graph_node()], [graph_edge()]) :: %{required(String.t()) => non_neg_integer()}
  def evaluate(nodes, edges) when is_list(nodes) and is_list(edges) do
    node_ids = Enum.map(nodes, & &1.id)
    adjacency = adjacency(node_ids, edges)
    signals = Map.new(nodes, &{&1.id, normalize_signal(Map.get(&1, :health_signal))})
    unhealthy_ids = node_ids |> Enum.filter(&(Map.get(signals, &1) == :unhealthy)) |> Enum.sort()

    case unhealthy_ids do
      [_ | _] ->
        root = select_root(unhealthy_ids, adjacency)
        affected = blast_radius(root, adjacency, 3)
        classify(node_ids, signals, root, affected)

      [] ->
        classify_without_root(node_ids, signals)
    end
  end

  @spec state_code(atom()) :: non_neg_integer()
  def state_code(state), do: Map.fetch!(@state_code, state)

  defp normalize_signal(:healthy), do: :healthy
  defp normalize_signal(:unhealthy), do: :unhealthy
  defp normalize_signal(_), do: :unknown

  defp adjacency(node_ids, edges) do
    base = Map.new(node_ids, &{&1, MapSet.new()})

    Enum.reduce(edges, base, fn edge, acc ->
      a = Map.get(edge, :source)
      b = Map.get(edge, :target)

      cond do
        is_nil(a) or is_nil(b) or a == b ->
          acc

        not Map.has_key?(acc, a) or not Map.has_key?(acc, b) ->
          acc

        true ->
          acc
          |> Map.update!(a, &MapSet.put(&1, b))
          |> Map.update!(b, &MapSet.put(&1, a))
      end
    end)
  end

  defp select_root(unhealthy_ids, adjacency) do
    unhealthy_ids
    |> Enum.sort_by(
      fn id -> {-MapSet.size(Map.get(adjacency, id, MapSet.new())), id} end,
      :asc
    )
    |> List.first()
  end

  defp blast_radius(root_id, adjacency, max_hops) do
    frontier = MapSet.new([root_id])
    visited = MapSet.new([root_id])
    do_blast_radius(frontier, visited, adjacency, max_hops, root_id)
  end

  defp do_blast_radius(_frontier, visited, _adjacency, 0, root_id),
    do: MapSet.delete(visited, root_id)

  defp do_blast_radius(frontier, visited, adjacency, hops_left, root_id) do
    neighbors =
      frontier
      |> Enum.reduce(MapSet.new(), fn id, acc ->
        Map.get(adjacency, id, MapSet.new())
        |> Enum.reduce(acc, &MapSet.put(&2, &1))
      end)
      |> MapSet.difference(visited)

    next_visited = MapSet.union(visited, neighbors)

    if MapSet.size(neighbors) == 0 do
      MapSet.delete(next_visited, root_id)
    else
      do_blast_radius(neighbors, next_visited, adjacency, hops_left - 1, root_id)
    end
  end

  defp classify(node_ids, signals, root, affected) do
    Enum.into(node_ids, %{}, fn id ->
      state =
        cond do
          id == root -> :root_cause
          MapSet.member?(affected, id) -> :affected
          Map.get(signals, id) == :healthy -> :healthy
          true -> :unknown
        end

      {id, state_code(state)}
    end)
  end

  defp classify_without_root(node_ids, signals) do
    Enum.into(node_ids, %{}, fn id ->
      state =
        case Map.get(signals, id) do
          :healthy -> :healthy
          _ -> :unknown
        end

      {id, state_code(state)}
    end)
  end
end
