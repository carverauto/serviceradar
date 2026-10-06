defmodule ServiceRadar.Inventory.Identity.BlockedFingerprintTest do
  @moduledoc """
  Integration coverage for how the scheduled reconciliation accounts for what it blocks
  (change `add-source-id-succession`, design D9, tasks 10.1-10.3 and 14.9).

  A run blocks a transitive component it will not flatten, and a pair a merge guard refuses.
  It records the evidence fingerprint with the decision, and skips the component while the
  fingerprint is unchanged, so a decision's occurrence count measures evidence changes rather
  than runs. These tests hold in place that:

    * an unchanged blocked pair or component is neither attempted nor recorded again, and the
      run counts it as blocked and unchanged;
    * a block is not an error;
    * a retired identifier, a new rule version and the end of the recheck window each
      evaluate a blocked component again;
    * a cooldown block, which depends on time, is never skipped.

  The duplicates are MAC siblings (`Mac.hardware_mac_sibling/1`), since two devices can never
  hold the same identifier row: `device_identifiers` is unique on type, value and partition.
  Each test runs the sweep once before it builds its fixture and compares the runs after it,
  so the blocks of rows other modules committed are already recorded and stay unchanged.
  """

  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.DuplicateSweep
  alias ServiceRadar.Inventory.Identity.PopulationGauges
  alias ServiceRadar.Inventory.Identity.ReconciliationRun
  alias ServiceRadar.Inventory.IdentityDecision
  alias ServiceRadar.Inventory.MergeAudit
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.IdentifierArchiveFixtures
  alias ServiceRadar.TestSupport.MetricContract

  @moduletag :integration

  @guard_blocked [:serviceradar, :identity_reconciler, :merge, :guard_blocked]
  @run [:serviceradar, :identity_reconciler, :run]
  @population [:serviceradar, :inventory, :identity_population]

  @run_measurements [
    :merges,
    :errors,
    :blocked_components,
    :blocked_merges,
    :blocked_unchanged,
    :succession_merges,
    :succession_reviews,
    :successions_skipped,
    :successions_deferred
  ]

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  @doc false
  # VM-global: forwards only what this test's own process emits.
  def forward(event, measurements, metadata, parent) do
    if self() == parent, do: send(parent, {:telemetry, event, measurements, metadata})
  end

  setup do
    n = System.unique_integer([:positive, :monotonic])
    handler = "blocked-fingerprint-test-#{n}"

    :ok =
      :telemetry.attach_many(
        handler,
        [@guard_blocked, @run, @population],
        &__MODULE__.forward/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    ctx = %{
      actor: SystemActor.system(:blocked_fingerprint_test),
      n: n,
      partition: "blocked-fingerprint-#{n}",
      source_id: Ecto.UUID.generate()
    }

    baseline = reconcile!(ctx)
    flush()

    {:ok, Map.put(ctx, :baseline, baseline)}
  end

  describe "an unchanged blocked pair" do
    test "is not attempted or recorded again, and is counted blocked and unchanged", ctx do
      pair = refused_pair!(ctx)
      key = source_block_key(pair)

      first = reconcile!(ctx)
      assert guards(pair) == [:source_authority_conflict]
      assert %{occurrence_count: 1, fingerprint: fingerprint} = decision!(key)
      assert is_binary(fingerprint)
      # A refusal is the guard working: a blocked merge, not an error.
      assert first.blocked_merges == ctx.baseline.blocked_merges + 1
      assert first.errors == ctx.baseline.errors

      second = reconcile!(ctx)
      assert guards(pair) == []
      assert %{occurrence_count: 1, fingerprint: ^fingerprint} = decision!(key)
      assert second.blocked_merges == first.blocked_merges
      assert second.blocked_unchanged == first.blocked_unchanged + 1
      assert second.errors == first.errors
      assert second.merges == first.merges
      assert live_count(pair) == 2

      run = latest_run(ctx)
      assert run.blocked_merges == second.blocked_merges
      assert run.blocked_unchanged == second.blocked_unchanged
      assert run.errors == second.errors
    end
  end

  describe "an unchanged blocked component" do
    test "is not recorded again, and is counted blocked and unchanged", ctx do
      component = blocked_component!(ctx)
      key = component_block_key(component)

      first = reconcile!(ctx)
      assert first.blocked_components == ctx.baseline.blocked_components + 1
      assert %{occurrence_count: 1, fingerprint: fingerprint} = decision!(key)
      assert is_binary(fingerprint)

      second = reconcile!(ctx)
      assert %{occurrence_count: 1, fingerprint: ^fingerprint} = decision!(key)
      assert second.blocked_components == first.blocked_components
      assert second.blocked_unchanged == first.blocked_unchanged + 1
      assert second.errors == first.errors
      assert latest_run(ctx).blocked_unchanged == second.blocked_unchanged
    end
  end

  describe "a retired identifier" do
    test "evaluates the blocked pair that held it again", ctx do
      pair = refused_pair!(ctx)
      key = source_block_key(pair)

      reconcile!(ctx)
      assert guards(pair) == [:source_authority_conflict]
      assert %{occurrence_count: 1, fingerprint: fingerprint} = decision!(key)

      # As the retirement pass does when the source stops reporting the id.
      IdentifierArchiveFixtures.archive!(:armis_device_id, "#{ctx.n}01", ctx.partition)

      # The retired id still conflicts with the other record's, so the pair is refused again,
      # but only after it was evaluated again.
      reconcile!(ctx)
      assert guards(pair) == [:source_authority_conflict]
      assert %{occurrence_count: 2, fingerprint: retired_fingerprint} = decision!(key)
      refute retired_fingerprint == fingerprint
    end
  end

  describe "a new rule version" do
    test "evaluates every blocked pair and component again, once", ctx do
      pair = refused_pair!(ctx)
      component = blocked_component!(ctx)
      pair_key = source_block_key(pair)
      component_key = component_block_key(component)

      reconcile!(ctx)
      assert guards(pair) == [:source_authority_conflict]
      assert %{occurrence_count: 1} = decision!(pair_key)
      assert %{occurrence_count: 1} = decision!(component_key)

      # A release that changes the rules.
      changed = reconcile!(ctx, rule_version: 2)
      assert guards(pair) == [:source_authority_conflict]
      assert %{occurrence_count: 2} = decision!(pair_key)
      assert %{occurrence_count: 2} = decision!(component_key)

      unchanged = reconcile!(ctx, rule_version: 2)
      assert guards(pair) == []
      assert %{occurrence_count: 2} = decision!(pair_key)
      assert %{occurrence_count: 2} = decision!(component_key)
      assert unchanged.blocked_unchanged == changed.blocked_unchanged + 2
    end
  end

  describe "the recheck window" do
    test "evaluates a blocked pair again once its decision is older than the window", ctx do
      pair = refused_pair!(ctx)
      key = source_block_key(pair)

      reconcile!(ctx)
      assert guards(pair) == [:source_authority_conflict]

      age!(key, recheck_seconds() + 3_600)

      reconcile!(ctx)
      assert guards(pair) == [:source_authority_conflict]
      assert %{occurrence_count: 2} = decision!(key)
    end
  end

  describe "a cooldown block" do
    test "is attempted on every run, because it depends on time", ctx do
      pair = sibling_pair!(ctx)
      [a, b] = pair

      MergeAudit.record!(
        %{
          from_device_id: a,
          to_device_id: b,
          reason: "identifier_backfill",
          source: "test",
          details: %{}
        },
        actor: ctx.actor
      )

      first = reconcile!(ctx)
      assert guards(pair) == [:merge_cooldown]

      second = reconcile!(ctx)
      assert guards(pair) == [:merge_cooldown]
      assert second.blocked_merges == first.blocked_merges
      assert second.blocked_unchanged == first.blocked_unchanged
    end
  end

  describe "the run telemetry" do
    test "carries the run's counters and outcome in a form the metrics export", ctx do
      pair = refused_pair!(ctx)
      stats = reconcile!(ctx)

      assert_received {:telemetry, @run, measurements, metadata}
      assert measurements == Map.take(stats, @run_measurements)
      assert metadata == %{status: :completed, trigger: :scheduled}
      MetricContract.assert_exported(@run, measurements, metadata)

      assert [%{measurements: guard_measurements, metadata: guard_metadata}] =
               guard_events(pair)

      assert guard_measurements == %{count: 1}
      MetricContract.assert_exported(@guard_blocked, guard_measurements, guard_metadata)

      assert_received {:telemetry, @population, population, population_metadata}
      assert population == PopulationGauges.inventory()
      MetricContract.assert_exported(@population, population, population_metadata)
    end
  end

  defp reconcile!(ctx, opts \\ []) do
    assert {:ok, stats} =
             DuplicateSweep.reconcile_duplicates([actor: ctx.actor, max_merges: 10_000] ++ opts)

    stats
  end

  # Two MAC siblings a source-authority conflict keeps apart: each holds a different id of the
  # same Armis source.
  defp refused_pair!(ctx) do
    x = device!(ctx, 1)
    y = device!(ctx, 2)
    register!(ctx, x, :mac, "00005E005301")
    register!(ctx, y, :mac, "02005E005301")
    register!(ctx, x, :armis_device_id, "#{ctx.n}01")
    register!(ctx, y, :armis_device_id, "#{ctx.n}02")
    Enum.sort([x, y])
  end

  # Two MAC siblings no guard but the cooldown refuses.
  defp sibling_pair!(ctx) do
    x = device!(ctx, 3)
    y = device!(ctx, 4)
    register!(ctx, x, :mac, "00005E005321")
    register!(ctx, y, :mac, "02005E005321")
    Enum.sort([x, y])
  end

  # Three records joined by two sibling pairs, X-Y and Y-Z: a transitive component, which the
  # run blocks rather than flattens.
  defp blocked_component!(ctx) do
    x = device!(ctx, 5)
    y = device!(ctx, 6)
    z = device!(ctx, 7)
    register!(ctx, x, :mac, "00005E005311")
    register!(ctx, y, :mac, "02005E005311")
    register!(ctx, y, :mac, "00005E005312")
    register!(ctx, z, :mac, "02005E005312")
    Enum.sort([x, y, z])
  end

  defp device!(ctx, i) do
    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: "blocked-#{ctx.n}-#{i}",
      ip: TestSupport.unique_device_ip()
    })
    |> Ash.create!(actor: ctx.actor)
    |> Map.fetch!(:uid)
  end

  defp register!(ctx, uid, :armis_device_id, value) do
    register!(ctx, uid, :armis_device_id, value, "armis", %{"sync_service_id" => ctx.source_id})
  end

  defp register!(ctx, uid, type, value), do: register!(ctx, uid, type, value, "test", %{})

  defp register!(ctx, uid, type, value, source, metadata) do
    DeviceIdentifier
    |> Ash.Changeset.for_create(:register, %{
      device_id: uid,
      identifier_type: type,
      identifier_value: value,
      partition: ctx.partition,
      source: source,
      metadata: metadata
    })
    |> Ash.create!(actor: ctx.actor)
  end

  defp source_block_key(pair),
    do: IdentityDecision.decision_key(:source_block, "source_authority_conflict", pair, nil)

  defp component_block_key(component),
    do:
      IdentityDecision.decision_key(
        :component_block,
        "ambiguous_transitive_component",
        component,
        nil
      )

  defp decision!(key) do
    Repo.one!(
      from(d in "identity_decisions",
        prefix: "platform",
        where: d.decision_key == ^key,
        select: %{
          occurrence_count: d.occurrence_count,
          fingerprint: fragment("?->>'fingerprint'", d.evidence)
        }
      )
    )
  end

  # Backdates a decision, as the passage of `seconds` would.
  defp age!(key, seconds) do
    %{num_rows: 1} =
      Repo.query!(
        """
        UPDATE platform.identity_decisions
        SET last_decided_at = last_decided_at - ($2::integer * interval '1 second')
        WHERE decision_key = $1
        """,
        [key, seconds]
      )
  end

  defp recheck_seconds do
    :serviceradar
    |> Application.get_env(DuplicateSweep, [])
    |> Keyword.get(:blocked_recheck_seconds, 86_400)
  end

  defp live_count(uids) do
    Repo.one!(from(d in Device, where: d.uid in ^uids and is_nil(d.deleted_at), select: count()))
  end

  defp latest_run(ctx) do
    ReconciliationRun
    |> Ash.Query.for_read(:recent, %{}, actor: ctx.actor)
    |> Ash.read!()
    |> hd()
  end

  # The guards that refused a merge of `pair` since the last call, oldest first. Drains every
  # guard event, the other pairs' included.
  defp guards(pair), do: pair |> guard_events() |> Enum.map(& &1.guard)

  defp guard_events(pair) do
    receive do
      {:telemetry, @guard_blocked, measurements, metadata} ->
        event = %{guard: metadata.guard, measurements: measurements, metadata: metadata}

        if Enum.sort([metadata.from_device_id, metadata.to_device_id]) == pair,
          do: [event | guard_events(pair)],
          else: guard_events(pair)
    after
      0 -> []
    end
  end

  defp flush do
    receive do
      {:telemetry, _event, _measurements, _metadata} -> flush()
    after
      0 -> :ok
    end
  end
end
