defmodule ServiceRadar.Repo.Migrations.AddWasmPluginRolloutSchema do
  @moduledoc """
  Lets the add-on rollout tables carry Wasm plugin rollouts
  (`redesign-wasm-plugin-management`, Decision 4, step B). Nothing creates a
  Wasm rollout yet; this is schema only.

  * `addon_rollouts` and `addon_rollout_targets` gain `artifact_kind`
    (`native_addon` or `wasm_plugin`). The column is added with the constant
    default `native_addon`, so every existing row is an add-on rollout.
  * Each artifact family has its own package FK pair. The add-on pair
    (`previous_package_id`, `candidate_package_id`, to `addon_packages`) becomes
    nullable, and a Wasm pair (`previous_plugin_package_id`,
    `candidate_plugin_package_id`, to `plugin_packages`) is added. A CHECK on each
    table requires exactly the pair that matches `artifact_kind`, the source
    types that kind's owners use, and, on targets, the member key of that kind.
  * `source_key` carries the credential-rule purpose, so two purposes of one
    rule are separate rollout sources.
  * Wasm targets are keyed by `plugin_assignment_id` (ON DELETE SET NULL, like
    `assignment_id`, so finished history outlives the assignment) and record the
    assignment's `partition_id`.
  * `plugin_assignments` gains the per-target override columns
    `rollout_plugin_package_id`, `rollout_id` and `rollout_started_at`, with
    restrictive FKs. A CHECK keeps the three set or cleared together.
  * The active-source unique index now includes `artifact_kind` and
    `source_key`. The add-on active-target index applies only to add-on targets,
    and Wasm targets get their own, keyed by `plugin_assignment_id`.
  * The `addon_fleet` view reads only `native_addon` rollout targets. Its
    assignment CTE now names the columns it uses instead of `assignment.*`, so
    re-creating the view does not make it depend on every `addon_assignments`
    column added since it was first created. Its output is unchanged.

  Startup safety: column additions use constant defaults or no default, and
  `DROP NOT NULL` changes only the catalog. Every new FK and CHECK is added
  `NOT VALID`, so adding it does not scan the table. Existing rows satisfy them
  by construction: each is `native_addon`, its add-on package pair was
  `NOT NULL` until this migration, and every new column is NULL. New writes are
  checked. The index rebuilds scan the two rollout tables, which hold one row per
  rollout and per rollout target.

  serviceradar:allow-startup-maintenance - nothing in `up` updates or deletes a
  row. The one DELETE, in `down`, removes Wasm rollouts, which cannot satisfy the
  restored `NOT NULL` add-on package columns.
  """

  use Ecto.Migration

  @prefix "platform"
  @active_rollout_states "('pending', 'running', 'paused', 'rolling_back')"
  @slot_holding_target_states "('pending', 'waiting_health', 'healthy_soak', 'succeeded', 'rollback_pending')"
  @native_source_types "('assignment', 'profile')"
  @wasm_source_types "('assignment', 'target_policy', 'credential_rule')"

  # The assignment columns the addon_fleet view reads.
  @fleet_assignment_columns Enum.map_join(
                              ~w(id agent_uid addon_id addon_package_id rollout_package_id
                                 rollout_started_at update_policy updated_at inserted_at),
                              ", ",
                              &"assignment.#{&1}"
                            )

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter_rollouts()
    alter_targets()
    alter_plugin_assignments()
    replace_unique_indexes()

    execute(addon_fleet_view(@fleet_assignment_columns, "WHERE target.artifact_kind = 'native_addon'"))
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    execute(addon_fleet_view("assignment.*", ""))

    execute("""
    ALTER TABLE #{@prefix}.plugin_assignments
      DROP CONSTRAINT IF EXISTS plugin_assignments_rollout_override_check,
      DROP COLUMN IF EXISTS rollout_started_at,
      DROP COLUMN IF EXISTS rollout_id,
      DROP COLUMN IF EXISTS rollout_plugin_package_id
    """)

    # Removes only Wasm rollouts (their targets cascade). They cannot satisfy
    # the add-on package columns' restored NOT NULL, and nothing else can hold
    # them once artifact_kind is gone.
    execute("DELETE FROM #{@prefix}.addon_rollouts WHERE artifact_kind = 'wasm_plugin'")

    execute("DROP INDEX IF EXISTS #{@prefix}.addon_rollout_targets_one_active_plugin_target_index")
    execute("DROP INDEX IF EXISTS #{@prefix}.addon_rollout_targets_plugin_assignment_id_index")
    execute("DROP INDEX IF EXISTS #{@prefix}.addon_rollout_targets_one_active_target_index")
    execute("DROP INDEX IF EXISTS #{@prefix}.addon_rollouts_one_active_source_index")

    execute("""
    ALTER TABLE #{@prefix}.addon_rollout_targets
      DROP CONSTRAINT IF EXISTS addon_rollout_targets_artifact_kind_check,
      DROP COLUMN IF EXISTS candidate_plugin_package_id,
      DROP COLUMN IF EXISTS previous_plugin_package_id,
      DROP COLUMN IF EXISTS partition_id,
      DROP COLUMN IF EXISTS plugin_assignment_id,
      DROP COLUMN IF EXISTS source_key,
      DROP COLUMN IF EXISTS artifact_kind,
      ALTER COLUMN previous_package_id SET NOT NULL,
      ALTER COLUMN candidate_package_id SET NOT NULL
    """)

    execute("""
    ALTER TABLE #{@prefix}.addon_rollouts
      DROP CONSTRAINT IF EXISTS addon_rollouts_artifact_kind_check,
      DROP COLUMN IF EXISTS candidate_plugin_package_id,
      DROP COLUMN IF EXISTS previous_plugin_package_id,
      DROP COLUMN IF EXISTS source_key,
      DROP COLUMN IF EXISTS artifact_kind,
      ALTER COLUMN previous_package_id SET NOT NULL,
      ALTER COLUMN candidate_package_id SET NOT NULL
    """)

    execute("""
    CREATE UNIQUE INDEX addon_rollouts_one_active_source_index
    ON #{@prefix}.addon_rollouts (source_type, source_id)
    WHERE state IN #{@active_rollout_states}
    """)

    execute("""
    CREATE UNIQUE INDEX addon_rollout_targets_one_active_target_index
    ON #{@prefix}.addon_rollout_targets (agent_uid, addon_id)
    WHERE state IN #{@slot_holding_target_states}
    """)
  end

  defp alter_rollouts do
    execute("""
    ALTER TABLE #{@prefix}.addon_rollouts
      ADD COLUMN artifact_kind text NOT NULL DEFAULT 'native_addon',
      ADD COLUMN source_key text,
      ADD COLUMN previous_plugin_package_id uuid,
      ADD COLUMN candidate_plugin_package_id uuid,
      ALTER COLUMN previous_package_id DROP NOT NULL,
      ALTER COLUMN candidate_package_id DROP NOT NULL
    """)

    execute("""
    ALTER TABLE #{@prefix}.addon_rollouts
      ADD CONSTRAINT addon_rollouts_previous_plugin_package_id_fkey
        FOREIGN KEY (previous_plugin_package_id)
        REFERENCES #{@prefix}.plugin_packages(id) ON DELETE RESTRICT NOT VALID,
      ADD CONSTRAINT addon_rollouts_candidate_plugin_package_id_fkey
        FOREIGN KEY (candidate_plugin_package_id)
        REFERENCES #{@prefix}.plugin_packages(id) ON DELETE RESTRICT NOT VALID,
      ADD CONSTRAINT addon_rollouts_artifact_kind_check CHECK (
        (artifact_kind = 'native_addon'
          AND source_type IN #{@native_source_types}
          AND source_key IS NULL
          AND previous_package_id IS NOT NULL
          AND candidate_package_id IS NOT NULL
          AND previous_plugin_package_id IS NULL
          AND candidate_plugin_package_id IS NULL)
        OR
        (artifact_kind = 'wasm_plugin'
          AND source_type IN #{@wasm_source_types}
          AND previous_plugin_package_id IS NOT NULL
          AND candidate_plugin_package_id IS NOT NULL
          AND previous_package_id IS NULL
          AND candidate_package_id IS NULL)
      ) NOT VALID
    """)
  end

  defp alter_targets do
    execute("""
    ALTER TABLE #{@prefix}.addon_rollout_targets
      ADD COLUMN artifact_kind text NOT NULL DEFAULT 'native_addon',
      ADD COLUMN source_key text,
      ADD COLUMN plugin_assignment_id uuid,
      ADD COLUMN partition_id text,
      ADD COLUMN previous_plugin_package_id uuid,
      ADD COLUMN candidate_plugin_package_id uuid,
      ALTER COLUMN previous_package_id DROP NOT NULL,
      ALTER COLUMN candidate_package_id DROP NOT NULL
    """)

    # A Wasm target keys its member by plugin_assignment_id and never by the
    # add-on assignment_id; an add-on target is the reverse. Either pointer may
    # be cleared by ON DELETE SET NULL once its assignment is deleted.
    execute("""
    ALTER TABLE #{@prefix}.addon_rollout_targets
      ADD CONSTRAINT addon_rollout_targets_plugin_assignment_id_fkey
        FOREIGN KEY (plugin_assignment_id)
        REFERENCES #{@prefix}.plugin_assignments(id) ON DELETE SET NULL NOT VALID,
      ADD CONSTRAINT addon_rollout_targets_previous_plugin_package_id_fkey
        FOREIGN KEY (previous_plugin_package_id)
        REFERENCES #{@prefix}.plugin_packages(id) ON DELETE RESTRICT NOT VALID,
      ADD CONSTRAINT addon_rollout_targets_candidate_plugin_package_id_fkey
        FOREIGN KEY (candidate_plugin_package_id)
        REFERENCES #{@prefix}.plugin_packages(id) ON DELETE RESTRICT NOT VALID,
      ADD CONSTRAINT addon_rollout_targets_artifact_kind_check CHECK (
        (artifact_kind = 'native_addon'
          AND source_type IN #{@native_source_types}
          AND source_key IS NULL
          AND plugin_assignment_id IS NULL
          AND previous_package_id IS NOT NULL
          AND candidate_package_id IS NOT NULL
          AND previous_plugin_package_id IS NULL
          AND candidate_plugin_package_id IS NULL)
        OR
        (artifact_kind = 'wasm_plugin'
          AND source_type IN #{@wasm_source_types}
          AND assignment_id IS NULL
          AND partition_id IS NOT NULL
          AND previous_plugin_package_id IS NOT NULL
          AND candidate_plugin_package_id IS NOT NULL
          AND previous_package_id IS NULL
          AND candidate_package_id IS NULL)
      ) NOT VALID
    """)
  end

  defp alter_plugin_assignments do
    execute("""
    ALTER TABLE #{@prefix}.plugin_assignments
      ADD COLUMN rollout_plugin_package_id uuid,
      ADD COLUMN rollout_id uuid,
      ADD COLUMN rollout_started_at timestamp without time zone
    """)

    execute("""
    ALTER TABLE #{@prefix}.plugin_assignments
      ADD CONSTRAINT plugin_assignments_rollout_plugin_package_id_fkey
        FOREIGN KEY (rollout_plugin_package_id)
        REFERENCES #{@prefix}.plugin_packages(id) ON DELETE RESTRICT NOT VALID,
      ADD CONSTRAINT plugin_assignments_rollout_id_fkey
        FOREIGN KEY (rollout_id)
        REFERENCES #{@prefix}.addon_rollouts(id) ON DELETE RESTRICT NOT VALID,
      ADD CONSTRAINT plugin_assignments_rollout_override_check CHECK (
        (rollout_plugin_package_id IS NULL AND rollout_id IS NULL AND rollout_started_at IS NULL)
        OR
        (rollout_plugin_package_id IS NOT NULL AND rollout_id IS NOT NULL AND rollout_started_at IS NOT NULL)
      ) NOT VALID
    """)
  end

  defp replace_unique_indexes do
    execute("DROP INDEX IF EXISTS #{@prefix}.addon_rollouts_one_active_source_index")

    execute("""
    CREATE UNIQUE INDEX addon_rollouts_one_active_source_index
    ON #{@prefix}.addon_rollouts (artifact_kind, source_type, source_id, source_key)
    NULLS NOT DISTINCT
    WHERE state IN #{@active_rollout_states}
    """)

    execute("DROP INDEX IF EXISTS #{@prefix}.addon_rollout_targets_one_active_target_index")

    execute("""
    CREATE UNIQUE INDEX addon_rollout_targets_one_active_target_index
    ON #{@prefix}.addon_rollout_targets (agent_uid, addon_id)
    WHERE artifact_kind = 'native_addon' AND state IN #{@slot_holding_target_states}
    """)

    execute("""
    CREATE UNIQUE INDEX addon_rollout_targets_one_active_plugin_target_index
    ON #{@prefix}.addon_rollout_targets (plugin_assignment_id)
    WHERE artifact_kind = 'wasm_plugin' AND state IN #{@slot_holding_target_states}
    """)

    # Serves the ON DELETE SET NULL lookup when a plugin assignment is deleted.
    execute("""
    CREATE INDEX addon_rollout_targets_plugin_assignment_id_index
    ON #{@prefix}.addon_rollout_targets (plugin_assignment_id)
    WHERE plugin_assignment_id IS NOT NULL
    """)
  end

  # The view from 20260720180000_add_addon_fleet_read_model, with the assignment
  # CTE's column list and the rollout-target filter as parameters. Its output
  # columns are identical either way, which CREATE OR REPLACE VIEW requires.
  defp addon_fleet_view(assignment_columns, target_filter) do
    """
    CREATE OR REPLACE VIEW #{@prefix}.addon_fleet AS
    WITH effective_assignments AS (
      SELECT DISTINCT ON (assignment.agent_uid, assignment.addon_id)
        #{assignment_columns}
      FROM #{@prefix}.addon_assignments AS assignment
      WHERE assignment.enabled = TRUE
      ORDER BY
        assignment.agent_uid,
        assignment.addon_id,
        CASE assignment.source
          WHEN 'manual' THEN 0
          WHEN 'profile' THEN 1
          ELSE 2
        END,
        CASE
          WHEN assignment.source = 'profile'
            AND COALESCE(assignment.profile_metadata ->> 'priority', '') ~ '^-?[0-9]+$'
            THEN (assignment.profile_metadata ->> 'priority')::integer
          ELSE 100
        END,
        assignment.updated_at DESC,
        assignment.inserted_at DESC,
        assignment.id ASC
    ),
    fleet_keys AS (
      SELECT agent_uid, addon_id FROM effective_assignments
      UNION
      SELECT agent_uid, addon_id FROM #{@prefix}.addon_statuses
    ),
    latest_rollout_targets AS (
      SELECT DISTINCT ON (target.assignment_id)
        target.assignment_id,
        target.classification,
        target.state AS target_state,
        target.reason_code AS target_reason_code,
        rollout.state AS rollout_state,
        rollout.blocked_reason,
        target.updated_at
      FROM #{@prefix}.addon_rollout_targets AS target
      LEFT JOIN #{@prefix}.addon_rollouts AS rollout ON rollout.id = target.rollout_id
      #{target_filter}
      ORDER BY target.assignment_id, target.updated_at DESC, target.id DESC
    ),
    base AS (
      SELECT
        keys.agent_uid,
        CASE
          WHEN agent.uid IS NULL THEN keys.agent_uid
          WHEN COALESCE(NULLIF(agent.name, ''), NULLIF(agent.host, '')) IS NULL THEN agent.uid
          ELSE CONCAT(COALESCE(NULLIF(agent.name, ''), NULLIF(agent.host, '')), ' (', agent.uid, ')')
        END AS agent_label,
        keys.addon_id,
        assignment.id IS NOT NULL AS assigned,
        package.name AS addon_name,
        package.version AS assigned_version,
        package.status AS package_status,
        package.supervision AS package_supervision,
        assignment.update_policy,
        assignment.rollout_started_at,
        assignment.updated_at AS assignment_updated_at,
        assignment.inserted_at AS assignment_inserted_at,
        status.state AS observed_state,
        status.version AS observed_version,
        status.active,
        status.degradation_reason,
        status.reported_at,
        agent.uid AS agent_uid_present,
        agent.status AS agent_status,
        agent.is_healthy AS agent_is_healthy,
        agent.last_seen_time AS agent_last_seen_time,
        target.classification AS target_classification,
        target.target_state,
        COALESCE(target.blocked_reason, target.target_reason_code) AS target_reason_code,
        target.rollout_state,
        CASE
          WHEN status.reported_at IS NULL THEN NULL
          ELSE GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (now() - status.reported_at)))::bigint)
        END AS evidence_age_seconds,
        CASE
          WHEN NULLIF(BTRIM(status.degradation_reason), '') IS NOT NULL THEN TRUE
          WHEN LOWER(COALESCE(status.state, '')) IN ('circuit_open', 'failed', 'unhealthy', 'verification_failed') THEN TRUE
          ELSE FALSE
        END AS observed_unhealthy,
        CASE
          WHEN NULLIF(BTRIM(status.degradation_reason), '') IS NOT NULL THEN FALSE
          WHEN package.supervision IN ('agent_sidecar', 'systemd_service')
            THEN status.active = TRUE AND LOWER(COALESCE(status.state, '')) IN ('active', 'healthy', 'running')
          WHEN package.supervision = 'systemd_timer'
            THEN LOWER(COALESCE(status.state, '')) IN ('active', 'enabled', 'healthy', 'ready', 'running', 'waiting')
          WHEN package.supervision = 'ephemeral_helper'
            THEN LOWER(COALESCE(status.state, '')) IN ('healthy', 'ready', 'registered', 'staged', 'verified')
          WHEN package.supervision = 'config_toggle'
            THEN LOWER(COALESCE(status.state, '')) IN ('active', 'applied', 'healthy', 'ready', 'running')
          ELSE FALSE
        END AS supervision_ready
      FROM fleet_keys AS keys
      LEFT JOIN effective_assignments AS assignment
        ON assignment.agent_uid = keys.agent_uid AND assignment.addon_id = keys.addon_id
      LEFT JOIN #{@prefix}.addon_packages AS package
        ON package.id = COALESCE(assignment.rollout_package_id, assignment.addon_package_id)
      LEFT JOIN #{@prefix}.addon_statuses AS status
        ON status.agent_uid = keys.agent_uid AND status.addon_id = keys.addon_id
      LEFT JOIN #{@prefix}.ocsf_agents AS agent ON agent.uid = keys.agent_uid
      LEFT JOIN latest_rollout_targets AS target ON target.assignment_id = assignment.id
    ),
    rules AS (
      SELECT
        base.*,
        CASE
          WHEN assigned AND COALESCE(package_status, '') <> 'approved' THEN 'invalid_desired_package'
          WHEN target_classification = 'incompatible' THEN 'incompatible_rollout'
          WHEN rollout_state IN ('paused', 'failed', 'rolled_back')
            OR target_state IN ('failed', 'rolled_back') THEN 'failed_rollout'
          WHEN rollout_state IN ('pending', 'running', 'rolling_back')
            AND target_state IN ('pending', 'waiting_health', 'healthy_soak', 'succeeded', 'rollback_pending') THEN 'active_rollout'
          WHEN NOT assigned AND reported_at IS NOT NULL AND now() - reported_at > interval '180 seconds' THEN 'observed_only_stale'
          WHEN NOT assigned AND observed_unhealthy THEN 'observed_unhealthy'
          WHEN NOT assigned THEN 'observed_only'
          WHEN agent_uid_present IS NULL
            OR agent_status IS DISTINCT FROM 'connected'
            OR agent_is_healthy = FALSE
            OR agent_last_seen_time IS NULL
            OR now() - agent_last_seen_time > interval '180 seconds' THEN 'agent_unavailable'
          WHEN reported_at IS NULL THEN 'runtime_not_reported'
          WHEN now() - reported_at > interval '180 seconds' THEN 'runtime_stale'
          WHEN observed_unhealthy THEN 'runtime_unhealthy'
          WHEN supervision_ready AND package_supervision = 'ephemeral_helper' THEN 'ephemeral_ready'
          WHEN supervision_ready AND observed_version = assigned_version THEN 'converged'
          WHEN now() - COALESCE(rollout_started_at, assignment_updated_at, assignment_inserted_at)
              <= interval '900 seconds' THEN 'convergence_grace'
          ELSE 'not_converged'
        END AS classification_rule
      FROM base
    )
    SELECT
      agent_uid,
      agent_label,
      addon_id,
      COALESCE(addon_name, addon_id) AS addon_name,
      assigned,
      assigned_version,
      observed_state,
      observed_version,
      active,
      CASE classification_rule
        WHEN 'invalid_desired_package' THEN 'action_required'
        WHEN 'incompatible_rollout' THEN 'action_required'
        WHEN 'failed_rollout' THEN 'action_required'
        WHEN 'active_rollout' THEN 'updating'
        WHEN 'observed_only_stale' THEN 'observed_only'
        WHEN 'observed_unhealthy' THEN 'action_required'
        WHEN 'observed_only' THEN 'observed_only'
        WHEN 'agent_unavailable' THEN 'unavailable'
        WHEN 'runtime_not_reported' THEN 'unavailable'
        WHEN 'runtime_stale' THEN 'unavailable'
        WHEN 'runtime_unhealthy' THEN 'action_required'
        WHEN 'ephemeral_ready' THEN 'expected_inactive'
        WHEN 'converged' THEN 'healthy'
        WHEN 'convergence_grace' THEN 'updating'
        ELSE 'action_required'
      END AS category,
      CASE classification_rule
        WHEN 'invalid_desired_package' THEN 'desired_package_not_approved'
        WHEN 'incompatible_rollout' THEN COALESCE(target_reason_code, 'rollout_target_incompatible')
        WHEN 'failed_rollout' THEN COALESCE(target_reason_code, 'rollout_failed')
        WHEN 'active_rollout' THEN COALESCE(target_reason_code, 'rollout_in_progress')
        WHEN 'observed_only_stale' THEN 'observed_only_stale'
        WHEN 'observed_unhealthy' THEN 'runtime_reported_unhealthy'
        WHEN 'observed_only' THEN 'healthy_observed_only_runtime'
        WHEN 'agent_unavailable' THEN 'agent_unavailable_or_stale'
        WHEN 'runtime_not_reported' THEN 'desired_runtime_not_yet_reported'
        WHEN 'runtime_stale' THEN 'runtime_observation_stale'
        WHEN 'runtime_unhealthy' THEN 'runtime_reported_unhealthy'
        WHEN 'ephemeral_ready' THEN 'ephemeral_helper_ready'
        WHEN 'converged' THEN 'desired_runtime_healthy'
        WHEN 'convergence_grace' THEN 'desired_state_converging'
        ELSE 'desired_state_not_converged'
      END AS reason_code,
      evidence_age_seconds,
      reported_at,
      rollout_state,
      update_policy,
      package_status,
      degradation_reason
    FROM rules
    """
  end
end
