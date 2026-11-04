defmodule ServiceRadar.NetworkDiscovery.TopologyGlobalPassWorker do
  @moduledoc """
  Runs the graph-wide passes that follow topology projection
  (`ServiceRadar.NetworkDiscovery.TopologyGraph.run_global_passes/0`): global
  stale-evidence pruning and the canonical rebuild.

  Every `TopologyProjectionWorker` job schedules this one after it projects a
  device. The job is scheduled 30 seconds ahead and is unique while it is
  available or scheduled, so a burst of device projections collapses into one
  run after the burst. A projection that finishes while this job executes
  schedules the next run, so the passes always follow the last projection.
  """

  use Oban.Worker,
    queue: :topology_projection,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled]]

  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @debounce_seconds 30

  @doc """
  Schedules the global passes unless a run is already pending. Never fails the
  caller; a run that cannot be scheduled is logged and the next projection
  schedules it again.
  """
  @spec schedule() :: :ok
  def schedule do
    case %{} |> new(schedule_in: @debounce_seconds) |> ObanSupport.safe_insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Topology global passes could not be scheduled",
          reason: inspect(reason)
        )

        :ok
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: to_timeout(minute: 10)

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: TopologyGraph.run_global_passes()
end
