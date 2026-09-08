defmodule ServiceRadar.Repo.Migrations.CreateDeviceHostnameRdnsSettings do
  @moduledoc """
  Singleton settings for the scheduled ocsf_devices reverse-DNS hostname job.
  """

  use Ecto.Migration

  def up do
    create table(:device_hostname_rdns_settings, primary_key: false, prefix: "platform") do
      add :key, :string, primary_key: true
      add :enabled, :boolean, null: false, default: true
      add :cron, :text, null: false, default: "0 * * * *"
      add :timezone, :string, null: false, default: "Etc/UTC"
      add :batch_size, :integer, null: false, default: 200
      add :timeout_ms, :integer, null: false, default: 250
      add :retry_after_minutes, :integer, null: false, default: 1_440
      add :overwrite_existing, :boolean, null: false, default: false
      add :last_run_at, :utc_datetime_usec
      add :last_success_at, :utc_datetime_usec
      add :next_run_at, :utc_datetime_usec
      add :last_status, :text
      add :last_error, :text
      add :last_looked_up, :integer, null: false, default: 0
      add :last_updated, :integer, null: false, default: 0
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end
  end

  def down do
    drop table(:device_hostname_rdns_settings, prefix: "platform")
  end
end
