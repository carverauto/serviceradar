defmodule ServiceRadar.Repo.Migrations.CreateOtelServiceCatalog do
  @moduledoc """
  `platform.otel_service_catalog`: one row per OTel `service.name`, with the last
  time each signal was seen. Schema for `ServiceRadar.Observability.OtelServiceCatalogEntry`.

  The picker searches it by substring (`service_name ILIKE '%x%'`), served by the
  trigram index, and orders by recency, served by the `last_seen_at DESC` btree.
  The operator class is written unqualified, like every earlier trigram index:
  pg_trgm lives in `platform` on some installs and in `public` on others, and the
  migration search path resolves it in either.

  The table is new and empty here, so both indexes are built inside the migration
  transaction.

  Finally, enqueue the one-shot `OtelServiceCatalogBackfillWorker` so the catalog has
  content right after an upgrade instead of only the services seen since. It is
  enqueued only when a source rollup holds rows: a fresh database has nothing to
  seed, and the job would be a no-op there. The row is inserted here, once per
  database, rather than from a boot-time scheduler, because Oban prunes completed
  jobs and a scheduler would then re-run a 30-day rollup scan on every check.
  """

  use Ecto.Migration

  @prefix "platform"
  @backfill_worker "ServiceRadar.Observability.OtelServiceCatalogBackfillWorker"

  def up do
    create table(:otel_service_catalog, primary_key: false, prefix: @prefix) do
      add :service_name, :text, primary_key: true
      add :logs_last_seen_at, :timestamptz
      add :traces_last_seen_at, :timestamptz
      add :metrics_last_seen_at, :timestamptz
      add :last_seen_at, :timestamptz, null: false
    end

    create constraint(:otel_service_catalog, :otel_service_catalog_service_name_length,
             check: "char_length(service_name) BETWEEN 1 AND 255",
             prefix: @prefix
           )

    execute("""
    CREATE INDEX otel_service_catalog_service_name_trgm_idx
      ON #{@prefix}.otel_service_catalog USING gin (service_name gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX otel_service_catalog_last_seen_at_idx
      ON #{@prefix}.otel_service_catalog (last_seen_at DESC)
    """)

    execute("""
    INSERT INTO #{@prefix}.oban_jobs (state, queue, worker, args, max_attempts)
    SELECT 'available', 'maintenance', '#{@backfill_worker}',
           '{"trigger": "migration"}'::jsonb, 5
    WHERE EXISTS (SELECT 1 FROM #{@prefix}.logs_severity_stats_5m)
       OR EXISTS (SELECT 1 FROM #{@prefix}.spans_red_1h)
       OR EXISTS (SELECT 1 FROM #{@prefix}.otel_metrics_hourly_stats)
    """)
  end

  # serviceradar:allow-startup-maintenance -- rollback only: removes at most the one
  # pending backfill job this migration enqueued, so it cannot run against a dropped table.
  def down do
    execute("""
    DELETE FROM #{@prefix}.oban_jobs
    WHERE worker = '#{@backfill_worker}'
      AND state IN ('available', 'scheduled', 'retryable')
    """)

    drop table(:otel_service_catalog, prefix: @prefix)
  end
end
