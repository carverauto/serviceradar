defmodule ServiceRadar.Inventory.Remediation.SourceIdRemediationTest do
  @moduledoc """
  Integration coverage for the source id remediation (change `add-source-id-succession`, design
  D11, tasks 13.1-13.4 and 14.10): the steps `source-id-retire`, `source-succession` and
  `released-seed-shells`, the read-only checks of `source-id-verify`, and `source-id-rollback`,
  run through `DireRemediation` as the mix task runs them.

  The world of a test is one invented Armis source instance, ten days back, holding a record of
  each class the remediation acts on:

    * C1 (class 1) holds two Armis ids, and the source stopped reporting one of them.
    * P, P2 and P3 each hold one id the source stopped reporting, and S, S2 and S3 the current
      id of the same device, sharing its MAC: P and S also share a first-seen time (class 3),
      P2 and S2 a hostname (class 2), and P3 and S3 nothing more (class 4, a review).
    * R5 (class 5) was left holding only a retired id, unmarked, and has no successor.
    * D1 and D2 (class 8) carry one Armis id in their metadata.
    * X (class 7) is a released-seed shell.

  A second world holds three records left holding only a retired id, unmarked, as R5 is: P6,
  whose successor S6 shares its MAC and first-seen time, P7, whose successor S7 shares only
  its MAC, and R8, with no successor.
  """

  use ServiceRadar.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceCleanupSettings
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.DeviceSourceObservationIngestor
  alias ServiceRadar.Inventory.Identity.SourceRetirement
  alias ServiceRadar.Inventory.IdentityDecision
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Inventory.Remediation.DireRemediation
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Inventory.Remediation.ReleasedSeedShells
  alias ServiceRadar.Inventory.Remediation.SourceIdRetire
  alias ServiceRadar.Inventory.Remediation.SourceSuccessionMerge
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration
  @moduletag :capture_log

  @prefix "platform"

  @steps ["source-id-retire", "source-succession", "released-seed-shells"]
  @verify "source-id-verify"
  @rollback "source-id-rollback"

  # N = 3 collections and T = 24 hours, no mass guard, and no scheduled succession during the
  # run, as the runbook sets them.
  @settings %{
    source_retirement_enabled: true,
    source_retirement_absent_collections: 3,
    source_retirement_min_absence_hours: 24,
    source_retirement_max_fraction: 1.0,
    source_retirement_guard_override: false,
    source_retired_grace_days: 7,
    max_successions_per_run: 0
  }

  defmodule FailWriter do
    @moduledoc false
    # A manifest that cannot take the entries of the action `failing_manifest/4` names, as on a
    # full disk. The steps write their entries in the calling process.

    alias ServiceRadar.Inventory.Remediation.Manifest.FileWriter

    def sync(device), do: FileWriter.sync(device)

    def write(device, %{action: action} = entry) do
      if action == Process.get(:fail_action),
        do: {:error, {:manifest_sync_failed, :injected}},
        else: FileWriter.write(device, entry)
    end

    def write_batch(device, entries), do: FileWriter.write_batch(device, entries)
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  # One Armis source instance per test, registered as an integration source so that its sync
  # runs can be recorded, and a directory for the manifests. t0 lies ten days back.
  setup do
    n = System.unique_integer([:positive, :monotonic])
    inst = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO platform.integration_sources (id, name, source_type, endpoint) " <>
        "VALUES (CAST(CAST($1 AS text) AS uuid), $2, 'armis', $3)",
      [inst, "source-id-remediation-#{n}", "https://inventory.example.com/#{n}"]
    )

    dir =
      Path.join(
        System.tmp_dir!(),
        "dire_remediation_test_source_id_#{n}_#{Ecto.UUID.generate()}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    ctx = %{
      actor: SystemActor.system(:source_id_remediation_test),
      n: n,
      inst: inst,
      instance: %{partition: "default", source: "armis", source_instance: inst},
      id_partition: "default:armis:#{inst}",
      t0: DateTime.utc_now() |> DateTime.shift(day: -10) |> DateTime.truncate(:second),
      dir: dir
    }

    put_settings!(ctx, @settings)
    {:ok, ctx}
  end

  describe "the dry run" do
    test "counts each class and changes nothing, and verify fails until they are gone", ctx do
      w = world!(ctx)
      before = state(w)

      assert {:error, {:step_failures, result}} =
               DireRemediation.run(
                 mode: :dry_run,
                 steps: @steps ++ [@verify],
                 actor: ctx.actor
               )

      assert result.failures == %{@verify => %{verification_failures: 4}}
      assert state(w) == before

      retire = result.reports["source-id-retire"]

      assert %{
               source_retirement_enabled: true,
               guard_override: false,
               would_retire_ids: 4,
               would_retire_records: 4,
               class_1_records: 1,
               would_leave_retired_only: 3,
               guard_would_refuse: 0,
               class_5_records: 1
             } = retire

      assert retire.class_5_sample == [w.r5.uid]

      assert retire.retire_sample |> Enum.map(&{&1.device_id, &1.value}) |> Enum.sort() ==
               Enum.sort([
                 {w.c1.uid, w.c1a},
                 {w.p.uid, w.pa},
                 {w.p2.uid, w.p2a},
                 {w.p3.uid, w.p3a}
               ])

      assert [%{status: :ready, would_retire_ids: 4, guard: %{verdict: :allow}}] =
               retire.instance_plans

      succession = result.reports["source-succession"]

      assert %{
               scheduled_successions_per_run: 0,
               class_2_pairs: 0,
               class_3_pairs: 0,
               class_4_reviews: 0,
               class_6_reviews: 0,
               class_8_groups: 1,
               class_8_records: 2
             } = succession

      assert succession.review_reasons == %{}

      assert succession.class_8_sample == [
               %{
                 sync_service_id: ctx.inst,
                 value: w.duplicate,
                 records: 2,
                 device_uids: Enum.sort([w.d1.uid, w.d2.uid])
               }
             ]

      assert result.reports["released-seed-shells"] == %{
               class_7_shells: 1,
               class_7_sample: [w.x.uid]
             }

      verify = result.reports[@verify]

      assert %{verification_failures: 4, verification_pending: 1, verified_manifests: 0} =
               verify

      assert results(verify) == %{
               "V1" => :fail,
               "V2" => :fail,
               "V3" => :fail,
               "V4" => :fail,
               "V5" => :not_run,
               "V6" => :not_run,
               "V7" => :pending,
               "V8" => :pass
             }

      assert %{details: %{instances: [v1]}} = check(verify, "V1")
      assert %{live_records: 7, unmarked_retired: 1, current_ids: 4, ratio: 2.0} = v1
      assert %{details: %{instances: [%{retirable_ids: 4, records: 4}]}} = check(verify, "V2")
      assert %{details: %{groups: 1, records: 2, reviewed_values: 0}} = check(verify, "V3")
      assert check(verify, "V4").details == %{live_shells: 1, sample: [w.x.uid]}

      # V5 judges V1-V4 once two complete collections of the instance, its latest activated
      # collection among them, started after the last batch.
      now = DateTime.utc_now()
      later = DateTime.shift(now, minute: 1)

      manifest =
        hand_manifest!(ctx, "window", DateTime.shift(now, hour: -2), [
          entry(
            "source-id-retire",
            "batch_finished",
            "none",
            [],
            DateTime.shift(now, hour: -1),
            %{
              "batch" => 1
            }
          )
        ])

      sync_run!(ctx, "#{ctx.inst}-c4", 1, [0], later)

      assert %{
               result: :pending,
               details: %{
                 collections: [%{complete_collections: 1, latest_collection_after: true}],
                 collections_waiting: 1,
                 sweeps_waiting: []
               }
             } = check(verify!(ctx, verify_manifests: [manifest]), "V5")

      sync_run!(ctx, "#{ctx.inst}-partial", 2, [0], later)

      assert %{result: :pending, details: %{collections_waiting: 1}} =
               check(verify!(ctx, verify_manifests: [manifest]), "V5")

      sync_run!(ctx, "#{ctx.inst}-c5", 1, [0], later)
      window = verify!(ctx, verify_manifests: [manifest])

      assert %{
               result: :fail,
               details: %{
                 collections: [%{complete_collections: 2}],
                 collections_waiting: 0,
                 not_passing: ["V1", "V2", "V3", "V4"]
               }
             } = check(window, "V5")

      assert check(window, "V6") == %{
               check: "V6",
               result: :pass,
               details: %{records: 0, revived: 0}
             }

      assert state(w) == before
    end
  end

  describe "--execute" do
    test "fixes each class, passes every check once the sources report again, and rolls back",
         ctx do
      w = world!(ctx)
      retire_manifest = path(ctx, "retire")

      assert {:ok, %{reports: %{"source-id-retire" => retire}}} =
               DireRemediation.run(
                 mode: :execute,
                 steps: ["source-id-retire"],
                 manifest_path: retire_manifest,
                 actor: ctx.actor
               )

      assert %{
               retired_ids: 4,
               retired_records: 4,
               marked_at_retirement: 3,
               skipped: 0,
               retire_failures: 0,
               manifest_failures: 0,
               mass_guard_failures: 0,
               class_5_marked: 1,
               class_5_not_marked: 0,
               mark_failures: 0,
               batches: 2,
               harm_check_failures: 0
             } = retire

      refute Map.has_key?(retire, :halted)
      assert [%{status: :retired, retired_ids: 4, retired_records: 4}] = retire.instance_plans

      assert held_by(ctx, w.c1b) == w.c1.uid
      assert Enum.map(archived(ctx, w.c1a), & &1.device_id) == [w.c1.uid, w.c1.uid]
      assert reload(ctx, w.c1).source_retired_at == nil

      for record <- [w.p, w.p2, w.p3, w.r5] do
        device = reload(ctx, record)
        assert device.source_retired_at
        assert device.metadata["identity_state"] == "source_retired"
      end

      # The retirements made P, P2 and P3 predecessors.
      assert {:ok, %{reports: %{"source-succession" => plan}}} =
               DireRemediation.run(
                 mode: :dry_run,
                 steps: ["source-succession"],
                 reviewed_source_ids: [w.duplicate],
                 actor: ctx.actor
               )

      assert %{
               class_2_pairs: 1,
               class_3_pairs: 1,
               class_4_reviews: 1,
               class_6_reviews: 0,
               class_8_groups: 0
             } = plan

      assert plan.review_reasons == %{mac_only: 1}

      assert Enum.sort_by(plan.merge_sample, & &1.predecessor) ==
               Enum.sort_by(
                 [
                   %{
                     predecessor: w.p.uid,
                     successor: w.s.uid,
                     survivor: w.p.uid,
                     merged: w.s.uid,
                     hostname_shared: false
                   },
                   %{
                     predecessor: w.p2.uid,
                     successor: w.s2.uid,
                     survivor: w.p2.uid,
                     merged: w.s2.uid,
                     hostname_shared: true
                   }
                 ],
                 & &1.predecessor
               )

      merge_manifest = path(ctx, "merge")

      assert {:ok, %{reports: reports}} =
               DireRemediation.run(
                 mode: :execute,
                 steps: ["source-succession", "released-seed-shells"],
                 manifest_path: merge_manifest,
                 actor: ctx.actor
               )

      assert %{
               merged: 2,
               merge_blocked: 0,
               stale: 0,
               merge_failures: 0,
               manifest_failures: 0,
               reviews_recorded: 1,
               review_failures: 0,
               batches: 1,
               harm_check_failures: 0
             } = reports["source-succession"]

      assert %{
               tombstoned: 1,
               tombstone_failures: 0,
               manifest_failures: 0,
               batches: 1,
               harm_check_failures: 0,
               shells_left: 0
             } = reports["released-seed-shells"]

      assert held_by(ctx, w.sb) == w.p.uid
      assert held_by(ctx, w.s2b) == w.p2.uid
      assert reload(ctx, w.p).source_retired_at == nil
      assert reload(ctx, w.p2).source_retired_at == nil
      assert reload(ctx, w.s).deleted_at
      assert reload(ctx, w.s2).deleted_at
      assert reload(ctx, w.p3).source_retired_at
      assert reload(ctx, w.s3).deleted_at == nil
      assert [_review] = reviews([w.p3.uid, w.s3.uid], ctx.actor)
      assert reload(ctx, w.r5).source_retired_at
      assert reload(ctx, w.d1).deleted_at == nil
      assert reload(ctx, w.d2).deleted_at == nil

      shell = reload(ctx, w.x)
      assert shell.deleted_at
      assert shell.deleted_reason == "seed_released"
      assert shell.deleted_by == "system:dire_remediation"

      manifests = [retire_manifest, merge_manifest]

      assert {:ok, %{reports: %{@verify => verify}}} =
               verify(ctx, verify_manifests: manifests, reviewed_source_ids: [w.duplicate])

      assert %{verification_failures: 0, verification_pending: 2, verified_manifests: 2} =
               verify

      assert results(verify) == %{
               "V1" => :pass,
               "V2" => :pass,
               "V3" => :pass,
               "V4" => :pass,
               "V5" => :pending,
               "V6" => :pass,
               "V7" => :pending,
               "V8" => :pass
             }

      assert %{details: %{instances: [v1]}} = check(verify, "V1")
      assert %{live_records: 4, unmarked_retired: 0, current_ids: 4, ratio: 1.0} = v1
      assert %{details: %{merges: 2, joined_present: 0, pending: 0}} = check(verify, "V8")

      # Two complete collections and a reconciliation run after the last batch.
      later = DateTime.shift(DateTime.utc_now(), minute: 1)
      sync_run!(ctx, "#{ctx.inst}-c4", 1, [0], later)
      sync_run!(ctx, "#{ctx.inst}-c5", 1, [0], later)
      reconciliation_run!("completed", 0, later)

      assert {:ok, %{reports: %{@verify => verify}}} =
               verify(ctx, verify_manifests: manifests, reviewed_source_ids: [w.duplicate])

      assert %{verification_failures: 0, verification_pending: 0} = verify
      assert verify |> results() |> Map.values() == List.duplicate(:pass, 8)

      assert {:ok, %{reports: %{@rollback => rollback_plan}}} =
               DireRemediation.run(
                 mode: :dry_run,
                 steps: [@rollback],
                 rollback_manifests: manifests,
                 actor: ctx.actor
               )

      assert rollback_plan == %{
               manifests: 2,
               would_restore_shells: 1,
               would_unmerge: 2,
               would_restore_marks: 2,
               would_clear_marks: 1,
               would_return_ids: 4,
               not_rolled_back: 1,
               ignored_entries: 0
             }

      rollback_manifest = path(ctx, "rollback")

      assert {:ok, %{reports: %{@rollback => rollback}}} =
               DireRemediation.run(
                 mode: :execute,
                 steps: [@rollback],
                 rollback_manifests: manifests,
                 manifest_path: rollback_manifest,
                 actor: ctx.actor
               )

      assert rollback == %{
               manifests: 2,
               shells_restored: 1,
               unmerged: 2,
               marks_restored: 2,
               marks_cleared: 1,
               ids_returned: 4,
               identity_states_restored: 3,
               skipped: 0,
               skip_reasons: %{},
               not_rolled_back: 1,
               ignored_entries: 0,
               rollback_failures: 0,
               manifest_failures: 0
             }

      assert {:ok, _header, undone} = Manifest.read(rollback_manifest)

      assert undone |> Enum.map(& &1["action"]) |> Enum.frequencies() == %{
               "undo_tombstone_shells" => 1,
               "undo_succession_merge" => 2,
               "undo_mark_source_retired" => 1,
               "undo_retire_source_ids" => 4
             }

      assert held_by(ctx, w.c1a) == w.c1.uid
      assert held_by(ctx, w.c1b) == w.c1.uid

      assert typed_id_holder(:integration_id, integration_id(ctx, w.c1a), ctx.id_partition) ==
               w.c1.uid

      assert archived(ctx, w.c1a) == []

      for {record, value} <- [{w.p, w.pa}, {w.p2, w.p2a}, {w.p3, w.p3a}] do
        assert held_by(ctx, value) == record.uid
        device = reload(ctx, record)
        assert device.source_retired_at == nil
        assert device.metadata["identity_state"] == "canonical"
      end

      for {record, value} <- [{w.s, w.sb}, {w.s2, w.s2b}] do
        assert held_by(ctx, value) == record.uid
        assert reload(ctx, record).deleted_at == nil
      end

      assert reload(ctx, w.r5).source_retired_at == nil
      assert [%{device_id: r5_uid}] = archived(ctx, w.r5a)
      assert r5_uid == w.r5.uid
      assert reload(ctx, w.x).deleted_at == nil
      assert [_review] = reviews([w.p3.uid, w.s3.uid], ctx.actor)

      # A second rollback of the same manifests finds everything reversed already.
      assert {:ok, %{reports: %{@rollback => replay}}} =
               DireRemediation.run(
                 mode: :execute,
                 steps: [@rollback],
                 rollback_manifests: manifests,
                 manifest_path: path(ctx, "replay"),
                 actor: ctx.actor
               )

      assert replay == %{
               manifests: 2,
               shells_restored: 0,
               unmerged: 0,
               marks_restored: 0,
               marks_cleared: 0,
               ids_returned: 0,
               identity_states_restored: 0,
               skipped: 8,
               skip_reasons: %{
                 shell_changed: 1,
                 already_unmerged: 2,
                 mark_changed: 1,
                 not_archived: 4
               },
               not_rolled_back: 1,
               ignored_entries: 0,
               rollback_failures: 0,
               manifest_failures: 0
             }
    end

    test "is refused while source retirement is disabled, and the later steps do not run", ctx do
      w = world!(ctx)
      put_settings!(ctx, %{source_retirement_enabled: false})
      before = state(w)
      manifest = path(ctx, "disabled")

      assert {:error, {:step_failures, result}} =
               DireRemediation.run(
                 mode: :execute,
                 steps: @steps,
                 manifest_path: manifest,
                 actor: ctx.actor
               )

      halted = "halted by source-id-retire: source_retirement_disabled"

      assert result.reports == %{
               "source-id-retire" => %{
                 execution_blocked: true,
                 execution_blocked_reason: "source_retirement_disabled",
                 halted: "source_retirement_disabled"
               },
               "source-succession" => %{not_run: halted},
               "released-seed-shells" => %{not_run: halted}
             }

      assert result.failures == %{"source-id-retire" => %{execution_blocked: true}}
      assert state(w) == before
      assert {:ok, _header, []} = Manifest.read(manifest)
    end

    test "leaves an instance the mass guard refuses, its class 5 records included", ctx do
      w = world!(ctx)
      put_settings!(ctx, %{source_retirement_max_fraction: 0.1})

      assert {:ok, %{reports: %{"source-id-retire" => %{guard_would_refuse: 1}}}} =
               DireRemediation.run(
                 mode: :dry_run,
                 steps: ["source-id-retire"],
                 actor: ctx.actor
               )

      before = state(w)

      assert {:error, {:step_failures, result}} =
               DireRemediation.run(
                 mode: :execute,
                 steps: ["source-id-retire"],
                 manifest_path: path(ctx, "guard"),
                 actor: ctx.actor
               )

      assert result.failures == %{"source-id-retire" => %{mass_guard_failures: 1}}
      retire = result.reports["source-id-retire"]
      assert %{retired_ids: 0, retired_records: 0, class_5_marked: 0, batches: 0} = retire
      refute Map.has_key?(retire, :halted)

      assert [%{status: :mass_guard_refused, guard: %{candidates: 4, live: 7, max_fraction: 0.1}}] =
               retire.instance_plans

      assert state(w) == before
    end

    test "marks no class 5 record that a succession merges or sends to review", ctx do
      w = candidates_world!(ctx)
      {:ok, retirement} = SourceRetirement.context(ctx.instance, settings: @settings)

      assert SourceRetirement.unmarked_retired(retirement, nil) ==
               Enum.sort([w.p6.uid, w.p7.uid, w.r8.uid])

      assert {:ok, %{reports: reports}} =
               DireRemediation.run(
                 mode: :dry_run,
                 steps: ["source-id-retire", "source-succession"],
                 actor: ctx.actor
               )

      assert %{class_3_pairs: 1, class_4_reviews: 1, review_reasons: %{mac_only: 1}} =
               reports["source-succession"]

      assert %{would_retire_ids: 0, class_5_records: 1} = reports["source-id-retire"]
      assert reports["source-id-retire"].class_5_sample == [w.r8.uid]
      manifest = path(ctx, "candidates")

      assert {:ok, %{reports: %{"source-id-retire" => retire}}} =
               DireRemediation.run(
                 mode: :execute,
                 steps: ["source-id-retire"],
                 manifest_path: manifest,
                 actor: ctx.actor
               )

      assert %{retired_ids: 0, class_5_marked: 1, class_5_not_marked: 0, batches: 1} = retire
      assert [%{status: :nothing_to_retire}] = retire.instance_plans
      assert {:ok, _header, entries} = Manifest.read(manifest)

      assert Enum.map(entries, &{&1["action"], &1["ids"]}) == [
               {"mark_source_retired", [w.r8.uid]},
               {"batch_finished", []}
             ]

      assert reload(ctx, w.r8).source_retired_at

      for record <- [w.p6, w.s6, w.p7, w.s7] do
        assert reload(ctx, record).source_retired_at == nil
      end
    end

    test "rolls a retirement back when its manifest entry cannot be written, and stops", ctx do
      w = world!(ctx)
      before = state(w)

      manifest = failing_manifest(ctx, "unwritable", "source-id-retire", "retire_source_ids")

      report =
        try do
          SourceIdRetire.run(:execute, [], manifest, ctx.actor)
        after
          Manifest.close(manifest)
        end

      assert %{
               manifest_failures: 4,
               retire_failures: 0,
               retired_ids: 0,
               retired_records: 0,
               class_5_marked: 0,
               batches: 0,
               halted: "manifest"
             } = report

      assert state(w) == before
    end

    test "rolls a merge and a soft-delete back when their entries cannot be written", ctx do
      w = world!(ctx)

      assert {:ok, %{reports: %{"source-id-retire" => %{retired_ids: 4}}}} =
               DireRemediation.run(
                 mode: :execute,
                 steps: ["source-id-retire"],
                 manifest_path: path(ctx, "retire"),
                 actor: ctx.actor
               )

      pairs = Map.take(w, [:p, :s, :p2, :s2])
      before = state(pairs)
      manifest = failing_manifest(ctx, "merges", "source-succession", "succession_merge")

      report =
        try do
          SourceSuccessionMerge.run(:execute, [], manifest, ctx.actor)
        after
          Manifest.close(manifest)
        end

      # The reviews were recorded before the first merge, which the step stopped at.
      assert %{
               merged: 0,
               merge_failures: 0,
               manifest_failures: 1,
               reviews_recorded: 1,
               batches: 0,
               halted: "manifest"
             } = report

      assert state(pairs) == before
      assert held_by(ctx, w.sb) == w.s.uid
      assert held_by(ctx, w.s2b) == w.s2.uid
      assert reload(ctx, w.p).source_retired_at
      assert reload(ctx, w.p2).source_retired_at

      shells = failing_manifest(ctx, "shells", "released-seed-shells", "tombstone_shells")

      report =
        try do
          ReleasedSeedShells.run(:execute, [], shells, ctx.actor)
        after
          Manifest.close(shells)
        end

      assert %{
               tombstoned: 0,
               tombstone_failures: 0,
               manifest_failures: 1,
               batches: 0,
               shells_left: 1,
               halted: "manifest"
             } = report

      assert reload(ctx, w.x).deleted_at == nil
    end

    test "stops after the batch a harm check fails, and the later steps do not run", ctx do
      w = world!(ctx)
      reconciliation_run!("failed", 0, DateTime.shift(DateTime.utc_now(), minute: 1))

      assert {:error, {:step_failures, result}} =
               DireRemediation.run(
                 mode: :execute,
                 steps: @steps,
                 manifest_path: path(ctx, "halt"),
                 source_batch_size: 1,
                 actor: ctx.actor
               )

      retire = result.reports["source-id-retire"]

      assert %{
               retired_ids: 1,
               retired_records: 1,
               batches: 1,
               harm_check_failures: 1,
               class_5_marked: 0,
               halted: "V7"
             } = retire

      assert %{result: :fail, details: %{failed_runs: 1}} = check(retire, "V7")

      halted = "halted by source-id-retire: V7"
      assert result.reports["source-succession"] == %{not_run: halted}
      assert result.reports["released-seed-shells"] == %{not_run: halted}
      assert result.failures == %{"source-id-retire" => %{harm_check_failures: 1}}

      retired =
        for value <- [w.c1a, w.pa, w.p2a, w.p3a],
            %{identifier_type: "armis_device_id"} <- archived(ctx, value),
            do: value

      assert length(retired) == 1
    end
  end

  describe "source-id-rollback" do
    test "leaves a merge that changed since the run and reverses the rest", ctx do
      w = world!(ctx)

      assert {:ok, _result} =
               DireRemediation.run(
                 mode: :execute,
                 steps: ["source-id-retire"],
                 manifest_path: path(ctx, "retire"),
                 actor: ctx.actor
               )

      merge_manifest = path(ctx, "merge")

      assert {:ok, %{reports: %{"source-succession" => %{merged: 2}}}} =
               DireRemediation.run(
                 mode: :execute,
                 steps: ["source-succession", "released-seed-shells"],
                 manifest_path: merge_manifest,
                 actor: ctx.actor
               )

      # Since the run, S came back as a record of its own and S2 merged into another record.
      revive!(w.s)
      merge_audit!(w.s2.uid, w.d1.uid, "manual", %{})
      rollback_manifest = path(ctx, "rollback")

      assert {:ok, %{reports: %{@rollback => rollback}}} =
               DireRemediation.run(
                 mode: :execute,
                 steps: [@rollback],
                 rollback_manifests: [merge_manifest],
                 manifest_path: rollback_manifest,
                 actor: ctx.actor
               )

      assert rollback == %{
               manifests: 1,
               shells_restored: 1,
               unmerged: 0,
               marks_restored: 0,
               marks_cleared: 0,
               ids_returned: 0,
               identity_states_restored: 0,
               skipped: 2,
               skip_reasons: %{not_merged: 1, merge_superseded: 1},
               not_rolled_back: 1,
               ignored_entries: 0,
               rollback_failures: 0,
               manifest_failures: 0
             }

      {:ok, _header, merges} = Manifest.read(merge_manifest)
      {:ok, _header, undone} = Manifest.read(rollback_manifest)

      merged =
        for %{"action" => "succession_merge", "ids" => [id], "merged" => uid} <- merges,
            into: %{},
            do: {id, uid}

      outcomes =
        for %{"action" => "undo_succession_merge", "ids" => [id], "outcome" => outcome} <- undone,
            into: %{},
            do: {merged[id], outcome}

      assert outcomes == %{
               w.s.uid => %{"skipped" => "not_merged"},
               w.s2.uid => %{"skipped" => "merge_superseded"}
             }

      assert held_by(ctx, w.sb) == w.p.uid
      assert held_by(ctx, w.s2b) == w.p2.uid
      assert reload(ctx, w.s2).deleted_reason == "merged"
      assert reload(ctx, w.p).source_retired_at == nil
      assert reload(ctx, w.p2).source_retired_at == nil
      assert reload(ctx, w.x).deleted_at == nil
    end
  end

  describe "source-id-verify" do
    test "V6 fails when a record the manifest names is revived outside the rollback", ctx do
      named = record!(ctx, hostname: "host61.example.com")
      other = record!(ctx, hostname: "host62.example.com")
      now = DateTime.utc_now()

      manifest =
        hand_manifest!(ctx, "revived", DateTime.shift(now, hour: -1), [
          entry(
            "source-id-retire",
            "mark_source_retired",
            "platform.ocsf_devices",
            [named.uid],
            DateTime.shift(now, minute: -30)
          )
        ])

      for record <- [named, other] do
        soft_delete!(record, "system:source_id_remediation_test", "test")
        revive!(record)
      end

      assert %{result: :fail, details: %{records: 1, revived: 1, sample: [revival]}} =
               check(verify!(ctx, verify_manifests: [manifest]), "V6")

      assert revival.device_uid == named.uid
    end

    test "V6 does not count the rollback's own restores", ctx do
      shell = record!(ctx, discovery_sources: ["sweep"])
      soft_delete!(shell, "system:dire_remediation", "seed_released")
      deleted_at = reload(ctx, shell).deleted_at
      now = DateTime.utc_now()

      manifest =
        hand_manifest!(ctx, "shells", DateTime.shift(now, hour: -1), [
          entry(
            "released-seed-shells",
            "tombstone_shells",
            "platform.ocsf_devices",
            [shell.uid],
            DateTime.shift(now, minute: -30),
            %{
              "deleted_reason" => "seed_released",
              "deleted_by" => "system:dire_remediation",
              "deleted_at" => [DateTime.to_iso8601(deleted_at)]
            }
          )
        ])

      assert {:ok, %{reports: %{@rollback => %{shells_restored: 1}}}} =
               DireRemediation.run(
                 mode: :execute,
                 steps: [@rollback],
                 rollback_manifests: [manifest],
                 manifest_path: path(ctx, "restore"),
                 actor: ctx.actor
               )

      assert reload(ctx, shell).deleted_at == nil
      assert revival_applications(shell) == ["dire_remediation_rollback"]

      assert check(verify!(ctx, verify_manifests: [manifest]), "V6") == %{
               check: "V6",
               result: :pass,
               details: %{records: 1, revived: 0, sample: []}
             }
    end

    test "V7 judges the latest reconciliation run, or the runs since the run started", ctx do
      now = DateTime.utc_now()

      assert %{result: :pending} = check(verify!(ctx, []), "V7")

      reconciliation_run!("completed", 0, DateTime.shift(now, hour: -3))
      assert %{result: :pass, details: %{status: "completed"}} = check(verify!(ctx, []), "V7")

      reconciliation_run!("completed", 2, DateTime.shift(now, hour: -2))
      assert %{result: :fail, details: %{errors: 2}} = check(verify!(ctx, []), "V7")

      manifest = hand_manifest!(ctx, "runs", DateTime.shift(now, hour: -1), [])

      assert %{result: :pending, details: %{runs: 0}} =
               check(verify!(ctx, verify_manifests: [manifest]), "V7")

      reconciliation_run!("completed", 0, DateTime.shift(now, minute: 1))

      assert %{result: :pass, details: %{runs: 1, runs_after_last_batch: 1}} =
               check(verify!(ctx, verify_manifests: [manifest]), "V7")

      reconciliation_run!("failed", 0, DateTime.shift(now, minute: 2))

      assert %{result: :fail, details: %{runs: 2, failed_runs: 1}} =
               check(verify!(ctx, verify_manifests: [manifest]), "V7")
    end

    test "V8 fails while a succession merge joins two ids the source still reports", ctx do
      merged = record!(ctx, hostname: "host71.example.com")
      survivor = record!(ctx, hostname: "host72.example.com")
      retired = %{uid: merged.uid, source_id: "#{ctx.n}071"}
      current = %{uid: survivor.uid, source_id: "#{ctx.n}072"}
      collect(ctx, 1, [retired, current], hours: 0)

      event_id =
        merge_audit!(merged.uid, survivor.uid, "source_succession", %{
          "retired_ids" => [%{"value" => retired.source_id, "partition" => ctx.id_partition}],
          "current_ids" => [%{"value" => current.source_id, "partition" => ctx.id_partition}]
        })

      assert %{result: :fail, details: %{merges: 1, joined_present: 1, sample: [sample]}} =
               check(verify!(ctx, []), "V8")

      assert sample == %{event_id: event_id, merged: merged.uid, survivor: survivor.uid}

      collect(ctx, 2, [current], hours: 1)

      assert %{result: :pass, details: %{merges: 1, joined_present: 0}} =
               check(verify!(ctx, []), "V8")

      collect(ctx, 3, [retired, current], hours: 2)
      assert %{result: :fail} = check(verify!(ctx, []), "V8")

      merge_audit!(survivor.uid, merged.uid, "unmerge", %{"original_merge_event_id" => event_id})

      assert check(verify!(ctx, []), "V8") == %{
               check: "V8",
               result: :pass,
               details: %{merges: 0, joined_present: 0, pending: 0, sample: []}
             }
    end
  end

  test "every step fails closed without the device cleanup settings", ctx do
    Repo.query!("DELETE FROM platform.device_cleanup_settings WHERE key = 'default'")

    assert {:error, {:step_failures, %{reports: reports}}} =
             DireRemediation.run(mode: :dry_run, steps: @steps ++ [@verify], actor: ctx.actor)

    assert reports ==
             Map.new(@steps ++ [@verify], &{&1, %{errors: 1, error: ":settings_unavailable"}})
  end

  # The world of the moduledoc. The source reported every id in collection 1 and only the
  # current ids in collections 2-4, ten days back, and a pass retired R5's id without leaving
  # its mark.
  defp world!(ctx) do
    ids =
      Map.new(
        [c1a: 1, c1b: 2, pa: 3, sb: 4, p2a: 5, s2b: 6, p3a: 7, s3b: 8, r5a: 9],
        fn {key, k} -> {key, "#{ctx.n}0#{k}"} end
      )

    canonical = %{"identity_state" => "canonical"}
    successor = at(ctx, -20)

    c1 = record!(ctx, hostname: "host11.example.com", mac: mac(11))
    p = record!(ctx, hostname: "host21.example.com", mac: mac(21), metadata: canonical)
    s = record!(ctx, hostname: "host22.example.com", mac: mac(21), created_time: successor)
    p2 = record!(ctx, hostname: "host31.example.com", mac: mac(31), metadata: canonical)
    s2 = record!(ctx, hostname: "host31.example.com", mac: mac(31), created_time: successor)
    p3 = record!(ctx, hostname: "host41.example.com", mac: mac(41), metadata: canonical)
    s3 = record!(ctx, hostname: "host42.example.com", mac: mac(41), created_time: successor)
    r5 = record!(ctx, hostname: "host51.example.com")
    duplicate = %{"armis_device_id" => "#{ctx.n}091", "sync_service_id" => ctx.inst}
    d1 = record!(ctx, hostname: "host81.example.com", metadata: duplicate)
    d2 = record!(ctx, hostname: "host82.example.com", metadata: duplicate)
    x = record!(ctx, discovery_sources: ["sweep"])

    # The days, from t0, on which the source first and last saw each device.
    reported =
      for {record, key, first, last} <- [
            {c1, :c1a, -9, -1},
            {c1, :c1b, -8, 0},
            {p, :pa, -7, -1},
            {s, :sb, -7, 0},
            {p2, :p2a, -6, -2},
            {s2, :s2b, -1, 0},
            {p3, :p3a, -5, -1},
            {s3, :s3b, -3, 0},
            {r5, :r5a, -4, -1}
          ] do
        source_id!(ctx, record, ids[key], first, last)
      end

    register(ctx, c1, :integration_id, integration_id(ctx, ids.c1a))
    backdate(ctx)

    current = Enum.filter(reported, &(&1.source_id in [ids.c1b, ids.sb, ids.s2b, ids.s3b]))
    collect(ctx, 1, reported, hours: 0)
    for k <- 2..4, do: collect(ctx, k, current, hours: k)

    assert {:ok, %{status: :completed, retired: 1, marked: 1}} =
             SourceRetirement.run(ctx.instance,
               settings: @settings,
               now: DateTime.shift(ctx.t0, hour: 100),
               actor: ctx.actor,
               uids: [r5.uid]
             )

    %{num_rows: 1} =
      Repo.query!("UPDATE platform.ocsf_devices SET source_retired_at = NULL WHERE uid = $1", [
        r5.uid
      ])

    Map.merge(ids, %{
      c1: c1,
      p: p,
      s: s,
      p2: p2,
      s2: s2,
      p3: p3,
      s3: s3,
      r5: r5,
      d1: d1,
      d2: d2,
      x: x,
      duplicate: duplicate["armis_device_id"]
    })
  end

  # The second world of the moduledoc, built as `world!/1` builds R5.
  defp candidates_world!(ctx) do
    ids =
      Map.new([p6a: 1, s6b: 2, p7a: 3, s7b: 4, r8a: 5], fn {key, k} ->
        {key, "#{ctx.n}1#{k}"}
      end)

    successor = at(ctx, -20)
    p6 = record!(ctx, hostname: "host61.example.com", mac: mac(61))
    s6 = record!(ctx, hostname: "host62.example.com", mac: mac(61), created_time: successor)
    p7 = record!(ctx, hostname: "host71.example.com", mac: mac(71))
    s7 = record!(ctx, hostname: "host72.example.com", mac: mac(71), created_time: successor)
    r8 = record!(ctx, hostname: "host91.example.com")

    reported =
      for {record, key, first, last} <- [
            {p6, :p6a, -7, -1},
            {s6, :s6b, -7, 0},
            {p7, :p7a, -5, -1},
            {s7, :s7b, -3, 0},
            {r8, :r8a, -4, -1}
          ] do
        source_id!(ctx, record, ids[key], first, last)
      end

    backdate(ctx)
    current = Enum.filter(reported, &(&1.source_id in [ids.s6b, ids.s7b]))
    collect(ctx, 1, reported, hours: 0)
    for k <- 2..4, do: collect(ctx, k, current, hours: k)
    retired = [p6.uid, p7.uid, r8.uid]

    assert {:ok, %{status: :completed, retired: 3, marked: 3}} =
             SourceRetirement.run(ctx.instance,
               settings: @settings,
               now: DateTime.shift(ctx.t0, hour: 100),
               actor: ctx.actor,
               uids: retired
             )

    %{num_rows: 3} =
      Repo.query!(
        "UPDATE platform.ocsf_devices SET source_retired_at = NULL WHERE uid = ANY($1)",
        [retired]
      )

    Map.merge(ids, %{p6: p6, s6: s6, p7: p7, s7: s7, r8: r8})
  end

  # What the remediation can change on the world's records: their deletion, marks and identity
  # states, the ids they hold and have archived, and the merges and decisions naming them.
  defp state(world) do
    uids = for {_key, %Device{uid: uid}} <- world, do: uid

    Enum.map(
      [
        "SELECT uid, deleted_at, source_retired_at, metadata->>'identity_state' " <>
          "FROM platform.ocsf_devices WHERE uid = ANY($1) ORDER BY uid",
        "SELECT device_id, identifier_type, identifier_value FROM platform.device_identifiers " <>
          "WHERE device_id = ANY($1) ORDER BY 1, 2, 3",
        "SELECT device_id, identifier_type, identifier_value " <>
          "FROM platform.device_identifier_archive WHERE device_id = ANY($1) ORDER BY 1, 2, 3",
        "SELECT count(*) FROM platform.merge_audit " <>
          "WHERE from_device_id = ANY($1) OR to_device_id = ANY($1)",
        "SELECT count(*) FROM platform.identity_decisions WHERE device_uids && CAST($1 AS text[])"
      ],
      &Repo.query!(&1, [uids]).rows
    )
  end

  defp put_settings!(ctx, attrs) do
    case DeviceCleanupSettings.get_settings(actor: ctx.actor) do
      {:ok, %DeviceCleanupSettings{} = settings} ->
        {:ok, _settings} =
          DeviceCleanupSettings.update_settings(settings, attrs, actor: ctx.actor)

      _missing ->
        {:ok, _settings} = DeviceCleanupSettings.create_settings(attrs, actor: ctx.actor)
    end
  end

  # A record created thirty days before t0 unless `attrs` says otherwise. No record has an IP.
  defp record!(ctx, attrs) do
    Device
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{uid: "sr:" <> Ecto.UUID.generate(), created_time: at(ctx, -30)},
        Map.new(attrs)
      )
    )
    |> Ash.create!(actor: ctx.actor)
  end

  # Registers the Armis id `value` on the record, with the times the source first and last saw
  # the device, `first` and `last` days from t0, as an Armis sync records them.
  defp source_id!(ctx, record, value, first, last) do
    register(ctx, record, :armis_device_id, value, %{
      "source_first_seen_time" => iso(at(ctx, first)),
      "source_last_seen_time" => iso(at(ctx, last))
    })

    %{uid: record.uid, source_id: value}
  end

  defp at(ctx, days), do: DateTime.shift(ctx.t0, day: days)

  defp integration_id(ctx, value),
    do: IntegrationIdentity.scoped_device_id("armis", ctx.inst, value)

  defp mac(i), do: "00:00:5e:00:53:" <> pad(i)
  defp pad(i), do: String.pad_leading(Integer.to_string(i), 2, "0")
  defp iso(%DateTime{} = time), do: DateTime.to_iso8601(time)

  # Backdates the sightings of the instance's source identifiers to t0, so only the
  # collections decide when the source last reported them.
  defp backdate(ctx) do
    Repo.update_all(
      from(di in "device_identifiers", where: di.partition == ^ctx.id_partition),
      [set: [first_seen: DateTime.to_naive(ctx.t0), last_seen: DateTime.to_naive(ctx.t0)]],
      prefix: @prefix
    )
  end

  # Activates exact collection k of the instance, observed `hours` after t0, reporting
  # `present`.
  defp collect(ctx, k, present, opts) do
    collection_id = "#{ctx.inst}-c#{k}"
    content_hash = sha(collection_id)
    observed_at = DateTime.shift(ctx.t0, hour: Keyword.fetch!(opts, :hours))

    snapshot = %{
      partition: "default",
      source: "armis",
      source_instance: ctx.inst,
      collection_id: collection_id,
      content_hash: content_hash,
      query_hash: nil,
      observed_at: observed_at,
      metadata: %{"accounting_status" => "exact"}
    }

    observations =
      Enum.map(present, fn record ->
        %{
          device_id: record.uid,
          partition: "default",
          source: "armis",
          source_instance: ctx.inst,
          source_object_id: record.source_id,
          source_integration_id: "armis:source:#{ctx.inst}:#{record.source_id}",
          collection_id: collection_id,
          content_hash: content_hash,
          query_hash: nil,
          present: true,
          first_observed_at: observed_at,
          last_observed_at: observed_at,
          absent_since: nil,
          hostname: nil,
          ip: nil,
          mac: nil,
          serial_number: nil,
          vendor_name: nil,
          model: nil,
          device_type: nil,
          site_name: nil,
          management_status: nil,
          metadata: %{}
        }
      end)

    assert :ok = DeviceSourceObservationIngestor.activate_resolved(snapshot, observations)
    snapshot
  end

  defp register(ctx, record, type, value, metadata \\ %{}) do
    {:ok, _identifier} =
      DeviceIdentifier
      |> Ash.Changeset.for_create(:register, %{
        device_id: record.uid,
        identifier_type: type,
        identifier_value: value,
        partition: ctx.id_partition,
        confidence: :strong,
        source: "test",
        metadata: metadata
      })
      |> Ash.create(actor: ctx.actor)
  end

  defp held_by(ctx, value), do: typed_id_holder(:armis_device_id, value, ctx.id_partition)

  defp typed_id_holder(type, value, partition) do
    Repo.one(
      from(di in "device_identifiers",
        where:
          di.identifier_type == ^Atom.to_string(type) and di.identifier_value == ^value and
            di.partition == ^partition,
        select: di.device_id
      ),
      prefix: @prefix
    )
  end

  # The archived rows of the Armis id `value` and of the integration id derived from it, the
  # Armis rows first.
  defp archived(ctx, value) do
    integration_id = integration_id(ctx, value)

    from(a in "device_identifier_archive",
      where:
        a.partition == ^ctx.id_partition and
          ((a.identifier_type == "armis_device_id" and a.identifier_value == ^value) or
             (a.identifier_type == "integration_id" and a.identifier_value == ^integration_id)),
      select: %{id: a.id, device_id: a.device_id, identifier_type: a.identifier_type}
    )
    |> Repo.all(prefix: @prefix)
    |> Enum.sort_by(&{&1.identifier_type, &1.id})
  end

  defp reload(ctx, record) do
    {:ok, device} = Device.get_by_uid(record.uid, true, actor: ctx.actor)
    device
  end

  defp reviews(uids, actor) do
    uids = Enum.sort(uids)

    IdentityDecision
    |> Ash.Query.filter(decision_kind == :succession_review)
    |> Ash.read!(actor: actor)
    |> Enum.filter(&(Enum.sort(&1.device_uids) == uids))
  end

  defp soft_delete!(record, deleted_by, reason) do
    %{num_rows: 1} =
      Repo.query!(
        "UPDATE platform.ocsf_devices SET deleted_at = now(), deleted_by = $2, " <>
          "deleted_reason = $3 WHERE uid = $1",
        [record.uid, deleted_by, reason]
      )
  end

  defp revive!(record) do
    %{num_rows: 1} =
      Repo.query!(
        "UPDATE platform.ocsf_devices SET deleted_at = NULL, deleted_by = NULL, " <>
          "deleted_reason = NULL WHERE uid = $1",
        [record.uid]
      )
  end

  defp revival_applications(record) do
    %{rows: rows} =
      Repo.query!(
        "SELECT revived_by_application FROM platform.device_revival_audit " <>
          "WHERE device_uid = $1 ORDER BY event_id",
        [record.uid]
      )

    Enum.map(rows, &hd/1)
  end

  # A sync run of the instance whose first chunk committed at `at`, with chunks `received` of
  # `total`.
  defp sync_run!(ctx, run_id, total, received, at) do
    Repo.query!(
      "INSERT INTO platform.sync_ingest_runs " <>
        "(sync_service_id, sync_run_id, total_chunks, received_chunks, inserted_at, updated_at) " <>
        "VALUES (CAST(CAST($1 AS text) AS uuid), $2, $3, $4, $5, $5)",
      [ctx.inst, run_id, total, received, DateTime.to_naive(at)]
    )
  end

  defp reconciliation_run!(status, errors, %DateTime{} = started_at) do
    Repo.query!(
      "INSERT INTO platform.identity_reconciliation_runs (run_id, started_at, status, errors) " <>
        "VALUES (CAST(CAST($1 AS text) AS uuid), $2, $3, $4)",
      [Ecto.UUID.generate(), DateTime.to_naive(started_at), status, errors]
    )
  end

  defp merge_audit!(from_uid, to_uid, reason, details) do
    %{rows: [[event_id]]} =
      Repo.query!(
        "INSERT INTO platform.merge_audit (from_device_id, to_device_id, reason, details, " <>
          "created_at) VALUES ($1, $2, $3, CAST(CAST($4 AS text) AS jsonb), $5) " <>
          "RETURNING event_id::text",
        [from_uid, to_uid, reason, Jason.encode!(details), NaiveDateTime.utc_now()]
      )

    event_id
  end

  # A manifest as a run started at `started_at` writes it, holding `entries`.
  defp hand_manifest!(ctx, name, %DateTime{} = started_at, entries) do
    header = %{
      "manifest" => "dire_remediation",
      "version" => 1,
      "mode" => "execute",
      "steps" => [],
      "started_at" => iso(started_at)
    }

    manifest = path(ctx, name)
    File.write!(manifest, Enum.map([header | entries], &[Jason.encode!(&1), "\n"]))
    manifest
  end

  defp entry(step, action, table, ids, %DateTime{} = at, extra \\ %{}) do
    Map.merge(extra, %{
      "step" => step,
      "action" => action,
      "table" => table,
      "ids" => ids,
      "count" => length(ids),
      "at" => iso(at)
    })
  end

  defp path(ctx, name), do: Path.join(ctx.dir, name <> ".ndjson")

  defp failing_manifest(ctx, name, step, action) do
    Process.put(:fail_action, action)
    %{Manifest.open(path(ctx, name), %{mode: "execute", steps: [step]}) | writer: FailWriter}
  end

  defp verify(ctx, opts),
    do: DireRemediation.run([mode: :dry_run, steps: [@verify], actor: ctx.actor] ++ opts)

  defp verify!(ctx, opts) do
    case verify(ctx, opts) do
      {:ok, %{reports: %{@verify => report}}} -> report
      {:error, {:step_failures, %{reports: %{@verify => report}}}} -> report
    end
  end

  defp check(report, name), do: Enum.find(report.checks, &(&1.check == name))
  defp results(report), do: Map.new(report.checks, &{&1.check, &1.result})

  defp sha(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
end
