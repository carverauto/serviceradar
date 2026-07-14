defmodule ServiceRadar.Repo.Migrations.AddCallbackTerminalWatchdogEvidence do
  @moduledoc false
  use Ecto.Migration

  @stage_constraint :automation_callback_command_attempts_stage_command_check
  @terminal_constraint :automation_callback_command_attempts_terminal_evidence_check

  def up do
    alter table(:automation_callback_command_attempts, prefix: "platform") do
      add :terminal_job_snapshot, :map
    end

    drop constraint(:automation_callback_command_attempts, @stage_constraint, prefix: "platform")

    create constraint(:automation_callback_command_attempts, @stage_constraint,
             check: """
             (stage = 'create_credential' AND command_type = 'awx.create_callback_credential' AND purpose = 'credential_creation' AND expected_credential_id IS NULL AND expected_job_id IS NULL)
             OR (stage = 'fetch_credential' AND command_type = 'awx.fetch_callback_credential' AND purpose = 'credential_reconciliation' AND expected_credential_id IS NULL AND expected_job_id IS NULL)
             OR (stage = 'launch_job' AND command_type = 'awx.launch_job' AND purpose = 'accepted_job_proof' AND expected_credential_id IS NOT NULL AND expected_job_id IS NULL)
             OR (stage = 'fetch_job' AND command_type = 'awx.fetch_job' AND purpose IN ('accepted_job_proof', 'scope_poll', 'terminal_poll') AND expected_job_id IS NOT NULL)
             OR (stage = 'list_recent_jobs' AND command_type = 'awx.list_recent_jobs' AND purpose = 'launch_reconciliation')
             OR (stage = 'fetch_host_summaries' AND command_type = 'awx.fetch_job_host_summaries' AND purpose IN ('host_scope_proof', 'terminal_confirmation') AND expected_job_id IS NOT NULL)
             OR (stage = 'cancel_job' AND command_type = 'awx.cancel_job' AND purpose = 'terminal_cleanup' AND expected_job_id IS NOT NULL)
             OR (stage = 'delete_credential' AND command_type = 'awx.delete_callback_credential' AND purpose = 'terminal_cleanup' AND expected_credential_id IS NOT NULL)
             """,
             prefix: "platform"
           )

    create constraint(:automation_callback_command_attempts, @terminal_constraint,
             check: """
             (purpose = 'terminal_confirmation' AND terminal_job_snapshot IS NOT NULL)
             OR (purpose <> 'terminal_confirmation' AND terminal_job_snapshot IS NULL)
             """,
             prefix: "platform"
           )
  end

  def down do
    drop constraint(:automation_callback_command_attempts, @terminal_constraint,
           prefix: "platform"
         )

    drop constraint(:automation_callback_command_attempts, @stage_constraint, prefix: "platform")

    create constraint(:automation_callback_command_attempts, @stage_constraint,
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

    alter table(:automation_callback_command_attempts, prefix: "platform") do
      remove :terminal_job_snapshot
    end
  end
end
