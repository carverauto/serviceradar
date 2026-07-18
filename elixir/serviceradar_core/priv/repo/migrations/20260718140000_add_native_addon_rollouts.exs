defmodule ServiceRadar.Repo.Migrations.AddNativeAddonRollouts do
  @moduledoc false
  use Ecto.Migration

  @default_policy %{
    "batch_size" => 10,
    "canary_size" => 1,
    "health_timeout_seconds" => 900,
    "max_parallel" => 10,
    "soak_seconds" => 300,
    "tolerated_failures" => 0
  }

  def up do
    alter table(:addon_assignments, prefix: "platform") do
      add :update_policy, :text, null: false, default: "manual_pin"
      add :explicit_version_pin, :boolean, null: false, default: false
      add :release_channel, :text, null: false, default: "stable"
      add :capability_ceiling, {:array, :text}, null: false, default: []
      add :rollout_policy, :map, null: false, default: @default_policy
      add :update_policy_backfill_pending, :boolean, null: false, default: true
    end

    alter table(:addon_profiles, prefix: "platform") do
      add :update_policy, :text, null: false, default: "manual_pin"
      add :explicit_version_pin, :boolean, null: false, default: false
      add :release_channel, :text, null: false, default: "stable"
      add :capability_ceiling, {:array, :text}, null: false, default: []
      add :rollout_policy, :map, null: false, default: @default_policy
      add :update_policy_backfill_pending, :boolean, null: false, default: true
    end

    # Existing rows retain TRUE from the fast column default, while rows created
    # after this migration are initialized by ApplyAddonUpdatePolicyDefaults and
    # must never be mistaken for legacy data by the asynchronous backfill worker.
    execute(
      "ALTER TABLE platform.addon_assignments ALTER COLUMN update_policy_backfill_pending SET DEFAULT FALSE"
    )

    execute(
      "ALTER TABLE platform.addon_profiles ALTER COLUMN update_policy_backfill_pending SET DEFAULT FALSE"
    )

    create table(:addon_rollouts, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :addon_id, :text, null: false
      add :source_type, :text, null: false
      add :source_id, :uuid, null: false

      add :previous_package_id,
          references(:addon_packages, type: :uuid, prefix: "platform", on_delete: :restrict),
          null: false

      add :candidate_package_id,
          references(:addon_packages, type: :uuid, prefix: "platform", on_delete: :restrict),
          null: false

      add :trigger, :text, null: false, default: "track_latest"
      add :state, :text, null: false, default: "pending"
      add :policy, :map, null: false, default: @default_policy
      add :target_snapshot, :map, null: false, default: %{}
      add :blocked_reason, :text
      add :error, :text
      add :started_at, :utc_datetime_usec
      add :paused_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :canceled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create table(:addon_rollout_targets, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :rollout_id,
          references(:addon_rollouts, type: :uuid, prefix: "platform", on_delete: :delete_all),
          null: false

      add :assignment_id,
          references(:addon_assignments, type: :uuid, prefix: "platform", on_delete: :restrict),
          null: false

      add :agent_uid, :text, null: false
      add :addon_id, :text, null: false
      add :source_type, :text, null: false
      add :source_id, :uuid, null: false

      add :previous_package_id,
          references(:addon_packages, type: :uuid, prefix: "platform", on_delete: :restrict),
          null: false

      add :candidate_package_id,
          references(:addon_packages, type: :uuid, prefix: "platform", on_delete: :restrict),
          null: false

      add :previous_params, :map, null: false, default: %{}
      add :previous_args, {:array, :text}, null: false, default: []
      add :batch_index, :bigint, null: false
      add :classification, :text, null: false, default: "eligible"
      add :state, :text, null: false, default: "pending"
      add :reason_code, :text
      add :error, :text
      add :override_applied_at, :utc_datetime_usec
      add :deadline_at, :utc_datetime_usec
      add :healthy_since, :utc_datetime_usec
      add :health_observed_at, :utc_datetime_usec
      add :rollback_started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :rolled_back_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    alter table(:addon_assignments, prefix: "platform") do
      add :rollout_package_id,
          references(:addon_packages, type: :uuid, prefix: "platform", on_delete: :restrict)

      add :rollout_id,
          references(:addon_rollouts, type: :uuid, prefix: "platform", on_delete: :nilify_all)

      add :rollout_started_at, :utc_datetime_usec
    end

    create index(:addon_rollouts, [:state], prefix: "platform")
    create index(:addon_rollout_targets, [:rollout_id, :batch_index], prefix: "platform")
    create index(:addon_rollout_targets, [:agent_uid, :addon_id], prefix: "platform")
    create index(:addon_assignments, [:update_policy], prefix: "platform")
    create index(:addon_profiles, [:update_policy], prefix: "platform")

    execute("""
    CREATE UNIQUE INDEX addon_rollouts_one_active_source_index
    ON platform.addon_rollouts (source_type, source_id)
    WHERE state IN ('pending', 'running', 'paused', 'rolling_back')
    """)

    execute("""
    CREATE UNIQUE INDEX addon_rollout_targets_one_active_target_index
    ON platform.addon_rollout_targets (agent_uid, addon_id)
    WHERE state IN ('pending', 'waiting_health', 'healthy_soak', 'succeeded', 'rollback_pending')
    """)

  end

  def down do
    drop_if_exists index(:addon_profiles, [:update_policy], prefix: "platform")
    drop_if_exists index(:addon_assignments, [:update_policy], prefix: "platform")

    alter table(:addon_assignments, prefix: "platform") do
      remove :rollout_started_at
      remove :rollout_id
      remove :rollout_package_id
    end

    drop table(:addon_rollout_targets, prefix: "platform")
    drop table(:addon_rollouts, prefix: "platform")

    alter table(:addon_profiles, prefix: "platform") do
      remove :update_policy_backfill_pending
      remove :rollout_policy
      remove :capability_ceiling
      remove :release_channel
      remove :explicit_version_pin
      remove :update_policy
    end

    alter table(:addon_assignments, prefix: "platform") do
      remove :update_policy_backfill_pending
      remove :rollout_policy
      remove :capability_ceiling
      remove :release_channel
      remove :explicit_version_pin
      remove :update_policy
    end
  end
end
