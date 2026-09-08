defmodule ServiceRadar.Repo.Migrations.AddMtrAutomationPolicyAndDispatchWindows do
  use Ecto.Migration

  def up do
    create table(:mtr_policies, primary_key: false, prefix: "platform") do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :enabled, :boolean, null: false, default: true
      add :scope, :text, null: false, default: "managed_devices"
      add :partition_id, :text
      add :target_selector, :map, null: false, default: %{}
      add :baseline_interval_sec, :integer, null: false, default: 300
      add :baseline_protocol, :text, null: false, default: "icmp"
      add :baseline_canary_vantages, :integer, null: false, default: 0
      add :incident_fanout_max_agents, :integer, null: false, default: 3
      add :incident_cooldown_sec, :integer, null: false, default: 600
      add :recovery_capture, :boolean, null: false, default: true
      add :consensus_mode, :text, null: false, default: "majority"
      add :consensus_threshold, :float, null: false, default: 0.66
      add :consensus_min_agents, :integer, null: false, default: 2
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mtr_policies, [:name], prefix: "platform")

    create index(:mtr_policies, [:enabled],
             prefix: "platform",
             where: "enabled = true"
           )

    create index(:mtr_policies, [:partition_id], prefix: "platform")

    execute("""
    ALTER TABLE platform.mtr_policies
    ADD CONSTRAINT mtr_policies_baseline_protocol_check
    CHECK (baseline_protocol IN ('icmp', 'udp', 'tcp'))
    """)

    execute("""
    ALTER TABLE platform.mtr_policies
    ADD CONSTRAINT mtr_policies_consensus_mode_check
    CHECK (consensus_mode IN ('majority', 'unanimous', 'threshold'))
    """)

    execute("""
    CREATE TABLE platform.mtr_dispatch_windows (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      target_key TEXT NOT NULL,
      trigger_mode TEXT NOT NULL,
      transition_class TEXT NOT NULL DEFAULT 'none',
      partition_id TEXT,
      last_dispatched_at TIMESTAMPTZ,
      cooldown_until TIMESTAMPTZ,
      incident_correlation_id TEXT,
      source_agent_ids TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
      dispatch_count INTEGER NOT NULL DEFAULT 0,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX mtr_dispatch_windows_target_mode_transition_partition_uidx
      ON platform.mtr_dispatch_windows (
        target_key,
        trigger_mode,
        COALESCE(transition_class, ''),
        COALESCE(partition_id, '')
      )
    """)

    create index(:mtr_dispatch_windows, [:cooldown_until], prefix: "platform")

    create index(:mtr_dispatch_windows, [:incident_correlation_id],
             prefix: "platform",
             where: "incident_correlation_id IS NOT NULL"
           )

    execute("""
    ALTER TABLE platform.mtr_dispatch_windows
    ADD CONSTRAINT mtr_dispatch_windows_trigger_mode_check
    CHECK (trigger_mode IN ('baseline', 'incident', 'recovery', 'manual'))
    """)
  end

  def down do
    drop index(:mtr_dispatch_windows, [:incident_correlation_id], prefix: "platform")
    drop index(:mtr_dispatch_windows, [:cooldown_until], prefix: "platform")

    execute("""
    DROP INDEX IF EXISTS platform.mtr_dispatch_windows_target_mode_transition_partition_uidx
    """)

    execute("""
    DROP TABLE IF EXISTS platform.mtr_dispatch_windows
    """)

    execute("""
    ALTER TABLE platform.mtr_policies
    DROP CONSTRAINT IF EXISTS mtr_policies_consensus_mode_check
    """)

    execute("""
    ALTER TABLE platform.mtr_policies
    DROP CONSTRAINT IF EXISTS mtr_policies_baseline_protocol_check
    """)

    drop index(:mtr_policies, [:partition_id], prefix: "platform")

    drop index(:mtr_policies, [:enabled],
           prefix: "platform",
           where: "enabled = true"
         )

    drop index(:mtr_policies, [:name], prefix: "platform")
    drop table(:mtr_policies, prefix: "platform")
  end
end
