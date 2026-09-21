defmodule ServiceRadar.NetworkChanges.Projector do
  @moduledoc """
  Project a CNPG change into Dgraph. Comments and diffs stay off the graph.
  Does not create `change.blocks` edges.
  """

  alias ServiceRadar.Dgraph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Backend

  @spec project(map()) :: :ok | {:error, term()}
  def project(change) when is_map(change) do
    persist(graph_payload(change))
  end

  @spec graph_payload(map()) :: map()
  def graph_payload(change) when is_map(change) do
    selector = Map.get(change, :selector) || Map.get(change, "selector") || %{}

    %{
      id: Map.get(change, :external_id) || Map.get(change, "external_id"),
      kind: kind_string(Map.get(change, :kind) || Map.get(change, "kind")),
      status: Map.get(change, :status) || Map.get(change, "status"),
      source: Map.get(change, :source) || Map.get(change, "source"),
      window_start: iso(Map.get(change, :window_start) || Map.get(change, "window_start")),
      window_end: iso(Map.get(change, :window_end) || Map.get(change, "window_end")),
      affects_prefix_cidrs: list(selector, :cidrs),
      affects_device_ids: list(selector, :device_uids)
    }
  end

  defp persist(payload) do
    if Backend.write_dgraph?() do
      Dgraph.upsert_change(payload)
    else
      :ok
    end
  end

  defp list(selector, key) when is_map(selector) do
    selector
    |> Map.get(key, Map.get(selector, Atom.to_string(key), []))
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp kind_string(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp kind_string(kind) when is_binary(kind), do: kind
  defp kind_string(_), do: "other"

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(value) when is_binary(value), do: value
  defp iso(_), do: nil
end
