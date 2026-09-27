defmodule ServiceRadarWebNG.Topology.AtlasWatch do
  @moduledoc "Builds bounded revision hints for the levels retained by one client."

  @max_hint_bytes 16_384

  def acknowledgement(current) do
    current |> Map.put(:reset, false) |> bounded()
  end

  def invalidation(revisions, revisions), do: nil

  def invalidation(previous, current) do
    previous_levels = if previous, do: previous.levels, else: %{}

    affected =
      current.levels
      |> Enum.filter(fn {id, revision} -> Map.get(previous_levels, id) != revision end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    payload = %{
      previous_canonical_revision: if(previous, do: previous.canonical_revision),
      canonical_revision: current.canonical_revision,
      affected_level_ids: affected,
      levels: Map.take(current.levels, affected),
      reset: is_nil(previous)
    }

    bounded(payload)
  end

  defp bounded(payload) do
    if byte_size(Jason.encode!(payload)) > @max_hint_bytes do
      payload
      |> Map.put(:levels, %{})
      |> Map.put(:reset, true)
      |> Map.replace(:affected_level_ids, [])
    else
      payload
    end
  end
end
