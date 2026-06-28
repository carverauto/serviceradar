defmodule ServiceRadar.Observability.StatefulAlertEngine.Helpers do
  @moduledoc """
  Cross-cutting pure helpers shared by the stateful alert engine modules:
  attribute/key access (`fetch_attr/2`, `map_value/2`, `get_nested_value/2`),
  map compaction (`compact_map/1`), and small value coercions.

  These functions have no side effects and depend on nothing else in the engine,
  so every other engine module can import them safely.
  """

  @doc "Fetch an attribute by atom key, falling back to its string form."
  def fetch_attr(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  def fetch_attr(_map, _key), do: nil

  @doc "Read a value from a map by string or atom key, tolerating either form."
  def map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || fetch_existing_atom_key(map, key)
  end

  def map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  def map_value(_map, _key), do: nil

  def fetch_existing_atom_key(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  @doc "Resolve a possibly dotted key path within nested maps."
  def get_nested_value(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      nil ->
        key
        |> String.split(".")
        |> Enum.reduce(map, &nested_map_get/2)

      value ->
        value
    end
  end

  def get_nested_value(map, key) when is_map(map), do: Map.get(map, key)
  def get_nested_value(_, _), do: nil

  def nested_map_get(segment, acc) when is_map(acc), do: Map.get(acc, segment)
  def nested_map_get(_, _), do: nil

  @doc "Drop nil/empty entries from a map, recursively compacting nested values."
  def compact_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      value = compact_value(value)

      if empty_value?(value) do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  def compact_value(%DateTime{} = value), do: iso8601(value)
  def compact_value(value) when is_map(value), do: compact_map(value)
  def compact_value(value) when is_list(value), do: Enum.reject(value, &empty_value?/1)
  def compact_value(value), do: value

  def empty_value?(nil), do: true
  def empty_value?(""), do: true
  def empty_value?(%{} = value), do: map_size(value) == 0
  def empty_value?(value) when is_list(value), do: value == []
  def empty_value?(_value), do: false

  def iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def iso8601(value), do: value
end
