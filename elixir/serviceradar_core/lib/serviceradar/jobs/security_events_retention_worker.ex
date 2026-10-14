defmodule ServiceRadar.Jobs.SecurityEventsRetentionWorker do
  @moduledoc """
  Oban worker that prunes `ServiceRadar.Security.SecurityEvent` rows
  older than the configured retention window.

  Configured by `config :serviceradar_core, #{__MODULE__}, retention_days: N`
  (default 90; `SECURITY_EVENTS_RETENTION_DAYS` via `config/runtime.exs`,
  clamped to at least 1 day). Scheduled daily at 03:23 UTC from the dev
  crontab in `config/config.exs` and the release crontab in `runtime.exs`.
  The worker is idempotent and safe to re-run.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Security.SecurityEvent

  require Logger

  @default_retention_days 90

  def retention_days do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:retention_days, @default_retention_days)
  end

  @impl Oban.Worker
  def perform(_job) do
    days = retention_days()
    cutoff = DateTime.shift(DateTime.utc_now(), day: -days)
    actor = SystemActor.system(:security_events_retention)

    case SecurityEvent.delete_older_than(cutoff, actor: actor) do
      {:ok, _result} ->
        Logger.info(
          "SecurityEventsRetention: pruned rows older than #{cutoff} (retention=#{days}d)"
        )

        :ok

      {:error, reason} ->
        Logger.error("SecurityEventsRetention: prune failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
