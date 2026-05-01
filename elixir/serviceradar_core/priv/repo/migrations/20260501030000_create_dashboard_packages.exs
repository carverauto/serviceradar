defmodule ServiceRadar.Repo.Migrations.CreateDashboardPackages do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:dashboard_packages, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dashboard_id, :text, null: false)
      add(:name, :text, null: false)
      add(:version, :text, null: false)
      add(:description, :text)
      add(:vendor, :text)
      add(:manifest, :map, null: false, default: %{})
      add(:renderer, :map, null: false, default: %{})
      add(:data_frames, {:array, :map}, null: false, default: [])
      add(:capabilities, {:array, :text}, null: false, default: [])
      add(:settings_schema, :map, null: false, default: %{})
      add(:wasm_object_key, :text)
      add(:content_hash, :text)
      add(:signature, :map, null: false, default: %{})
      add(:source_type, :text, null: false, default: "upload")
      add(:source_repo_url, :text)
      add(:source_ref, :text)
      add(:source_manifest_path, :text)
      add(:source_commit, :text)
      add(:source_bundle_digest, :text)
      add(:source_metadata, :map, null: false, default: %{})
      add(:imported_at, :utc_datetime_usec)
      add(:verification_status, :text)
      add(:verification_error, :text)
      add(:status, :text, null: false, default: "staged")

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
      unique_index(:dashboard_packages, [:dashboard_id, :version],
        name: :dashboard_packages_unique_dashboard_version_idx,
        prefix: @prefix
      )
    )

    create(
      index(:dashboard_packages, [:source_type, :source_ref],
        name: :dashboard_packages_source_idx,
        prefix: @prefix
      )
    )

    create(
      index(:dashboard_packages, [:source_bundle_digest],
        name: :dashboard_packages_bundle_digest_idx,
        prefix: @prefix
      )
    )

    create(
      index(:dashboard_packages, [:status], name: :dashboard_packages_status_idx, prefix: @prefix)
    )

    create table(:dashboard_instances, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :dashboard_package_id,
        references(:dashboard_packages,
          column: :id,
          type: :uuid,
          prefix: @prefix,
          on_delete: :delete_all
        ),
        null: false
      )

      add(:name, :text, null: false)
      add(:route_slug, :text, null: false)
      add(:placement, :text, null: false, default: "dashboard")
      add(:enabled, :boolean, null: false, default: false)
      add(:is_default, :boolean, null: false, default: false)
      add(:settings, :map, null: false, default: %{})
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
      unique_index(:dashboard_instances, [:route_slug],
        name: :dashboard_instances_route_slug_idx,
        prefix: @prefix
      )
    )

    create(
      index(:dashboard_instances, [:placement, :enabled],
        name: :dashboard_instances_placement_enabled_idx,
        prefix: @prefix
      )
    )

    create(
      index(:dashboard_instances, [:placement, :is_default],
        name: :dashboard_instances_default_placement_idx,
        prefix: @prefix,
        where: "is_default = true"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:dashboard_instances, [:placement, :is_default],
        name: :dashboard_instances_default_placement_idx,
        prefix: @prefix
      )
    )

    drop_if_exists(
      index(:dashboard_instances, [:placement, :enabled],
        name: :dashboard_instances_placement_enabled_idx,
        prefix: @prefix
      )
    )

    drop_if_exists(
      unique_index(:dashboard_instances, [:route_slug],
        name: :dashboard_instances_route_slug_idx,
        prefix: @prefix
      )
    )

    drop(table(:dashboard_instances, prefix: @prefix))

    drop_if_exists(
      index(:dashboard_packages, [:status], name: :dashboard_packages_status_idx, prefix: @prefix)
    )

    drop_if_exists(
      index(:dashboard_packages, [:source_bundle_digest],
        name: :dashboard_packages_bundle_digest_idx,
        prefix: @prefix
      )
    )

    drop_if_exists(
      index(:dashboard_packages, [:source_type, :source_ref],
        name: :dashboard_packages_source_idx,
        prefix: @prefix
      )
    )

    drop_if_exists(
      unique_index(:dashboard_packages, [:dashboard_id, :version],
        name: :dashboard_packages_unique_dashboard_version_idx,
        prefix: @prefix
      )
    )

    drop(table(:dashboard_packages, prefix: @prefix))
  end
end
