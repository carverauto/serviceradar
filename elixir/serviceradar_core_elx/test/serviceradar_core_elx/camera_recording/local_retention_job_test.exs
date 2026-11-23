defmodule ServiceRadarCoreElx.CameraRecording.LocalRetentionJobTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingHolds
  alias ServiceRadarCoreElx.CameraRecording.LocalRetentionJob
  alias ServiceRadarCoreElx.Test.StorageHTTPFixture, as: Fixture
  alias ServiceRadarNVRClient.Config, as: ClientConfig

  @moduletag :tmp_dir

  @member "serviceradar-nvr-0"
  @storage_id "00000000-0000-4000-8000-000000000011"
  @recovery_generation "00000000-0000-4000-8000-000000000021"
  @camera_id "00000000-0000-4000-8000-000000000103"
  @profile_id "00000000-0000-4000-8000-000000000104"
  @fixed_now ~U[2026-11-22 12:00:00.000000Z]
  @gib 1_073_741_824
  @wire_token "synthetic-local-retention-wire-token-0123456789"

  describe "Oban worker configuration and no-op behavior" do
    test "uses maintenance queue, 500-block pass cap, and unique window including executing" do
      opts = LocalRetentionJob.__opts__()

      assert opts[:queue] == :maintenance
      assert opts[:max_attempts] == 3
      assert LocalRetentionJob.max_blocks_per_pass() == 500

      unique = Keyword.fetch!(opts, :unique)
      assert unique[:keys] == [:member]
      assert unique[:states] == [:available, :scheduled, :retryable, :executing]
      assert :executing in unique[:states]
    end

    test "enqueue_all returns empty list when NVR client is not configured" do
      insert_fn = fn _changeset ->
        flunk("insert_fn must not be called when NVR client is not configured")
      end

      assert {:ok, []} =
               LocalRetentionJob.enqueue_all(
                 target_opts: [config_file: nil, token_file: nil],
                 insert_fn: insert_fn
               )
    end

    test "enqueue_all fans out one unique per-member job per configured NVR member" do
      targets = [
        target("serviceradar-nvr-0", "00000000-0000-4000-8000-000000000011"),
        target("serviceradar-nvr-1", "00000000-0000-4000-8000-000000000012")
      ]

      {:ok, agent} = Agent.start_link(fn -> [] end)

      insert_fn = fn changeset ->
        Agent.update(agent, &(&1 ++ [changeset]))
        {:ok, Ecto.Changeset.apply_changes(changeset)}
      end

      assert {:ok, jobs} = LocalRetentionJob.enqueue_all(targets: targets, insert_fn: insert_fn)
      assert Enum.map(jobs, & &1.args) == [%{"member" => "serviceradar-nvr-0"}, %{"member" => "serviceradar-nvr-1"}]

      changesets = Agent.get(agent, & &1)
      assert length(changesets) == 2

      for {changeset, expected_member} <- Enum.zip(changesets, ["serviceradar-nvr-0", "serviceradar-nvr-1"]) do
        assert changeset.valid?
        assert Ecto.Changeset.get_field(changeset, :args) == %{"member" => expected_member}
        assert Ecto.Changeset.get_field(changeset, :queue) == "maintenance"
        assert Ecto.Changeset.get_field(changeset, :worker) == "ServiceRadarCoreElx.CameraRecording.LocalRetentionJob"

        unique = Ecto.Changeset.get_change(changeset, :unique)
        assert unique[:keys] == [:member]
        assert unique[:period] == 55
        assert unique[:states] == [:available, :scheduled, :retryable, :executing]
      end
    end

    test "enqueue_all propagates Oban insert failures" do
      targets = [
        target("serviceradar-nvr-0", "00000000-0000-4000-8000-000000000011"),
        target("serviceradar-nvr-1", "00000000-0000-4000-8000-000000000012")
      ]

      insert_fn = fn changeset ->
        if Ecto.Changeset.get_field(changeset, :args) == %{"member" => "serviceradar-nvr-1"} do
          {:error, :db_unavailable}
        else
          {:ok, Ecto.Changeset.apply_changes(changeset)}
        end
      end

      assert {:error, :db_unavailable} = LocalRetentionJob.enqueue_all(targets: targets, insert_fn: insert_fn)
    end

    test "perform dispatches per-member args to run_member" do
      assert {:error, :invalid_nvr_member} =
               LocalRetentionJob.perform(%Oban.Job{args: %{"member" => "invalid member name"}})
    end
  end

  describe "space-driven high-water to low-water eviction" do
    test "evicts oldest verified blocks from high water down to low water and stops at low water" do
      # Budget: 1000 bytes, high water 90% (900), low water 80% (800).
      # Used: 950 bytes across 5 blocks of 50 bytes each -> evict 3 oldest (950 - 150 = 800 <= 800).
      entries =
        for idx <- 1..5 do
          entry(idx, archive_state: :verified, media_bytes: 50, timeline_start_us: idx * 1_000_000)
        end

      {harness, opts} =
        build_harness(
          entries: entries,
          capacity: capacity(used_bytes: 950, max_spool_bytes: 1_000, blocks: 5, max_blocks: 100),
          settings: settings(max_local_age_mode: :unlimited, max_local_age_seconds: nil)
        )

      assert {:ok, summary} = LocalRetentionJob.run_target(target(), opts)
      assert summary.status == :ok
      assert summary.reclaimed == 3
      assert summary.processed == 3

      state = harness_state(harness)

      assert Enum.map(state.intents, &{&1.block_key, &1.reason}) == [
               {block_key(1), :budget},
               {block_key(2), :budget},
               {block_key(3), :budget}
             ]

      assert Enum.map(state.finalized, & &1.block_key) == [block_key(1), block_key(2), block_key(3)]
    end

    test "does not space-evict or query present entries when below high water and age modes are unlimited" do
      entries = [entry(1, archive_state: :verified, media_bytes: 50)]

      {harness, opts} =
        build_harness(
          entries: entries,
          capacity: capacity(used_bytes: 899, max_spool_bytes: 1_000, blocks: 1, max_blocks: 100),
          settings:
            settings(
              max_local_age_mode: :unlimited,
              max_local_age_seconds: nil,
              local_only_max_age_mode: :unlimited,
              local_only_max_age_seconds: nil
            )
        )

      assert {:ok, summary} = LocalRetentionJob.run_target(target(), opts)
      assert summary.reclaimed == 0
      state = harness_state(harness)
      assert state.intents == []
      assert state.present_loads == []
    end

    test "stops at low water when reclaim succeeds but follow-up lookup_blocks returns 503" do
      # Budget: 1000 bytes, high water 90% (900), low water 80% (800).
      # Used: 950 bytes across ten 100-byte local-only blocks under overwrite_oldest.
      # Two reclaims bring projected bytes from 950 -> 750 <= 800 even when lookup_blocks returns 503.
      entries =
        for idx <- 1..10 do
          entry(idx, archive_state: :not_required, media_bytes: 100, timeline_start_us: idx * 1_000_000)
        end

      {harness, opts} =
        build_harness(
          entries: entries,
          capacity: capacity(used_bytes: 950, max_spool_bytes: 1_000, blocks: 10, max_blocks: 100),
          settings:
            settings(
              max_local_age_mode: :unlimited,
              max_local_age_seconds: nil,
              local_only_full_policy: :overwrite_oldest
            ),
          lookup_error: {:error, {:lookup_status, 503, %{"error" => "busy"}}}
        )

      assert {:ok, summary} = LocalRetentionJob.run_target(target(), opts)
      assert summary.reclaimed == 0
      assert summary.deferred == 2
      assert summary.processed == 2

      state = harness_state(harness)
      assert Enum.map(state.reclaim_calls, & &1.block_id) == [block_key(1), block_key(2)]
      assert state.finalized == []
    end

    test "deducts projected usage on resumed sealed reclaim when follow-up lookup returns 503" do
      # Used: 950 bytes, low water 800. Resuming block 1 (100 bytes) + space-evicting block 2 (100 bytes)
      # reaches 750 <= 800 even if follow-up lookup_blocks returns 503 after each reclaim.
      still_sealed = entry(1, local_state: :reclaiming, archive_state: :verified, media_bytes: 100)

      present_entries =
        for idx <- 2..6 do
          entry(idx, archive_state: :verified, media_bytes: 100, timeline_start_us: idx * 1_000_000)
        end

      {harness, opts} =
        build_harness(
          reclaiming_entries: [still_sealed],
          entries: present_entries,
          capacity: capacity(used_bytes: 950, max_spool_bytes: 1_000, blocks: 6, max_blocks: 100),
          settings: settings(max_local_age_mode: :unlimited, max_local_age_seconds: nil),
          dispositions: %{
            still_sealed.id => %{operation_id: "00000000-0000-4000-8000-000000000778", copy: :local}
          },
          initial_nvr_states: %{still_sealed.block_key => :sealed},
          post_reclaim_lookup_error: {:error, {:lookup_status, 503, %{"error" => "busy"}}}
        )

      assert {:ok, summary} = LocalRetentionJob.run_target(target(), opts)
      assert summary.reclaimed == 0
      assert summary.deferred == 2
      assert summary.processed == 2

      state = harness_state(harness)
      assert Enum.map(state.reclaim_calls, & &1.block_id) == [block_key(1), block_key(2)]
      assert state.finalized == []
    end

    test "triggers space eviction on block cap and stops once projected blocks reach low water" do
      entries =
        for idx <- 1..4 do
          entry(idx, archive_state: :verified, media_bytes: 10, timeline_start_us: idx * 1_000_000)
        end

      # Bytes are well under high water (40 / 10000), but blocks are at 90 / 100 (high=90, low=80).
      # Evicting 4 available blocks brings blocks from 90 -> 86 (stops when candidates exhausted).
      {harness, opts} =
        build_harness(
          entries: entries,
          capacity: capacity(used_bytes: 40, max_spool_bytes: 10_000, blocks: 90, max_blocks: 100),
          settings: settings(max_local_age_mode: :unlimited, max_local_age_seconds: nil)
        )

      assert {:ok, summary} = LocalRetentionJob.run_target(target(), opts)
      assert summary.reclaimed == 4
      assert length(harness_state(harness).finalized) == 4
    end
  end

  describe "C1 eviction table protections" do
    test "never evicts kind (c) archive states, quarantined entries, or unreconciled blocks" do
      kind_c_states = [:awaiting_binding, :pending, :failed_retryable, :failed_terminal, :deleting, :missing]

      kind_c_entries =
        kind_c_states
        |> Enum.with_index(1)
        |> Enum.map(fn {arch_state, idx} ->
          entry(idx, archive_state: arch_state, media_bytes: 100, sealed_at: hours_ago(48))
        end)

      quarantined =
        entry(20,
          local_state: :quarantined,
          quarantine_reason: :unattributable,
          archive_state: :verified,
          media_bytes: 100,
          sealed_at: hours_ago(48)
        )

      unreconciled =
        entry(21,
          recording_block_id: nil,
          archive_state: :verified,
          media_bytes: 100,
          sealed_at: hours_ago(48)
        )

      evictable = entry(22, archive_state: :verified, media_bytes: 100, sealed_at: hours_ago(1))

      {harness, opts} =
        build_harness(
          entries: kind_c_entries ++ [quarantined, unreconciled, evictable],
          capacity: capacity(used_bytes: 950, max_spool_bytes: 1_000, blocks: 9, max_blocks: 100),
          settings: settings(max_local_age_mode: :limited, max_local_age_seconds: 3_600)
        )

      assert {:ok, summary} = LocalRetentionJob.run_target(target(), opts)
      assert summary.reclaimed == 1
      assert Enum.map(harness_state(harness).finalized, & &1.block_key) == [block_key(22)]
    end
  end

  describe "PD5 hold semantics" do
    test "evicts held verified block (archive copy pinned) but skips held local-only and archive-deleted blocks" do
      verified_held = entry(1, archive_state: :verified, media_bytes: 100, timeline_start_us: 1_000)
      local_only_held = entry(2, archive_state: :not_required, media_bytes: 100, timeline_start_us: 2_000)
      deleted_held = entry(3, archive_state: :deleted, media_bytes: 100, timeline_start_us: 3_000)
      unheld = entry(4, archive_state: :verified, media_bytes: 100, timeline_start_us: 4_000)

      hold = %{
        id: "00000000-0000-4000-8000-000000000901",
        state: :accepted,
        camera_source_id: @camera_id,
        stream_profile_id: @profile_id,
        start_us: 0,
        end_us: 3_500,
        kind: :investigation,
        unavailable_blocks: []
      }

      {harness, opts} =
        build_harness(
          entries: [verified_held, local_only_held, deleted_held, unheld],
          holds: [hold],
          capacity: capacity(used_bytes: 950, max_spool_bytes: 1_000, blocks: 4, max_blocks: 100),
          settings:
            settings(
              max_local_age_mode: :unlimited,
              max_local_age_seconds: nil,
              local_only_full_policy: :overwrite_oldest
            )
        )

      assert {:ok, summary} = LocalRetentionJob.run_target(target(), opts)
      assert summary.reclaimed == 2
      assert summary.held_skipped == 2

      assert Enum.map(harness_state(harness).finalized, & &1.block_key) == [
               block_key(1),
               block_key(4)
             ]
    end
  end

  describe "local_only_full_policy behavior" do
    test "overwrite_oldest interleaves kind (a) and kind (b) oldest-first with distinct disposition reasons" do
      entries = [
        entry(1, archive_state: :not_required, media_bytes: 60, timeline_start_us: 1_000),
        entry(2, archive_state: :verified, media_bytes: 60, timeline_start_us: 2_000),
        entry(3, archive_state: :not_required, media_bytes: 60, timeline_start_us: 3_000),
        entry(4, archive_state: :verified, media_bytes: 60, timeline_start_us: 4_000)
      ]

      # Need to free 150 bytes (950 -> 800): blocks 1, 2, 3 (180 bytes) bring projected to 770 <= 800.
      {harness, opts} =
        build_harness(
          entries: entries,
          capacity: capacity(used_bytes: 950, max_spool_bytes: 1_000, blocks: 4, max_blocks: 100),
          settings:
            settings(
              max_local_age_mode: :unlimited,
              max_local_age_seconds: nil,
              local_only_full_policy: :overwrite_oldest
            )
        )

      assert {:ok, summary} = LocalRetentionJob.run_target(target(), opts)
      assert summary.reclaimed == 3

      assert Enum.map(harness_state(harness).intents, &{&1.block_key, &1.reason}) == [
               {block_key(1), :local_only_overwrite},
               {block_key(2), :budget},
               {block_key(3), :local_only_overwrite}
             ]
    end

    test "stop_when_full and unset policy never space-evict kind (b)" do
      entries = [
        entry(1, archive_state: :not_required, media_bytes: 100, timeline_start_us: 1_000),
        entry(2, archive_state: :verified, media_bytes: 100, timeline_start_us: 2_000)
      ]

      for full_policy <- [:stop_when_full, nil] do
        {harness, opts} =
          build_harness(
            entries: entries,
            capacity: capacity(used_bytes: 950, max_spool_bytes: 1_000, blocks: 2, max_blocks: 100),
            settings:
              settings(
                max_local_age_mode: :unlimited,
                max_local_age_seconds: nil,
                local_only_full_policy: full_policy
              )
          )

        assert {:ok, summary} = LocalRetentionJob.run_target(target(), opts)
        assert summary.reclaimed == 1
        assert Enum.map(harness_state(harness).finalized, & &1.block_key) == [block_key(2)]
      end
    end
  end

  describe "age-driven eviction" do
    test "evicts kind (a) by max_local_age and kind (b) by local_only_max_age regardless of full policy" do
      entries = [
        entry(1, archive_state: :verified, media_bytes: 50, sealed_at: hours_ago(30)),
        entry(2, archive_state: :verified, media_bytes: 50, sealed_at: hours_ago(2)),
        entry(3, archive_state: :not_required, media_bytes: 50, sealed_at: hours_ago(50)),
        entry(4, archive_state: :not_required, media_bytes: 50, sealed_at: hours_ago(10))
      ]

      # Below high water (200 / 1000) and stop_when_full: only age ceilings apply.
      {harness, opts} =
        build_harness(
          entries: entries,
          capacity: capacity(used_bytes: 200, max_spool_bytes: 1_000, blocks: 4, max_blocks: 100),
          settings:
            settings(
              max_local_age_mode: :limited,
              max_local_age_seconds: 86_400,
              local_only_full_policy: :stop_when_full,
              local_only_max_age_mode: :limited,
              local_only_max_age_seconds: 172_800
            )
        )

      assert {:ok, summary} = LocalRetentionJob.run_target(target(), opts)
      assert summary.reclaimed == 2

      assert Enum.map(harness_state(harness).intents, &{&1.block_key, &1.reason}) == [
               {block_key(1), :max_local_age},
               {block_key(3), :local_only_max_age}
             ]
    end
  end

  describe "crash recovery and retryable error handling" do
    test "resumes pre-existing reclaiming entries: finalizes already-reclaimed and retries still-sealed" do
      already_reclaimed = entry(1, local_state: :reclaiming, archive_state: :verified, media_bytes: 100)
      still_sealed = entry(2, local_state: :reclaiming, archive_state: :verified, media_bytes: 100)
      existing_op_id = "00000000-0000-4000-8000-000000000777"

      {harness, base_opts} =
        build_harness(
          reclaiming_entries: [already_reclaimed, still_sealed],
          entries: [],
          capacity: capacity(used_bytes: 100, max_spool_bytes: 1_000, blocks: 1, max_blocks: 100),
          settings: settings(max_local_age_mode: :unlimited, max_local_age_seconds: nil),
          dispositions: %{
            already_reclaimed.id => %{operation_id: "00000000-0000-4000-8000-000000000776", copy: :local},
            still_sealed.id => %{operation_id: existing_op_id, copy: :local}
          },
          initial_nvr_states: %{
            already_reclaimed.block_key => :reclaimed,
            still_sealed.block_key => :sealed
          }
        )

      assert {:ok, summary} = LocalRetentionJob.run_target(target(), base_opts)
      assert summary.resumed == 2
      assert summary.reclaimed == 2

      state = harness_state(harness)
      assert Enum.map(state.finalized, & &1.block_key) == [block_key(1), block_key(2)]

      # Only block 2 needed a reclaim_block RPC, reusing its existing operation_id and descriptor digest.
      assert [%{block_id: block2_id, request: req}] = state.reclaim_calls
      assert block2_id == block_key(2)
      assert req["operation_id"] == existing_op_id
      assert req["expected_descriptor_sha256"] == still_sealed.descriptor_sha256
    end

    test "leaves entry reclaiming on retryable NVR errors without aborting remaining candidates" do
      first = entry(1, archive_state: :verified, media_bytes: 100, timeline_start_us: 1_000)
      second = entry(2, archive_state: :verified, media_bytes: 100, timeline_start_us: 2_000)
      third = entry(3, archive_state: :verified, media_bytes: 100, timeline_start_us: 3_000)

      {harness, opts} =
        build_harness(
          entries: [first, second, third],
          capacity: capacity(used_bytes: 950, max_spool_bytes: 1_000, blocks: 3, max_blocks: 100),
          settings: settings(max_local_age_mode: :unlimited, max_local_age_seconds: nil),
          reclaim_overrides: %{
            first.block_key => {:error, {:reclaim_status, 409, %{"error" => "block_active"}}},
            second.block_key => {:error, {:reclaim_status, 503, %{"error" => "busy"}}}
          }
        )

      assert {:ok, summary} = LocalRetentionJob.run_target(target(), opts)
      assert summary.deferred == 2
      assert summary.reclaimed == 1

      state = harness_state(harness)
      assert Enum.map(state.finalized, & &1.block_key) == [block_key(3)]

      failed_steps = Enum.filter(state.steps, &(&1.step == :failed))
      assert Enum.map(failed_steps, & &1.extra[:error_class]) == ["block_active", "busy"]
    end

    test "finalizes on outcome_unknown when lookup_blocks confirms reclaimed" do
      first = entry(1, archive_state: :verified, media_bytes: 150, timeline_start_us: 1_000)

      {harness, opts} =
        build_harness(
          entries: [first],
          capacity: capacity(used_bytes: 950, max_spool_bytes: 1_000, blocks: 1, max_blocks: 100),
          settings: settings(max_local_age_mode: :unlimited, max_local_age_seconds: nil),
          reclaim_overrides: %{
            first.block_key => {:outcome_unknown_but_reclaimed}
          }
        )

      assert {:ok, summary} = LocalRetentionJob.run_target(target(), opts)
      assert summary.reclaimed == 1
      assert Enum.map(harness_state(harness).finalized, & &1.block_key) == [block_key(1)]
    end
  end

  describe "pass cap and safety gates" do
    test "caps each pass at 500 blocks per member" do
      entries =
        for idx <- 1..550 do
          entry(idx, archive_state: :verified, media_bytes: 10, timeline_start_us: idx * 1_000)
        end

      {harness, opts} =
        build_harness(
          entries: entries,
          capacity: capacity(used_bytes: 95_000, max_spool_bytes: 100_000, blocks: 550, max_blocks: 1_000),
          settings: settings(max_local_age_mode: :unlimited, max_local_age_seconds: nil)
        )

      assert {:ok, summary} = LocalRetentionJob.run_target(target(), opts)
      assert summary.reclaimed == 500
      assert summary.processed == 500
      assert length(harness_state(harness).finalized) == 500
    end

    test "keyset-paginates past more than one page of held local-only rows to evict newer unheld blocks" do
      # 550 oldest local-only rows are covered by a PD5 hold (exceeding one 500-row page),
      # followed by 5 unheld evictable rows of 100 bytes each.
      # Budget: 1000 bytes, high water 900, low water 800, used 950 -> evict 2 unheld blocks (551, 552).
      held_entries =
        for idx <- 1..550 do
          entry(idx, archive_state: :not_required, media_bytes: 100, timeline_start_us: idx * 1_000)
        end

      unheld_entries =
        for idx <- 551..555 do
          entry(idx, archive_state: :not_required, media_bytes: 100, timeline_start_us: idx * 1_000)
        end

      hold = %{
        id: "00000000-0000-4000-8000-000000000902",
        state: :accepted,
        camera_source_id: @camera_id,
        stream_profile_id: @profile_id,
        start_us: 0,
        end_us: 550_500,
        kind: :investigation,
        unavailable_blocks: []
      }

      {harness, opts} =
        build_harness(
          entries: held_entries ++ unheld_entries,
          holds: [hold],
          capacity: capacity(used_bytes: 950, max_spool_bytes: 1_000, blocks: 555, max_blocks: 1_000),
          settings:
            settings(
              max_local_age_mode: :unlimited,
              max_local_age_seconds: nil,
              local_only_full_policy: :overwrite_oldest
            )
        )

      assert {:ok, summary} = LocalRetentionJob.run_target(target(), opts)
      assert summary.held_skipped == 550
      assert summary.reclaimed == 2
      assert summary.processed == 2

      state = harness_state(harness)
      assert length(state.present_loads) == 2
      assert Enum.map(state.finalized, & &1.block_key) == [block_key(551), block_key(552)]
    end

    test "skips member when recovery gate is closed, storage_id mismatches, or inventory is not ready" do
      entries = [entry(1, archive_state: :verified, media_bytes: 100)]

      {_h1, closed_gate_opts} =
        build_harness(
          entries: entries,
          recovery_gate_result: {:error, :nvr_recovery_closed},
          capacity: capacity(used_bytes: 950, max_spool_bytes: 1_000, blocks: 1, max_blocks: 100)
        )

      assert {:ok, %{status: :skipped, skipped_reason: :nvr_recovery_closed}} =
               LocalRetentionJob.run_target(target(), closed_gate_opts)

      {_h2, mismatch_opts} =
        build_harness(
          entries: entries,
          status_overrides: %{storage_id: "00000000-0000-4000-8000-000000000099"},
          capacity: capacity(used_bytes: 950, max_spool_bytes: 1_000, blocks: 1, max_blocks: 100)
        )

      assert {:ok, %{status: :skipped, skipped_reason: :storage_id_mismatch}} =
               LocalRetentionJob.run_target(target(), mismatch_opts)

      {_h3, rebuilding_opts} =
        build_harness(
          entries: entries,
          status_overrides: %{inventory: :rebuilding, capacity: nil},
          capacity: capacity(used_bytes: 950, max_spool_bytes: 1_000, blocks: 1, max_blocks: 100)
        )

      assert {:ok, %{status: :skipped, skipped_reason: :inventory_not_ready}} =
               LocalRetentionJob.run_target(target(), rebuilding_opts)
    end
  end

  describe "end-to-end mTLS ServiceRadarNVRClient wire integration" do
    test "enqueue_all reads configured members from disk and run_member drives status, reclaim, and lookup over mTLS",
         ctx do
      dir = setup_wire_recovery_gate!(ctx)
      certs = generate_wire_certs()

      entries =
        for idx <- 1..5 do
          entry(idx, archive_state: :verified, media_bytes: 50, timeline_start_us: idx * 1_000)
        end

      server_state = start_wire_nvr_state(entries, used_bytes: 950)
      port = start_wire_nvr(certs.server_config, server_state)
      target_opts = write_wire_nvr_files(dir, certs.client_config, port, extra_member: true)

      assert {:ok, jobs} =
               LocalRetentionJob.enqueue_all(
                 target_opts: target_opts,
                 insert_fn: fn changeset -> {:ok, Ecto.Changeset.apply_changes(changeset)} end
               )

      assert Enum.map(jobs, & &1.args) == [
               %{"member" => "serviceradar-nvr-0"},
               %{"member" => "serviceradar-nvr-1"}
             ]

      attach_retention_telemetry!()

      {harness, wire_opts} =
        build_wire_harness(entries, target_opts, max_local_age_mode: :unlimited, max_local_age_seconds: nil)

      {result, log} = with_log(fn -> LocalRetentionJob.run_member(@member, wire_opts) end)

      assert {:ok, %{status: :ok, reclaimed: 3, processed: 3} = summary} = result
      assert Enum.map(harness_state(harness).finalized, & &1.block_key) == [block_key(1), block_key(2), block_key(3)]

      assert_receive {:retention_telemetry, %{reclaimed: 3, processed: 3, deferred: 0, held_skipped: 0},
                      %{member: @member, storage_id: @storage_id, status: :ok, skipped_reason: nil}}

      requests = Agent.get(server_state, & &1.requests)
      assert Enum.all?(requests, &(&1.headers["authorization"] == "Bearer " <> @wire_token))

      assert Enum.map(requests, &{&1.method, &1.target}) == [
               {"GET", "/v1/status"},
               {"POST", "/v1/blocks/#{block_key(1)}/reclaim"},
               {"POST", "/v1/blocks/lookup"},
               {"POST", "/v1/blocks/#{block_key(2)}/reclaim"},
               {"POST", "/v1/blocks/lookup"},
               {"POST", "/v1/blocks/#{block_key(3)}/reclaim"},
               {"POST", "/v1/blocks/lookup"}
             ]

      reclaim_req = Enum.at(requests, 1)
      lookup_req = Enum.at(requests, 2)
      decoded_reclaim = Jason.decode!(reclaim_req.body)

      assert {reclaim_req.headers["content-type"], lookup_req.headers["content-type"]} ==
               {"application/vnd.serviceradar.nvr-reclaim.v1+json", "application/vnd.serviceradar.nvr-lookup.v1+json"}

      assert Map.take(decoded_reclaim, ["version", "storage_id", "recovery_generation", "expected_descriptor_sha256"]) ==
               %{
                 "version" => 1,
                 "storage_id" => @storage_id,
                 "recovery_generation" => @recovery_generation,
                 "expected_descriptor_sha256" => descriptor_sha256(1)
               }

      assert Jason.decode!(lookup_req.body) == %{"block_ids" => [block_key(1)]}
      refute log =~ @wire_token or inspect(summary) =~ @wire_token
    end

    test "handles mTLS 503 lookup deferral without over-evicting, 409 block_active, closed gate, and storage mismatch",
         ctx do
      dir = setup_wire_recovery_gate!(ctx)
      gate_path = Path.join(dir, "recovery-state.json")
      certs = generate_wire_certs()

      entries =
        for idx <- 1..6 do
          entry(idx, archive_state: :not_required, media_bytes: 100, timeline_start_us: idx * 1_000)
        end

      server_state =
        start_wire_nvr_state(entries,
          used_bytes: 950,
          lookup_override: {503, %{"error" => "busy"}},
          reclaim_overrides: %{block_key(1) => {409, %{"error" => "block_active"}}}
        )

      port = start_wire_nvr(certs.server_config, server_state)
      target_opts = write_wire_nvr_files(dir, certs.client_config, port)

      {harness, wire_opts} =
        build_wire_harness(entries, target_opts,
          max_local_age_mode: :unlimited,
          max_local_age_seconds: nil,
          local_only_full_policy: :overwrite_oldest
        )

      # Block 1 returns 409 block_active (deferred, NOT deducted); blocks 2 and 3 succeed reclaim
      # (950 -> 850 -> 750 <= 800 low water) even though lookup returns 503 busy.
      assert {:ok, %{status: :ok, reclaimed: 0, deferred: 3, processed: 3}} =
               LocalRetentionJob.run_member(@member, wire_opts)

      state = harness_state(harness)
      assert state.finalized == []
      assert Enum.any?(state.steps, &(&1.step == :failed and &1.extra[:error_class] == "block_active"))

      reclaim_targets =
        server_state
        |> Agent.get(& &1.requests)
        |> Enum.filter(&String.ends_with?(&1.target, "/reclaim"))
        |> Enum.map(& &1.target)

      assert reclaim_targets == [
               "/v1/blocks/#{block_key(1)}/reclaim",
               "/v1/blocks/#{block_key(2)}/reclaim",
               "/v1/blocks/#{block_key(3)}/reclaim"
             ]

      # Mismatched storage_id in /v1/status skips without issuing any reclaim.
      Agent.update(server_state, fn st ->
        %{st | requests: [], status_storage_id: "00000000-0000-4000-8000-000000000099"}
      end)

      assert {:ok, %{status: :skipped, skipped_reason: :storage_id_mismatch}} =
               LocalRetentionJob.run_member(@member, wire_opts)

      assert Enum.map(Agent.get(server_state, & &1.requests), & &1.target) == ["/v1/status"]

      # Closed recovery gate skips before contacting NVR at all.
      Agent.update(server_state, fn st -> %{st | requests: [], status_storage_id: @storage_id} end)
      File.write!(gate_path, ~s({"generation":"#{@recovery_generation}","state":"closed"}))

      assert {:ok, %{status: :skipped, skipped_reason: :nvr_recovery_closed}} =
               LocalRetentionJob.run_member(@member, wire_opts)

      assert Agent.get(server_state, & &1.requests) == []
    end
  end

  defp setup_wire_recovery_gate!(ctx) do
    {:ok, _} = Application.ensure_all_started(:ssl)
    prev_gate = Application.get_env(:serviceradar_core, :nvr_recovery_gate)
    on_exit(fn -> Application.put_env(:serviceradar_core, :nvr_recovery_gate, prev_gate) end)

    dir = Path.expand(ctx.tmp_dir)
    gate_path = Path.join(dir, "recovery-state.json")
    File.write!(gate_path, ~s({"generation":"#{@recovery_generation}","state":"ready"}))
    Application.put_env(:serviceradar_core, :nvr_recovery_gate, %{generation: @recovery_generation, path: gate_path})
    dir
  end

  defp attach_retention_telemetry! do
    handler = "local-retention-wire-test-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:serviceradar, :camera_recording, :local_retention, :pass],
        fn _event, measurements, metadata, _cfg ->
          send(parent, {:retention_telemetry, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp build_wire_harness(entries, target_opts, settings_overrides) do
    {harness, harness_opts} = build_harness(entries: entries, settings: settings(settings_overrides))

    wire_opts =
      harness_opts
      |> Keyword.drop([:recovery_gate_fn, :status_fn, :reclaim_fn, :lookup_fn])
      |> Keyword.put(:target_opts, target_opts)

    {harness, wire_opts}
  end

  defp start_wire_nvr_state(entries, overrides) do
    blocks =
      Map.new(entries, fn e ->
        {e.block_key, %{state: "sealed", bytes: e.media_bytes, digest: e.descriptor_sha256}}
      end)

    initial =
      Map.merge(
        %{
          requests: [],
          blocks: blocks,
          used_bytes: 0,
          max_spool_bytes: 1_000,
          max_blocks: 100,
          lookup_override: nil,
          reclaim_overrides: %{},
          status_storage_id: @storage_id
        },
        Map.new(overrides)
      )

    {:ok, state} = Agent.start_link(fn -> initial end)
    state
  end

  defp generate_wire_certs do
    algorithm = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}

    :public_key.pkix_test_data(%{
      server_chain: %{root: algorithm, intermediates: [], peer: algorithm ++ [extensions: [san]]},
      client_chain: %{root: algorithm, intermediates: [], peer: algorithm}
    })
  end

  defp write_wire_nvr_files(dir, client, port, opts \\ []) do
    {key_type, key_der} = client[:key]
    roots = Enum.map(client[:cacerts], &{:Certificate, &1, :not_encrypted})
    ca = Path.join(dir, "ca.pem")
    cert = Path.join(dir, "client.pem")
    key = Path.join(dir, "client-key.pem")
    token = Path.join(dir, "nvr-token")
    config = Path.join(dir, "nvr-client.json")

    File.write!(ca, :public_key.pem_encode(roots))
    File.write!(cert, :public_key.pem_encode([{:Certificate, client[:cert], :not_encrypted}]))
    File.write!(key, :public_key.pem_encode([{key_type, key_der, :not_encrypted}]))
    File.write!(token, @wire_token)

    members =
      if Keyword.get(opts, :extra_member, false) do
        %{
          @member => %{"host" => "localhost", "storage_id" => @storage_id},
          "serviceradar-nvr-1" => %{
            "host" => "localhost",
            "storage_id" => "00000000-0000-4000-8000-000000000012"
          }
        }
      else
        %{@member => %{"host" => "localhost", "storage_id" => @storage_id}}
      end

    File.write!(
      config,
      Jason.encode!(%{
        "version" => 1,
        "port" => port,
        "ca_file" => ca,
        "cert_file" => cert,
        "key_file" => key,
        "members" => members
      })
    )

    [config_file: config, token_file: token]
  end

  defp start_wire_nvr(server_tls, state_agent) do
    Fixture.start(server_tls, fn request ->
      Agent.update(state_agent, fn st -> %{st | requests: st.requests ++ [request]} end)
      handle_wire_nvr_request(request, state_agent)
    end)
  end

  defp handle_wire_nvr_request(request, state_agent) do
    json = %{"content-type" => "application/json"}

    if request.headers["authorization"] == "Bearer " <> @wire_token do
      route_wire_nvr_request(request, state_agent, json)
    else
      {401, json, Jason.encode!(%{"error" => "unauthorized"})}
    end
  end

  defp route_wire_nvr_request(%{method: "GET", target: "/v1/status"}, state_agent, json) do
    wire_status_response(state_agent, json)
  end

  defp route_wire_nvr_request(%{method: "POST", target: "/v1/blocks/lookup"} = request, state_agent, json) do
    wire_lookup_response(request, state_agent, json)
  end

  defp route_wire_nvr_request(%{method: "POST", target: "/v1/blocks/" <> _} = request, state_agent, json) do
    if String.ends_with?(request.target, "/reclaim") do
      wire_reclaim_response(request, state_agent, json)
    else
      {404, json, Jason.encode!(%{"error" => "not_found"})}
    end
  end

  defp route_wire_nvr_request(_request, _state_agent, json) do
    {404, json, Jason.encode!(%{"error" => "not_found"})}
  end

  defp wire_status_response(state_agent, json) do
    st = Agent.get(state_agent, & &1)
    sealed_count = Enum.count(st.blocks, fn {_k, v} -> v.state == "sealed" end)

    body = %{
      "version" => 1,
      "storage_id" => st.status_storage_id,
      "recovery" => %{"state" => "ready", "generation" => @recovery_generation},
      "inventory" => "ready",
      "capacity" => %{
        "available_bytes" => st.max_spool_bytes - st.used_bytes,
        "blocks" => sealed_count,
        "max_blocks" => st.max_blocks,
        "max_spool_bytes" => st.max_spool_bytes,
        "reservations" => 0,
        "reserve_bytes" => 0,
        "reserved_bytes" => 0,
        "used_bytes" => st.used_bytes
      },
      "max_sessions" => 8,
      "archive_busy" => false,
      "release" => "0.1.0-wire-test"
    }

    {200, json, Jason.encode!(body)}
  end

  defp wire_reclaim_response(request, state_agent, json) do
    block_id = request.target |> String.trim_leading("/v1/blocks/") |> String.trim_trailing("/reclaim")
    payload = Jason.decode!(request.body)
    st = Agent.get(state_agent, & &1)

    case Map.get(st.reclaim_overrides, block_id) do
      {status, err_body} ->
        {status, json, Jason.encode!(err_body)}

      nil ->
        mark_wire_block_reclaimed(state_agent, block_id)

        receipt = %{
          "version" => 1,
          "status" => "reclaimed",
          "storage_id" => @storage_id,
          "block_id" => block_id,
          "operation_id" => payload["operation_id"],
          "reclaimed_at_ms" => DateTime.to_unix(@fixed_now, :millisecond)
        }

        {200, json, Jason.encode!(receipt)}
    end
  end

  defp mark_wire_block_reclaimed(state_agent, block_id) do
    Agent.update(state_agent, fn cur ->
      case Map.get(cur.blocks, block_id) do
        %{state: "sealed", bytes: b} = blk ->
          %{
            cur
            | blocks: Map.put(cur.blocks, block_id, %{blk | state: "reclaimed", bytes: nil}),
              used_bytes: max(cur.used_bytes - b, 0)
          }

        _ ->
          cur
      end
    end)
  end

  defp wire_lookup_response(request, state_agent, json) do
    st = Agent.get(state_agent, & &1)

    case st.lookup_override do
      {status, err_body} ->
        {status, json, Jason.encode!(err_body)}

      nil ->
        %{"block_ids" => ids} = Jason.decode!(request.body)
        blocks = Enum.map(ids, &wire_lookup_entry(&1, Map.get(st.blocks, &1)))
        {200, json, Jason.encode!(%{"version" => 1, "storage_id" => @storage_id, "blocks" => blocks})}
    end
  end

  defp wire_lookup_entry(bid, %{state: "sealed", bytes: b, digest: d}) do
    %{"block_id" => bid, "state" => "sealed", "writing" => false, "bytes" => b, "descriptor_sha256" => d}
  end

  defp wire_lookup_entry(bid, %{state: "reclaimed"}) do
    %{"block_id" => bid, "state" => "reclaimed", "writing" => false, "bytes" => nil}
  end

  defp wire_lookup_entry(bid, nil) do
    %{"block_id" => bid, "state" => "absent", "writing" => false, "bytes" => nil}
  end

  defp target(member \\ @member, storage_id \\ @storage_id) do
    %{
      member: member,
      storage_id: storage_id,
      client_config: %ClientConfig{
        host: "#{member}.example.internal",
        port: 8_443,
        ca: "/run/nvr/ca.pem",
        cert: "/run/nvr/client.pem",
        key: "/run/nvr/client-key.pem",
        token: "synthetic-local-retention-token"
      }
    }
  end

  defp settings(overrides \\ []) do
    Map.merge(RecordingArchiveSettings.default_settings(), Map.new(overrides))
  end

  defp capacity(overrides) do
    Map.merge(
      %{
        available_bytes: 10 * @gib,
        blocks: 10,
        max_blocks: 1_000,
        max_spool_bytes: 10 * @gib,
        reservations: 0,
        reserve_bytes: 64 * 1_048_576,
        reserved_bytes: 0,
        used_bytes: 0
      },
      Map.new(overrides)
    )
  end

  defp entry(index, overrides) do
    base = %{
      id: entry_uuid(index),
      recording_block_id: block_row_uuid(index),
      camera_source_id: @camera_id,
      stream_profile_id: @profile_id,
      storage_id: @storage_id,
      block_key: block_key(index),
      descriptor_sha256: descriptor_sha256(index),
      local_state: :present,
      quarantine_reason: nil,
      archive_state: :verified,
      media_bytes: 100,
      timeline_start_us: index * 1_000_000,
      timeline_end_us: index * 1_000_000 + 500,
      sealed_at: DateTime.shift(@fixed_now, second: -3_600 + index),
      inserted_at: DateTime.shift(@fixed_now, second: -3_600 + index)
    }

    Map.merge(base, Map.new(overrides))
  end

  defp build_harness(config) do
    entries = Keyword.get(config, :entries, [])
    reclaiming_entries = Keyword.get(config, :reclaiming_entries, [])
    holds = Keyword.get(config, :holds, [])
    dispositions = Keyword.get(config, :dispositions, %{})
    reclaim_overrides = Keyword.get(config, :reclaim_overrides, %{})
    lookup_error = Keyword.get(config, :lookup_error)
    post_reclaim_lookup_error = Keyword.get(config, :post_reclaim_lookup_error)
    initial_nvr_states = Keyword.get(config, :initial_nvr_states, %{})
    cap = Keyword.get(config, :capacity, capacity([]))
    cfg_settings = Keyword.get(config, :settings, settings())
    gate_result = Keyword.get(config, :recovery_gate_result, {:ok, @recovery_generation})

    status_map =
      Map.merge(
        %{
          storage_id: @storage_id,
          recovery: %{state: :ready, generation: @recovery_generation},
          inventory: :ready,
          capacity: cap,
          max_sessions: 8,
          archive_busy: false,
          release: "0.1.0-test"
        },
        Keyword.get(config, :status_overrides, %{})
      )

    entries_by_id = Map.new(entries ++ reclaiming_entries, &{&1.id, &1})

    nvr_states =
      Enum.reduce(entries ++ reclaiming_entries, initial_nvr_states, fn e, acc ->
        Map.put_new(acc, e.block_key, :sealed)
      end)

    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          nvr_states: nvr_states,
          present_loads: [],
          intents: [],
          reclaim_calls: [],
          steps: [],
          finalized: []
        }
      end)

    opts = [
      now_fn: fn -> @fixed_now end,
      recovery_gate_fn: fn -> gate_result end,
      status_fn: fn _cfg -> {:ok, status_map} end,
      settings_loader: fn -> {:ok, cfg_settings} end,
      reclaiming_loader: fn @storage_id -> {:ok, reclaiming_entries} end,
      present_loader: fn @storage_id, query_spec ->
        Agent.update(agent, fn st -> %{st | present_loads: st.present_loads ++ [query_spec]} end)
        {:ok, slice_present_page(entries, query_spec)}
      end,
      disposition_loader: fn entry_id -> {:ok, Map.get(dispositions, entry_id)} end,
      begin_intent_fn: fn entry_id, :local, attrs, _intent_opts ->
        e = Map.fetch!(entries_by_id, entry_id)
        summary = RecordingHolds.summarize_entry(e, holds)

        if summary.pinned_copy == :local do
          {:error, {:blocked_by_hold, summary}}
        else
          op_id = Ecto.UUID.generate()
          reclaiming = %{e | local_state: :reclaiming}

          disp = %{
            operation_id: op_id,
            catalog_entry_id: e.id,
            storage_id: e.storage_id,
            block_key: e.block_key,
            copy: :local,
            reason: attrs.reason
          }

          Agent.update(agent, fn st ->
            %{st | intents: st.intents ++ [%{block_key: e.block_key, reason: attrs.reason, operation_id: op_id}]}
          end)

          {:ok, %{entry: reclaiming, disposition: disp}}
        end
      end,
      record_step_fn: fn disp, step, extra, _step_opts ->
        Agent.update(agent, fn st ->
          %{st | steps: st.steps ++ [%{operation_id: disp.operation_id, step: step, extra: extra}]}
        end)

        {:ok, disp}
      end,
      reclaim_fn: fn _cfg, block_id, request ->
        Agent.update(agent, fn st ->
          %{st | reclaim_calls: st.reclaim_calls ++ [%{block_id: block_id, request: request}]}
        end)

        case Map.get(reclaim_overrides, block_id) do
          nil ->
            Agent.update(agent, fn st -> put_in(st.nvr_states[block_id], :reclaimed) end)

            {:ok,
             %{
               storage_id: @storage_id,
               block_id: block_id,
               operation_id: request["operation_id"],
               status: :reclaimed,
               reclaimed_at_ms: DateTime.to_unix(@fixed_now, :millisecond)
             }}

          {:outcome_unknown_but_reclaimed} ->
            Agent.update(agent, fn st -> put_in(st.nvr_states[block_id], :reclaimed) end)
            {:error, :outcome_unknown}

          {:error, _} = err ->
            err
        end
      end,
      lookup_fn: build_lookup_fn(agent, lookup_error, post_reclaim_lookup_error),
      finalize_reclaimed_fn: fn e, now ->
        updated = %{e | local_state: :reclaimed}

        Agent.update(agent, fn st ->
          %{st | finalized: st.finalized ++ [%{block_key: e.block_key, finalized_at: now}]}
        end)

        {:ok, updated}
      end
    ]

    {agent, opts}
  end

  defp build_lookup_fn(agent, lookup_error, post_reclaim_lookup_error) do
    fn _cfg, block_ids ->
      current = Agent.get(agent, & &1)

      cond do
        not is_nil(lookup_error) ->
          lookup_error

        not is_nil(post_reclaim_lookup_error) and current.reclaim_calls != [] ->
          post_reclaim_lookup_error

        true ->
          blocks = Enum.map(block_ids, &lookup_block_entry(&1, current.nvr_states))
          {:ok, %{storage_id: @storage_id, blocks: blocks}}
      end
    end
  end

  defp lookup_block_entry(bid, nvr_states) do
    st = Map.get(nvr_states, bid, :absent)

    %{
      block_id: bid,
      state: st,
      writing: false,
      bytes: if(st == :sealed, do: 100),
      descriptor_sha256: nil,
      reason: nil
    }
  end

  defp slice_present_page(entries, query_spec) do
    entries
    |> Enum.sort_by(&cursor_sort_key/1)
    |> filter_after_cursor(query_spec.cursor)
    |> Enum.take(query_spec.limit)
  end

  defp filter_after_cursor(entries, nil), do: entries

  defp filter_after_cursor(entries, {last_ts, last_sealed_at, last_block_key}) do
    cursor_key = {last_ts || 0, sealed_at_us(last_sealed_at), last_block_key || ""}
    Enum.filter(entries, &(cursor_sort_key(&1) > cursor_key))
  end

  defp cursor_sort_key(e) do
    {e.timeline_start_us || 0, sealed_at_us(e.sealed_at), e.block_key || ""}
  end

  defp sealed_at_us(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)
  defp sealed_at_us(_), do: 0

  defp harness_state(agent), do: Agent.get(agent, & &1)

  defp hours_ago(hours), do: DateTime.shift(@fixed_now, hour: -hours)

  defp entry_uuid(index) do
    "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(index), 12, "0")
  end

  defp block_row_uuid(index) do
    "00000000-0000-4000-9000-" <> String.pad_leading(Integer.to_string(index), 12, "0")
  end

  defp block_key(index) do
    index
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(64, "0")
  end

  defp descriptor_sha256(index) do
    index
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(64, "a")
  end
end
