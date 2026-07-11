defmodule ServiceRadar.Repo.Migrations.OrderHealthEventsByDatabaseSequence do
  @moduledoc false

  use Ecto.Migration

  @prefix "platform"
  @sequence "platform.health_events_event_sequence_seq"

  def up do
    # serviceradar:allow-startup-maintenance - this backfill is required before the
    # application can use event_sequence as its total-order key. Deferring it would
    # expose NULL or partially ordered health events to readers. The live relation was
    # verified at 1,080 rows / 824 KiB on 2026-07-10 before release; an exclusive lock
    # keeps legacy rows and concurrent inserts in one ordering epoch. Transaction-local
    # deadlines make unexpected contention or growth fail the migration instead of
    # stalling first-boot startup indefinitely.
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")
    execute("LOCK TABLE platform.health_events IN ACCESS EXCLUSIVE MODE")

    alter table(:health_events, prefix: @prefix) do
      modify :recorded_at, :utc_datetime_usec, null: false
      add :event_sequence, :bigint
    end

    execute("CREATE SEQUENCE #{@sequence} AS bigint MINVALUE 1 NO CYCLE")

    # Startup ownership repair deliberately makes existing ServiceRadar tables
    # app-owned before migrations run, while the Helm migration Repo remains an
    # admin so it can bootstrap extensions and databases. PostgreSQL rejects
    # OWNED BY when a newly created admin-owned sequence and its table have
    # different owners, so align the sequence with the table first. This is also
    # a no-op owner transition when migrations already run as the app role.
    execute("""
    DO $migration$
    DECLARE
      table_owner name;
    BEGIN
      SELECT pg_get_userbyid(c.relowner)
      INTO STRICT table_owner
      FROM pg_class AS c
      WHERE c.oid = 'platform.health_events'::regclass;

      EXECUTE format(
        'ALTER SEQUENCE platform.health_events_event_sequence_seq OWNER TO %I',
        table_owner
      );
    END
    $migration$
    """)

    # The legacy column only retained whole seconds. Within those ties, xmin is
    # the best remaining transaction-order signal and ctid preserves physical
    # insert order within one transaction; UUID is the final stable fallback.
    # xmin and ctid are intentionally used once under this lock because neither
    # system value is preserved by dump/restore.
    execute("""
    WITH ordered AS MATERIALIZED (
      SELECT id,
             row_number() OVER (
               ORDER BY recorded_at ASC, xmin::text::bigint ASC, ctid ASC, id ASC
             )::bigint AS event_sequence
      FROM platform.health_events
    )
    UPDATE platform.health_events AS health_event
    SET event_sequence = ordered.event_sequence
    FROM ordered
    WHERE health_event.id = ordered.id
    """)

    execute("""
    SELECT setval(
      '#{@sequence}'::regclass,
      COALESCE((SELECT max(event_sequence) FROM platform.health_events), 0) + 1,
      false
    )
    """)

    execute("""
    ALTER TABLE platform.health_events
      ALTER COLUMN event_sequence
      SET DEFAULT nextval('#{@sequence}'::regclass),
      ALTER COLUMN event_sequence SET NOT NULL
    """)

    execute("ALTER SEQUENCE #{@sequence} OWNED BY platform.health_events.event_sequence")

    create(
      unique_index(:health_events, [:event_sequence],
        name: "health_events_event_sequence_uidx",
        prefix: @prefix
      )
    )

    create(
      index(:health_events, [:entity_type, :entity_id, :event_sequence],
        name: "health_events_entity_id_sequence_idx",
        prefix: @prefix
      )
    )

    create(
      index(:health_events, [:entity_type, :new_state, :event_sequence],
        name: "health_events_state_sequence_idx",
        prefix: @prefix
      )
    )
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")
    execute("LOCK TABLE platform.health_events IN ACCESS EXCLUSIVE MODE")

    drop_if_exists(
      index(:health_events, [:entity_type, :new_state, :event_sequence],
        name: "health_events_state_sequence_idx",
        prefix: @prefix
      )
    )

    drop_if_exists(
      index(:health_events, [:entity_type, :entity_id, :event_sequence],
        name: "health_events_entity_id_sequence_idx",
        prefix: @prefix
      )
    )

    drop_if_exists(
      unique_index(:health_events, [:event_sequence],
        name: "health_events_event_sequence_uidx",
        prefix: @prefix
      )
    )

    alter table(:health_events, prefix: @prefix) do
      remove :event_sequence
      modify :recorded_at, :utc_datetime, null: false
    end

    execute("DROP SEQUENCE IF EXISTS #{@sequence}")
  end
end
