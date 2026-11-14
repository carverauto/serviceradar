defmodule ServiceRadar.Edge.RemoteAccessSessionReaperWorker do
  @moduledoc """
  Expires stale remote-access sessions stranded in non-terminal states after
  broker teardown, node restarts, or unattached tickets.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled]]

  alias ServiceRadar.Edge.RemoteAccessSessions

  require Logger

  @default_closing_grace_seconds 60
  @default_timeout_grace_seconds 60
  @default_batch_size 500

  @impl Oban.Worker
  def perform(_job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    closing_grace_seconds =
      Keyword.get(config, :closing_grace_seconds, @default_closing_grace_seconds)

    timeout_grace_seconds =
      Keyword.get(config, :timeout_grace_seconds, @default_timeout_grace_seconds)

    batch_size = Keyword.get(config, :batch_size, @default_batch_size)

    case RemoteAccessSessions.expire_stale(
           closing_grace_seconds: closing_grace_seconds,
           timeout_grace_seconds: timeout_grace_seconds,
           batch_size: batch_size
         ) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info("RemoteAccessSessionReaper: expired stale sessions", count: count)
        :ok

      {:error, reason} ->
        Logger.error("RemoteAccessSessionReaper: failed to expire stale sessions",
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end
end
