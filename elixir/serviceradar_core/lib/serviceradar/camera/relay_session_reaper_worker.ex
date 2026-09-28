defmodule ServiceRadar.Camera.RelaySessionReaperWorker do
  @moduledoc """
  Periodically closes camera relay sessions whose edge pull stopped without a close.

  See `ServiceRadar.Camera.RelaySessionReaper`.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 60, states: :incomplete]

  alias ServiceRadar.Camera.RelaySessionReaper

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    case RelaySessionReaper.reap(config) do
      {:ok, %{closed: 0, failed: 0}} ->
        :ok

      {:ok, result} ->
        Logger.info("Camera relay session reaper closed stale sessions",
          closed: result.closed,
          skipped: result.skipped,
          failed: result.failed
        )

        :ok

      {:error, reason} ->
        Logger.error("Camera relay session reaper failed", reason: inspect(reason))
        {:error, reason}
    end
  end
end
