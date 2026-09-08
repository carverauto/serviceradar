defmodule ServiceRadar.Automation.Ansible.SecureExecutionPartitionMigrationTest do
  use ExUnit.Case, async: true

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20260713150000_add_callback_candidate_job_cleanup_queue.exs",
                    __DIR__
                  )
  @external_resource @migration_path
  @agent_commands_migration_path Path.expand(
                                   "../../../../priv/repo/migrations/20260204120000_add_agent_commands.exs",
                                   __DIR__
                                 )
  @external_resource @agent_commands_migration_path

  test "terminal audit enrichment joins the real AgentCommand table and physical primary key" do
    migration = File.read!(@migration_path)
    agent_commands = File.read!(@agent_commands_migration_path)

    assert agent_commands =~
             "create table(:agent_commands, primary_key: false, prefix: \"platform\")"

    assert agent_commands =~ "add :command_id, :uuid,"
    assert agent_commands =~ "primary_key: true"

    assert migration =~ "FROM platform.agent_commands AS command"
    assert migration =~ "WHERE command.command_id = attempt.command_id"
    assert migration =~ "command.agent_id = attempt.dispatch_agent_id"
    assert migration =~ "command.sent_at IS NOT NULL"
    assert migration =~ "NULLIF(BTRIM(command.partition_id), '') IS NOT NULL"

    refute migration =~ "platform.edge_agent_commands"
    refute migration =~ "command.id = attempt.command_id"
  end

  test "legacy active attempts are quarantined before default partition can be audit-enriched" do
    migration = File.read!(@migration_path)

    quarantine = "execute(@secure_attempt_quarantine_sql)"
    backfill = "execute(@secure_attempt_terminal_audit_sql)"

    {quarantine_offset, _} = :binary.match(migration, quarantine)
    {backfill_offset, _} = :binary.match(migration, backfill)

    assert quarantine_offset < backfill_offset

    assert migration =~
             "WHERE state IN ('planned', 'dispatching', 'dispatched', 'processing', 'waiting')"

    assert migration =~
             "outcome_code = COALESCE(outcome_code, 'unproven_dispatch_partition')"

    assert migration =~
             "last_error_code = COALESCE(last_error_code, 'unproven_dispatch_partition')"

    assert migration =~ "next_attempt_at = NULL"
    assert migration =~ "lease_token = NULL"
    assert migration =~ "lease_expires_at = NULL"

    # A legacy command whose partition is merely the historical `default` may
    # enrich the audit field only after its attempt is terminal. The backfill
    # cannot leave or restore an authoritative active state.
    assert migration =~ "attempt.state IN ('succeeded', 'failed', 'ambiguous')"
  end

  test "only terminal rows may omit a pre-send-bound partition after migration" do
    migration = File.read!(@migration_path)

    assert migration =~
             "state IN ('succeeded', 'failed', 'ambiguous') OR (dispatch_partition_id IS NOT NULL AND BTRIM(dispatch_partition_id) <> '')"
  end

  test "rollback fails closed when rows exceed the legacy cleanup bound" do
    migration = File.read!(@migration_path)

    guard = "WHERE cardinality(candidate_job_ids) > 50"
    old_constraint = "AND cardinality(candidate_job_ids) <= 50\n"

    {guard_offset, _} = :binary.match(migration, guard)
    {constraint_offset, _} = :binary.match(migration, old_constraint)

    assert guard_offset < constraint_offset

    assert migration =~
             "FROM platform.automation_callback_command_attempts"

    assert migration =~
             "AND (cleanup_only = true OR cardinality(candidate_job_ids) > 0)"

    assert migration =~
             "cannot roll back candidate cleanup queue: active containment state is not representable by the legacy schema"
  end
end
