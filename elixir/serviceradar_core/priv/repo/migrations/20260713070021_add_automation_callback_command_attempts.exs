defmodule ServiceRadar.Repo.Migrations.AddAutomationCallbackCommandAttempts do
  @moduledoc false
  use Ecto.Migration

  @active_states "('planned', 'dispatching', 'dispatched', 'processing', 'waiting')"

  def change do
    create table(:automation_callback_command_attempts, primary_key: false, prefix: "platform") do
      add :id, :uuid,
        primary_key: true,
        null: false,
        default: fragment("uuid_generate_v7()")

      add :grant_id,
          references(:automation_callback_grants,
            type: :uuid,
            on_delete: :restrict,
            prefix: "platform"
          ),
          null: false

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
        default: "serviceradar.automation_callback_command/v1"

      add :request_digest, :text, null: false
      add :context_digest, :text, null: false
      add :result_digest, :text
      add :expected_credential_id, :bigint
      add :expected_job_id, :bigint
      add :reconcile_after, :utc_datetime_usec
      add :state, :text, null: false, default: "planned"
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

    create unique_index(:automation_callback_command_attempts, [:command_id],
             name: "automation_callback_command_attempts_command_uidx",
             prefix: "platform"
           )

    create unique_index(
             :automation_callback_command_attempts,
             [:grant_id, :stage, :purpose, :attempt],
             name: "automation_callback_command_attempts_stage_attempt_uidx",
             prefix: "platform"
           )

    create unique_index(
             :automation_callback_command_attempts,
             [:grant_id, :stage, :purpose],
             name: "automation_callback_command_attempts_active_stage_uidx",
             where: "state IN #{@active_states}",
             prefix: "platform"
           )

    create index(:automation_callback_command_attempts, [:state, :next_attempt_at, :inserted_at],
             name: "automation_callback_command_attempts_due_idx",
             where: "state IN ('planned', 'waiting', 'dispatched')",
             prefix: "platform"
           )

    create index(:automation_callback_command_attempts, [:state, :lease_expires_at],
             name: "automation_callback_command_attempts_lease_idx",
             where: "state IN ('dispatching', 'processing')",
             prefix: "platform"
           )

    create index(:automation_callback_command_attempts, [:processed_at],
             name: "automation_callback_command_attempts_activation_cleanup_idx",
             where: "state = 'succeeded' AND outcome_code = 'scope_verified_and_activated'",
             prefix: "platform"
           )

    create constraint(
             :automation_callback_command_attempts,
             :automation_callback_command_attempts_digest_check,
             check: """
             request_digest ~ '^[0-9a-f]{64}$'
             AND context_digest ~ '^[0-9a-f]{64}$'
             AND (result_digest IS NULL OR result_digest ~ '^[0-9a-f]{64}$')
             """,
             prefix: "platform"
           )

    create constraint(
             :automation_callback_command_attempts,
             :automation_callback_command_attempts_schema_check,
             check: "request_schema_version = 'serviceradar.automation_callback_command/v1'",
             prefix: "platform"
           )

    create constraint(
             :automation_callback_command_attempts,
             :automation_callback_command_attempts_stage_command_check,
             check: """
             (stage = 'create_credential' AND command_type = 'awx.create_callback_credential' AND purpose = 'credential_creation' AND expected_credential_id IS NULL AND expected_job_id IS NULL)
             OR (stage = 'fetch_credential' AND command_type = 'awx.fetch_callback_credential' AND purpose = 'credential_reconciliation' AND expected_credential_id IS NULL AND expected_job_id IS NULL)
             OR (stage = 'launch_job' AND command_type = 'awx.launch_job' AND purpose = 'accepted_job_proof' AND expected_credential_id IS NOT NULL AND expected_job_id IS NULL)
             OR (stage = 'fetch_job' AND command_type = 'awx.fetch_job' AND purpose IN ('accepted_job_proof', 'scope_poll', 'terminal_confirmation') AND expected_job_id IS NOT NULL)
             OR (stage = 'list_recent_jobs' AND command_type = 'awx.list_recent_jobs' AND purpose = 'launch_reconciliation')
             OR (stage = 'fetch_host_summaries' AND command_type = 'awx.fetch_job_host_summaries' AND purpose = 'host_scope_proof' AND expected_job_id IS NOT NULL)
             OR (stage = 'cancel_job' AND command_type = 'awx.cancel_job' AND purpose = 'terminal_cleanup' AND expected_job_id IS NOT NULL)
             OR (stage = 'delete_credential' AND command_type = 'awx.delete_callback_credential' AND purpose = 'terminal_cleanup' AND expected_credential_id IS NOT NULL)
             """,
             prefix: "platform"
           )

    create constraint(
             :automation_callback_command_attempts,
             :automation_callback_command_attempts_deadline_check,
             check: "next_attempt_at IS NULL OR next_attempt_at <= deadline_at",
             prefix: "platform"
           )

    create constraint(
             :automation_callback_command_attempts,
             :automation_callback_command_attempts_reconcile_check,
             check: """
             (stage = 'list_recent_jobs' AND reconcile_after IS NOT NULL)
             OR (stage <> 'list_recent_jobs' AND reconcile_after IS NULL)
             """,
             prefix: "platform"
           )

    create constraint(
             :automation_callback_command_attempts,
             :automation_callback_command_attempts_lease_check,
             check: """
             (state IN ('dispatching', 'processing') AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)
             OR (state NOT IN ('dispatching', 'processing') AND lease_token IS NULL AND lease_expires_at IS NULL)
             """,
             prefix: "platform"
           )

    create constraint(
             :automation_callback_command_attempts,
             :automation_callback_command_attempts_terminal_check,
             check: """
             (state IN ('succeeded', 'failed', 'ambiguous') AND processed_at IS NOT NULL AND outcome_code IS NOT NULL AND next_attempt_at IS NULL)
             OR (state NOT IN ('succeeded', 'failed', 'ambiguous') AND processed_at IS NULL)
             """,
             prefix: "platform"
           )
  end
end
