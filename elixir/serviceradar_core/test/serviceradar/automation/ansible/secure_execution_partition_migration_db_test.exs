defmodule ServiceRadar.Automation.Ansible.SecureExecutionPartitionMigrationDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.Migrations.AddCallbackCandidateJobCleanupQueue, as: Migration

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20260713150000_add_callback_candidate_job_cleanup_queue.exs",
                    __DIR__
                  )
  @external_resource @migration_path

  Code.require_file(@migration_path)

  test "legacy default partition is quarantined before terminal-only audit enrichment" do
    Repo.query!("""
    CREATE TEMP TABLE migration_secure_execution_attempts (
      command_id uuid PRIMARY KEY,
      dispatch_agent_id text NOT NULL,
      dispatch_partition_id text,
      state text NOT NULL,
      processed_at timestamp,
      outcome_code text,
      last_error_code text,
      next_attempt_at timestamp,
      lease_token uuid,
      lease_expires_at timestamp,
      updated_at timestamp NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
    ) ON COMMIT DROP
    """)

    Repo.query!("""
    CREATE TEMP TABLE migration_agent_commands (
      command_id uuid PRIMARY KEY,
      agent_id text NOT NULL,
      partition_id text NOT NULL,
      sent_at timestamp
    ) ON COMMIT DROP
    """)

    command_id = Ecto.UUID.dump!(Ecto.UUID.generate())
    lease_token = Ecto.UUID.dump!(Ecto.UUID.generate())

    Repo.query!(
      """
      INSERT INTO migration_secure_execution_attempts (
        command_id,
        dispatch_agent_id,
        state,
        next_attempt_at,
        lease_token,
        lease_expires_at
      )
      VALUES ($1::uuid, 'edge-agent-1', 'processing', now(), $2::uuid, now() + interval '1 minute')
      """,
      [command_id, lease_token]
    )

    Repo.query!(
      """
      INSERT INTO migration_agent_commands (command_id, agent_id, partition_id, sent_at)
      VALUES ($1::uuid, 'edge-agent-1', 'default', now())
      """,
      [command_id]
    )

    quarantine_sql =
      String.replace(
        Migration.secure_attempt_quarantine_sql(),
        "platform.automation_secure_execution_command_attempts",
        "migration_secure_execution_attempts"
      )

    Repo.query!(quarantine_sql)

    assert %Postgrex.Result{
             rows: [
               [
                 "failed",
                 "unproven_dispatch_partition",
                 "unproven_dispatch_partition",
                 nil,
                 nil,
                 nil,
                 nil
               ]
             ]
           } =
             Repo.query!(
               """
               SELECT
                 state,
                 outcome_code,
                 last_error_code,
                 dispatch_partition_id,
                 next_attempt_at,
                 lease_token,
                 lease_expires_at
               FROM migration_secure_execution_attempts
               WHERE command_id = $1::uuid
               """,
               [command_id]
             )

    terminal_audit_sql =
      Migration.secure_attempt_terminal_audit_sql()
      |> String.replace(
        "platform.automation_secure_execution_command_attempts",
        "migration_secure_execution_attempts"
      )
      |> String.replace("platform.agent_commands", "migration_agent_commands")

    Repo.query!(terminal_audit_sql)

    assert %Postgrex.Result{rows: [["failed", "default"]]} =
             Repo.query!(
               """
               SELECT state, dispatch_partition_id
               FROM migration_secure_execution_attempts
               WHERE command_id = $1::uuid
               """,
               [command_id]
             )

    assert %Postgrex.Result{rows: [[0]]} =
             Repo.query!("""
             SELECT count(*)
             FROM migration_secure_execution_attempts
             WHERE state IN ('planned', 'dispatching', 'dispatched', 'processing', 'waiting')
             """)
  end
end
