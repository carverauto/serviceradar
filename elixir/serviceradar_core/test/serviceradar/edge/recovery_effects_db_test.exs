defmodule ServiceRadar.Edge.RecoveryEffectsDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.RecoveryAssignmentEvidence, as: Evidence
  alias ServiceRadar.Edge.RecoveryAssignmentIssuance, as: Issuance
  alias ServiceRadar.Edge.RecoveryAssignments, as: Assignments
  alias ServiceRadar.Edge.RecoveryEffects, as: Effects
  alias ServiceRadar.Edge.RecoveryLossSpan, as: Span
  alias ServiceRadar.Edge.RecoveryLossTransition, as: Transition
  alias ServiceRadar.Edge.RecoveryRangeLoss, as: RangeLoss
  alias ServiceRadar.Edge.RecoveryRetryIntent, as: RetryIntent
  alias Serviceradar.Edge.V1.EdgeClassificationSpanV1
  alias Serviceradar.Edge.V1.EdgeLossManifestPageV1
  alias Serviceradar.Edge.V1.EdgeUnattributableV1
  alias Serviceradar.Edge.V1.SpoolLossTombstoneV1
  alias ServiceRadar.RecoveryAssignmentFixtures
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.RecoveryRetryIntents

  require Ash.Query

  @moduletag :integration

  test "active loss records partial produced-range coverage and one semantic retry, passive loss records only delivery loss" do
    for kind <- [:sweep, :standing] do
      ctx = RecoveryAssignmentFixtures.fixture(kind)
      entry = entry(ctx, kind)
      {:ok, :committed} = Assignments.commit_issuance([entry])
      manifest = manifest([ctx.span])
      assert {:ok, :applied} = apply_manifest(ctx, manifest)
      assert {:ok, :applied} = apply_manifest(ctx, manifest)
      assert [%{state: :applied}] = spans(manifest)
      assert length(transitions(manifest)) == 1
      assert length(intents(manifest)) == if(kind == :sweep, do: 1, else: 0)
      assert range_count(entry.key) == if(kind == :sweep, do: 1, else: 0)

      assert {:ok, false} =
               Effects.generation_fenced?(ctx.scope, ctx.agent, manifest.tombstone.prior_spool_id)
    end
  end

  test "unattributable loss fences only its prior generation and queues reconciliation before completion" do
    ctx = RecoveryAssignmentFixtures.fixture()
    manifest = manifest([unattributable(1)])
    assert {:ok, :applied} = apply_manifest(ctx, manifest)
    assert {:ok, :applied} = apply_manifest(ctx, manifest)
    assert [%{disposition: :pending} = intent] = intents(manifest)
    assert [%{outcome: :unattributable}] = transitions(manifest)

    assert {:ok, true} =
             Effects.generation_fenced?(ctx.scope, ctx.agent, manifest.tombstone.prior_spool_id)

    assert {:ok, false} =
             Effects.generation_fenced?(ctx.scope, ctx.agent, manifest.tombstone.new_spool_id)

    assert {:ok, false} =
             Effects.generation_fenced?(
               ctx.scope,
               "other.example.com",
               manifest.tombstone.prior_spool_id
             )

    assert {:ok, [_]} = Effects.generation_fences(ctx.scope, ctx.agent, 1)

    other = manifest([unattributable(1)])
    assert {:ok, :applied} = apply_manifest(ctx, other)
    assert {:error, :fence_snapshot_limit} = Effects.generation_fences(ctx.scope, ctx.agent, 1)

    assert {:ok, _} =
             RecoveryRetryIntents.reconciled_before(
               DateTime.shift(intent.inserted_at, second: -1)
             )

    assert [%{disposition: :pending}] = intents(manifest)
    assert {:ok, _} = RecoveryRetryIntents.reconciled_before(DateTime.utc_now())
    assert [%{disposition: :obsolete}] = intents(manifest)

    assert {:ok, true} =
             Effects.generation_fenced?(ctx.scope, ctx.agent, manifest.tombstone.prior_spool_id)
  end

  test "missing authority retains delivery and bounded audit history until original-evidence repair" do
    ctx = RecoveryAssignmentFixtures.fixture()
    entry = entry(ctx, :sweep)
    {:ok, :committed} = Assignments.commit_issuance([entry])
    [original] = originals(entry.key)

    Repo.query!(
      "DELETE FROM platform.edge_recovery_assignment_candidates WHERE issuance_id = $1",
      [
        Ecto.UUID.dump!(original.id)
      ]
    )

    manifest = manifest([ctx.span])
    assert {:ok, :blocked} = apply_manifest(ctx, manifest)
    assert {:ok, :blocked} = apply_manifest(ctx, manifest)
    assert [%{outcome: :missing}] = transitions(manifest)
    assert range_count(entry.key) == 0
    assert intents(manifest) == []

    assert {:ok, true} =
             Effects.generation_fenced?(ctx.scope, ctx.agent, manifest.tombstone.prior_spool_id)

    assert {:ok, :committed} = Assignments.repair(original.id)
    assert {:ok, :applied} = apply_manifest(ctx, manifest)
    assert Enum.sort(Enum.map(transitions(manifest), & &1.outcome)) == [:found, :missing]
    assert range_count(entry.key) == 1
    assert length(intents(manifest)) == 1
  end

  test "corrupt and conflicting mappings quarantine the span without a manufactured range",
    do: assert_quarantined_mappings()

  test "same span identity with a different complete body retains the original and blocks replay" do
    ctx = RecoveryAssignmentFixtures.fixture()
    entry = entry(ctx, :sweep)
    {:ok, :committed} = Assignments.commit_issuance([entry])
    original = manifest([ctx.span])
    assert {:ok, :applied} = apply_manifest(ctx, original)
    [stored] = spans(original)
    changed = manifest([%{ctx.span | through_sequence: 2}], original.tombstone)
    assert {:ok, :blocked} = apply_manifest(ctx, changed)
    assert [%{span: bytes, outcome: :body_conflict}] = spans(original)
    assert bytes == stored.span
    assert {:ok, :blocked} = apply_manifest(ctx, original)
    assert range_count(entry.key) == 1
  end

  test "later candidate resolution preserves earlier applied range loss and releases a blocked new recovery" do
    ctx = RecoveryAssignmentFixtures.fixture()
    first = entry(ctx, :sweep)
    assert {:ok, :committed} = Assignments.commit_issuance([first])
    old_manifest = manifest([ctx.span])
    assert {:ok, :applied} = apply_manifest(ctx, old_manifest)

    slot = %{
      ctx.slot
      | plan_header: %{
          ctx.slot.plan_header
          | execution_plan_id: Ecto.UUID.dump!(Ash.UUID.generate())
        }
    }

    {:ok, [second]} = Evidence.sweep(ctx.capability, slot, ctx.key.public_key)
    assert {:ok, :conflicting} = Assignments.commit_issuance([second])
    new_manifest = manifest([ctx.span])
    assert {:ok, :blocked} = apply_manifest(ctx, new_manifest)
    original = Enum.find(originals(first.key), &(&1.mapping_value == second.value))
    {:ok, token} = Assignments.acquire_resolver(first.key)

    assert {:ok, :selected} =
             Assignments.resolve(
               first.key,
               token.resolver_epoch,
               token.candidate_generation,
               original.id
             )

    assert {:ok, :applied} = apply_manifest(ctx, new_manifest)
    assert {:ok, :applied} = apply_manifest(ctx, old_manifest)
    assert [%{mapping_value: old_value}] = spans(old_manifest)
    assert [%{mapping_value: new_value}] = spans(new_manifest)
    assert old_value == first.value
    assert new_value == second.value
    assert range_count(first.key) == 2
    assert Enum.sort(Enum.map(transitions(new_manifest), & &1.outcome)) == [:conflicting, :found]
  end

  test "the caller rollback leaves no loss audit, range, fence or retry intent" do
    ctx = RecoveryAssignmentFixtures.fixture()
    entry = entry(ctx, :sweep)
    {:ok, :committed} = Assignments.commit_issuance([entry])
    manifest = manifest([ctx.span, unattributable(2)])

    assert {:error, _} =
             Ash.transact(Effects.resources(), fn ->
               assert {:ok, :applied} =
                        Effects.apply_manifest(
                          ctx.scope,
                          ctx.agent,
                          manifest.tombstone,
                          manifest.pages
                        )

               {:error,
                Ash.Error.Query.InvalidArgument.exception(
                  field: :test,
                  value: :rollback,
                  message: "synthetic rollback"
                )}
             end)

    assert spans(manifest) == []
    assert intents(manifest) == []
    assert range_count(entry.key) == 0

    assert {:ok, false} =
             Effects.generation_fenced?(ctx.scope, ctx.agent, manifest.tombstone.prior_spool_id)
  end

  defp assert_quarantined_mappings do
    for outcome <- [:corrupt, :conflicting] do
      ctx = RecoveryAssignmentFixtures.fixture()
      entry = entry(ctx, :sweep)
      {:ok, :committed} = Assignments.commit_issuance([entry])
      [original] = originals(entry.key)

      if outcome == :corrupt do
        Repo.query!(
          "UPDATE platform.edge_recovery_assignment_issuances SET evidence = '{}' WHERE id = $1",
          [
            Ecto.UUID.dump!(original.id)
          ]
        )
      else
        slot = %{
          ctx.slot
          | plan_header: %{
              ctx.slot.plan_header
              | execution_plan_id: Ecto.UUID.dump!(Ash.UUID.generate())
            }
        }

        {:ok, [different]} = Evidence.sweep(ctx.capability, slot, ctx.key.public_key)
        assert {:ok, :conflicting} = Assignments.commit_issuance([different])
      end

      manifest = manifest([ctx.span])
      assert {:ok, :blocked} = apply_manifest(ctx, manifest)
      assert {:ok, :blocked} = apply_manifest(ctx, manifest)
      assert [%{outcome: ^outcome, state: :blocked}] = spans(manifest)
      assert length(transitions(manifest)) == 1
      assert range_count(entry.key) == 0
      assert intents(manifest) == []
    end
  end

  defp entry(ctx, :sweep) do
    {:ok, [entry]} = Evidence.sweep(ctx.capability, ctx.slot, ctx.key.public_key)
    entry
  end

  defp entry(ctx, :standing) do
    {:ok, entry} = Evidence.standing(ctx.capability, ctx.key.public_key)
    entry
  end

  defp manifest(spans, tombstone \\ nil) do
    tombstone =
      tombstone ||
        %SpoolLossTombstoneV1{
          recovery_id: uuid7(),
          prior_spool_id: uuid7(),
          new_spool_id: uuid7(),
          manifest_page_count: 1,
          detected_at_unix_nano: 1,
          reason: "synthetic loss",
          digest_version: 1
        }

    page = %EdgeLossManifestPageV1{
      recovery_id: tombstone.recovery_id,
      page_count: 1,
      page_index: 0,
      terminal: true,
      digest_version: 1,
      classification_spans: spans
    }

    page = %{page | page_sha256: HashGrammar.manifest_page_digest(page)}

    %{
      tombstone: %{tombstone | manifest_root_sha256: HashGrammar.manifest_root([page])},
      pages: [page]
    }
  end

  defp unattributable(sequence),
    do: %EdgeClassificationSpanV1{
      from_sequence: sequence,
      through_sequence: sequence,
      classification:
        {:unattributable,
         %EdgeUnattributableV1{reason: :EDGE_UNATTRIBUTABLE_REASON_BINDING_CORRUPT}}
    }

  defp uuid7, do: <<0::48, 7::4, 0::12, 2::2, System.unique_integer([:positive])::62>>

  defp apply_manifest(ctx, manifest) do
    case Ash.transact(Effects.resources(), fn ->
           Effects.apply_manifest(ctx.scope, ctx.agent, manifest.tombstone, manifest.pages)
         end) do
      {:ok, result} -> result
      error -> error
    end
  end

  defp spans(manifest),
    do:
      Span
      |> Ash.Query.filter(recovery_id == ^Ecto.UUID.cast!(manifest.tombstone.recovery_id))
      |> Ash.read!(actor: actor())

  defp transitions(manifest) do
    ids = Enum.map(spans(manifest), & &1.id)
    Transition |> Ash.Query.filter(span_id in ^ids) |> Ash.read!(actor: actor())
  end

  defp intents(manifest),
    do:
      RetryIntent
      |> Ash.Query.filter(recovery_id == ^Ecto.UUID.cast!(manifest.tombstone.recovery_id))
      |> Ash.read!(actor: actor())

  defp originals(key),
    do: Issuance |> Ash.Query.filter(mapping_key == ^key) |> Ash.read!(actor: actor())

  defp range_count(key),
    do: RangeLoss |> Ash.Query.filter(mapping_key == ^key) |> Ash.count!(actor: actor())

  defp actor, do: ServiceRadar.Actors.SystemActor.system(:recovery_effects_test)
end
