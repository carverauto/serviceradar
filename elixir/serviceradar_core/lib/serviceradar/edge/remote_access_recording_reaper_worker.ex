defmodule ServiceRadar.Edge.RemoteAccessRecordingReaperWorker do
  @moduledoc """
  Expires stale remote-access recordings left pending or active after broker failure.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 300, states: :incomplete]

  alias ServiceRadar.Edge.RemoteAccessRecordings

  require Logger

  @default_stale_after_seconds 4 * 60 * 60
  @default_batch_size 100

  @impl Oban.Worker
  def perform(_job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    stale_after_seconds = Keyword.get(config, :stale_after_seconds, @default_stale_after_seconds)
    batch_size = Keyword.get(config, :batch_size, @default_batch_size)

    case RemoteAccessRecordings.expire_stale(
           stale_after_seconds: stale_after_seconds,
           batch_size: batch_size
         ) do
      {:ok, expired} ->
        Logger.info("RemoteAccessRecordingReaper: expired stale recordings", expired: expired)
        :ok

      {:error, reason} ->
        Logger.error("RemoteAccessRecordingReaper: failed to expire stale recordings",
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end
end
