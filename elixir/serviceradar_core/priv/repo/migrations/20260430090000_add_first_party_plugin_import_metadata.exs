defmodule ServiceRadar.Repo.Migrations.AddFirstPartyPluginImportMetadata do
  @moduledoc false
  use Ecto.Migration

  def up do
    alter table(:plugin_packages, prefix: "platform") do
      add :source_release_tag, :text
      add :source_oci_ref, :text
      add :source_oci_digest, :text
      add :source_bundle_digest, :text
      add :source_metadata, :map, null: false, default: %{}
      add :imported_at, :utc_datetime_usec
      add :verification_status, :text
      add :verification_error, :text
    end

    create_if_not_exists index(:plugin_packages, [:source_type, :source_release_tag],
                           name: "plugin_packages_source_release_index",
                           prefix: "platform"
                         )

    create_if_not_exists index(:plugin_packages, [:source_oci_digest],
                           name: "plugin_packages_source_oci_digest_index",
                           prefix: "platform"
                         )
  end

  def down do
    drop_if_exists index(:plugin_packages, [:source_oci_digest],
                     name: "plugin_packages_source_oci_digest_index",
                     prefix: "platform"
                   )

    drop_if_exists index(:plugin_packages, [:source_type, :source_release_tag],
                     name: "plugin_packages_source_release_index",
                     prefix: "platform"
                   )

    alter table(:plugin_packages, prefix: "platform") do
      remove :verification_error
      remove :verification_status
      remove :imported_at
      remove :source_metadata
      remove :source_bundle_digest
      remove :source_oci_digest
      remove :source_oci_ref
      remove :source_release_tag
    end
  end
end
