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

  # Every entry kind the commit decides, interleaved in one batch. The expected
  # state of each lane is the specified mapping behaviour (first value selects
  # itself, a differing value quarantines the projection, same-value replay is a
  # no-op, a captured resolver token is fenced by a new candidate), and the same
  # entries committed one at a time must leave exactly the same state.
  test "a mixed batch decides every entry as one-at-a-time commits do" do
    batched = mixed_world()
    single = mixed_world()

    assert {:ok, :conflicting} = Assignments.commit_issuance(mixed_batch(batched))

    outcomes = Enum.map(mixed_batch(single), &Assignments.commit_issuance([&1]))
    assert {:ok, :conflicting} in outcomes
    assert Enum.all?(outcomes, &(&1 in [{:ok, :committed}, {:ok, :conflicting}]))

    expected = %{
      valid: %{lookup: {:found, :v1}, generation: 1, selected: :v1, candidates: [:v1]},
      duplicate: %{lookup: {:found, :v1}, generation: 1, selected: :v1, candidates: [:v1]},
      replay: %{lookup: {:found, :v1}, generation: 1, selected: :v1, candidates: [:v1]},
      conflict: %{lookup: :conflicting, generation: 2, selected: nil, candidates: [:v1, :v2]},
      double: %{lookup: :conflicting, generation: 2, selected: nil, candidates: [:v1, :v2]},
      stale: %{lookup: {:found, :v2}, generation: 2, selected: :v2, candidates: [:v1, :v2]},
      fenced: %{lookup: :conflicting, generation: 2, selected: nil, candidates: [:v1, :v2]}
    }

    assert world_state(batched) == expected
    assert world_state(single) == expected

    for world <- [batched, single] do
      fenced = world.fenced
      assert {:ok, :changed_candidates} = resolve(fenced, fenced.token, fenced.v1_id)
    end
  end

  test "replaying a committed mixed batch answers the same and writes nothing" do
    world = mixed_world()
    batch = mixed_batch(world)
    assert {:ok, :conflicting} = Assignments.commit_issuance(batch)
    before = row_counts(world)

    assert {:ok, :conflicting} = Assignments.commit_issuance(batch)
    assert row_counts(world) == before
  end

  test "an integrity failure answers the first failing entry and commits nothing" do
    missing = committed_lane()

    Repo.query!(
      "DELETE FROM platform.edge_recovery_assignment_candidates WHERE issuance_id = $1",
      [Ecto.UUID.dump!(hd(originals(missing.v1.key)).id)]
    )

    corrupt = committed_lane()

    Repo.query!(
      "UPDATE platform.edge_recovery_assignment_issuances SET evidence = '{}' WHERE id = $1",
      [Ecto.UUID.dump!(hd(originals(corrupt.v1.key)).id)]
    )

    fresh = new_lane()

    assert {:error, :missing} =
             Assignments.commit_issuance([fresh.v1, missing.v1, corrupt.v1])

    assert {:error, :corrupt} =
             Assignments.commit_issuance([fresh.v1, corrupt.v1, missing.v1])

    assert :missing = lookup(fresh.ctx)
    assert [] = originals(fresh.v1.key)
  end

  # Counts the statements the test process sends while committing: the set-based
  # commit runs the same fixed set whatever the batch size, where the per-entry
  # loop ran seven or eight per entry.
  test "a commit runs a fixed number of statements whatever its batch size" do
    counts =
      for size <- [1, 64, 256] do
        batch = Enum.map(1..size, fn _ -> new_lane().v1 end)
        {statements, result} = count_statements(fn -> Assignments.commit_issuance(batch) end)
        assert {:ok, :committed} = result
        {replayed, replay} = count_statements(fn -> Assignments.commit_issuance(batch) end)
        assert {:ok, :committed} = replay
        assert replayed <= statements
        statements
      end

    assert [count, count, count] = counts
    assert count <= 10
  end

  defp lookup(ctx), do: Assignments.lookup(ctx.scope, ctx.agent, ctx.span)

  defp select(ctx, token, id),
    do: Assignments.resolve(ctx.entry.key, token.resolver_epoch, token.candidate_generation, id)

  defp resolve(lane, token, id),
    do: Assignments.resolve(lane.v1.key, token.resolver_epoch, token.candidate_generation, id)

  defp new_lane do
    ctx = RecoveryAssignmentFixtures.fixture()
    {:ok, [v1]} = Evidence.sweep(ctx.capability, ctx.slot, ctx.key.public_key)

    other_plan = %{
      ctx.slot
      | plan_header: %{
          ctx.slot.plan_header
          | execution_plan_id: Ecto.UUID.dump!(Ash.UUID.generate())
        }
    }

    {:ok, [v2]} = Evidence.sweep(ctx.capability, other_plan, ctx.key.public_key)
    %{ctx: ctx, v1: v1, v2: v2}
  end

  defp committed_lane do
    lane = new_lane()
    {:ok, :committed} = Assignments.commit_issuance([lane.v1])
    lane
  end

  # Seven lanes, each its own key, in the state the batch meets them.
  defp mixed_world do
    stale = committed_lane()
    {:ok, :conflicting} = Assignments.commit_issuance([stale.v2])
    {:ok, resolver} = Assignments.acquire_resolver(stale.v1.key)
    v2_id = Enum.find(originals(stale.v1.key), &(&1.mapping_value == stale.v2.value)).id
    {:ok, :selected} = resolve(stale, resolver, v2_id)

    fenced = committed_lane()
    {:ok, token} = Assignments.acquire_resolver(fenced.v1.key)
    v1_id = hd(originals(fenced.v1.key)).id
    {:ok, :selected} = resolve(fenced, token, v1_id)

    %{
      valid: new_lane(),
      duplicate: new_lane(),
      replay: committed_lane(),
      conflict: committed_lane(),
      double: new_lane(),
      stale: stale,
      fenced: fenced |> Map.put(:token, token) |> Map.put(:v1_id, v1_id)
    }
  end

  defp mixed_batch(world) do
    [
      world.valid.v1,
      world.duplicate.v1,
      world.replay.v1,
      world.conflict.v2,
      world.double.v1,
      world.stale.v1,
      world.duplicate.v1,
      world.double.v2,
      world.stale.v2,
      world.fenced.v2,
      # The selection captured at generation 1 must not count at generation 2.
      world.fenced.v1
    ]
  end

  defp world_state(world) do
    world
    |> Map.take([:valid, :duplicate, :replay, :conflict, :double, :stale, :fenced])
    |> Map.new(fn {name, lane} -> {name, lane_state(lane)} end)
  end

  # The lane's key row, candidates and lookup, with values named :v1/:v2.
  defp lane_state(lane) do
    label = fn value -> if value == lane.v1.value, do: :v1, else: :v2 end
    issuances = originals(lane.v1.key)
    names = Map.new(issuances, &{&1.id, label.(&1.mapping_value)})

    %{rows: [[key_id, generation, selected_id]]} =
      Repo.query!(
        "SELECT id, generation, selected_issuance_id FROM platform.edge_recovery_assignment_keys WHERE mapping_key = $1::jsonb",
        [lane.v1.key]
      )

    %{rows: candidate_rows} =
      Repo.query!(
        "SELECT issuance_id FROM platform.edge_recovery_assignment_candidates WHERE key_id = $1",
        [key_id]
      )

    lookup =
      case lookup(lane.ctx) do
        {:found, value} -> {:found, label.(value)}
        other -> other
      end

    %{
      lookup: lookup,
      generation: generation,
      selected: selected_id && names[Ecto.UUID.cast!(selected_id)],
      candidates:
        candidate_rows |> Enum.map(fn [id] -> names[Ecto.UUID.cast!(id)] end) |> Enum.sort()
    }
  end

  defp row_counts(world) do
    keys = world |> Map.values() |> Enum.map(& &1.v1.key)

    for table <- ~w(issuances candidates resolutions keys), into: %{} do
      sql =
        case table do
          "issuances" ->
            "SELECT count(*) FROM platform.edge_recovery_assignment_issuances WHERE mapping_key = ANY($1::jsonb[])"

          "keys" ->
            "SELECT count(*) FROM platform.edge_recovery_assignment_keys WHERE mapping_key = ANY($1::jsonb[])"

          other ->
            "SELECT count(*) FROM platform.edge_recovery_assignment_#{other} r JOIN platform.edge_recovery_assignment_keys k ON k.id = r.key_id WHERE k.mapping_key = ANY($1::jsonb[])"
        end

      %{rows: [[count]]} = Repo.query!(sql, [keys])
      {table, count}
    end
  end

  defp count_statements(fun) do
    test_pid = self()
    counter = :counters.new(1, [])
    handler_id = {__MODULE__, :statements, make_ref()}
    event = Repo.config() |> Keyword.fetch!(:telemetry_prefix) |> Kernel.++([:query])

    :telemetry.attach(
      handler_id,
      event,
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      result = fun.()
      {:counters.get(counter, 1), result}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp originals(key),
    do:
      Issuance
      |> Ash.Query.filter(mapping_key == ^key)
      |> Ash.read!(actor: ServiceRadar.Actors.SystemActor.system(:mapping_test))
end
