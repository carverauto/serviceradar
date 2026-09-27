defmodule ServiceRadarWebNG.Topology.AtlasSource do
  @moduledoc """
  Reads canonical Device vertices for the semantic atlas, including isolated ones.

  The caller binds a backend and its query function once for both vertex and edge
  reads. AGE returns decoded maps directly; Dgraph returns a decoded JSON object.
  Relation endpoints are retained even when a concurrent vertex read lacks their
  metadata. A failed or malformed provider response fails the entire read so the
  caller can keep the previously published index.
  """

  @age_query """
  MATCH (n:Device)
  WHERE n.id IS NOT NULL AND n.id STARTS WITH 'sr:'
  RETURN {id: n.id, label: coalesce(n.name, n.hostname, n.ip, n.id)} AS node
  """

  @dgraph_query """
  {
    nodes(func: type(Device)) @filter(has(device.id)) {
      device.id
      device.hostname
      device.ip
    }
  }
  """

  @type source :: {:age | :dgraph, (String.t() -> {:ok, term()} | {:error, term()})}

  @spec fetch_nodes([map()], source()) :: {:ok, [map()]} | {:error, term()}
  def fetch_nodes(edges, {backend, query}) when is_list(edges) and backend in [:age, :dgraph] and is_function(query, 1) do
    with {:ok, rows} <- query_rows(backend, query),
         {:ok, nodes} <- index_vertices(rows, backend),
         {:ok, nodes} <- add_endpoints(nodes, edges) do
      {:ok, nodes |> Map.values() |> Enum.sort_by(& &1.id)}
    end
  rescue
    error -> {:error, {:vertex_read_failed, error}}
  catch
    :exit, reason -> {:error, {:vertex_read_exit, reason}}
  end

  def fetch_nodes(_edges, _source), do: {:error, :invalid_vertex_source}

  defp query_for(:age), do: @age_query
  defp query_for(:dgraph), do: @dgraph_query

  defp query_rows(backend, query) do
    case query.(query_for(backend)) do
      {:ok, response} -> rows_for(backend, response)
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_vertex_response}
    end
  end

  defp rows_for(:age, rows) when is_list(rows), do: {:ok, rows}
  defp rows_for(:dgraph, %{"nodes" => rows}) when is_list(rows), do: {:ok, rows}
  defp rows_for(_backend, _response), do: {:error, :invalid_vertex_response}

  defp index_vertices(rows, backend) do
    Enum.reduce_while(rows, {:ok, %{}}, fn
      row, {:ok, nodes} when is_map(row) ->
        if Map.has_key?(row, id_field(backend)) do
          case vertex(row, backend) do
            %{id: id} = node ->
              {:cont, {:ok, Map.update(nodes, id, node, &preferred_label(&1, node))}}

            nil ->
              {:cont, {:ok, nodes}}
          end
        else
          {:halt, {:error, :invalid_vertex_response}}
        end

      _, _ ->
        {:halt, {:error, :invalid_vertex_response}}
    end)
  end

  defp id_field(:age), do: "id"
  defp id_field(:dgraph), do: "device.id"

  defp vertex(row, :age), do: node(row["id"], [row["label"]])

  defp vertex(row, :dgraph), do: node(row["device.id"], [row["device.hostname"], row["device.ip"]])

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
