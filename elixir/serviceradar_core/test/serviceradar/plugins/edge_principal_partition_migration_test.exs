defmodule ServiceRadar.Plugins.EdgePrincipalPartitionMigrationTest do
  use ExUnit.Case, async: true

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20260713140000_bind_edge_principals_to_partitions.exs",
                    __DIR__
                  )
  @external_resource @migration_path
  @assignment_path Path.expand(
                     "../../../lib/serviceradar/plugins/plugin_assignment.ex",
                     __DIR__
                   )
  @external_resource @assignment_path

  test "legacy assignments are quarantined without trusting current Agent metadata" do
    migration = File.read!(@migration_path)

    assert migration =~ "UPDATE platform.plugin_assignments"
    assert migration =~ "SET enabled = false,\n        partition_id = NULL"
    refute migration =~ "FROM platform.ocsf_agents"
    refute migration =~ "metadata->>'partition_id'"
  end

  test "source-key identity and indexes bind the full edge principal partition" do
    migration = File.read!(@migration_path)

    assert migration =~
             "ON platform.plugin_assignments (partition_id, source, source_key)"

    assert migration =~
             "ON platform.plugin_assignments (partition_id, agent_uid, plugin_id)"

    assert migration =~
             "ON platform.plugin_assignments (partition_id, agent_uid, plugin_package_id)"
  end

  test "source-key lookup cannot resolve globally across partitions" do
    resource = File.read!(@assignment_path)

    assert resource =~ "read :by_partition_source_key do"
    assert resource =~ "argument :partition_id, :string, allow_nil?: false"
    refute resource =~ "read :by_source_key do"
  end

  test "legacy callback authority is quarantined before terminal audit enrichment" do
    migration = File.read!(@migration_path)

    assert length(Regex.scan(~r/command\.sent_at IS NOT NULL/, migration)) == 2
    assert migration =~ "execute(@legacy_envelope_quarantine_sql)"
    assert migration =~ "execute(@legacy_grant_quarantine_sql)"
    assert migration =~ "execute(@legacy_attempt_quarantine_sql)"

    {quarantine_offset, _} = :binary.match(migration, "execute(@legacy_attempt_quarantine_sql)")

    {audit_offset, _} =
      :binary.match(migration, "UPDATE platform.automation_launch_envelopes AS envelope")

    assert quarantine_offset < audit_offset
    assert migration =~ "AND envelope.state = 'expired'"
    assert migration =~ "AND callback_grant.state IN ('revoked', 'expired', 'consumed')"
    assert migration =~ "AND attempt.state IN ('succeeded', 'failed', 'ambiguous')"

    assert migration =~
             "revocation_reason = COALESCE(revocation_reason, 'unproven_dispatch_partition')"

    assert migration =~
             "WHERE state IN ('planned', 'dispatching', 'dispatched', 'processing', 'waiting')"
  end

  test "down restores all three legacy plugin index definitions" do
    migration = File.read!(@migration_path)

    legacy_indexes = [
      {"plugin_assignments_one_enabled_per_agent_plugin_index",
       "ON platform.plugin_assignments (agent_uid, plugin_id)\n    WHERE enabled = true"},
      {"plugin_assignments_unique_manual_agent_package_index",
       "ON platform.plugin_assignments (agent_uid, plugin_package_id)\n    WHERE source = 'manual'"},
      {"plugin_assignments_unique_source_key_index",
       "ON platform.plugin_assignments (source, source_key)\n    WHERE source_key IS NOT NULL"}
    ]

    for {name, ddl} <- legacy_indexes do
      assert migration =~ "CREATE UNIQUE INDEX IF NOT EXISTS #{name}"
      assert migration =~ ddl
    end

    assert migration =~
             "cannot roll back partition-bound plugin assignments: cross-partition identities would collide"
  end
end
