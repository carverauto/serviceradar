defmodule ServiceRadar.Repo.Migrations.EnsureLogsSeverityStats5mCagg do
  @moduledoc """
  Ensures the log-severity continuous aggregate exists on every database path.

  The SRQL `rollup_stats:severity` query has always depended on this view. The
  original creator lived in the January 8 tenant migration chain, which was
  removed when tenant migrations were consolidated on January 17. Its
  replacement schema and the current baseline omitted this CAGG, so fresh
  baseline databases have no relation for SRQL to query.

  The safety-net creates the normalized replacement with no data, avoiding a
  synchronous raw-log scan during startup. Before promotion, it installs the
  replacement's refresh policy and removes the old CAGG's policy. It then
  atomically promotes the fully configured candidate as the final operation and
  keeps an existing out-of-band CAGG under a rollback name. The TimescaleDB policy
  follows the candidate relation when it is renamed and maintains the window from
  three hours through thirty minutes ago; `RefreshLogsSeverityStatsWorker`
  asynchronously fills the full 24-hour card window once and then maintains the
  newest thirty minutes.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @source_table "platform.logs"
  @classifier "platform.serviceradar_log_severity_bucket"
  @view "platform.logs_severity_stats_5m"
  @candidate_view "platform.logs_severity_stats_5m_v2"
  @legacy_view "platform.logs_severity_stats_5m_legacy"
  @refresh_start_offset "3 hours"
  @refresh_end_offset "30 minutes"
  @refresh_interval "10 minutes"

  def up do
    # serviceradar:allow-startup-maintenance - WITH NO DATA makes creation
    # metadata-only; policy refreshes and 24h bootstrap happen asynchronously.
    # Every step before the final transactional rename is retry-safe: candidate
    # DDL uses IF NOT EXISTS, candidate policy creation is idempotent, and old
    # policy removal uses if_exists. A legacy out-of-band CAGG is retained under
    # a rollback name while the configured candidate is promoted atomically.
    if promotion_already_complete?() do
      # The final rename can commit before Ecto records the migration version if
      # its connection drops. Recognize the normalized main view with no pending
      # candidate and finish idempotently. The rollback view is optional because
      # a fresh database has no prior main CAGG to preserve.
      create_severity_classifier()
      configure_promoted_policy()
    else
      preflight_promotion()
      create_severity_classifier()
      create_candidate()
      configure_candidate_policy()
      remove_current_policy()
      promote_candidate()
    end
  end

  defp promotion_already_complete? do
    %{rows: [[view_definition]]} =
      repo().query!(
        """
        SELECT CASE
          WHEN to_regclass($1) IS NOT NULL
            AND to_regclass($2) IS NULL
          THEN (
            SELECT view_definition
            FROM timescaledb_information.continuous_aggregates
            WHERE view_schema = 'platform'
              AND view_name = 'logs_severity_stats_5m'
          )
          ELSE NULL
        END
        """,
        [@view, @candidate_view]
      )

    is_binary(view_definition) and
      String.contains?(view_definition, "serviceradar_log_severity_bucket")
  end

  defp create_severity_classifier do
    execute("""
    CREATE OR REPLACE FUNCTION #{@classifier}(
      severity_text text,
      severity_number integer
    )
    RETURNS text
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $function$
      SELECT CASE
        WHEN lower(COALESCE(severity_text, '')) IN (
          'fatal',
          'critical',
          'emergency',
          'alert',
          'severity_number_fatal',
          'severity_number_fatal2',
          'severity_number_fatal3',
          'severity_number_fatal4'
        ) THEN 'fatal'
        WHEN lower(COALESCE(severity_text, '')) IN (
          'error',
          'err',
          'severity_number_error',
          'severity_number_error2',
          'severity_number_error3',
          'severity_number_error4'
        ) THEN 'error'
        WHEN lower(COALESCE(severity_text, '')) IN (
          'warning',
          'warn',
          'severity_number_warn',
          'severity_number_warn2',
          'severity_number_warn3',
          'severity_number_warn4'
        ) THEN 'warning'
        WHEN lower(COALESCE(severity_text, '')) IN (
          'info',
          'information',
          'informational',
          'notice',
          'severity_number_info',
          'severity_number_info2',
          'severity_number_info3',
          'severity_number_info4'
        ) THEN 'info'
        WHEN lower(COALESCE(severity_text, '')) IN (
          'debug',
          'trace',
          'severity_number_debug',
          'severity_number_debug2',
          'severity_number_debug3',
          'severity_number_debug4',
          'severity_number_trace',
          'severity_number_trace2',
          'severity_number_trace3',
          'severity_number_trace4'
        ) THEN 'debug'
        WHEN severity_number BETWEEN 21 AND 24 THEN 'fatal'
        WHEN severity_number BETWEEN 17 AND 20 THEN 'error'
        WHEN severity_number BETWEEN 13 AND 16 THEN 'warning'
        WHEN severity_number BETWEEN 9 AND 12 THEN 'info'
        WHEN severity_number BETWEEN 1 AND 8 THEN 'debug'
        ELSE NULL
      END
    $function$
    """)
  end

  defp preflight_promotion do
    execute("""
    DO $$
    BEGIN
      IF to_regclass('#{@legacy_view}') IS NOT NULL THEN
        RAISE EXCEPTION '#{@legacy_view} already exists; refusing an ambiguous CAGG promotion';
      END IF;
    END;
    $$;
    """)
  end

  defp create_candidate do
    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@candidate_view}
    WITH (
      timescaledb.continuous,
      timescaledb.create_group_indexes = false
    ) AS
    SELECT
      time_bucket('5 minutes', timestamp) AS bucket,
      service_name,
      COUNT(*)::bigint AS total_count,
      COUNT(*) FILTER (
        WHERE #{@classifier}(severity_text, severity_number) = 'fatal'
      )::bigint AS fatal_count,
      COUNT(*) FILTER (
        WHERE #{@classifier}(severity_text, severity_number) = 'error'
      )::bigint AS error_count,
      COUNT(*) FILTER (
        WHERE #{@classifier}(severity_text, severity_number) = 'warning'
      )::bigint AS warning_count,
      COUNT(*) FILTER (
        WHERE #{@classifier}(severity_text, severity_number) = 'info'
      )::bigint AS info_count,
      COUNT(*) FILTER (
        WHERE #{@classifier}(severity_text, severity_number) = 'debug'
      )::bigint AS debug_count
    FROM #{@source_table}
    GROUP BY 1, 2
    WITH NO DATA
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_logs_severity_stats_5m_v2_service_bucket
    ON #{@candidate_view} (service_name, bucket DESC)
    """)
  end

  defp configure_candidate_policy do
    configure_policy(@candidate_view)
  end

  defp configure_promoted_policy do
    configure_policy(@view)
  end

  defp configure_policy(view) do
    execute("""
    DO $$
    DECLARE
      ts_schema text;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RAISE EXCEPTION 'TimescaleDB extension is required for #{view}';
      END IF;

      IF to_regclass('#{view}') IS NULL THEN
        RAISE EXCEPTION 'CAGG #{view} is missing';
      END IF;

      EXECUTE format(
        'SELECT %I.add_continuous_aggregate_policy(%L::regclass, '
        'start_offset => INTERVAL ''#{@refresh_start_offset}'', '
        'end_offset => INTERVAL ''#{@refresh_end_offset}'', '
        'schedule_interval => INTERVAL ''#{@refresh_interval}'', '
        'if_not_exists => true)',
        ts_schema,
        '#{view}'
      );
    END;
    $$;
    """)
  end

  defp remove_current_policy do
    execute("""
    DO $$
    DECLARE
      ts_schema text;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RAISE EXCEPTION 'TimescaleDB extension is required for #{@view}';
      END IF;

      IF to_regclass('#{@candidate_view}') IS NULL THEN
        RAISE EXCEPTION 'Candidate CAGG #{@candidate_view} is missing';
      END IF;

      IF to_regclass('#{@view}') IS NOT NULL THEN
        EXECUTE format(
          'SELECT %I.remove_continuous_aggregate_policy(%L::regclass, if_exists => true)',
          ts_schema,
          '#{@view}'
        );
      END IF;
    END;
    $$;
    """)
  end

  defp promote_candidate do
    execute("""
    DO $$
    BEGIN
      IF to_regclass('#{@view}') IS NOT NULL THEN
        ALTER MATERIALIZED VIEW #{@view}
          RENAME TO logs_severity_stats_5m_legacy;
      END IF;

      ALTER MATERIALIZED VIEW #{@candidate_view}
        RENAME TO logs_severity_stats_5m;
    END;
    $$;
    """)
  end

  def down do
    # Safety-net migration: never remove a rollup that may predate this version.
  end
end
