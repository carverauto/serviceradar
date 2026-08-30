defmodule ServiceRadar.SweepJobs.SweepGroupAgentIdsMigrationDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.Migrations.AddSweepGroupAgentIds

  @moduletag :integration

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20260830120000_add_sweep_group_agent_ids.exs",
                    __DIR__
                  )

  Code.require_file(@migration_path)

  setup do
    table = "sweep_group_agent_ids_#{System.unique_integer([:positive, :monotonic])}"

    Repo.query!("""
    CREATE TEMPORARY TABLE #{table} (
      id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      agent_id text,
      agent_ids text[]
    ) ON COMMIT DROP
    """)

    Repo.query!(AddSweepGroupAgentIds.backfill_sql(table))
    Repo.query!(AddSweepGroupAgentIds.compatibility_function_sql())
    Repo.query!(AddSweepGroupAgentIds.compatibility_trigger_sql(table))

    {:ok, table: table}
  end

  test "backfills nil, blank, and scalar legacy assignments", %{table: table} do
    Repo.query!("INSERT INTO #{table} (agent_id) VALUES (NULL), ('  '), ('agent-b')")
    Repo.query!(AddSweepGroupAgentIds.backfill_sql(table))

    assert %{rows: [[nil, []], ["  ", []], ["agent-b", ["agent-b"]]]} =
             Repo.query!("SELECT agent_id, agent_ids FROM #{table} ORDER BY id")
  end

  test "the trigger mirrors old scalar writers without collapsing a multi-agent assignment", %{
    table: table
  } do
    Repo.query!("INSERT INTO #{table} (agent_id) VALUES ('agent-b')")

    assert %{rows: [["agent-b", ["agent-b"]]]} =
             Repo.query!("SELECT agent_id, agent_ids FROM #{table}")

    Repo.query!(
      "UPDATE #{table} SET agent_ids = ARRAY['agent-b', 'agent-a'], agent_id = 'agent-a'"
    )

    Repo.query!("UPDATE #{table} SET agent_id = 'agent-a'")

    assert %{rows: [["agent-a", ["agent-a", "agent-b"]]]} =
             Repo.query!("SELECT agent_id, agent_ids FROM #{table}")
  end

  test "an array-aware writer retains a multi-agent subset and its scalar bridge", %{table: table} do
    Repo.query!("INSERT INTO #{table} (agent_id) VALUES ('agent-a')")

    Repo.query!(
      "UPDATE #{table} SET agent_ids = ARRAY['agent-c', 'agent-a'], agent_id = 'agent-a'"
    )

    assert %{rows: [["agent-a", ["agent-a", "agent-c"]]]} =
             Repo.query!("SELECT agent_id, agent_ids FROM #{table}")
  end

  test "the migration retains the scalar column while adding the canonical array contract" do
    migration = File.read!(@migration_path)

    assert migration =~ "ARRAY[]::text[]"
    assert migration =~ "sweep_groups_agent_ids_gin_idx"
    assert migration =~ "platform.sweep_groups_agent_ids_compat"
    assert migration =~ "platform.sweep_groups"
    refute migration =~ "remove :agent_id"
  end
end
