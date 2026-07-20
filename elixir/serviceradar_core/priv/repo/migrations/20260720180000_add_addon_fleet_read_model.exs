defmodule ServiceRadar.Repo.Migrations.AddAddonFleetReadModel do
  @moduledoc false
  use Ecto.Migration

  # This view is the queryable counterpart of the operator fleet matrix. It
  # keeps the desired assignment, rollout snapshot, agent availability, and
  # observed status in one row so SRQL consumers do not have to reimplement the
  # precedence rules from individual platform tables.
  def up do
    execute("""
    CREATE VIEW platform.addon_fleet AS
    WITH effective_assignments AS (
      SELECT DISTINCT ON (assignment.agent_uid, assignment.addon_id)
        assignment.*
      FROM platform.addon_assignments AS assignment
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
      SELECT agent_uid, addon_id FROM platform.addon_statuses
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
      FROM platform.addon_rollout_targets AS target
      LEFT JOIN platform.addon_rollouts AS rollout ON rollout.id = target.rollout_id
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
      LEFT JOIN platform.addon_packages AS package
        ON package.id = COALESCE(assignment.rollout_package_id, assignment.addon_package_id)
      LEFT JOIN platform.addon_statuses AS status
        ON status.agent_uid = keys.agent_uid AND status.addon_id = keys.addon_id
      LEFT JOIN platform.ocsf_agents AS agent ON agent.uid = keys.agent_uid
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
    """)
  end

  def down do
    execute("DROP VIEW IF EXISTS platform.addon_fleet")
  end
end
