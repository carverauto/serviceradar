defmodule ServiceRadarWebNG.Topology.TileControl do
  @moduledoc """
  Generation fences and bounded revision reconciliation for a client's tile LRU.

  A fence advances response admission without discarding cached geometry. A
  reconciliation compares against the client's last confirmed revisions, so
  coalescing several publications does not lose an intervening tile change.
  """

  @max_bytes 16_384

  def fence(%{layout_version: version, generation: generation}) do
    %{layout_version: version, generation: generation}
  end

  def acknowledgement(current), do: current |> Map.put(:reset, false) |> bounded()

  def reconcile(%{generation: previous}, %{generation: current}) when previous > current, do: {:error, :stale_generation}

  def reconcile(previous, current) do
    same_layout? = previous && previous.layout_version == current.layout_version
    confirmed = if same_layout?, do: previous.tiles, else: %{}

    dirty =
      current.tiles
      |> Enum.filter(fn {key, revision} -> Map.get(confirmed, key) != revision end)
      |> Map.new()

    current
    |> Map.put(:tiles, dirty)
    |> Map.put(:dirty_tiles, dirty |> Map.keys() |> Enum.sort())
    |> Map.put(:reset, !same_layout?)
    |> bounded()
    |> then(&{:ok, &1})
  end

  defp bounded(payload) do
    if byte_size(Jason.encode!(payload)) <= @max_bytes do
      payload
    else
      payload |> Map.put(:reset, true) |> Map.put(:tiles, %{}) |> Map.put(:dirty_tiles, [])
    end
  end
end
