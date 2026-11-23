defmodule ServiceRadar.Repo.Migrations.CreateSettingsBackupDestinations do
  @moduledoc """
  Creates the singleton settings backup destination table for customer-owned
  object storage exports.
  """

  use Ecto.Migration

  def up do
    create table(:settings_backup_destinations, primary_key: false, prefix: "platform") do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:key, :text, null: false, default: "default")
      add(:enabled, :boolean, null: false, default: false)
      add(:provider, :text, null: false, default: "linode_object_storage")
      add(:endpoint, :text, null: false)
      add(:bucket, :text, null: false)
      add(:region, :text, null: false)
      add(:prefix, :text, null: false, default: "")
      add(:schedule_cron, :text, null: false, default: "0 */6 * * *")
      add(:next_run_at, :utc_datetime_usec)
      add(:encrypted_access_key_id, :binary)
      add(:encrypted_secret_access_key, :binary)
      add(:last_exported_at, :utc_datetime_usec)
      add(:last_export_status, :text)
      add(:last_export_error, :text)
      add(:last_export_object_key, :text)
      add(:last_export_etag, :text)
      add(:last_export_sha256, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:settings_backup_destinations, [:key],
        prefix: "platform",
        name: :settings_backup_destinations_key_index
      )
    )
  end

  def down do
    drop(table(:settings_backup_destinations, prefix: "platform"))
  end
end
