defmodule ServiceRadarCoreElx.CameraRecording.LocalRetentionJobTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingHolds
  alias ServiceRadarCoreElx.CameraRecording.LocalRetentionJob
  alias ServiceRadarNVRClient.Config, as: ClientConfig

  @member "serviceradar-nvr-0"
  @storage_id "00000000-0000-4000-8000-000000000011"
  @recovery_generation "00000000-0000-4000-8000-000000000021"
  @camera_id "00000000-0000-4000-8000-000000000103"
  @profile_id "00000000-0000-4000-8000-000000000104"
  @fixed_now ~U[2026-11-22 12:00:00.000000Z]
  @gib 1_073_741_824

  describe "Oban worker configuration and no-op behavior" do
    test "uses maintenance queue, 500-block pass cap, and unique window without executing orphan stall" do
      opts = LocalRetentionJob.__opts__()

      assert opts[:queue] == :maintenance
      assert opts[:max_attempts] == 3
      assert LocalRetentionJob.max_blocks_per_pass() == 500

      unique = Keyword.fetch!(opts, :unique)
      assert unique[:keys] == [:member]
      assert unique[:states] == [:available, :scheduled, :retryable]
      refute :executing in unique[:states]
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
        assert unique[:states] == [:available, :scheduled, :retryable]
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

    test "bounds present catalog query with oldest-first sort, headroom limit, and policy/age filters" do
      cutoff_a = DateTime.shift(@fixed_now, day: -1)
      cutoff_b = DateTime.shift(@fixed_now, day: -2)

      space_stop_query =
        LocalRetentionJob.present_entries_query(@storage_id, %{
          space_needed?: true,
          full_policy: :stop_when_full,
          kind_a_age_cutoff: nil,
          kind_b_age_cutoff: nil,
          limit: 1_000
        })

      assert space_stop_query.limit == 1_000
      assert space_stop_query.sort == [timeline_start_us: :asc, sealed_at: :asc, block_key: :asc]
      refute inspect(space_stop_query.filter) =~ "not_required"

      age_only_query =
        LocalRetentionJob.present_entries_query(@storage_id, %{
          space_needed?: false,
          full_policy: :stop_when_full,
          kind_a_age_cutoff: cutoff_a,
          kind_b_age_cutoff: cutoff_b,
          limit: 1_000
        })

      assert age_only_query.limit == 1_000
      assert age_only_query.sort == [timeline_start_us: :asc, sealed_at: :asc, block_key: :asc]
      assert inspect(age_only_query.filter) =~ "sealed_at"

      entries = [entry(1, archive_state: :verified, media_bytes: 50, sealed_at: hours_ago(30))]

      {harness, opts} =
        build_harness(
          entries: entries,
          capacity: capacity(used_bytes: 200, max_spool_bytes: 1_000, blocks: 1, max_blocks: 100),
          settings:
            settings(
              max_local_age_mode: :limited,
              max_local_age_seconds: 86_400,
              local_only_max_age_mode: :unlimited,
              local_only_max_age_seconds: nil
            )
        )

      assert {:ok, _summary} = LocalRetentionJob.run_target(target(), opts)
      assert [query_spec] = harness_state(harness).present_loads
      assert query_spec.limit == 1_000
      assert query_spec.space_needed? == false
      assert query_spec.kind_a_age_cutoff == cutoff_a
      assert query_spec.kind_b_age_cutoff == nil
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
        {:ok, entries}
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
