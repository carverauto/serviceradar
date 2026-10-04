defmodule ServiceRadar.Observability.OtelServiceCatalogPruneWorker do
  @moduledoc """
  Daily retention for `platform.otel_service_catalog`.

  Deletes services whose `last_seen_at` is older than the retention window, then
  clears each remaining service's per-signal last-seen columns that are older
  than the window and recomputes `last_seen_at` from what is left. A service
  that stopped sending traces a month ago but still sends logs therefore stops
  appearing in the traces picker while staying in the logs picker.

  The window is `:otel_service_catalog_retention_days` in the `:serviceradar_core`
  application env (default 30; `SERVICERADAR_OTEL_SERVICE_CATALOG_RETENTION_DAYS`
  through `ServiceRadar.Observability.ProductionSchedule.app_env/1`).

  Scheduled by `ServiceRadar.Observability.ProductionSchedule.cron_entries/1`.
  Both statements are idempotent, so a retry or an overlapping run is harmless.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 3_600, states: :incomplete]

  alias ServiceRadar.Repo

  require Logger

  @default_retention_days 30
  @query_timeout_ms 120_000

  @delete_sql """
  DELETE FROM platform.otel_service_catalog
  WHERE last_seen_at < $1
  """

  # Every surviving row has last_seen_at >= $1, and last_seen_at is the greatest
  # of the per-signal columns, so at least one column survives; the COALESCE only
  # guards the NOT NULL constraint against a row that broke that invariant.
  @clear_stale_signals_sql """
  WITH cleared AS (
    SELECT service_name,
           CASE WHEN logs_last_seen_at < $1 THEN NULL ELSE logs_last_seen_at END AS logs_at,
           CASE WHEN traces_last_seen_at < $1 THEN NULL ELSE traces_last_seen_at END AS traces_at,
           CASE WHEN metrics_last_seen_at < $1 THEN NULL ELSE metrics_last_seen_at END AS metrics_at
    FROM platform.otel_service_catalog
    WHERE logs_last_seen_at < $1
       OR traces_last_seen_at < $1
       OR metrics_last_seen_at < $1
  )
  UPDATE platform.otel_service_catalog AS c
  SET logs_last_seen_at = cleared.logs_at,
      traces_last_seen_at = cleared.traces_at,
      metrics_last_seen_at = cleared.metrics_at,
      last_seen_at = COALESCE(
        GREATEST(cleared.logs_at, cleared.traces_at, cleared.metrics_at),
        c.last_seen_at
      )
  FROM cleared
  WHERE c.service_name = cleared.service_name
  """

  @doc "Retention window in days."
  @spec retention_days() :: pos_integer()
  def retention_days do
    case Application.get_env(
           :serviceradar_core,
           :otel_service_catalog_retention_days,
           @default_retention_days
         ) do
      days when is_integer(days) and days > 0 -> days
      _ -> @default_retention_days
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.shift(DateTime.utc_now(), day: -retention_days())

    with {:ok, %{num_rows: deleted}} <-
           Repo.query(@delete_sql, [cutoff], timeout: @query_timeout_ms),
         {:ok, %{num_rows: cleared}} <-
           Repo.query(@clear_stale_signals_sql, [cutoff], timeout: @query_timeout_ms) do
      if deleted > 0 or cleared > 0 do
        Logger.info("Pruned OTel service catalog",
          deleted: deleted,
          signals_cleared: cleared,
          retention_days: retention_days()
        )
      end

      :ok
    end
  end
end
