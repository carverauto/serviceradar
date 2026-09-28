defmodule ServiceRadarWebNG.Topology.WorldScene do
  @moduledoc "Encodes one authorized, bounded detail page for the existing ELK renderer."

  alias ServiceRadarWebNG.Topology.GodViewStream
  alias ServiceRadarWebNG.Topology.Native

  def encode(%{nodes: nodes, edges: edges} = level) when length(nodes) <= 128 and length(edges) <= 256 do
    index = nodes |> Enum.with_index() |> Map.new(fn {node, index} -> {node.id, index} end)

    if map_size(index) == length(nodes) and
         Enum.all?(edges, &(Map.has_key?(index, &1.source) and Map.has_key?(index, &1.target))) do
      case_result =
        case encode(level, index, :full) do
          {:error, "scene_budget_exceeded"} -> encode(level, index, :identity)
          result -> result
        end

      result(case_result)
    else
      {:error, :invalid_detail}
    end
  end

  def encode(_level), do: {:error, :payload_too_large}

  defp encode(level, index, detail) do
    payload = %{
      schema_version: 3,
      revision: level.revision,
      nodes: Enum.map(level.nodes, &node(&1, detail)),
      edges: Enum.map(level.edges, &{Map.fetch!(index, &1.source), Map.fetch!(index, &1.target), 0, 0, 0, "", 0}),
      edge_meta: Enum.map(level.edges, &edge_meta/1),
      edge_directional: [],
      edge_details: Enum.map(level.edges, &Jason.encode!(%{id: &1.id, role: &1.role})),
      root_bitmap_bytes: 0,
      affected_bitmap_bytes: 0,
      healthy_bitmap_bytes: 0,
      unknown_bitmap_bytes: 0
    }

    metadata =
      Map.new(
        %{
          payload_kind: "detail",
          level_id: level.level_id,
          parent_level_id: level.parent_level_id,
          layout_version: level.layout_version,
          generation: level.generation,
          structure_revision: level.structure_revision,
          next_cursor: level.next_cursor,
          detail_kind: level.kind,
          layout_algorithm: "elk",
          deferred_details: if(detail == :identity, do: "inventory,camera", else: "camera"),
          max_nodes: 128,
          max_edges: 256,
          max_encoded_bytes: 262_144
        },
        fn {name, value} -> {Atom.to_string(name), to_string(value)} end
      )

    Native.encode_scene(payload, metadata)
  end

  defp edge_meta(edge) do
    {GodViewStream.edge_topology_class(edge), "", to_string(edge.evidence_class)}
  end

  defp node(node, detail) do
    details = Map.put(node.details, :id, node.id)

    details =
      if detail == :identity,
        do: Map.take(details, [:id, :device_uid, :type, :device_role, :topology_plane]),
        else: details

    # Availability is not a causal diagnosis. An unavailable device remains
    # unknown here rather than being labelled a root cause without analysis.
    state = if node.health_signal == :healthy, do: 2, else: 3
    {0, 0, state, node.label, 0, 0, Jason.encode!(details)}
  end

  defp result({:ok, payload}) do
    revision = :sha256 |> :crypto.hash(payload) |> Base.encode16(case: :lower)
    {:ok, %{payload: payload, revision: revision}}
  end

  defp result({:error, "scene_budget_exceeded"}), do: {:error, :payload_too_large}
  defp result({:error, _reason}), do: {:error, :invalid_detail}
end
