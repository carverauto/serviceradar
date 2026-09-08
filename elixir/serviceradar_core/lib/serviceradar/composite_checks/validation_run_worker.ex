defmodule ServiceRadar.CompositeChecks.ValidationRunWorker do
  @moduledoc """
  Advances one validation run until it completes, fails, or times out.

  Probe waits use Oban snooze so a busy agent does not block a request process.
  """

  use Oban.Worker,
    queue: :monitoring,
    max_attempts: 100,
    unique: [period: :infinity, keys: [:run_id], states: :incomplete]

  alias ServiceRadar.CompositeChecks.Validation.Orchestrator

  # 2s snooze × ~90 ticks covers the 180s run deadline. Each snooze counts as
  # an attempt in Oban 2.23, so max_attempts must outlast the deadline.
  @probe_snooze_seconds 2

  @impl true
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) do
    case Orchestrator.advance(run_id) do
      {:ok, :continue} -> {:snooze, @probe_snooze_seconds}
      {:ok, status} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end
end
