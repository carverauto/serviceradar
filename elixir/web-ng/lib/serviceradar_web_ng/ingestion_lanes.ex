defmodule ServiceRadarWebNG.IngestionLanes do
  @moduledoc """
  Current ingestion lane depth and recent rejections, for the Cluster Status page.

  The numbers live in `ServiceRadar.ResultIngestion.LaneMetrics` on the core
  coordinator node: an ETS read there, no database query. Every connected node
  is asked at once with a short timeout and the first node that collects lane
  metrics answers; with none, the result is `{:error, :unavailable}`.
  """

  alias ServiceRadar.ResultIngestion.LaneMetrics

  @rpc_timeout_ms 1_000

  @callback stats() :: {:ok, [map()]} | {:error, :unavailable}

  @spec stats() :: {:ok, [map()]} | {:error, :unavailable}
  def stats do
    [Node.self() | Node.list()]
    |> Task.async_stream(&snapshot_on/1,
      timeout: @rpc_timeout_ms + 500,
      on_timeout: :kill_task,
      max_concurrency: 4,
      ordered: false
    )
    |> Enum.find_value({:error, :unavailable}, fn
      {:ok, {:ok, lanes}} when is_list(lanes) -> {:ok, lanes}
      _other -> nil
    end)
  end

  defp snapshot_on(node) when node == node(), do: LaneMetrics.snapshot()

  defp snapshot_on(node) do
    case :rpc.call(node, LaneMetrics, :snapshot, [], @rpc_timeout_ms) do
      {:ok, lanes} when is_list(lanes) -> {:ok, lanes}
      _other -> {:error, :unavailable}
    end
  end
end
