defmodule ServiceRadar.Edge.RecordTrustTerminalIntervalsDbTest do
  @moduledoc """
  The trust document's terminal-interval list (openspec add-edge-production-time-admission,
  design Decision 4, task 2.6a): every authority interval that ended `certificate_revoked` or
  `revoked_cause_unknown`, named once, so a gateway or agent quarantines a late record naming one
  whoever presents it. The list is never pruned, so it is bounded by its own cap and the document
  fails closed past it, exactly like the assignment cap.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.RecordTrust
  alias ServiceRadar.Repo

  @moduletag :integration

  @key IssuerKey.from_seed(:binary.copy(<<0x6B>>, 32))

  setup do
    suffix = System.unique_integer([:positive])
    {:ok, agent: "agent-terminal-#{suffix}", other: "agent-terminal-other-#{suffix}"}
  end

  defp insert_interval!(agent, assignment, scope, epoch, reason) do
    now = DateTime.utc_now()
    until = if reason, do: DateTime.shift(now, day: -1)

    Repo.query!(
      """
      INSERT INTO platform.edge_authority_history
        (assignment_id, assignment_kind, agent_id, network_scope_id, run_shard,
         authority_epoch, active_from, active_until, ended_reason)
      VALUES ($1::uuid, 'output_grant', $2, $3::uuid, 0, $4, $5, $6, $7)
      """,
      [assignment, agent, scope, epoch, DateTime.shift(now, day: -10), until, reason]
    )
  end

  defp entry(assignment, scope, epoch) do
    %{
      "network_scope_id" => Base.encode64(scope),
      "producer_assignment_id" => Base.encode64(assignment),
      "run_shard" => 0,
      "authority_epoch" => epoch
    }
  end

  defp terminals(document, assignments) do
    ids = MapSet.new(assignments, &Base.encode64/1)

    document["terminal_intervals"]
    |> Enum.filter(&MapSet.member?(ids, &1["producer_assignment_id"]))
    |> Enum.sort()
  end

  test "names each terminal interval once, and an agent's own document names only its own", ctx do
    scope = Ecto.UUID.bingenerate()
    revoked = Ecto.UUID.bingenerate()
    unknown = Ecto.UUID.bingenerate()
    ordinary = Ecto.UUID.bingenerate()

    # Two closed rows of the same epoch would name one interval twice; the list names it once.
    insert_interval!(ctx.agent, revoked, scope, 2, "certificate_revoked")
    insert_interval!(ctx.agent, revoked, scope, 2, "certificate_revoked")
    insert_interval!(ctx.other, unknown, scope, 5, "revoked_cause_unknown")
    # Ordinary, compromised and open intervals are not terminal.
    insert_interval!(ctx.agent, ordinary, scope, 1, "epoch_changed")
    insert_interval!(ctx.agent, ordinary, scope, 3, "compromised")
    insert_interval!(ctx.agent, ordinary, scope, 4, nil)

    assert {:ok, global} = RecordTrust.snapshot(@key)

    assert terminals(global, [revoked, unknown, ordinary]) ==
             Enum.sort([entry(revoked, scope, 2), entry(unknown, scope, 5)])

    # An agent's document carries its own terminal intervals, even with no partition bound.
    assert {:ok, own} = RecordTrust.agent_snapshot(ctx.agent, Ecto.UUID.generate(), @key)
    assert own["terminal_intervals"] == [entry(revoked, scope, 2)]
  end

  test "the global list fails closed past its cap, exactly like the assignment cap" do
    assert RecordTrust.max_terminal_intervals() == 100_000

    %{rows: [[existing]]} =
      Repo.query!("""
      SELECT count(*) FROM (
        SELECT DISTINCT assignment_id, network_scope_id, run_shard, authority_epoch
          FROM platform.edge_authority_history
         WHERE ended_reason IN ('certificate_revoked', 'revoked_cause_unknown')
      ) AS terminal
      """)

    insert_terminals = fn count ->
      Repo.query!(
        """
        INSERT INTO platform.edge_authority_history
          (assignment_id, assignment_kind, agent_id, network_scope_id, run_shard,
           authority_epoch, active_from, active_until, ended_reason)
        SELECT gen_random_uuid(), 'output_grant', 'agent-terminal-cap', gen_random_uuid(), 0, 1,
               now() - interval '2 days', now() - interval '1 day', 'certificate_revoked'
          FROM generate_series(1, $1)
        """,
        [count]
      )
    end

    insert_terminals.(100_000 - existing)
    assert {:ok, document} = RecordTrust.snapshot(@key)
    assert length(document["terminal_intervals"]) == 100_000

    insert_terminals.(1)
    assert {:error, :trust_snapshot_too_large} = RecordTrust.snapshot(@key)
  end
end
