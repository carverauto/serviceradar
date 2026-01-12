defmodule ServiceRadar.Repo.TenantMigrations.AddSweepJobsTables do
  @moduledoc """
  Creates tables for the SweepJobs domain.

  Tables:
  - sweep_profiles: Admin-managed scanner profiles
  - sweep_groups: User-configured sweep groups
  - sweep_group_executions: Execution tracking per group
  - sweep_host_results: Per-host results from sweep executions
  """

  use Ecto.Migration

  def up do
    # Sweep Profiles - Admin-managed scanner profiles
    create table(:sweep_profiles, primary_key: false, prefix: prefix()) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :tenant_id, :uuid, null: false
      add :name, :text, null: false
      add :description, :text
      add :ports, {:array, :integer}, null: false, default: []
      add :sweep_modes, {:array, :text}, null: false, default: ["icmp", "tcp"]
      add :concurrency, :integer, null: false, default: 50
      add :timeout, :text, null: false, default: "3s"
      add :icmp_settings, :map, null: false, default: %{}
      add :tcp_settings, :map, null: false, default: %{}
      add :admin_only, :boolean, null: false, default: false
      add :enabled, :boolean, null: false, default: true

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:sweep_profiles, [:tenant_id, :name],
             name: "sweep_profiles_unique_name_per_tenant_index",
             prefix: prefix()
           )

    # Sweep Groups - User-configured sweep groups
    create table(:sweep_groups, primary_key: false, prefix: prefix()) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :tenant_id, :uuid, null: false
      add :name, :text, null: false
      add :description, :text
      add :partition, :text, null: false, default: "default"
      add :agent_id, :text
      add :enabled, :boolean, null: false, default: true

      # Schedule configuration
      add :interval, :text, null: false, default: "1h"
      add :schedule_type, :text, null: false, default: "interval"
      add :cron_expression, :text

      # Device targeting
      add :target_criteria, :map, null: false, default: %{}
      add :static_targets, {:array, :text}, null: false, default: []

      # Scan configuration (overrides profile)
      add :ports, {:array, :integer}
      add :sweep_modes, {:array, :text}
      add :overrides, :map, null: false, default: %{}

      # Tracking
      add :last_run_at, :utc_datetime

      # Profile reference
      add :profile_id,
          references(:sweep_profiles,
            column: :id,
            name: "sweep_groups_profile_id_fkey",
            type: :uuid,
            prefix: prefix(),
            on_delete: :nilify_all
          )

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:sweep_groups, [:tenant_id, :name],
             name: "sweep_groups_unique_name_per_tenant_index",
             prefix: prefix()
           )

    create index(:sweep_groups, [:tenant_id, :partition],
             name: "sweep_groups_tenant_partition_idx",
             prefix: prefix()
           )

    create index(:sweep_groups, [:tenant_id, :agent_id],
             name: "sweep_groups_tenant_agent_idx",
             where: "agent_id IS NOT NULL",
             prefix: prefix()
           )

    # Sweep Group Executions - Execution tracking per group
    create table(:sweep_group_executions, primary_key: false, prefix: prefix()) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :tenant_id, :uuid, null: false
      add :status, :text, null: false, default: "pending"
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :duration_ms, :integer
      add :hosts_total, :integer, default: 0
      add :hosts_available, :integer, default: 0
      add :hosts_failed, :integer, default: 0
      add :error_message, :text
      add :agent_id, :text
      add :config_version, :text

      add :sweep_group_id,
          references(:sweep_groups,
            column: :id,
            name: "sweep_group_executions_sweep_group_id_fkey",
            type: :uuid,
            prefix: prefix(),
            on_delete: :delete_all
          ),
          null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:sweep_group_executions, [:tenant_id, :sweep_group_id, :started_at],
             name: "sweep_group_executions_group_started_idx",
             prefix: prefix()
           )

    create index(:sweep_group_executions, [:tenant_id, :status],
             name: "sweep_group_executions_status_idx",
             prefix: prefix()
           )

    # Sweep Host Results - Per-host results from sweep executions
    create table(:sweep_host_results, primary_key: false, prefix: prefix()) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :tenant_id, :uuid, null: false
      add :ip, :text, null: false
      add :hostname, :text
      add :status, :text, null: false
      add :response_time_ms, :integer
      add :sweep_modes_results, :map, null: false, default: %{}
      add :open_ports, {:array, :integer}, null: false, default: []
      add :error_message, :text
      add :device_id, :uuid

      add :execution_id,
          references(:sweep_group_executions,
            column: :id,
            name: "sweep_host_results_execution_id_fkey",
            type: :uuid,
            prefix: prefix(),
            on_delete: :delete_all
          ),
          null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:sweep_host_results, [:tenant_id, :execution_id],
             name: "sweep_host_results_execution_idx",
             prefix: prefix()
           )

    create index(:sweep_host_results, [:tenant_id, :ip],
             name: "sweep_host_results_ip_idx",
             prefix: prefix()
           )

    create index(:sweep_host_results, [:tenant_id, :status],
             name: "sweep_host_results_status_idx",
             prefix: prefix()
           )
  end

  def down do
    drop_if_exists index(:sweep_host_results, [:tenant_id, :status],
                     name: "sweep_host_results_status_idx",
                     prefix: prefix()
                   )

    drop_if_exists index(:sweep_host_results, [:tenant_id, :ip],
                     name: "sweep_host_results_ip_idx",
                     prefix: prefix()
                   )

    drop_if_exists index(:sweep_host_results, [:tenant_id, :execution_id],
                     name: "sweep_host_results_execution_idx",
                     prefix: prefix()
                   )

    drop constraint(:sweep_host_results, "sweep_host_results_execution_id_fkey")

    drop table(:sweep_host_results, prefix: prefix())

    drop_if_exists index(:sweep_group_executions, [:tenant_id, :status],
                     name: "sweep_group_executions_status_idx",
                     prefix: prefix()
                   )

    drop_if_exists index(:sweep_group_executions, [:tenant_id, :sweep_group_id, :started_at],
                     name: "sweep_group_executions_group_started_idx",
                     prefix: prefix()
                   )

    drop constraint(:sweep_group_executions, "sweep_group_executions_sweep_group_id_fkey")

    drop table(:sweep_group_executions, prefix: prefix())

    drop_if_exists index(:sweep_groups, [:tenant_id, :agent_id],
                     name: "sweep_groups_tenant_agent_idx",
                     prefix: prefix()
                   )

    drop_if_exists index(:sweep_groups, [:tenant_id, :partition],
                     name: "sweep_groups_tenant_partition_idx",
                     prefix: prefix()
                   )

    drop_if_exists unique_index(:sweep_groups, [:tenant_id, :name],
                     name: "sweep_groups_unique_name_per_tenant_index",
                     prefix: prefix()
                   )

    drop constraint(:sweep_groups, "sweep_groups_profile_id_fkey")

    drop table(:sweep_groups, prefix: prefix())

    drop_if_exists unique_index(:sweep_profiles, [:tenant_id, :name],
                     name: "sweep_profiles_unique_name_per_tenant_index",
                     prefix: prefix()
                   )

    drop table(:sweep_profiles, prefix: prefix())
  end
end
