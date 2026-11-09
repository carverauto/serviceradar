defmodule ServiceRadar.Edge.RecoveryAssignmentsDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Edge.RecoveryAssignmentEvidence, as: Evidence
  alias ServiceRadar.Edge.RecoveryAssignmentIssuance, as: Issuance
  alias ServiceRadar.Edge.RecoveryAssignments, as: Assignments
  alias ServiceRadar.RecoveryAssignmentFixtures
  alias ServiceRadar.Repo

  require Ash.Query

  @moduletag :integration

  setup do
    ctx = RecoveryAssignmentFixtures.fixture()
    {:ok, [entry]} = Evidence.sweep(ctx.capability, ctx.slot, ctx.key.public_key)
    {:ok, Map.put(ctx, :entry, entry)}
  end

  test "positive and explicit-negative replays retain one original issuance and never convert a miss to negative",
       ctx do
    assert :missing = lookup(ctx)
    assert {:ok, :committed} = Assignments.commit_issuance([ctx.entry])
    assert {:ok, :committed} = Assignments.commit_issuance([ctx.entry])
    assert {:found, value} = lookup(ctx)
    assert value["execution_id"] == Base.encode16(ctx.slot.execution_id, case: :lower)
    assert [_] = originals(ctx.entry.key)

    passive = RecoveryAssignmentFixtures.fixture(:standing)
    {:ok, negative} = Evidence.standing(passive.capability, passive.key.public_key)
    assert :missing = lookup(passive)
    assert {:ok, :committed} = Assignments.commit_issuance([negative])
    assert {:ok, :committed} = Assignments.commit_issuance([negative])
    assert {:not_scheduled, %{"reason" => "standing_output_grant"}} = lookup(passive)
    assert [_] = originals(negative.key)
  end

  test "a differing candidate quarantines lookup until a fenced, append-only selection", ctx do
    {:ok, :committed} = Assignments.commit_issuance([ctx.entry])
    [first] = originals(ctx.entry.key)

    changed_slot = %{
      ctx.slot
      | plan_header: %{
          ctx.slot.plan_header
          | execution_plan_id: Ecto.UUID.dump!(Ash.UUID.generate())
        }
    }

    {:ok, [second_entry]} = Evidence.sweep(ctx.capability, changed_slot, ctx.key.public_key)
    assert {:ok, :conflicting} = Assignments.commit_issuance([second_entry])
    assert :conflicting = lookup(ctx)
    [second] = Enum.reject(originals(ctx.entry.key), &(&1.id == first.id))

    {:ok, old} = Assignments.acquire_resolver(ctx.entry.key)
    {:ok, current} = Assignments.acquire_resolver(ctx.entry.key)
    assert {:ok, :stale_resolver} = select(ctx, old, first.id)

    assert {:ok, :future_resolver} =
             select(ctx, %{current | resolver_epoch: current.resolver_epoch + 1}, first.id)

    assert {:ok, :changed_candidates} =
             select(
               ctx,
               %{current | candidate_generation: current.candidate_generation + 1},
               first.id
             )

    assert :conflicting = lookup(ctx)

    assert {:ok, :selected} = select(ctx, current, second.id)
    assert {:ok, :selected} = select(ctx, current, second.id)

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM platform.edge_recovery_assignment_resolutions WHERE issuance_id = $1 AND outcome = 'selected'",
               [Ecto.UUID.dump!(second.id)]
             )

    assert {:ok, :selection_conflict} = select(ctx, current, first.id)
    {:ok, later} = Assignments.acquire_resolver(ctx.entry.key)
    assert later.resolver_epoch > current.resolver_epoch
    assert {:ok, :selection_conflict} = select(ctx, later, first.id)
    assert {:found, selected} = lookup(ctx)
    assert selected["plan"]["id"] == second_entry.value["plan"]["id"]
    assert length(originals(ctx.entry.key)) == 2
    assert {:ok, :committed} = Assignments.commit_issuance([second_entry])
    assert {:ok, :conflicting} = Assignments.commit_issuance([ctx.entry])

    # Storage corruption creating contradictory accepted decisions must not pick the latest row.
    Repo.query!(
      "UPDATE platform.edge_recovery_assignment_resolutions SET outcome = 'selected' WHERE issuance_id = $1 AND outcome = 'selection_conflict'",
      [Ecto.UUID.dump!(first.id)]
    )

    assert :conflicting = lookup(ctx)
  end

  test "a later candidate invalidates the old selection and its captured generation", ctx do
    {:ok, :committed} = Assignments.commit_issuance([ctx.entry])
    [first] = originals(ctx.entry.key)
    {:ok, old} = Assignments.acquire_resolver(ctx.entry.key)
    assert {:ok, :selected} = select(ctx, old, first.id)

    slot = %{
      ctx.slot
      | plan_header: %{
          ctx.slot.plan_header
          | execution_plan_id: Ecto.UUID.dump!(Ash.UUID.generate())
        }
    }

    {:ok, [entry]} = Evidence.sweep(ctx.capability, slot, ctx.key.public_key)
    assert {:ok, :conflicting} = Assignments.commit_issuance([entry])
    assert :conflicting = lookup(ctx)
    assert {:ok, :changed_candidates} = select(ctx, old, first.id)
  end

  test "missing membership is repaired only from independently retained original evidence", ctx do
    {:ok, :committed} = Assignments.commit_issuance([ctx.entry])
    [original] = originals(ctx.entry.key)

    Repo.query!(
      "DELETE FROM platform.edge_recovery_assignment_candidates WHERE issuance_id = $1",
      [
        Ecto.UUID.dump!(original.id)
      ]
    )

    assert :missing = lookup(ctx)
    assert {:error, :missing_original_issuance} = Assignments.repair(Ash.UUID.generate())
    assert {:error, :missing} = Assignments.commit_issuance([ctx.entry])
    assert {:ok, :committed} = Assignments.repair(original.id)
    assert {:found, _} = lookup(ctx)

    Repo.query!(
      "UPDATE platform.edge_recovery_assignment_issuances SET evidence = '{}' WHERE id = $1",
      [
        Ecto.UUID.dump!(original.id)
      ]
    )

    assert :corrupt = lookup(ctx)
    assert {:error, :corrupt} = Assignments.repair(original.id)
    assert {:error, :invalid_issuance} = Assignments.commit_issuance([%{ctx.entry | proof: %{}}])
  end

  defp lookup(ctx), do: Assignments.lookup(ctx.scope, ctx.agent, ctx.span)

  defp select(ctx, token, id),
    do: Assignments.resolve(ctx.entry.key, token.resolver_epoch, token.candidate_generation, id)

  defp originals(key),
    do:
      Issuance
      |> Ash.Query.filter(mapping_key == ^key)
      |> Ash.read!(actor: ServiceRadar.Actors.SystemActor.system(:mapping_test))
end
