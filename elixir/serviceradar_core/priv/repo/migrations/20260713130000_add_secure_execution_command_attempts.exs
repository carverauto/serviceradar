defmodule ServiceRadar.Repo.Migrations.AddSecureExecutionCommandAttempts do
  @moduledoc false
  use Ecto.Migration

  @active_states "('planned', 'dispatching', 'dispatched', 'processing', 'waiting')"

  def change do
    create table(:automation_secure_execution_command_attempts,
             primary_key: false,
             prefix: "platform"
           ) do
      add :id, :uuid,
        primary_key: true,
        null: false,
        default: fragment("uuid_generate_v7()")

      add :operation_id,
          references(:ansible_automation_operations,
            type: :uuid,
            on_delete: :restrict,
            prefix: "platform"
          ),
          null: false

      add :execution_id,
          references(:ansible_automation_executions,
            type: :uuid,
            on_delete: :restrict,
            prefix: "platform"
          ),
          null: false

      add :controller_id,
          references(:ansible_controllers,
            type: :uuid,
            on_delete: :restrict,
            prefix: "platform"
          ),
          null: false

      add :dispatch_agent_id, :text, null: false
      add :stage, :text, null: false
      add :purpose, :text, null: false
      add :attempt, :bigint, null: false, default: 1
      add :command_id, :uuid, null: false
      add :command_type, :text, null: false

      add :request_schema_version, :text,
        null: false,
        default: "serviceradar.automation_execution_command/v1"

      add :request_digest, :text, null: false
      add :context_digest, :text, null: false
      add :result_digest, :text
      add :expected_job_id, :bigint
      add :reconcile_after, :utc_datetime_usec
      add :terminal_job_snapshot, :map
      add :candidate_job_ids, {:array, :bigint}, null: false, default: []
      add :state, :text, null: false, default: "planned"
      add :lock_version, :bigint, null: false, default: 1
      add :deadline_at, :utc_datetime_usec, null: false
      add :next_attempt_at, :utc_datetime_usec
      add :lease_token, :uuid
      add :lease_expires_at, :utc_datetime_usec
      add :dispatched_at, :utc_datetime_usec
      add :processing_started_at, :utc_datetime_usec
      add :processed_at, :utc_datetime_usec
      add :outcome_code, :text
      add :last_error_code, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:automation_secure_execution_command_attempts, [:command_id],
             name: "automation_secure_execution_attempts_command_uidx",
             prefix: "platform"
           )

    create unique_index(
             :automation_secure_execution_command_attempts,
             [:execution_id, :stage, :purpose, :attempt],
             name: "automation_secure_execution_attempts_stage_attempt_uidx",
             prefix: "platform"
           )

    create unique_index(
             :automation_secure_execution_command_attempts,
             [:execution_id, :stage, :purpose],
             name: "automation_secure_execution_attempts_active_stage_uidx",
             where: "state IN #{@active_states}",
             prefix: "platform"
           )

    create index(
             :automation_secure_execution_command_attempts,
             [:state, :next_attempt_at, :inserted_at],
             name: "automation_secure_execution_attempts_due_idx",
             where: "state IN ('planned', 'waiting', 'dispatched')",
             prefix: "platform"
           )

    create index(:automation_secure_execution_command_attempts, [:state, :lease_expires_at],
             name: "automation_secure_execution_attempts_lease_idx",
             where: "state IN ('dispatching', 'processing')",
             prefix: "platform"
           )

    create index(:automation_secure_execution_command_attempts, [:execution_id, :inserted_at],
             name: "automation_secure_execution_attempts_execution_idx",
             prefix: "platform"
           )

    create constraint(
             :automation_secure_execution_command_attempts,
             :automation_secure_execution_attempts_digest_check,
             check: """
             request_digest ~ '^[0-9a-f]{64}$'
             AND context_digest ~ '^[0-9a-f]{64}$'
             AND (result_digest IS NULL OR result_digest ~ '^[0-9a-f]{64}$')
             """,
             prefix: "platform"
           )

    create constraint(
             :automation_secure_execution_command_attempts,
             :automation_secure_execution_attempts_schema_check,
             check: "request_schema_version = 'serviceradar.automation_execution_command/v1'",
             prefix: "platform"
           )

    create constraint(
             :automation_secure_execution_command_attempts,
             :automation_secure_execution_attempts_stage_command_check,
             check: """
             (stage = 'launch_job' AND command_type = 'awx.launch_job' AND purpose = 'accepted_job_proof' AND expected_job_id IS NULL)
             OR (stage = 'fetch_job' AND command_type = 'awx.fetch_job' AND purpose IN ('accepted_job_proof', 'scope_poll', 'terminal_poll') AND expected_job_id IS NOT NULL)
             OR (stage = 'list_recent_jobs' AND command_type = 'awx.list_recent_jobs' AND purpose = 'launch_reconciliation' AND expected_job_id IS NULL)
             OR (stage = 'fetch_host_summaries' AND command_type = 'awx.fetch_job_host_summaries' AND purpose IN ('host_scope_proof', 'terminal_confirmation') AND expected_job_id IS NOT NULL)
             OR (stage = 'cancel_job' AND command_type = 'awx.cancel_job' AND purpose = 'terminal_cleanup' AND expected_job_id IS NOT NULL)
             """,
             prefix: "platform"
           )

    create constraint(
             :automation_secure_execution_command_attempts,
             :automation_secure_execution_attempts_bounds_check,
             check: """
             attempt BETWEEN 1 AND 1000
             AND dispatch_agent_id <> ''
             AND (expected_job_id IS NULL OR expected_job_id > 0)
             AND cardinality(candidate_job_ids) <= 50
             AND 0 < ALL(candidate_job_ids)
             AND array_position(candidate_job_ids, NULL) IS NULL
             AND state IN ('planned', 'dispatching', 'dispatched', 'processing', 'waiting', 'succeeded', 'failed', 'ambiguous')
             """,
             prefix: "platform"
           )

    create constraint(
             :automation_secure_execution_command_attempts,
             :automation_secure_execution_attempts_deadline_check,
             check: "next_attempt_at IS NULL OR next_attempt_at <= deadline_at",
             prefix: "platform"
           )

    create constraint(
             :automation_secure_execution_command_attempts,
             :automation_secure_execution_attempts_reconcile_check,
             check: """
             (stage = 'list_recent_jobs' AND reconcile_after IS NOT NULL)
             OR (stage <> 'list_recent_jobs' AND reconcile_after IS NULL)
             """,
             prefix: "platform"
           )

    create constraint(
             :automation_secure_execution_command_attempts,
             :automation_secure_execution_attempts_terminal_evidence_check,
             check: """
             (purpose = 'terminal_confirmation' AND terminal_job_snapshot IS NOT NULL)
             OR (purpose <> 'terminal_confirmation' AND terminal_job_snapshot IS NULL)
             """,
             prefix: "platform"
           )

    create constraint(
             :automation_secure_execution_command_attempts,
             :automation_secure_execution_attempts_lease_check,
             check: """
             (state IN ('dispatching', 'processing') AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)
             OR (state NOT IN ('dispatching', 'processing') AND lease_token IS NULL AND lease_expires_at IS NULL)
             """,
             prefix: "platform"
           )

    create constraint(
             :automation_secure_execution_command_attempts,
             :automation_secure_execution_attempts_terminal_check,
             check: """
             (state IN ('succeeded', 'failed', 'ambiguous') AND processed_at IS NOT NULL AND outcome_code IS NOT NULL AND next_attempt_at IS NULL)
             OR (state NOT IN ('succeeded', 'failed', 'ambiguous') AND processed_at IS NULL)
             """,
             prefix: "platform"
           )
  end
end
