defmodule ServiceRadar.Repo.Migrations.AddEndpointInventoryStorage do
  @moduledoc false
  use Ecto.Migration

  def up do
    create table(:endpoint_inventory_scans, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:device_uid, :text)
      add(:agent_id, :text, null: false)
      add(:scan_id, :text, null: false)
      add(:collector_name, :text)
      add(:collector_version, :text)
      add(:state, :text, null: false, default: "not_scanned")
      add(:coverage_state, :text, null: false, default: "not_scanned")
      add(:package_count, :integer, null: false, default: 0)
      add(:enabled_sources, {:array, :text}, null: false, default: [])
      add(:manager_counts, :map, null: false, default: %{})
      add(:source_summaries, {:array, :map}, null: false, default: [])
      add(:artifact_count, :integer, null: false, default: 0)
      add(:current, :boolean, null: false, default: false)
      add(:last_successful_scan_at, :utc_datetime_usec)
      add(:last_scan_at, :utc_datetime_usec)
      add(:ingested_at, :utc_datetime_usec)
      add(:metadata, :map, null: false, default: %{})

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(:endpoint_inventory_scans, [:agent_id, :scan_id],
        name: "endpoint_inventory_scans_agent_scan_uidx",
        prefix: "platform"
      )
    )

    create(
      index(:endpoint_inventory_scans, [:agent_id, :current],
        name: "endpoint_inventory_scans_agent_current_idx",
        prefix: "platform"
      )
    )

    create(
      index(:endpoint_inventory_scans, [:device_uid, :current],
        name: "endpoint_inventory_scans_device_current_idx",
        prefix: "platform",
        where: "device_uid IS NOT NULL"
      )
    )

    create table(:endpoint_inventory_artifacts, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :scan_ref,
        references(:endpoint_inventory_scans,
          type: :uuid,
          on_delete: :delete_all,
          prefix: "platform"
        ),
        null: false
      )

      add(:agent_id, :text, null: false)
      add(:device_uid, :text)
      add(:object_key, :text, null: false)
      add(:bucket, :text)
      add(:domain, :text)
      add(:content_type, :text, null: false, default: "application/json")
      add(:format, :text, null: false, default: "CycloneDX")
      add(:spec_version, :text)
      add(:sha256, :text, null: false)
      add(:size_bytes, :bigint, null: false, default: 0)
      add(:storage_backend, :text, null: false, default: "datasvc_object_store")
      add(:uploaded_at, :utc_datetime_usec)
      add(:metadata, :map, null: false, default: %{})

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      index(:endpoint_inventory_artifacts, [:scan_ref],
        name: "endpoint_inventory_artifacts_scan_ref_idx",
        prefix: "platform"
      )
    )

    create(
      unique_index(:endpoint_inventory_artifacts, [:object_key],
        name: "endpoint_inventory_artifacts_object_key_uidx",
        prefix: "platform"
      )
    )

    create(
      index(:endpoint_inventory_artifacts, [:sha256],
        name: "endpoint_inventory_artifacts_sha256_idx",
        prefix: "platform"
      )
    )

    create table(:endpoint_inventory_packages, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :scan_ref,
        references(:endpoint_inventory_scans,
          type: :uuid,
          on_delete: :delete_all,
          prefix: "platform"
        ),
        null: false
      )

      add(:device_uid, :text)
      add(:agent_id, :text, null: false)
      add(:name, :text, null: false)
      add(:version, :text)
      add(:architecture, :text)
      add(:package_manager, :text, null: false)
      add(:ecosystem, :text)
      add(:purl, :text)
      add(:cpes, {:array, :text}, null: false, default: [])
      add(:supplier, :text)
      add(:license, :text)
      add(:source, :text)
      add(:evidence, :map, null: false, default: %{})
      add(:current, :boolean, null: false, default: false)
      add(:metadata, :map, null: false, default: %{})

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      index(:endpoint_inventory_packages, [:scan_ref],
        name: "endpoint_inventory_packages_scan_ref_idx",
        prefix: "platform"
      )
    )

    create(
      index(:endpoint_inventory_packages, [:agent_id, :current, :package_manager, :name],
        name: "endpoint_inventory_packages_agent_current_name_idx",
        prefix: "platform"
      )
    )

    create(
      index(:endpoint_inventory_packages, [:device_uid, :current, :package_manager, :name],
        name: "endpoint_inventory_packages_device_current_name_idx",
        prefix: "platform",
        where: "device_uid IS NOT NULL"
      )
    )

    create(
      index(:endpoint_inventory_packages, [:purl],
        name: "endpoint_inventory_packages_purl_idx",
        prefix: "platform",
        where: "purl IS NOT NULL"
      )
    )
  end

  def down do
    drop_if_exists(table(:endpoint_inventory_packages, prefix: "platform"))
    drop_if_exists(table(:endpoint_inventory_artifacts, prefix: "platform"))
    drop_if_exists(table(:endpoint_inventory_scans, prefix: "platform"))
  end
end
