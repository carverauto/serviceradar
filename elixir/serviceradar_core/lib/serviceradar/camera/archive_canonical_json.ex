defmodule ServiceRadar.Camera.ArchiveCanonicalJSON do
  @moduledoc "Canonical compact JSON for validated archive protocol documents."

  def encode(value), do: value |> ordered() |> Jason.encode!()

  defp ordered(value) when is_map(value) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, item} -> {key, ordered(item)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(value) when is_list(value), do: Enum.map(value, &ordered/1)
  defp ordered(value), do: value
end
