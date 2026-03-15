defmodule ServiceRadar.Plugins.MapUtils do
  @moduledoc false

  @spec stringify_keys(term()) :: term()
  def stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  def stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  def stringify_keys(value), do: value

  @spec stringify_keys_or_empty(term()) :: map()
  def stringify_keys_or_empty(nil), do: %{}
  def stringify_keys_or_empty(value), do: stringify_keys(value)
end
