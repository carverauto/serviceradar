defmodule ServiceRadar.Edge.AuthorityHistoryDbTest do
  @moduledoc """
  The append-only authority history late admission judges records against
  (openspec add-edge-production-time-admission, design Decision 4). The oracle is the design's
  interval rules, not the trigger's own code: an active row opens an interval, an epoch or state
  change closes it with the recorded cause and opens the next only while the row is active, a
  delete closes without a successor, a write that bypasses Ash is recorded all the same, and an
  interval once closed can never be rewritten.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Edge.OutputGrants
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.Repo

  @moduletag :integration
  @contract "serviceradar.metrics.batch"

  setup do
    actor = ServiceRadar.Actors.SystemActor.system(:authority_history_test)
    slug = "history-#{System.unique_integer([:positive])}"

    partition =
      Partition
      |> Ash.Changeset.for_create(:create, %{name: slug, slug: slug}, actor: actor)
      |> Ash.create!()

    {:ok, scope: partition.id, agent: "agent-history-#{System.unique_integer([:positive])}"}
  end

  defp intervals(grant_id) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT authority_epoch, active_until IS NULL, ended_reason
          FROM platform.edge_authority_history
         WHERE assignment_id = $1
         ORDER BY id
        """,
        [Ecto.UUID.dump!(grant_id)]
      )

    Enum.map(rows, fn [epoch, open?, reason] -> {epoch, open?, reason} end)
  end

  test "a grant's revocation cause closes its interval, and only an active grant opens one",
       ctx do
    {:ok, grant} = OutputGrants.reconcile(ctx.agent, @contract, ctx.scope)
    assert intervals(grant.id) == [{1, true, nil}]

    # A revoked certificate ends the interval for good; the revoked row has no live epoch.
    assert {:ok, 1} = OutputGrants.revoke_agent(ctx.agent, :certificate_revoked)
    assert intervals(grant.id) == [{1, false, "certificate_revoked"}]

    # Reactivation opens a new interval at the new epoch; supersession closes it normally.
    {:ok, reactivated} = OutputGrants.reconcile(ctx.agent, @contract, ctx.scope)
    assert reactivated.authority_epoch == 3
    assert {:ok, 1} = OutputGrants.revoke_agent(ctx.agent, :identity_superseded)

    assert intervals(grant.id) == [
             {1, false, "certificate_revoked"},
             {3, false, "identity_superseded"}
           ]
  end

  test "a write that bypasses Ash and a delete are recorded, and a delete opens no successor",
       ctx do
    {:ok, grant} = OutputGrants.reconcile(ctx.agent, @contract, ctx.scope)
    id = Ecto.UUID.dump!(grant.id)

    Repo.query!(
      "UPDATE platform.edge_output_grants SET authority_epoch = authority_epoch + 1, epoch_changed_at = now() WHERE id = $1",
      [id]
    )

    assert intervals(grant.id) == [{1, false, "epoch_changed"}, {2, true, nil}]

    Repo.query!("DELETE FROM platform.edge_output_grants WHERE id = $1", [id])
    assert intervals(grant.id) == [{1, false, "epoch_changed"}, {2, false, "deleted"}]
  end

  test "an epoch bump that does not advance epoch_changed_at still closes a non-empty interval",
       ctx do
    {:ok, grant} = OutputGrants.reconcile(ctx.agent, @contract, ctx.scope)
    id = Ecto.UUID.dump!(grant.id)

    Repo.query!(
      "UPDATE platform.edge_output_grants SET authority_epoch = authority_epoch + 1 WHERE id = $1",
      [id]
    )

    Repo.query!(
      "UPDATE platform.edge_output_grants SET authority_epoch = authority_epoch + 1, epoch_changed_at = now() WHERE id = $1",
      [id]
    )

    %{rows: rows} =
      Repo.query!(
        """
        SELECT authority_epoch, active_from, active_until
          FROM platform.edge_authority_history
         WHERE assignment_id = $1
         ORDER BY id
        """,
        [id]
      )

    assert [[1, from1, until1], [2, from2, until2], [3, from3, nil]] = rows

    # Each closed epoch covers a real span, and its successor starts exactly where it ended,
    # so a record produced while an epoch was live always falls inside one interval.
    assert DateTime.after?(until1, from1)
    assert from2 == until1
    assert DateTime.after?(until2, from2)
    assert from3 == until2
  end

  test "a closed interval cannot be rewritten", ctx do
    {:ok, grant} = OutputGrants.reconcile(ctx.agent, @contract, ctx.scope)
    assert {:ok, 1} = OutputGrants.revoke_agent(ctx.agent, :certificate_revoked)
    id = Ecto.UUID.dump!(grant.id)

    assert_raise Postgrex.Error, ~r/immutable/, fn ->
      Repo.query!(
        "UPDATE platform.edge_authority_history SET ended_reason = 'identity_superseded' WHERE assignment_id = $1",
        [id]
      )
    end
  end

  test "an open interval's epoch and binding cannot be rewritten", ctx do
    {:ok, grant} = OutputGrants.reconcile(ctx.agent, @contract, ctx.scope)
    id = Ecto.UUID.dump!(grant.id)

    assert_raise Postgrex.Error, ~r/immutable/, fn ->
      Repo.query!(
        "UPDATE platform.edge_authority_history SET authority_epoch = 7 WHERE assignment_id = $1",
        [id]
      )
    end
  end
end
