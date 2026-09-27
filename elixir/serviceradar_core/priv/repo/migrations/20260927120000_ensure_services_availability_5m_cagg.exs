defmodule ServiceRadar.Repo.Migrations.EnsureServicesAvailability5mCagg do
  @moduledoc """
  Creates the service availability continuous aggregate the dashboard service
  card, the service health sparkline and SRQL `rollup_stats:availability` read.

  Those readers have always queried `platform.services_availability_5m`, and the
  `cnpg` and `srql` specs require it, but nothing creates it: the original
  definition (archived change `fix-observability-logs-stats-cards`) counted
  `COUNT(DISTINCT (poller_id, agent_id, service_name))`, which a TimescaleDB
  continuous aggregate refuses, so every reader returned nothing.

  The same counts without DISTINCT: one row per 5-minute bucket and service
  instance (`gateway_id`, `agent_id`, `service_name`, `service_type`), with
  `total_count` 1, `available_count` 1 when the instance reported available in the
  bucket and `unavailable_count` 1 when it reported unavailable. Readers sum the
  rows, so each instance is counted once per availability state, broken down by
  `service_type`, as the specs describe.

  The view is real time (`materialized_only = false`), so buckets newer than the
  refresh window are read from `service_status` directly, and it is created with
  no data, so startup does not scan the table; the refresh policy materializes
  the last day. An out-of-band copy left by an earlier schema is kept under a
  rollback name, as `EnsureLogsSeverityStats5mCagg` does, instead of being
  mistaken for this one.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @source_table "platform.service_status"
  @view "platform.services_availability_5m"
  @candidate_view "platform.services_availability_5m_v2"
  @legacy_view "platform.services_availability_5m_legacy"
  @refresh_start_offset "1 day"
  @refresh_end_offset "5 minutes"
  @refresh_interval "5 minutes"

  def up do
    # serviceradar:allow-startup-maintenance - WITH NO DATA makes creation
    # metadata-only; the policy materializes the last day asynchronously. Every
    # step before the final transactional rename is retry-safe: candidate DDL uses
    # IF NOT EXISTS, policy creation is idempotent, and old policy removal uses
    # if_exists. An out-of-band view is kept under a rollback name.
    if promotion_already_complete?() do
      configure_policy(@view)
    else
      preflight_promotion()
      create_candidate()
      configure_policy(@candidate_view)
      remove_current_policy()
      promote_candidate()
    end
  end

  # The final rename can commit before Ecto records this version if the
  # connection drops. A main view built from service_status with no candidate
  # left over is this migration's own, so finish idempotently.
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
              AND view_name = 'services_availability_5m'
          )
          ELSE NULL
        END
        """,
        [@view, @candidate_view]
      )

    is_binary(view_definition) and String.contains?(view_definition, "service_status") and
      String.contains?(view_definition, "unavailable_count")
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
      timescaledb.materialized_only = false,
      timescaledb.create_group_indexes = false
    ) AS
    SELECT
      time_bucket('5 minutes', timestamp) AS bucket,
      gateway_id,
      agent_id,
      service_name,
      service_type,
      1::bigint AS total_count,
      (CASE WHEN bool_or(available IS TRUE) THEN 1 ELSE 0 END)::bigint AS available_count,
      (CASE WHEN bool_or(available IS FALSE) THEN 1 ELSE 0 END)::bigint AS unavailable_count
    FROM #{@source_table}
    GROUP BY 1, 2, 3, 4, 5
    WITH NO DATA
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_services_availability_5m_v2_bucket
    ON #{@candidate_view} (bucket DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_services_availability_5m_v2_service_bucket
    ON #{@candidate_view} (service_name, bucket DESC)
    """)
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

      IF to_regclass('#{@view}') IS NOT NULL
        AND EXISTS (
          SELECT 1
          FROM timescaledb_information.continuous_aggregates
          WHERE view_schema = 'platform'
            AND view_name = 'services_availability_5m'
        )
      THEN
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

  # An out-of-band relation may be a continuous aggregate, a materialized view
  # or a plain view, and each is renamed with its own statement. A continuous
  # aggregate's relation is itself a view (relkind v) that refuses ALTER VIEW, so
  # it is recognised through the TimescaleDB catalog, not by relkind.
  defp promote_candidate do
    execute("""
    DO $$
    DECLARE
      existing_kind "char";
      existing_is_cagg boolean;
    BEGIN
      SELECT c.relkind
      INTO existing_kind
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'platform'
        AND c.relname = 'services_availability_5m';

      SELECT EXISTS (
        SELECT 1
        FROM timescaledb_information.continuous_aggregates
        WHERE view_schema = 'platform'
          AND view_name = 'services_availability_5m'
      )
      INTO existing_is_cagg;

      IF existing_is_cagg OR existing_kind = 'm' THEN
        ALTER MATERIALIZED VIEW #{@view} RENAME TO services_availability_5m_legacy;
      ELSIF existing_kind = 'v' THEN
        ALTER VIEW #{@view} RENAME TO services_availability_5m_legacy;
      ELSIF existing_kind IS NOT NULL THEN
        ALTER TABLE #{@view} RENAME TO services_availability_5m_legacy;
      END IF;

      ALTER MATERIALIZED VIEW #{@candidate_view}
        RENAME TO services_availability_5m;
    END;
    $$;
    """)
  end

  def down do
    # Safety-net migration: never remove a rollup that an earlier schema may own.
  end
end
