defmodule ServiceRadar.Repo.Migrations.CreateDeviceSourceInventory do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:device_source_snapshots, primary_key: false, prefix: @prefix) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :partition, :text, null: false, default: "default"
      add :source, :text, null: false
      add :source_instance, :text, null: false
      add :collection_id, :text, null: false
      add :content_hash, :text, null: false
      add :query_hash, :text
      add :observed_at, :utc_datetime_usec, null: false
      add :activated_at, :utc_datetime_usec, null: false
      add :device_count, :bigint, null: false, default: 0
      add :absent_count, :bigint, null: false, default: 0
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false, default: utc_now()
      add :updated_at, :utc_datetime_usec, null: false, default: utc_now()
    end

    create unique_index(
             :device_source_snapshots,
             [:partition, :source, :source_instance],
             prefix: @prefix,
             name: "device_source_snapshots_source_instance_uidx"
           )

    create index(:device_source_snapshots, [:source, :observed_at],
             prefix: @prefix,
             name: "device_source_snapshots_source_observed_idx"
           )

    create table(:device_source_observations, primary_key: false, prefix: @prefix) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :device_id,
          references(:ocsf_devices,
            prefix: @prefix,
            column: :uid,
            type: :text,
            on_delete: :restrict,
            name: "device_source_observations_device_id_fkey"
          ),
          null: false

      add :partition, :text, null: false, default: "default"
      add :source, :text, null: false
      add :source_instance, :text, null: false
      add :source_object_id, :text, null: false
      add :source_integration_id, :text, null: false
      add :collection_id, :text, null: false
      add :content_hash, :text, null: false
      add :query_hash, :text
      add :present, :boolean, null: false, default: true
      add :first_observed_at, :utc_datetime_usec, null: false
      add :last_observed_at, :utc_datetime_usec, null: false
      add :absent_since, :utc_datetime_usec
      add :hostname, :text
      add :ip, :text
      add :mac, :text
      add :serial_number, :text
      add :vendor_name, :text
      add :model, :text
      add :device_type, :text
      add :site_name, :text
      add :management_status, :text
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false, default: utc_now()
      add :updated_at, :utc_datetime_usec, null: false, default: utc_now()
    end

    create unique_index(
             :device_source_observations,
             [:partition, :source, :source_instance, :source_object_id],
             prefix: @prefix,
             name: "device_source_observations_source_object_uidx"
           )

    create index(
             :device_source_observations,
             [:source, :source_instance, :present, :last_observed_at, :id],
             prefix: @prefix,
             name: "device_source_observations_current_cursor_idx"
           )

    create index(:device_source_observations, [:device_id, :source],
             prefix: @prefix,
             name: "device_source_observations_device_source_idx"
           )

    create index(:device_source_observations, [:source, :source_instance, :collection_id],
             prefix: @prefix,
             name: "device_source_observations_collection_idx"
           )

    create index(:device_source_observations, [:source, :source_instance, :source_object_id],
             prefix: @prefix,
             name: "device_source_observations_object_lookup_idx"
           )

    execute("""
    CREATE INDEX device_source_observations_hostname_trgm_idx
      ON #{@prefix}.device_source_observations USING gin (hostname gin_trgm_ops)
      WHERE present = true
    """)

    execute("""
    CREATE INDEX device_source_observations_serial_trgm_idx
      ON #{@prefix}.device_source_observations USING gin (serial_number gin_trgm_ops)
      WHERE present = true
    """)
  end

  def down do
    drop table(:device_source_observations, prefix: @prefix)
    drop table(:device_source_snapshots, prefix: @prefix)
  end

  defp utc_now, do: fragment("timezone('utc', now())")
end
