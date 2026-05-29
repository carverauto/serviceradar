defmodule ServiceRadar.Repo.Migrations.AddAddonPackagesAndAssignments do
  @moduledoc """
  Adds the native add-on (feature set) catalog tables for issue 3425:
  `platform.addon_packages` (staged/approved add-on packages) and
  `platform.addon_assignments` (per-agent add-on assignments). DDL mirrors the
  Ash resource definitions in ServiceRadar.Plugins.AddonPackage / AddonAssignment.
  """

  use Ecto.Migration

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS platform")

    create table(:addon_packages, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :addon_id, :text, null: false
      add :name, :text, null: false
      add :version, :text, null: false
      add :description, :text
      add :kind, :text, null: false, default: "native"
      add :delivery, :text, null: false, default: "pushed_artifact"
      add :supervision, :text, null: false, default: "agent_sidecar"
      add :binary, :text
      add :install_path, :text, null: false, default: "/usr/local/lib/serviceradar/bin"
      add :capabilities, {:array, :text}, null: false, default: []
      add :config_schema, :map, null: false, default: %{}
      add :artifacts, :map, null: false, default: %{}
      add :requires, :map, null: false, default: %{}
      add :source_type, :text, null: false, default: "first_party"
      add :source_oci_ref, :text
      add :source_oci_digest, :text
      add :source_release_tag, :text
      add :source_metadata, :map, null: false, default: %{}
      add :imported_at, :utc_datetime_usec
      add :verification_status, :text
      add :verification_error, :text
      add :status, :text, null: false, default: "staged"
      add :approved_capabilities, {:array, :text}, null: false, default: []
      add :approved_by, :text
      add :approved_at, :utc_datetime_usec
      add :denied_reason, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:addon_packages, [:addon_id, :version],
             name: "addon_packages_unique_addon_version_index",
             prefix: "platform"
           )

    create table(:addon_assignments, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :agent_uid, :text, null: false
      add :addon_id, :text, null: false

      add :addon_package_id,
          references(:addon_packages,
            column: :id,
            name: "addon_assignments_addon_package_id_fkey",
            type: :uuid,
            prefix: "platform",
            on_delete: :delete_all
          ),
          null: false

      add :source, :text, null: false, default: "manual"
      add :source_key, :text
      add :enabled, :boolean, null: false, default: true
      add :params, :map, null: false, default: %{}
      add :args, {:array, :text}, null: false, default: []

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:addon_assignments, [:source, :source_key],
             name: "addon_assignments_unique_source_key_index",
             prefix: "platform"
           )
  end

  def down do
    drop_if_exists unique_index(:addon_assignments, [:source, :source_key],
                     name: "addon_assignments_unique_source_key_index",
                     prefix: "platform"
                   )

    drop table(:addon_assignments, prefix: "platform")

    drop_if_exists unique_index(:addon_packages, [:addon_id, :version],
                     name: "addon_packages_unique_addon_version_index",
                     prefix: "platform"
                   )

    drop table(:addon_packages, prefix: "platform")
  end
end
