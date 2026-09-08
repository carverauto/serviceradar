defmodule ServiceRadar.Repo.Migrations.CreateVirtualizationInventoryTables do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def change do
    create table(:virtualization_clusters, primary_key: false, prefix: @prefix) do
      add :id, :uuid, primary_key: true
      add :provider, :text, null: false
      add :provider_ref, :text, null: false
      add :name, :text, null: false
      add :status, :text
      add :version, :text
      add :metadata, :map, null: false, default: %{}
      add :observed_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:virtualization_clusters, [:provider, :provider_ref],
             prefix: @prefix,
             name: :virtualization_clusters_provider_ref_idx
           )

    create table(:virtualization_hosts, primary_key: false, prefix: @prefix) do
      add :id, :uuid, primary_key: true
      add :provider, :text, null: false
      add :provider_ref, :text, null: false

      add :cluster_id,
          references(:virtualization_clusters,
            type: :uuid,
            on_delete: :nilify_all,
            prefix: @prefix
          )

      add :device_uid,
          references(:ocsf_devices,
            column: :uid,
            type: :text,
            on_delete: :nilify_all,
            prefix: @prefix
          )

      add :name, :text, null: false
      add :status, :text
      add :version, :text
      add :cpu_ratio, :float
      add :memory_used_bytes, :bigint
      add :memory_total_bytes, :bigint
      add :uptime_seconds, :bigint
      add :metadata, :map, null: false, default: %{}
      add :observed_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:virtualization_hosts, [:provider, :provider_ref],
             prefix: @prefix,
             name: :virtualization_hosts_provider_ref_idx
           )

    create index(:virtualization_hosts, [:cluster_id], prefix: @prefix)
    create index(:virtualization_hosts, [:device_uid], prefix: @prefix)

    create table(:virtualization_guests, primary_key: false, prefix: @prefix) do
      add :id, :uuid, primary_key: true
      add :provider, :text, null: false
      add :provider_ref, :text, null: false

      add :host_id,
          references(:virtualization_hosts, type: :uuid, on_delete: :nilify_all, prefix: @prefix)

      add :device_uid,
          references(:ocsf_devices,
            column: :uid,
            type: :text,
            on_delete: :nilify_all,
            prefix: @prefix
          )

      add :name, :text
      add :guest_type, :text, null: false
      add :status, :text
      add :cpu_ratio, :float
      add :memory_used_bytes, :bigint
      add :memory_total_bytes, :bigint
      add :disk_used_bytes, :bigint
      add :disk_total_bytes, :bigint
      add :uptime_seconds, :bigint
      add :metadata, :map, null: false, default: %{}
      add :observed_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:virtualization_guests, [:provider, :provider_ref],
             prefix: @prefix,
             name: :virtualization_guests_provider_ref_idx
           )

    create index(:virtualization_guests, [:host_id], prefix: @prefix)
    create index(:virtualization_guests, [:device_uid], prefix: @prefix)

    create table(:virtualization_datastores, primary_key: false, prefix: @prefix) do
      add :id, :uuid, primary_key: true
      add :provider, :text, null: false
      add :provider_ref, :text, null: false

      add :cluster_id,
          references(:virtualization_clusters,
            type: :uuid,
            on_delete: :nilify_all,
            prefix: @prefix
          )

      add :host_id,
          references(:virtualization_hosts, type: :uuid, on_delete: :nilify_all, prefix: @prefix)

      add :name, :text, null: false
      add :storage_type, :text
      add :content, :text
      add :active, :boolean
      add :enabled, :boolean
      add :shared, :boolean
      add :used_bytes, :bigint
      add :available_bytes, :bigint
      add :total_bytes, :bigint
      add :metadata, :map, null: false, default: %{}
      add :observed_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:virtualization_datastores, [:provider, :provider_ref],
             prefix: @prefix,
             name: :virtualization_datastores_provider_ref_idx
           )

    create index(:virtualization_datastores, [:cluster_id], prefix: @prefix)
    create index(:virtualization_datastores, [:host_id], prefix: @prefix)

    create table(:virtualization_host_disks, primary_key: false, prefix: @prefix) do
      add :id, :uuid, primary_key: true
      add :provider, :text, null: false
      add :provider_ref, :text, null: false

      add :host_id,
          references(:virtualization_hosts, type: :uuid, on_delete: :delete_all, prefix: @prefix),
          null: false

      add :device_uid,
          references(:ocsf_devices,
            column: :uid,
            type: :text,
            on_delete: :nilify_all,
            prefix: @prefix
          )

      add :path, :text
      add :by_id, :text
      add :disk_type, :text
      add :vendor, :text
      add :model, :text
      add :health, :text
      add :size_bytes, :bigint
      add :wearout, :integer
      add :usage, :text
      add :metadata, :map, null: false, default: %{}
      add :observed_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:virtualization_host_disks, [:provider, :provider_ref],
             prefix: @prefix,
             name: :virtualization_host_disks_provider_ref_idx
           )

    create index(:virtualization_host_disks, [:host_id], prefix: @prefix)
    create index(:virtualization_host_disks, [:device_uid], prefix: @prefix)

    create table(:virtualization_network_interfaces, primary_key: false, prefix: @prefix) do
      add :id, :uuid, primary_key: true
      add :provider, :text, null: false
      add :provider_ref, :text, null: false

      add :host_id,
          references(:virtualization_hosts, type: :uuid, on_delete: :delete_all, prefix: @prefix),
          null: false

      add :device_uid,
          references(:ocsf_devices,
            column: :uid,
            type: :text,
            on_delete: :nilify_all,
            prefix: @prefix
          )

      add :name, :text, null: false
      add :interface_type, :text
      add :active, :boolean
      add :exists, :boolean
      add :method, :text
      add :method6, :text
      add :address, :text
      add :cidr, :text
      add :gateway, :text
      add :bridge_ports, :text
      add :vlan_id, :integer
      add :metadata, :map, null: false, default: %{}
      add :observed_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:virtualization_network_interfaces, [:provider, :provider_ref],
             prefix: @prefix,
             name: :virtualization_network_interfaces_provider_ref_idx
           )

    create index(:virtualization_network_interfaces, [:host_id], prefix: @prefix)
    create index(:virtualization_network_interfaces, [:device_uid], prefix: @prefix)

    create table(:virtualization_storage_systems, primary_key: false, prefix: @prefix) do
      add :id, :uuid, primary_key: true
      add :provider, :text, null: false
      add :provider_ref, :text, null: false

      add :cluster_id,
          references(:virtualization_clusters,
            type: :uuid,
            on_delete: :nilify_all,
            prefix: @prefix
          )

      add :host_id,
          references(:virtualization_hosts, type: :uuid, on_delete: :nilify_all, prefix: @prefix)

      add :name, :text
      add :storage_system_type, :text, null: false
      add :health, :text
      add :status, :text
      add :metadata, :map, null: false, default: %{}
      add :observed_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:virtualization_storage_systems, [:provider, :provider_ref],
             prefix: @prefix,
             name: :virtualization_storage_systems_provider_ref_idx
           )

    create index(:virtualization_storage_systems, [:cluster_id], prefix: @prefix)
    create index(:virtualization_storage_systems, [:host_id], prefix: @prefix)
  end
end
