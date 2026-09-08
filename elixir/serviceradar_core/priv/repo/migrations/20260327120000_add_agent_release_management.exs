defmodule ServiceRadar.Repo.Migrations.AddAgentReleaseManagement do
  @moduledoc """
  Adds agent release catalog, rollout tracking, and agent inventory release fields.
  """

  use Ecto.Migration

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS platform")

    create table(:agent_releases, primary_key: false, prefix: "platform") do
      add(:release_id, :uuid,
        null: false,
        default: fragment("gen_random_uuid()"),
        primary_key: true
      )

      add(:version, :text, null: false)
      add(:manifest, :map, null: false, default: %{})
      add(:signature, :text, null: false)
      add(:release_notes, :text)
      add(:published_at, :utc_datetime)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:agent_releases, [:version], prefix: "platform"))

    create table(:agent_release_rollouts, primary_key: false, prefix: "platform") do
      add(:rollout_id, :uuid,
        null: false,
        default: fragment("gen_random_uuid()"),
        primary_key: true
      )

      add(
        :release_id,
        references(:agent_releases,
          column: :release_id,
          type: :uuid,
          prefix: "platform",
          on_delete: :delete_all
        ),
        null: false
      )

      add(:desired_version, :text, null: false)
      add(:cohort_agent_ids, {:array, :text}, null: false, default: [])
      add(:batch_size, :integer, null: false, default: 1)
      add(:batch_delay_seconds, :integer, null: false, default: 0)
      add(:status, :text, null: false, default: "active")
      add(:created_by, :text)
      add(:started_at, :utc_datetime)
      add(:paused_at, :utc_datetime)
      add(:completed_at, :utc_datetime)
      add(:canceled_at, :utc_datetime)
      add(:last_dispatch_at, :utc_datetime)
      add(:notes, :text)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:agent_release_rollouts, [:status], prefix: "platform"))
    create(index(:agent_release_rollouts, [:release_id], prefix: "platform"))

    create table(:agent_release_targets, primary_key: false, prefix: "platform") do
      add(:target_id, :uuid,
        null: false,
        default: fragment("gen_random_uuid()"),
        primary_key: true
      )

      add(
        :rollout_id,
        references(:agent_release_rollouts,
          column: :rollout_id,
          type: :uuid,
          prefix: "platform",
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :release_id,
        references(:agent_releases,
          column: :release_id,
          type: :uuid,
          prefix: "platform",
          on_delete: :delete_all
        ),
        null: false
      )

      add(:agent_id, :text, null: false)
      add(:cohort_index, :integer, null: false, default: 0)
      add(:desired_version, :text, null: false)
      add(:current_version, :text)
      add(:command_id, :uuid)
      add(:status, :text, null: false, default: "pending")
      add(:progress_percent, :integer)
      add(:last_status_message, :text)
      add(:last_error, :text)
      add(:dispatched_at, :utc_datetime)
      add(:completed_at, :utc_datetime)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:agent_release_targets, [:rollout_id, :agent_id], prefix: "platform"))
    create(unique_index(:agent_release_targets, [:command_id], prefix: "platform"))
    create(index(:agent_release_targets, [:agent_id, :status], prefix: "platform"))
    create(index(:agent_release_targets, [:rollout_id, :status], prefix: "platform"))

    alter table(:ocsf_agents, prefix: "platform") do
      add(:desired_version, :text)
      add(:release_rollout_state, :text)
      add(:last_update_at, :utc_datetime)
      add(:last_update_error, :text)
    end
  end

  def down do
    alter table(:ocsf_agents, prefix: "platform") do
      remove(:desired_version)
      remove(:release_rollout_state)
      remove(:last_update_at)
      remove(:last_update_error)
    end

    drop(index(:agent_release_targets, [:rollout_id, :status], prefix: "platform"))
    drop(index(:agent_release_targets, [:agent_id, :status], prefix: "platform"))
    drop(unique_index(:agent_release_targets, [:command_id], prefix: "platform"))
    drop(unique_index(:agent_release_targets, [:rollout_id, :agent_id], prefix: "platform"))
    drop(table(:agent_release_targets, prefix: "platform"))

    drop(index(:agent_release_rollouts, [:release_id], prefix: "platform"))
    drop(index(:agent_release_rollouts, [:status], prefix: "platform"))
    drop(table(:agent_release_rollouts, prefix: "platform"))

    drop(unique_index(:agent_releases, [:version], prefix: "platform"))
    drop(table(:agent_releases, prefix: "platform"))
  end
end
