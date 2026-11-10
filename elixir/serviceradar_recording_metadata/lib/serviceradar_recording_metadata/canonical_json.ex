defmodule ServiceRadarRecordingMetadata.CanonicalJSON do
  @moduledoc false

  def encode(value), do: Jason.encode(canonical(value))

  defp canonical(value) when is_map(value) do
    value
    |> Enum.sort()
    |> Enum.map(fn {key, value} -> {key, canonical(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
end
