defmodule ServiceRadar.Repo.Migrations.AddCallbackCandidateJobCleanupQueue do
  @moduledoc false
  use Ecto.Migration

  @secure_attempt_quarantine_sql """
  UPDATE platform.automation_secure_execution_command_attempts
  SET state = 'failed',
      processed_at = COALESCE(processed_at, now() AT TIME ZONE 'utc'),
      outcome_code = COALESCE(outcome_code, 'unproven_dispatch_partition'),
      last_error_code = COALESCE(last_error_code, 'unproven_dispatch_partition'),
      next_attempt_at = NULL,
      lease_token = NULL,
      lease_expires_at = NULL,
      updated_at = now() AT TIME ZONE 'utc'
  WHERE state IN ('planned', 'dispatching', 'dispatched', 'processing', 'waiting')
  """

  @secure_attempt_terminal_audit_sql """
  UPDATE platform.automation_secure_execution_command_attempts AS attempt
  SET dispatch_partition_id = NULLIF(BTRIM(command.partition_id), '')
  FROM platform.agent_commands AS command
  WHERE command.command_id = attempt.command_id
    AND command.agent_id = attempt.dispatch_agent_id
    AND command.sent_at IS NOT NULL
    AND NULLIF(BTRIM(command.partition_id), '') IS NOT NULL
    AND attempt.state IN ('succeeded', 'failed', 'ambiguous')
    AND attempt.dispatch_partition_id IS NULL
  """

  @doc false
  def secure_attempt_quarantine_sql, do: @secure_attempt_quarantine_sql

  @doc false
  def secure_attempt_terminal_audit_sql, do: @secure_attempt_terminal_audit_sql

  def up do
    # serviceradar:allow-startup-maintenance - pre-migration secure attempts
    # lack durable dispatch-partition authority and must be quarantined before
    # the new constraint is active. Terminal audit enrichment cannot revive an
    # attempt; finite-table statements and local deadlines bound first startup.
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '2min'")

    alter table(:automation_callback_command_attempts, prefix: "platform") do
      add :candidate_job_ids, {:array, :bigint}, null: false, default: []
      add :cleanup_only, :boolean, null: false, default: false
    end

    alter table(:automation_secure_execution_command_attempts, prefix: "platform") do
      add :dispatch_partition_id, :text
    end

    # `agent_commands.partition_id` historically defaulted to `default`, so it
    # is not sufficient provenance for preserving authority on an in-flight
    # attempt. Quarantine every pre-migration active attempt before any audit
    # enrichment. New active attempts are created with the partition selected
    # by the pre-send control-session binding and are enforced below.
    execute(@secure_attempt_quarantine_sql)

    # Terminal rows no longer carry authority. Enrich those rows for audit only
    # when the durable command identity, agent, sent state, and nonblank
    # partition all match exactly. This value is never used to revive a row.
    execute(@secure_attempt_terminal_audit_sql)

    drop constraint(
           :automation_secure_execution_command_attempts,
           :automation_secure_execution_attempts_bounds_check,
           prefix: "platform"
         )

    create constraint(
             :automation_secure_execution_command_attempts,
             :automation_secure_execution_attempts_bounds_check,
             prefix: "platform",
             check: """
             attempt BETWEEN 1 AND 1000
             AND dispatch_agent_id <> ''
             AND (expected_job_id IS NULL OR expected_job_id > 0)
             AND cardinality(candidate_job_ids) <= 5000
             AND 0 < ALL(candidate_job_ids)
             AND array_position(candidate_job_ids, NULL) IS NULL
             AND state IN ('planned', 'dispatching', 'dispatched', 'processing', 'waiting', 'succeeded', 'failed', 'ambiguous')
             """
           )

    create constraint(
             :automation_callback_command_attempts,
             :automation_callback_command_attempts_candidate_jobs_check,
             prefix: "platform",
             check: """
             cardinality(candidate_job_ids) <= 5000
             AND 0 < ALL(candidate_job_ids)
             AND array_position(candidate_job_ids, NULL) IS NULL
             """
           )

    create constraint(
             :automation_secure_execution_command_attempts,
             :automation_secure_execution_attempts_partition_check,
             prefix: "platform",
             check:
               "state IN ('succeeded', 'failed', 'ambiguous') OR (dispatch_partition_id IS NOT NULL AND BTRIM(dispatch_partition_id) <> '')"
           )
  end

  def down do
    # The older coordinator can retain at most 50 cleanup candidates. Refuse a
    # transactional rollback that would silently discard proven AWX job IDs or
    # fail later while recreating the old constraint.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM platform.automation_secure_execution_command_attempts
        WHERE cardinality(candidate_job_ids) > 50
      ) OR EXISTS (
        SELECT 1
        FROM platform.automation_callback_command_attempts
        WHERE state IN ('planned', 'dispatching', 'dispatched', 'processing', 'waiting')
          AND (cleanup_only = true OR cardinality(candidate_job_ids) > 0)
      ) THEN
        RAISE EXCEPTION
          'cannot roll back candidate cleanup queue: active containment state is not representable by the legacy schema';
      END IF;
    END
    $$
    """)

    drop constraint(
           :automation_callback_command_attempts,
           :automation_callback_command_attempts_candidate_jobs_check,
           prefix: "platform"
         )

    drop constraint(
           :automation_secure_execution_command_attempts,
           :automation_secure_execution_attempts_partition_check,
           prefix: "platform"
         )

    drop constraint(
           :automation_secure_execution_command_attempts,
           :automation_secure_execution_attempts_bounds_check,
           prefix: "platform"
         )

    create constraint(
             :automation_secure_execution_command_attempts,
             :automation_secure_execution_attempts_bounds_check,
             prefix: "platform",
             check: """
             attempt BETWEEN 1 AND 1000
             AND dispatch_agent_id <> ''
             AND (expected_job_id IS NULL OR expected_job_id > 0)
             AND cardinality(candidate_job_ids) <= 50
             AND 0 < ALL(candidate_job_ids)
             AND array_position(candidate_job_ids, NULL) IS NULL
             AND state IN ('planned', 'dispatching', 'dispatched', 'processing', 'waiting', 'succeeded', 'failed', 'ambiguous')
             """
           )

    alter table(:automation_secure_execution_command_attempts, prefix: "platform") do
      remove :dispatch_partition_id
    end

    alter table(:automation_callback_command_attempts, prefix: "platform") do
      remove :cleanup_only
      remove :candidate_job_ids
    end
  end
end
