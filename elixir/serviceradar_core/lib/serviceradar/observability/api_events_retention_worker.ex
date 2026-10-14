defmodule ServiceRadar.Observability.ApiEventsRetentionWorker do
  @moduledoc """
  Oban worker that prunes `ServiceRadar.Observability.ApiEvent` rows
  older than the configured retention window, mirroring
  `ServiceRadar.Jobs.SecurityEventsRetentionWorker`'s single-table shape.

  Configured by `config :serviceradar_core, #{__MODULE__}, retention_days: N`
  (default 90; `API_EVENTS_RETENTION_DAYS` env var via `config/runtime.exs`).
  Scheduled via the Oban cron entry in `config/config.exs`; the worker is
  idempotent and safe to re-run.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.ApiEvent

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
    actor = SystemActor.system(:api_events_retention)

    case ApiEvent.delete_older_than(cutoff, actor: actor) do
      {:ok, _result} ->
        Logger.info("ApiEventsRetention: pruned rows older than #{cutoff} (retention=#{days}d)")

        :ok

      {:error, reason} ->
        Logger.error("ApiEventsRetention: prune failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
