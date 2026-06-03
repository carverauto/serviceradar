defmodule ServiceRadar.Repo.Migrations.AddDeviceFleetOrdinals do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute("""
    CREATE SEQUENCE IF NOT EXISTS platform.device_fleet_ordinals_ordinal_seq
      AS integer
      MINVALUE 1
      NO CYCLE
    """)

    create table(:device_fleet_ordinals, primary_key: false, prefix: "platform") do
      add(
        :uid,
        references(:ocsf_devices,
          column: :uid,
          type: :text,
          prefix: "platform",
          on_delete: :restrict
        ),
        null: false,
        primary_key: true
      )

      add(:ordinal, :integer,
        null: false,
        default: fragment("nextval('platform.device_fleet_ordinals_ordinal_seq'::regclass)")
      )

      add(:tombstoned, :boolean, null: false, default: false)

      add(:allocated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(:device_fleet_ordinals, [:ordinal],
        name: "device_fleet_ordinals_ordinal_uidx",
        prefix: "platform"
      )
    )

    create(
      index(:device_fleet_ordinals, [:tombstoned],
        name: "device_fleet_ordinals_tombstoned_idx",
        prefix: "platform"
      )
    )

    execute("""
    INSERT INTO platform.device_fleet_ordinals (uid, ordinal, tombstoned, allocated_at)
    SELECT d.uid,
           nextval('platform.device_fleet_ordinals_ordinal_seq'::regclass)::integer,
           FALSE,
           now()
    FROM platform.ocsf_devices AS d
    WHERE d.uid IS NOT NULL
      AND d.uid NOT LIKE 'serviceradar:%'
      AND COALESCE(d.is_active, TRUE) = TRUE
      AND d.deleted_at IS NULL
    ON CONFLICT (uid) DO NOTHING
    """)
  end

  def down do
    drop_if_exists(
      index(:device_fleet_ordinals, [:tombstoned],
        name: "device_fleet_ordinals_tombstoned_idx",
        prefix: "platform"
      )
    )

    drop_if_exists(
      unique_index(:device_fleet_ordinals, [:ordinal],
        name: "device_fleet_ordinals_ordinal_uidx",
        prefix: "platform"
      )
    )

    drop_if_exists(table(:device_fleet_ordinals, prefix: "platform"))
    execute("DROP SEQUENCE IF EXISTS platform.device_fleet_ordinals_ordinal_seq")
  end
end
