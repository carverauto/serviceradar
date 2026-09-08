defmodule ServiceRadar.Repo.Migrations.AddDeviceSoftDeleteAndCleanupSettings do
  @moduledoc """
  Adds soft delete tombstones to devices and creates device cleanup settings.
  """

  use Ecto.Migration

  def up do
    alter table(:ocsf_devices, prefix: "platform") do
      add :deleted_at, :utc_datetime_usec
      add :deleted_by, :text
      add :deleted_reason, :text
    end

    create index(:ocsf_devices, [:deleted_at], prefix: "platform")

    create table(:device_cleanup_settings, primary_key: false, prefix: "platform") do
      add :key, :string, primary_key: true
      add :retention_days, :integer, null: false, default: 30
      add :cleanup_interval_minutes, :integer, null: false, default: 1_440
      add :batch_size, :integer, null: false, default: 1_000
      add :enabled, :boolean, null: false, default: true
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end
  end

  def down do
    drop table(:device_cleanup_settings, prefix: "platform")
    drop_if_exists index(:ocsf_devices, [:deleted_at], prefix: "platform")

    alter table(:ocsf_devices, prefix: "platform") do
      remove :deleted_at
      remove :deleted_by
      remove :deleted_reason
    end
  end
end
