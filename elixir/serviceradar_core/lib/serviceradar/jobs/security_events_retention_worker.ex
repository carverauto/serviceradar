defmodule ServiceRadar.Jobs.SecurityEventsRetentionWorker do
  @moduledoc """
  Oban worker that prunes `ServiceRadar.Security.SecurityEvent` rows
  older than the configured retention window.

  Configured by `config :serviceradar_core, #{__MODULE__}, retention_days: N`
  (default 90). Scheduled via the Oban cron entry in `config/config.exs`;
  the worker is idempotent and safe to re-run.
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
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
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
