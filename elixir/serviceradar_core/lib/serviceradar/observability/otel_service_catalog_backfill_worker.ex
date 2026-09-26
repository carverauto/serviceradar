defmodule ServiceRadar.Observability.OtelServiceCatalogBackfillWorker do
  @moduledoc """
  Seeds `platform.otel_service_catalog` from the CNPG telemetry rollups, so the
  service picker has content right after an upgrade.

  Reads, over the catalog retention window
  (`OtelServiceCatalogPruneWorker.retention_days/0`):

    * logs from `logs_severity_stats_5m`,
    * traces from `spans_red_1h`,
    * metrics from `otel_metrics_hourly_stats`,

  and upserts each service's latest bucket per signal. Every column only moves
  forward (`GREATEST`), and a row the seed would not advance is skipped, so the
  job is idempotent and safe to re-run at any time, including while EventWriter
  is upserting the same rows. Gaps the rollups cannot cover (logs already
  written to StarRocks, OTLP metric points) are filled by EventWriter within one
  refresh interval of the next batch.

  Enqueued once by the migration that creates the catalog
  (`20260926140000_create_otel_service_catalog`), only when a rollup holds rows.
  To re-seed by hand: `%{} |> OtelServiceCatalogBackfillWorker.new() |> Oban.insert()`.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 5,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.EventWriter.ServiceCatalog
  alias ServiceRadar.Observability.OtelServiceCatalogPruneWorker
  alias ServiceRadar.Repo

  require Logger

  @query_timeout_ms 600_000

  @backfill_sql """
  WITH seen AS (
    SELECT service_name, 'logs' AS signal, max(bucket) AS seen_at
    FROM platform.logs_severity_stats_5m
    WHERE bucket >= $1
    GROUP BY service_name
    UNION ALL
    SELECT service_name, 'traces', max(bucket)
    FROM platform.spans_red_1h
    WHERE bucket >= $1
    GROUP BY service_name
    UNION ALL
    SELECT service_name, 'metrics', max(bucket)
    FROM platform.otel_metrics_hourly_stats
    WHERE bucket >= $1
    GROUP BY service_name
  ),
  services AS (
    SELECT service_name,
           max(seen_at) FILTER (WHERE signal = 'logs') AS logs_at,
           max(seen_at) FILTER (WHERE signal = 'traces') AS traces_at,
           max(seen_at) FILTER (WHERE signal = 'metrics') AS metrics_at,
           max(seen_at) AS last_at
    FROM seen
    WHERE btrim(service_name) <> ''
      AND char_length(service_name) <= $2
    GROUP BY service_name
  )
  INSERT INTO platform.otel_service_catalog AS c
    (service_name, logs_last_seen_at, traces_last_seen_at, metrics_last_seen_at, last_seen_at)
  SELECT service_name, logs_at, traces_at, metrics_at, last_at
  FROM services
  ORDER BY service_name
  ON CONFLICT (service_name) DO UPDATE
  SET logs_last_seen_at = GREATEST(c.logs_last_seen_at, EXCLUDED.logs_last_seen_at),
      traces_last_seen_at = GREATEST(c.traces_last_seen_at, EXCLUDED.traces_last_seen_at),
      metrics_last_seen_at = GREATEST(c.metrics_last_seen_at, EXCLUDED.metrics_last_seen_at),
      last_seen_at = GREATEST(c.last_seen_at, EXCLUDED.last_seen_at)
  WHERE GREATEST(c.logs_last_seen_at, EXCLUDED.logs_last_seen_at)
          IS DISTINCT FROM c.logs_last_seen_at
     OR GREATEST(c.traces_last_seen_at, EXCLUDED.traces_last_seen_at)
          IS DISTINCT FROM c.traces_last_seen_at
     OR GREATEST(c.metrics_last_seen_at, EXCLUDED.metrics_last_seen_at)
          IS DISTINCT FROM c.metrics_last_seen_at
  """

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    days = OtelServiceCatalogPruneWorker.retention_days()
    since = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    case Repo.query(@backfill_sql, [since, ServiceCatalog.max_name_length()],
           timeout: @query_timeout_ms
         ) do
      {:ok, %{num_rows: written}} ->
        Logger.info("Seeded OTel service catalog from rollups",
          services_written: written,
          window_days: days
        )

        :ok

      {:error, reason} ->
        Logger.warning("OTel service catalog backfill failed", reason: inspect(reason))
        {:error, reason}
    end
  end
end
