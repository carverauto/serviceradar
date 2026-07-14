defmodule ServiceRadar.Repo.Migrations.BindEdgePrincipalsToPartitions do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  @legacy_envelope_quarantine_sql """
  UPDATE platform.automation_launch_envelopes
  SET state = 'expired',
      expired_at = COALESCE(expired_at, now() AT TIME ZONE 'utc'),
      resolved_at = NULL,
      resolved_by_agent_id = NULL,
      resolved_by_partition_id = NULL,
      updated_at = now() AT TIME ZONE 'utc'
  WHERE state IN ('sealed', 'resolved')
  """

  @legacy_grant_quarantine_sql """
  UPDATE platform.automation_callback_grants
  SET state = 'revoked',
      revoked_at = COALESCE(revoked_at, now() AT TIME ZONE 'utc'),
      revocation_reason = COALESCE(revocation_reason, 'unproven_dispatch_partition'),
      updated_at = now() AT TIME ZONE 'utc'
  WHERE state IN ('pending', 'active')
  """

  @legacy_attempt_quarantine_sql """
  UPDATE platform.automation_callback_command_attempts
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

  @terminal_attempt_command_audit_sql """
  UPDATE platform.automation_callback_command_attempts AS attempt
  SET dispatch_partition_id = NULLIF(BTRIM(command.partition_id), '')
  FROM platform.agent_commands AS command
  WHERE command.command_id = attempt.command_id
    AND command.agent_id = attempt.dispatch_agent_id
    AND command.sent_at IS NOT NULL
    AND NULLIF(BTRIM(command.partition_id), '') IS NOT NULL
    AND attempt.state IN ('succeeded', 'failed', 'ambiguous')
  """

  @doc false
  def legacy_envelope_quarantine_sql, do: @legacy_envelope_quarantine_sql

  @doc false
  def legacy_grant_quarantine_sql, do: @legacy_grant_quarantine_sql

  @doc false
  def legacy_attempt_quarantine_sql, do: @legacy_attempt_quarantine_sql

  @doc false
  def terminal_attempt_command_audit_sql, do: @terminal_attempt_command_audit_sql

  def up do
    # serviceradar:allow-startup-maintenance - legacy assignments and live
    # callback chains have no trustworthy partition provenance, so they must be
    # disabled or quarantined before partition constraints admit application
    # traffic. The audit enrichment never revives authority; every operation is
    # a finite-table statement protected by transaction-local startup deadlines.
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '2min'")

    alter table(:plugin_assignments, prefix: @prefix) do
      add :partition_id, :text
    end

    # A current ocsf_agents row is not historical provenance: the same UID may
    # have re-enrolled in another partition. No legacy assignment stored an
    # immutable partition, so every one must be reconciled/reapproved before it
    # can become live under the new tuple.
    execute("""
    UPDATE platform.plugin_assignments
    SET enabled = false,
        partition_id = NULL,
        updated_at = now() AT TIME ZONE 'utc'
    """)

    execute("DROP INDEX IF EXISTS platform.plugin_assignments_one_enabled_per_agent_plugin_index")
    execute("DROP INDEX IF EXISTS platform.plugin_assignments_unique_manual_agent_package_index")
    execute("DROP INDEX IF EXISTS platform.plugin_assignments_unique_source_key_index")

    execute("""
    CREATE UNIQUE INDEX plugin_assignments_one_enabled_per_edge_plugin_index
    ON platform.plugin_assignments (partition_id, agent_uid, plugin_id)
    WHERE enabled = true
    """)

    execute("""
    CREATE UNIQUE INDEX plugin_assignments_unique_manual_edge_package_index
    ON platform.plugin_assignments (partition_id, agent_uid, plugin_package_id)
    WHERE source = 'manual'
    """)

    execute("""
    CREATE UNIQUE INDEX plugin_assignments_unique_partition_source_key_index
    ON platform.plugin_assignments (partition_id, source, source_key)
    WHERE source_key IS NOT NULL
    """)

    create constraint(:plugin_assignments, :plugin_assignments_enabled_partition_required,
             prefix: @prefix,
             check: "enabled = false OR (partition_id IS NOT NULL AND BTRIM(partition_id) <> '')"
           )

    alter table(:automation_callback_grants, prefix: @prefix) do
      add :dispatch_partition_id, :text
    end

    alter table(:automation_launch_envelopes, prefix: @prefix) do
      add :dispatch_partition_id, :text
      add :resolved_by_partition_id, :text
    end

    alter table(:automation_callback_command_attempts, prefix: @prefix) do
      add :dispatch_partition_id, :text
    end

    # `agent_commands.partition_id` historically defaulted to `default`, so it
    # cannot prove which authenticated edge partition authorized an existing
    # chain. Quarantine every pre-migration live chain before enriching any
    # terminal row for audit. Audit enrichment below must never retain or revive
    # authority.
    execute(@legacy_envelope_quarantine_sql)
    execute(@legacy_grant_quarantine_sql)
    execute(@legacy_attempt_quarantine_sql)

    execute("""
    UPDATE platform.automation_launch_envelopes AS envelope
    SET dispatch_partition_id = NULLIF(BTRIM(command.partition_id), '')
    FROM platform.agent_commands AS command
    WHERE command.command_id = envelope.command_id
      AND envelope.dispatch_agent_id = command.agent_id
      AND command.sent_at IS NOT NULL
      AND NULLIF(BTRIM(command.partition_id), '') IS NOT NULL
      AND envelope.state = 'expired'
    """)

    execute("""
    UPDATE platform.automation_callback_grants AS callback_grant
    SET dispatch_partition_id = envelope.dispatch_partition_id
    FROM platform.automation_launch_envelopes AS envelope
    WHERE envelope.callback_grant_id = callback_grant.id
      AND envelope.dispatch_agent_id = callback_grant.dispatch_agent_id
      AND envelope.dispatch_partition_id IS NOT NULL
      AND callback_grant.state IN ('revoked', 'expired', 'consumed')
    """)

    execute(@terminal_attempt_command_audit_sql)

    execute("""
    UPDATE platform.automation_callback_command_attempts AS attempt
    SET dispatch_partition_id = callback_grant.dispatch_partition_id
    FROM platform.automation_callback_grants AS callback_grant
    WHERE callback_grant.id = attempt.grant_id
      AND callback_grant.dispatch_agent_id = attempt.dispatch_agent_id
      AND attempt.dispatch_partition_id IS NULL
      AND callback_grant.dispatch_partition_id IS NOT NULL
      AND attempt.state IN ('succeeded', 'failed', 'ambiguous')
    """)

    # Defensive idempotence for malformed historical rows that could not be
    # audit-enriched. All legitimate pre-migration live rows were already
    # quarantined above, regardless of the historical command default.
    execute("""
    UPDATE platform.automation_launch_envelopes
    SET state = 'expired',
        expired_at = COALESCE(expired_at, now() AT TIME ZONE 'utc'),
        resolved_at = NULL,
        resolved_by_agent_id = NULL,
        resolved_by_partition_id = NULL,
        updated_at = now() AT TIME ZONE 'utc'
    WHERE state IN ('sealed', 'resolved')
      AND (
        dispatch_partition_id IS NULL
        OR (
          state = 'resolved'
          AND (
            resolved_by_agent_id IS DISTINCT FROM dispatch_agent_id
            OR resolved_by_partition_id IS DISTINCT FROM dispatch_partition_id
          )
        )
      )
    """)

    execute("""
    UPDATE platform.automation_callback_grants
    SET state = 'revoked',
        revoked_at = COALESCE(revoked_at, now() AT TIME ZONE 'utc'),
        revocation_reason = COALESCE(revocation_reason, 'unproven_dispatch_partition'),
        updated_at = now() AT TIME ZONE 'utc'
    WHERE state IN ('pending', 'active')
      AND dispatch_partition_id IS NULL
    """)

    execute("""
    UPDATE platform.automation_callback_command_attempts
    SET state = 'failed',
        processed_at = COALESCE(processed_at, now() AT TIME ZONE 'utc'),
        outcome_code = COALESCE(outcome_code, 'unproven_dispatch_partition'),
        last_error_code = COALESCE(last_error_code, 'unproven_dispatch_partition'),
        next_attempt_at = NULL,
        lease_token = NULL,
        lease_expires_at = NULL,
        updated_at = now() AT TIME ZONE 'utc'
    WHERE state IN ('planned', 'dispatching', 'dispatched', 'processing', 'waiting')
      AND dispatch_partition_id IS NULL
    """)

    create constraint(:automation_launch_envelopes, :automation_launch_envelopes_partition,
             prefix: @prefix,
             check:
               "state = 'expired' OR (" <>
                 "dispatch_partition_id IS NOT NULL AND BTRIM(dispatch_partition_id) <> '' AND (" <>
                 "state = 'sealed' OR (state = 'resolved' AND " <>
                 "resolved_by_agent_id = dispatch_agent_id AND " <>
                 "resolved_by_partition_id = dispatch_partition_id)))"
           )

    create constraint(:automation_callback_grants, :automation_callback_grants_partition,
             prefix: @prefix,
             check:
               "state IN ('revoked', 'expired', 'consumed') OR (dispatch_partition_id IS NOT NULL AND BTRIM(dispatch_partition_id) <> '')"
           )

    create constraint(
             :automation_callback_command_attempts,
             :automation_callback_command_attempts_partition,
             prefix: @prefix,
             check:
               "state IN ('succeeded', 'failed', 'ambiguous') OR (dispatch_partition_id IS NOT NULL AND BTRIM(dispatch_partition_id) <> '')"
           )
  end

  def down do
    # The old schema cannot represent two partition-scoped assignments that
    # collapse to the same global key. Abort the transactional rollback before
    # dropping partition data instead of deleting authority records or failing
    # later with a partially explained unique-index violation.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM platform.plugin_assignments
        WHERE enabled = true
        GROUP BY agent_uid, plugin_id
        HAVING count(*) > 1
      ) OR EXISTS (
        SELECT 1
        FROM platform.plugin_assignments
        WHERE source = 'manual'
        GROUP BY agent_uid, plugin_package_id
        HAVING count(*) > 1
      ) OR EXISTS (
        SELECT 1
        FROM platform.plugin_assignments
        WHERE source_key IS NOT NULL
        GROUP BY source, source_key
        HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION
          'cannot roll back partition-bound plugin assignments: cross-partition identities would collide';
      END IF;
    END
    $$
    """)

    drop_if_exists constraint(
                     :automation_callback_command_attempts,
                     :automation_callback_command_attempts_partition,
                     prefix: @prefix
                   )

    drop_if_exists constraint(:automation_callback_grants, :automation_callback_grants_partition,
                     prefix: @prefix
                   )

    drop_if_exists constraint(
                     :automation_launch_envelopes,
                     :automation_launch_envelopes_partition,
                     prefix: @prefix
                   )

    alter table(:automation_callback_command_attempts, prefix: @prefix) do
      remove :dispatch_partition_id
    end

    alter table(:automation_launch_envelopes, prefix: @prefix) do
      remove :resolved_by_partition_id
      remove :dispatch_partition_id
    end

    alter table(:automation_callback_grants, prefix: @prefix) do
      remove :dispatch_partition_id
    end

    drop_if_exists constraint(:plugin_assignments, :plugin_assignments_enabled_partition_required,
                     prefix: @prefix
                   )

    execute("DROP INDEX IF EXISTS platform.plugin_assignments_unique_partition_source_key_index")
    execute("DROP INDEX IF EXISTS platform.plugin_assignments_unique_manual_edge_package_index")
    execute("DROP INDEX IF EXISTS platform.plugin_assignments_one_enabled_per_edge_plugin_index")

    alter table(:plugin_assignments, prefix: @prefix) do
      remove :partition_id
    end

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS plugin_assignments_one_enabled_per_agent_plugin_index
    ON platform.plugin_assignments (agent_uid, plugin_id)
    WHERE enabled = true
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS plugin_assignments_unique_manual_agent_package_index
    ON platform.plugin_assignments (agent_uid, plugin_package_id)
    WHERE source = 'manual'
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS plugin_assignments_unique_source_key_index
    ON platform.plugin_assignments (source, source_key)
    WHERE source_key IS NOT NULL
    """)
  end
end
