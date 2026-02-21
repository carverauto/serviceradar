defmodule ServiceRadar.Repo.Migrations.UpdateInterfaceObservations do
  use Ecto.Migration

  def up do
    alter table(:discovered_interfaces) do
      add :interface_uid, :text
      add :if_type, :integer
      add :if_type_name, :text
      add :interface_kind, :text
      add :mtu, :integer
      add :duplex, :text
      add :speed_bps, :bigint
    end

    execute("""
    UPDATE #{prefix() || "platform"}.discovered_interfaces
       SET interface_uid = CASE
         WHEN interface_uid IS NOT NULL AND interface_uid <> '' THEN interface_uid
         WHEN if_index IS NOT NULL THEN 'ifindex:' || if_index::text
         WHEN if_name IS NOT NULL AND if_name <> '' THEN 'ifname:' || if_name
         WHEN if_descr IS NOT NULL AND if_descr <> '' THEN 'ifdescr:' || if_descr
         ELSE 'unknown'
       END
     WHERE interface_uid IS NULL OR interface_uid = ''
    """)

    execute("""
    UPDATE #{prefix() || "platform"}.discovered_interfaces
       SET speed_bps = if_speed
     WHERE speed_bps IS NULL AND if_speed IS NOT NULL
    """)

    execute(
      "ALTER TABLE #{prefix() || "platform"}.discovered_interfaces DROP CONSTRAINT IF EXISTS discovered_interfaces_pkey"
    )

    execute("ALTER TABLE #{prefix() || "platform"}.discovered_interfaces ALTER COLUMN interface_uid SET NOT NULL")
    execute("ALTER TABLE #{prefix() || "platform"}.discovered_interfaces ALTER COLUMN if_index DROP NOT NULL")

    execute(
      "ALTER TABLE #{prefix() || "platform"}.discovered_interfaces ADD PRIMARY KEY (timestamp, device_id, interface_uid)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_discovered_interfaces_device ON #{prefix() || "platform"}.discovered_interfaces (device_id)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS idx_discovered_interfaces_device_time ON #{prefix() || "platform"}.discovered_interfaces (device_id, timestamp DESC)"
    )

    # Convert to hypertable and add retention policy if TimescaleDB is available
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb') THEN
        IF NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_name = 'discovered_interfaces'
          AND hypertable_schema = '#{prefix() || "platform"}'
        ) THEN
          PERFORM create_hypertable(
            '#{prefix() || "platform"}.discovered_interfaces'::regclass,
            'timestamp',
            migrate_data => true,
            if_not_exists => true
          );
        END IF;

        PERFORM add_retention_policy(
          '#{prefix() || "platform"}.discovered_interfaces'::regclass,
          INTERVAL '3 days',
          if_not_exists => true
        );
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not configure interface retention policy: %', SQLERRM;
    END;
    $$;
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_discovered_interfaces_device_time")
    execute("DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_discovered_interfaces_device")

    execute(
      "ALTER TABLE #{prefix() || "platform"}.discovered_interfaces DROP CONSTRAINT IF EXISTS discovered_interfaces_pkey"
    )

    execute("ALTER TABLE #{prefix() || "platform"}.discovered_interfaces ALTER COLUMN if_index SET NOT NULL")

    execute(
      "ALTER TABLE #{prefix() || "platform"}.discovered_interfaces ADD PRIMARY KEY (timestamp, device_id, if_index)"
    )

    alter table(:discovered_interfaces) do
      remove :interface_uid
      remove :if_type
      remove :if_type_name
      remove :interface_kind
      remove :mtu
      remove :duplex
      remove :speed_bps
    end
  end
end
