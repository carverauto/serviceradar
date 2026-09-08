defmodule ServiceRadar.Repo.Migrations.AddCanonicalDeviceFacts do
  @moduledoc """
  Canonical switch-port attachment plus generic source-fact comparison.

  Source-prefixed metadata such as `armis_access_switch` stays on the device.
  These tables record normalized per-source facts, operator authority, and
  durable disagreements. `ocsf_events` is not the report source of truth.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:ocsf_devices, prefix: @prefix) do
      add_if_not_exists(:switch_port_attachment, :map)
    end

    execute("""
    CREATE INDEX IF NOT EXISTS ocsf_devices_switch_port_hostname_idx
    ON #{@prefix}.ocsf_devices ((switch_port_attachment ->> 'switch_hostname'))
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS ocsf_devices_switch_port_port_idx
    ON #{@prefix}.ocsf_devices ((switch_port_attachment ->> 'port'))
    """)

    create_if_not_exists table(:device_source_facts, primary_key: false, prefix: @prefix) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :device_uid, :text, null: false
      add :source, :text, null: false
      add :source_instance, :text, null: false, default: "default"
      add :fact_key, :text, null: false
      add :compare_hash, :text, null: false
      add :value, :map, null: false, default: %{}
      add :raw, :text
      add :present, :boolean, null: false, default: true
      add :observed_at, :utc_datetime_usec, null: false, default: utc_now()
      add :inserted_at, :utc_datetime_usec, null: false, default: utc_now()
      add :updated_at, :utc_datetime_usec, null: false, default: utc_now()
    end

    create unique_index(:device_source_facts, [:device_uid, :source, :source_instance, :fact_key],
             prefix: @prefix,
             name: :device_source_facts_device_source_key_uidx
           )

    create index(:device_source_facts, [:device_uid, :fact_key],
             prefix: @prefix,
             name: :device_source_facts_device_key_idx
           )

    create_if_not_exists table(:source_fact_disagreements, primary_key: false, prefix: @prefix) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :device_uid, :text, null: false
      add :fact_key, :text, null: false
      add :status, :text, null: false, default: "open"
      add :compare_signature, :text, null: false
      add :values, :map, null: false, default: %{}
      add :configuration_conflict, :boolean, null: false, default: false
      add :first_detected_at, :utc_datetime_usec, null: false, default: utc_now()
      add :last_detected_at, :utc_datetime_usec, null: false, default: utc_now()
      add :cleared_at, :utc_datetime_usec
      add :dismissed_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false, default: utc_now()
      add :updated_at, :utc_datetime_usec, null: false, default: utc_now()
    end

    create index(:source_fact_disagreements, [:status, :fact_key], prefix: @prefix)

    create index(:source_fact_disagreements, [:device_uid], prefix: @prefix)

    execute("""
    CREATE UNIQUE INDEX source_fact_disagreements_open_uidx
    ON #{@prefix}.source_fact_disagreements (device_uid, fact_key)
    WHERE status = 'open'
    """)

    create_if_not_exists table(:source_fact_authorities, primary_key: false, prefix: @prefix) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :source_kind, :text, null: false
      add :source_ref, :text, null: false
      add :source, :text, null: false
      add :source_instance, :text
      add :fact_key, :text, null: false
      add :rank, :integer, null: false, default: 1
      add :enabled, :boolean, null: false, default: true
      add :inserted_at, :utc_datetime_usec, null: false, default: utc_now()
      add :updated_at, :utc_datetime_usec, null: false, default: utc_now()
    end

    create unique_index(:source_fact_authorities, [:source_kind, :source_ref, :fact_key],
             prefix: @prefix,
             name: :source_fact_authorities_kind_ref_key_uidx
           )
  end

  def down do
    execute("DROP INDEX IF EXISTS #{@prefix}.source_fact_disagreements_open_uidx")
    drop_if_exists table(:source_fact_authorities, prefix: @prefix)
    drop_if_exists table(:source_fact_disagreements, prefix: @prefix)
    drop_if_exists table(:device_source_facts, prefix: @prefix)
    execute("DROP INDEX IF EXISTS #{@prefix}.ocsf_devices_switch_port_port_idx")
    execute("DROP INDEX IF EXISTS #{@prefix}.ocsf_devices_switch_port_hostname_idx")

    alter table(:ocsf_devices, prefix: @prefix) do
      remove_if_exists(:switch_port_attachment, :map)
    end
  end

  defp utc_now do
    fragment("timezone('utc', now())")
  end
end
