defmodule ServiceRadarWebNG.Topology.AtlasSource do
  @moduledoc """
  Decodes canonical Device vertices for the semantic atlas, including isolated ones.

  Dgraph is the topology authority. The typed NIF returns all vertices and edges
  from one paged read-only transaction. No legacy graph or SQL projection is used
  as a fallback.
  Relation endpoints are retained when the vertex set lacks their metadata,
  including endpoints from supplemental inventory links. A malformed response
  fails the entire read so the
  caller can keep the previously published index.
  """

  @doc "Decodes canonical Dgraph vertices and retains every admitted relation endpoint."
  @spec decode_nodes(term(), [map()]) :: {:ok, [map()]} | {:error, atom()}
  def decode_nodes(rows, edges) when is_list(rows) and is_list(edges) do
    with {:ok, nodes} <- index_vertices(rows),
         {:ok, nodes} <- add_endpoints(nodes, edges) do
      {:ok, nodes |> Map.values() |> Enum.sort_by(& &1.id)}
    end
  end

  def decode_nodes(_response, _edges), do: {:error, :invalid_vertex_response}

  defp index_vertices(rows) do
    Enum.reduce_while(rows, {:ok, %{}}, fn
      %{id: id, hostname: hostname, ip: ip}, {:ok, nodes}
      when is_binary(id) and id != "" and (is_nil(hostname) or is_binary(hostname)) and
             (is_nil(ip) or is_binary(ip)) ->
        case node(id, [hostname, ip]) do
          %{id: id} = node ->
            {:cont, {:ok, Map.update(nodes, id, node, &preferred_label(&1, node))}}

          nil ->
            {:cont, {:ok, nodes}}
        end

      _, _ ->
        {:halt, {:error, :invalid_vertex_response}}
    end)
  end

  defp node("sr:" <> suffix = id, labels) when byte_size(suffix) > 0 do
    label = Enum.find(labels, id, &(is_binary(&1) and String.trim(&1) != ""))
    %{id: id, label: label}
  end

  defp node(_id, _labels), do: nil

  defp preferred_label(%{id: id, label: id}, incoming), do: incoming
  defp preferred_label(existing, %{id: id, label: id}), do: existing

  defp preferred_label(existing, incoming), do: if(existing.label <= incoming.label, do: existing, else: incoming)

  defp add_endpoints(nodes, edges) do
    Enum.reduce_while(edges, {:ok, nodes}, fn
      %{source: "sr:" <> source, target: "sr:" <> target}, {:ok, acc}
      when byte_size(source) > 0 and byte_size(target) > 0 ->
        {:cont, {:ok, acc |> put_endpoint("sr:" <> source) |> put_endpoint("sr:" <> target)}}

      _, _ ->
        {:halt, {:error, :invalid_edge_endpoint}}
    end)
  end

  defp put_endpoint(nodes, id), do: Map.put_new(nodes, id, %{id: id, label: id})
end
