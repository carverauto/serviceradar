defmodule ServiceRadar.Repo.Migrations.AddBumblebeeExposureAndRiskContributions do
  @moduledoc false
  use Ecto.Migration

  def up do
    create table(:device_risk_contributions, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:device_uid, :text, null: false)
      add(:source, :text, null: false)
      add(:source_ref, :text, null: false, default: "current")
      add(:score, :integer, null: false)
      add(:risk_level_id, :integer, null: false)
      add(:risk_level, :text, null: false)
      add(:reason, :text)
      add(:active, :boolean, null: false, default: true)
      add(:occurred_at, :utc_datetime_usec)
      add(:resolved_at, :utc_datetime_usec)
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
      unique_index(:device_risk_contributions, [:device_uid, :source, :source_ref],
        name: "device_risk_contributions_device_source_ref_uidx",
        prefix: "platform"
      )
    )

    create(
      index(:device_risk_contributions, [:device_uid, :active, :score],
        name: "device_risk_contributions_device_active_score_idx",
        prefix: "platform"
      )
    )

    create(
      index(:device_risk_contributions, [:source, :active],
        name: "device_risk_contributions_source_active_idx",
        prefix: "platform"
      )
    )

    create table(:device_risk_contribution_versions, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:version_action_inputs, :map, null: false, default: %{})
      add(:version_source_id, :uuid, null: false)
      add(:changes, :map)

      add(:version_inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:version_updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      index(:device_risk_contribution_versions, [:version_source_id],
        name: "device_risk_contribution_versions_source_idx",
        prefix: "platform"
      )
    )

    create table(:bumblebee_catalog_sources, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:name, :text, null: false)
      add(:url, :text, null: false)
      add(:pinned_revision, :text)
      add(:refresh_cron, :text)
      add(:enabled, :boolean, null: false, default: true)
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
      unique_index(:bumblebee_catalog_sources, [:name],
        name: "bumblebee_catalog_sources_name_uidx",
        prefix: "platform"
      )
    )

    create table(:bumblebee_catalog_source_versions, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:version_action_inputs, :map, null: false, default: %{})
      add(:version_source_id, :uuid, null: false)
      add(:changes, :map)

      add(:version_inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:version_updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      index(:bumblebee_catalog_source_versions, [:version_source_id],
        name: "bumblebee_catalog_source_versions_source_idx",
        prefix: "platform"
      )
    )

    create table(:bumblebee_catalog_snapshots, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :source_id,
        references(:bumblebee_catalog_sources,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: "platform"
        ),
        null: true
      )

      add(:snapshot_ref, :text, null: false)
      add(:source_revision, :text)
      add(:catalog_version, :text)
      add(:schema_version, :text)
      add(:status, :text, null: false, default: "candidate")
      add(:entry_count, :integer, null: false, default: 0)
      add(:content_sha256, :text)
      add(:object_key, :text)
      add(:object_size_bytes, :bigint)
      add(:promoted_at, :utc_datetime_usec)
      add(:validation_result, :map, null: false, default: %{})
      add(:artifact_metadata, :map, null: false, default: %{})
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
      unique_index(:bumblebee_catalog_snapshots, [:snapshot_ref],
        name: "bumblebee_catalog_snapshots_ref_uidx",
        prefix: "platform"
      )
    )

    create(
      index(:bumblebee_catalog_snapshots, [:status, :promoted_at],
        name: "bumblebee_catalog_snapshots_status_promoted_idx",
        prefix: "platform"
      )
    )

    create(
      index(:bumblebee_catalog_snapshots, [:content_sha256],
        name: "bumblebee_catalog_snapshots_sha256_idx",
        prefix: "platform"
      )
    )

    create table(:bumblebee_catalog_snapshot_versions, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:version_action_inputs, :map, null: false, default: %{})
      add(:version_source_id, :uuid, null: false)
      add(:changes, :map)

      add(:version_inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:version_updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      index(:bumblebee_catalog_snapshot_versions, [:version_source_id],
        name: "bumblebee_catalog_snapshot_versions_source_idx",
        prefix: "platform"
      )
    )

    create table(:bumblebee_catalog_entries, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :snapshot_id,
        references(:bumblebee_catalog_snapshots,
          type: :uuid,
          on_delete: :delete_all,
          prefix: "platform"
        ),
        null: false
      )

      add(:catalog_id, :text, null: false)
      add(:ecosystem, :text, null: false)
      add(:package_name, :text, null: false)
      add(:affected_versions, {:array, :text}, null: false, default: [])
      add(:severity, :text, null: false)
      add(:source_url, :text)
      add(:metadata, :map, null: false, default: %{})

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(:bumblebee_catalog_entries, [:snapshot_id, :catalog_id],
        name: "bumblebee_catalog_entries_snapshot_catalog_uidx",
        prefix: "platform"
      )
    )

    create(
      index(:bumblebee_catalog_entries, [:ecosystem, :package_name],
        name: "bumblebee_catalog_entries_package_idx",
        prefix: "platform"
      )
    )

    create table(:bumblebee_device_postures, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:device_uid, :text)
      add(:agent_id, :text, null: false)
      add(:run_id, :text)
      add(:catalog_snapshot_ref, :text)
      add(:scanner_version, :text)
      add(:state, :text, null: false, default: "not_scanned")
      add(:coverage_state, :text, null: false, default: "not_scanned")
      add(:attempted_root_count, :integer, null: false, default: 0)
      add(:scanned_root_count, :integer, null: false, default: 0)
      add(:skipped_root_count, :integer, null: false, default: 0)
      add(:root_covered, :boolean)
      add(:skipped_roots, {:array, :map}, null: false, default: [])
      add(:risk_score, :integer, null: false, default: 0)
      add(:highest_severity, :text)
      add(:active_finding_count, :integer, null: false, default: 0)
      add(:last_successful_scan_at, :utc_datetime_usec)
      add(:last_scan_at, :utc_datetime_usec)
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
      unique_index(:bumblebee_device_postures, [:agent_id],
        name: "bumblebee_device_postures_agent_uidx",
        prefix: "platform"
      )
    )

    create(
      index(:bumblebee_device_postures, [:device_uid],
        name: "bumblebee_device_postures_device_uid_idx",
        prefix: "platform",
        where: "device_uid IS NOT NULL"
      )
    )

    create table(:bumblebee_findings, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:device_uid, :text)
      add(:agent_id, :text, null: false)
      add(:run_id, :text)
      add(:finding_id, :text, null: false)
      add(:catalog_id, :text)
      add(:catalog_snapshot_ref, :text)
      add(:scanner_version, :text)
      add(:severity, :text, null: false)
      add(:risk_score, :integer, null: false, default: 0)
      add(:ecosystem, :text)
      add(:package_name, :text)
      add(:package_version, :text)
      add(:evidence, :map, null: false, default: %{})
      add(:confidence, :text)
      add(:status, :text, null: false, default: "active")
      add(:first_seen_at, :utc_datetime_usec)
      add(:last_seen_at, :utc_datetime_usec)
      add(:resolved_at, :utc_datetime_usec)
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
      unique_index(:bumblebee_findings, [:agent_id, :finding_id],
        name: "bumblebee_findings_agent_finding_uidx",
        prefix: "platform"
      )
    )

    create(
      index(:bumblebee_findings, [:device_uid, :status, :risk_score],
        name: "bumblebee_findings_device_status_score_idx",
        prefix: "platform",
        where: "device_uid IS NOT NULL"
      )
    )
  end

  def down do
    drop_if_exists(table(:bumblebee_findings, prefix: "platform"))
    drop_if_exists(table(:bumblebee_device_postures, prefix: "platform"))
    drop_if_exists(table(:bumblebee_catalog_entries, prefix: "platform"))
    drop_if_exists(table(:bumblebee_catalog_snapshot_versions, prefix: "platform"))
    drop_if_exists(table(:bumblebee_catalog_snapshots, prefix: "platform"))
    drop_if_exists(table(:bumblebee_catalog_source_versions, prefix: "platform"))
    drop_if_exists(table(:bumblebee_catalog_sources, prefix: "platform"))
    drop_if_exists(table(:device_risk_contribution_versions, prefix: "platform"))
    drop_if_exists(table(:device_risk_contributions, prefix: "platform"))
  end
end
