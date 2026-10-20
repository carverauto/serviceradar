defmodule ServiceRadarWebNG.Topology.BitmapValues do
  @moduledoc "Current canonical value discovery; search text never becomes a membership predicate."

  alias ServiceRadarWebNG.Topology.BitmapQueries
  alias ServiceRadarWebNG.Topology.Native
  alias ServiceRadarWebNGWeb.Endpoint

  @salt "topology-value-cursor-v1"

  def page(params, context) do
    with true <- Enum.all?(Map.keys(params), &(&1 in ["facet", "search", "cursor", "limit"])),
         facet = Map.get(params, "facet"),
         true <- text?(facet) and byte_size(facet) in 1..64,
         search = Map.get(params, "search", ""),
         true <- text?(search),
         search = String.trim(search),
         {:ok, limit} <- limit(Map.get(params, "limit", 50)),
         identity = {facet, search, context.authority},
         {:ok, after_value} <- position(Map.get(params, "cursor"), identity),
         {:ok, budget} <- BitmapQueries.remaining(context),
         {:ok, {values, next}} <-
           Native.bitmap_query_values(context.ref, context.authority, facet, search, after_value, limit, budget) do
      cursor = if next, do: Phoenix.Token.sign(Endpoint, @salt, {identity, next})
      items = Enum.map(values, fn {value, count} -> %{value: value, count: count} end)
      {:ok, %{facet: facet, search: search, items: items, cursor: cursor}}
    else
      false -> {:error, :invalid_query}
      error -> error
    end
  end

  defp position(nil, _identity), do: {:ok, nil}

  defp position(cursor, identity) when is_binary(cursor) and byte_size(cursor) <= 4_096 do
    case Phoenix.Token.verify(Endpoint, @salt, cursor, max_age: 300) do
      {:ok, {^identity, value}} when is_binary(value) and byte_size(value) in 1..256 -> {:ok, value}
      _ -> {:error, :invalid_cursor}
    end
  end

  defp position(_cursor, _identity), do: {:error, :invalid_cursor}
  defp limit(value) when is_integer(value) and value in 1..50, do: {:ok, value}

  defp limit(value) when is_binary(value) and byte_size(value) in 1..2 do
    case Integer.parse(value) do
      {number, ""} -> limit(number)
      _ -> {:error, :invalid_page_limit}
    end
  end

  defp limit(_), do: {:error, :invalid_page_limit}
  defp text?(value), do: is_binary(value) and byte_size(value) <= 256 and String.valid?(value)
end
