defmodule ServiceRadar.Repo.Migrations.CreateAdhocScanRunsAndPolicy do
  @moduledoc """
  Creates the adhoc_scan_runs aggregate table and the singleton
  scan_policy_settings table for the ad-hoc network scan feature.

  Per-target/per-port scan results live in the adhoc_scan_results hypertable
  (separate migration); these two tables are regular platform-schema tables.
  """
  use Ecto.Migration

  def up do
    create table(:adhoc_scan_runs, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, primary_key: true, default: fragment("gen_random_uuid()")
      add :agent_id, :text, null: false
      add :gateway_id, :text
      add :partition, :text
      add :modes, {:array, :text}, null: false
      add :ports, {:array, :integer}, null: false, default: []
      add :targets, {:array, :text}, null: false, default: []
      add :target_count, :integer, null: false, default: 0
      add :options, :map, null: false, default: %{}
      add :status, :text, null: false, default: "pending"
      add :requested_by, :text
      add :scan_command_id, :text
      add :mtr_command_id, :text
      add :hosts_up, :integer, null: false, default: 0
      add :ports_open, :integer, null: false, default: 0
      add :error, :text
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:adhoc_scan_runs, [:agent_id], prefix: "platform")
    create index(:adhoc_scan_runs, [:status], prefix: "platform")
    create index(:adhoc_scan_runs, [:inserted_at], prefix: "platform")

    create table(:scan_policy_settings, primary_key: false, prefix: "platform") do
      add :key, :string, primary_key: true
      add :restrict_to_inventory, :boolean, null: false, default: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end
  end

  def down do
    drop table(:scan_policy_settings, prefix: "platform")
    drop table(:adhoc_scan_runs, prefix: "platform")
  end
end
