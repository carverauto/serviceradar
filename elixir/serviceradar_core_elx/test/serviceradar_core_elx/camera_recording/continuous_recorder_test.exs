defmodule ServiceRadarCoreElx.CameraRecording.ContinuousRecorderTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadarCoreElx.CameraRecording.ContinuousManager
  alias ServiceRadarCoreElx.CameraRecording.ContinuousRecorder
  alias ServiceRadarNVRClient.Config, as: ClientConfig
  alias ServiceRadarRecording.Inbox
  alias ServiceRadarRecordingMetadata.Descriptor

  @camera_id "00000000-0000-4000-8000-000000000201"
  @profile_id "00000000-0000-4000-8000-000000000202"
  @policy_id "00000000-0000-4000-8000-000000000203"
  @relay_id "00000000-0000-4000-8000-000000000204"
  @ingest_owner_id "00000000-0000-4000-8000-000000000205"
  @claim_id "00000000-0000-4000-8000-000000000206"
  @storage_id "00000000-0000-4000-8000-000000000207"
  @recovery_generation "00000000-0000-4000-8000-000000000208"
  @media_ingest_id "synthetic-ingest-continuous-1"
  @member "serviceradar-nvr-0"

  # Synthetic H.264 AnnexB payloads:
  # SPS (NAL type 7 = 0x67), PPS (NAL type 8 = 0x68), IDR (NAL type 5 = 0x65), non-IDR slice (NAL type 1 = 0x41)
  @idr_payload <<0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1E, 0, 0, 0, 1, 0x68, 0xCE, 0x3C, 0x80, 0, 0, 0, 1, 0x65, 0x88, 0x84>>
  @p_frame_payload <<0, 0, 0, 1, 0x41, 0x9A, 0x24, 0x6C, 0x11, 0x22, 0x33, 0x44>>
  @base_utc_us 1_763_800_000_000_000

  describe "defaults and AnnexB keyframe detection" do
    test "default bounds match A.1.1 hard ceilings and A.3.4 soft targets" do
      bounds = ContinuousRecorder.default_bounds()

      assert bounds.soft_duration_ms == 260_000
      assert bounds.max_duration_ms == 270_000
      assert bounds.soft_frames == 7_800
      assert bounds.max_frames == 8_100
      assert bounds.soft_bytes == 10_485_760
      assert bounds.max_bytes == 12_582_912
    end

    test "keyframe_unit?/1 detects relay keyframe flag and AnnexB NAL type 5" do
      assert ContinuousRecorder.keyframe_unit?(%{keyframe: true, payload: @p_frame_payload})
      assert ContinuousRecorder.keyframe_unit?(%{payload: @idr_payload})
      assert ContinuousRecorder.keyframe_unit?(%{payload: <<0, 0, 1, 0x65, 0x01, 0x02>>})
      refute ContinuousRecorder.keyframe_unit?(%{payload: @p_frame_payload})
      refute ContinuousRecorder.keyframe_unit?(%{keyframe: false, payload: @p_frame_payload})
      refute ContinuousRecorder.keyframe_unit?(%{payload: <<0, 0, 0, 1, 0x67, 0x42>>})
    end
  end

  describe "multi-block contiguous keyframe-aligned handover" do
    test "cuts at soft target on next IDR, preserves contiguity, catalogs and enqueues archive" do
      harness = start_harness(bounds: %{soft_frames: 3, max_frames: 6})
      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, run_info}}, 1_000
      assert run_info.run_id == "#{@relay_id}:1"

      # Block 0: seq 0 (IDR), 1 (P), 2 (P) -> soft_frames=3 reached, 3 (P) still fits before IDR
      # Seq 4 (IDR) triggers clean keyframe-aligned cut -> starts Block 1 contiguously!
      send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
      send_unit(pid, harness.inbox_id, 1, 3_000, @base_utc_us + 33_333, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 2, 6_000, @base_utc_us + 66_666, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 3, 9_000, @base_utc_us + 100_000, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 4, 12_000, @base_utc_us + 133_333, @idr_payload)

      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key0, catalog: {:registered, entry0}}}},
                     1_000

      assert_receive {:sent_block, ^key0, block0_units}, 1_000
      assert_receive {:cataloged, ^key0, attrs0}, 1_000
      assert_receive {:archive_enqueued, ^entry0}, 1_000

      seqs0 = Enum.map(block0_units, & &1.sequence)

      assert {seqs0, attrs0.anchor_id, attrs0.reanchored, attrs0.contiguous_with_previous, attrs0.timeline_start_us} ==
               {[0, 1, 2, 3], "#{@relay_id}:1:0", false, false, @base_utc_us}

      # Feed rest of Block 1 and cut on Seq 8 (IDR)
      send_unit(pid, harness.inbox_id, 5, 15_000, @base_utc_us + 166_666, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 6, 18_000, @base_utc_us + 200_000, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 7, 21_000, @base_utc_us + 233_333, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 8, 24_000, @base_utc_us + 266_666, @idr_payload)

      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key1, catalog: {:registered, entry1}}}},
                     1_000

      assert_receive {:sent_block, ^key1, block1_units}, 1_000
      assert_receive {:cataloged, ^key1, attrs1}, 1_000
      assert_receive {:archive_enqueued, ^entry1}, 1_000

      seqs1 = Enum.map(block1_units, & &1.sequence)

      assert {seqs1, attrs1.anchor_id, attrs1.reanchored, attrs1.contiguous_with_previous, attrs1.timeline_start_us} ==
               {[4, 5, 6, 7], "#{@relay_id}:1:0", false, true, @base_utc_us + div(12_000 * 1_000_000, 90_000)}

      # Stop cleanly -> Block 2 (with Seq 8) seals and claim releases
      ContinuousRecorder.stop(pid, :policy_disabled)

      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key2, catalog: {:registered, entry2}}}},
                     1_000

      assert_receive {:sent_block, ^key2, block2_units}, 1_000
      assert Enum.map(block2_units, & &1.sequence) == [8]
      assert_receive {:archive_enqueued, ^entry2}, 1_000
      assert_receive {:continuous_recorder, ^pid, {:run_stopped, %{reason: :policy_disabled}}}, 1_000
      assert_receive :claim_released, 1_000
      refute_receive {:gap_recorded, _}, 100
    end
  end

  describe "hard bound cut and keyframe_wait gap" do
    test "cuts at hard frame ceiling without IDR and records exact keyframe_wait gap until next IDR" do
      harness = start_harness(bounds: %{soft_frames: 2, max_frames: 4})
      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

      # 4 frames (seq 0..3) hit max_frames=4 without another IDR
      send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
      send_unit(pid, harness.inbox_id, 1, 3_000, @base_utc_us + 33_333, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 2, 6_000, @base_utc_us + 66_666, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 3, 9_000, @base_utc_us + 100_000, @p_frame_payload)

      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key0}}}, 1_000
      assert_receive {:sent_block, ^key0, block0_units}, 1_000
      assert Enum.map(block0_units, & &1.sequence) == [0, 1, 2, 3]

      # Seq 4 and 5 are non-IDR -> dropped with :keyframe_wait; Seq 6 is IDR -> starts Block 1
      send_unit(pid, harness.inbox_id, 4, 12_000, @base_utc_us + 133_333, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 5, 15_000, @base_utc_us + 166_666, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 6, 18_000, @base_utc_us + 200_000, @idr_payload)

      assert_receive {:gap_recorded, gap}, 1_000
      assert gap.reason == :keyframe_wait
      assert gap.time_basis == :received
      assert gap.time_uncertainty_us == nil
      # Dropped pts 12_000..18_000 = 6_000 ticks at 90 kHz = 66_666_666 ns
      assert gap.media_gap_ns == div(6_000 * 1_000_000_000, 90_000)

      ContinuousRecorder.stop(pid, :policy_disabled)
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key1}}}, 1_000
      assert_receive {:sent_block, ^key1, block1_units}, 1_000
      assert Enum.map(block1_units, & &1.sequence) == [6]
      assert_receive {:cataloged, ^key1, attrs1}, 1_000
      assert attrs1.contiguous_with_previous == false
      assert_receive {:continuous_recorder, ^pid, {:run_stopped, _}}, 1_000
    end
  end

  describe "forced handover inbox overflow" do
    test "drops excess units cleanly while sealing and records exact handover_overflow gap" do
      parent = self()
      gate = make_ref()

      send_fn = fn _cfg, header, stream, _timeout ->
        units = Enum.to_list(stream)
        block_key = header_block_key(header)
        send(parent, {:sent_block, block_key, units})

        if header["identity"]["block_sequence"] == 0 do
          send(parent, {:block0_waiting_to_seal, self()})

          receive do
            {^gate, :release_seal} -> :ok
          end
        end

        {:ok, %{status: :sealed_local, storage_id: @storage_id, block_ids: [block_key]}}
      end

      harness =
        start_harness(
          bounds: %{soft_frames: 2, max_frames: 4},
          handover_max_samples: 2,
          send_recording_fn: send_fn
        )

      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

      # Block 0 takes seq 0, 1, then seq 2 (IDR) triggers soft cut -> Block 0 enters :sealing
      send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
      send_unit(pid, harness.inbox_id, 1, 3_000, @base_utc_us + 33_333, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 2, 6_000, @base_utc_us + 66_666, @idr_payload)

      assert_receive {:block0_waiting_to_seal, sender0_pid}, 1_000

      # While Block 0 is sealing, handover_queue already has seq 2 (1/2).
      # Seq 3 fits (2/2). Seq 4 and Seq 5 overflow -> dropped!
      send_unit(pid, harness.inbox_id, 3, 9_000, @base_utc_us + 100_000, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 4, 12_000, @base_utc_us + 133_333, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 5, 15_000, @base_utc_us + 166_666, @p_frame_payload)

      # Release Block 0 seal -> drains seq 2, 3 into Block 1
      send(sender0_pid, {gate, :release_seal})
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: _key0}}}, 1_000

      # Seq 6 (IDR) arrives after the drop -> closes Block 1, records :handover_overflow gap, starts Block 2
      send_unit(pid, harness.inbox_id, 6, 18_000, @base_utc_us + 200_000, @idr_payload)

      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key1}}}, 1_000
      assert_receive {:sent_block, ^key1, block1_units}, 1_000
      assert Enum.map(block1_units, & &1.sequence) == [2, 3]

      assert_receive {:gap_recorded, gap}, 1_000
      assert gap.reason == :handover_overflow
      assert gap.detail_class == "handover_queue_full"
      assert gap.media_gap_ns == div(6_000 * 1_000_000_000, 90_000)

      ContinuousRecorder.stop(pid, :policy_disabled)
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key2}}}, 1_000
      assert_receive {:sent_block, ^key2, block2_units}, 1_000
      assert Enum.map(block2_units, & &1.sequence) == [6]
      assert_receive {:cataloged, ^key2, attrs2}, 1_000
      assert attrs2.contiguous_with_previous == false
      assert_receive {:continuous_recorder, ^pid, {:run_stopped, _}}, 1_000
    end
  end

  describe "NVR refusal" do
    test "records nvr_refused gap with detail_class and continues on next block" do
      parent = self()

      send_fn = fn _cfg, header, stream, _timeout ->
        units = Enum.to_list(stream)
        block_key = header_block_key(header)
        send(parent, {:sent_block, block_key, units})

        if header["identity"]["block_sequence"] == 0 do
          {:error, {:ingest_refused, 503, %{"error" => "nvr_inventory_limit"}}}
        else
          {:ok, %{status: :sealed_local, storage_id: @storage_id, block_ids: [block_key]}}
        end
      end

      harness = start_harness(bounds: %{soft_frames: 2, max_frames: 2}, send_recording_fn: send_fn)
      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

      send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
      send_unit(pid, harness.inbox_id, 1, 3_000, @base_utc_us + 33_333, @p_frame_payload)

      assert_receive {:continuous_recorder, ^pid, {:nvr_refused, %{status: 503, detail_class: "nvr_inventory_limit"}}},
                     1_000

      assert_receive {:gap_recorded, gap}, 1_000
      assert gap.reason == :nvr_refused
      assert gap.detail_class == "nvr_inventory_limit"
      assert gap.media_gap_ns == div(6_000 * 1_000_000_000, 90_000)

      # Next IDR succeeds on Block 1
      send_unit(pid, harness.inbox_id, 2, 6_000, @base_utc_us + 66_666, @idr_payload)
      send_unit(pid, harness.inbox_id, 3, 9_000, @base_utc_us + 100_000, @p_frame_payload)

      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key1, catalog: {:registered, _}}}},
                     1_000

      assert_receive {:cataloged, ^key1, attrs1}, 1_000
      assert attrs1.contiguous_with_previous == false

      ContinuousRecorder.stop(pid, :policy_disabled)
      assert_receive {:continuous_recorder, ^pid, {:run_stopped, _}}, 1_000
    end
  end

  describe "uncertain outcome resolution via lookup_blocks (design A3 table)" do
    test "resolves :sealed via lookup, catalogs under live claim, enqueues archive, and continues" do
      parent = self()

      send_fn = fn _cfg, header, stream, _timeout ->
        _units = Enum.to_list(stream)
        block_key = header_block_key(header)

        if header["identity"]["block_sequence"] == 0 do
          {:error, :outcome_unknown}
        else
          {:ok, %{status: :sealed_local, storage_id: @storage_id, block_ids: [block_key]}}
        end
      end

      lookup_fn = fn _cfg, [block_key], _timeout ->
        send(parent, {:lookup_called, block_key})
        {:ok, %{storage_id: @storage_id, blocks: [%{block_id: block_key, state: :sealed}]}}
      end

      harness =
        start_harness(
          bounds: %{soft_frames: 2, max_frames: 2},
          send_recording_fn: send_fn,
          lookup_blocks_fn: lookup_fn
        )

      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

      send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
      send_unit(pid, harness.inbox_id, 1, 3_000, @base_utc_us + 33_333, @p_frame_payload)

      assert_receive {:lookup_called, key0}, 1_000

      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: ^key0, catalog: {:registered, entry0}}}},
                     1_000

      assert_receive {:archive_enqueued, ^entry0}, 1_000

      # Run continues into Block 1
      send_unit(pid, harness.inbox_id, 2, 6_000, @base_utc_us + 66_666, @idr_payload)
      send_unit(pid, harness.inbox_id, 3, 9_000, @base_utc_us + 100_000, @p_frame_payload)
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: _key1}}}, 1_000

      ContinuousRecorder.stop(pid, :policy_disabled)
      assert_receive {:continuous_recorder, ^pid, {:run_stopped, _}}, 1_000
    end

    test "resolves :absent via lookup, records block_absent gap, and continues" do
      send_fn = fn _cfg, header, stream, _timeout ->
        _units = Enum.to_list(stream)
        block_key = header_block_key(header)

        if header["identity"]["block_sequence"] == 0 do
          {:error, {:ingest_status, 500}}
        else
          {:ok, %{status: :sealed_local, storage_id: @storage_id, block_ids: [block_key]}}
        end
      end

      lookup_fn = fn _cfg, [block_key], _timeout ->
        {:ok, %{storage_id: @storage_id, blocks: [%{block_id: block_key, state: :absent}]}}
      end

      harness =
        start_harness(
          bounds: %{soft_frames: 2, max_frames: 2},
          send_recording_fn: send_fn,
          lookup_blocks_fn: lookup_fn
        )

      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

      send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
      send_unit(pid, harness.inbox_id, 1, 3_000, @base_utc_us + 33_333, @p_frame_payload)

      assert_receive {:gap_recorded, gap}, 1_000
      assert gap.reason == :block_absent
      assert_receive {:continuous_recorder, ^pid, {:uncertain_resolved, %{resolution: :absent}}}, 1_000

      # Run continues into Block 1
      send_unit(pid, harness.inbox_id, 2, 6_000, @base_utc_us + 66_666, @idr_payload)
      send_unit(pid, harness.inbox_id, 3, 9_000, @base_utc_us + 100_000, @p_frame_payload)
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: _key1}}}, 1_000

      ContinuousRecorder.stop(pid, :policy_disabled)
      assert_receive {:continuous_recorder, ^pid, {:run_stopped, _}}, 1_000
    end

    test "resolves :incomplete via lookup, records run_stopped gap, and ends run for reconciler" do
      send_fn = fn _cfg, _header, stream, _timeout ->
        _units = Enum.to_list(stream)
        {:error, :outcome_unknown}
      end

      lookup_fn = fn _cfg, [block_key], _timeout ->
        {:ok, %{storage_id: @storage_id, blocks: [%{block_id: block_key, state: :incomplete}]}}
      end

      harness =
        start_harness(
          bounds: %{soft_frames: 2, max_frames: 2},
          send_recording_fn: send_fn,
          lookup_blocks_fn: lookup_fn
        )

      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

      send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
      send_unit(pid, harness.inbox_id, 1, 3_000, @base_utc_us + 33_333, @p_frame_payload)

      assert_receive {:gap_recorded, gap}, 1_000
      assert gap.reason == :run_stopped
      assert gap.detail_class == "block_incomplete"
      assert_receive {:continuous_recorder, ^pid, {:uncertain_resolved, %{resolution: :incomplete}}}, 1_000
      assert_receive {:continuous_recorder, ^pid, {:run_stopped, %{reason: {:unresolved_block, :incomplete}}}}, 1_000
      assert_receive :claim_released, 1_000
    end

    test "retries unreachable lookup within bounded window, then ends run keeping claim for lease expiry" do
      parent = self()

      send_fn = fn _cfg, _header, stream, _timeout ->
        _units = Enum.to_list(stream)
        {:error, :outcome_unknown}
      end

      lookup_fn = fn _cfg, [block_key], _timeout ->
        send(parent, {:lookup_attempt, block_key})
        {:error, :unavailable}
      end

      harness =
        start_harness(
          bounds: %{soft_frames: 2, max_frames: 2},
          lookup_max_attempts: 2,
          lookup_retry_delay_ms: 5,
          send_recording_fn: send_fn,
          lookup_blocks_fn: lookup_fn
        )

      capture_log(fn ->
        {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
        assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

        send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
        send_unit(pid, harness.inbox_id, 1, 3_000, @base_utc_us + 33_333, @p_frame_payload)

        assert_receive {:lookup_attempt, _}, 1_000
        assert_receive {:lookup_attempt, _}, 1_000
        assert_receive {:gap_recorded, gap}, 1_000
        assert gap.reason == :run_stopped
        assert gap.detail_class == "nvr_unreachable"
        assert_receive {:continuous_recorder, ^pid, {:run_stopped, %{reason: :nvr_unreachable}}}, 1_000
        # Claim is NOT released when NVR member is unreachable; lease expires naturally.
        refute_receive :claim_released, 100
      end)
    end
  end

  describe "drift check and re-anchoring (design T, A.3.5)" do
    test "re-anchors when observed receive time drifts beyond 2 s without recording a media gap" do
      harness = start_harness(bounds: %{soft_frames: 2, max_frames: 4})
      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

      # Block 0: seq 0, 1 (PTS 0, 3_000) anchored at @base_utc_us
      send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
      send_unit(pid, harness.inbox_id, 1, 3_000, @base_utc_us + 33_333, @p_frame_payload)

      # Block 1: seq 2 (IDR, PTS 6_000 -> expected +66_666 us; observed +100_000 us -> drift <= 2 s)
      send_unit(pid, harness.inbox_id, 2, 6_000, @base_utc_us + 100_000, @idr_payload)
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key0}}}, 1_000
      assert_receive {:cataloged, ^key0, attrs0}, 1_000
      assert attrs0.anchor_id == "#{@relay_id}:1:0"
      assert attrs0.reanchored == false

      send_unit(pid, harness.inbox_id, 3, 9_000, @base_utc_us + 133_333, @p_frame_payload)

      # Block 2: seq 4 (IDR, PTS 12_000 -> expected +133_333 us; observed +5 s -> drift > 2 s -> re-anchored)
      drifted_utc_us = @base_utc_us + 5_000_000
      send_unit(pid, harness.inbox_id, 4, 12_000, drifted_utc_us, @idr_payload)

      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key1}}}, 1_000
      assert_receive {:cataloged, ^key1, attrs1}, 1_000
      assert attrs1.anchor_id == "#{@relay_id}:1:0"
      assert attrs1.reanchored == false
      assert attrs1.timeline_start_us == @base_utc_us + div(6_000 * 1_000_000, 90_000)

      ContinuousRecorder.stop(pid, :policy_disabled)
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key2}}}, 1_000
      assert_receive {:cataloged, ^key2, attrs2}, 1_000
      assert attrs2.reanchored == true
      assert attrs2.anchor_id == "#{@relay_id}:1:2"
      assert attrs2.timeline_start_us == drifted_utc_us
      assert attrs2.contiguous_with_previous == true
      assert_receive {:continuous_recorder, ^pid, {:run_stopped, _}}, 1_000
      refute_receive {:gap_recorded, _}, 100
    end
  end

  describe "policy updates, durable control stop, and ContinuousManager" do
    test "stops cleanly on durable RecordingControl stop during lease renewal" do
      harness =
        start_harness(
          bounds: %{soft_frames: 10, max_frames: 10},
          lease_ms: 400,
          renew_claim_fn: fn _owner, _claim, _ttl, _opts -> {:error, :recording_stopped} end
        )

      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

      send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
      send(pid, :renew_lease)

      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: _}}}, 1_000
      assert_receive {:continuous_recorder, ^pid, {:run_stopped, %{reason: :recording_stopped}}}, 1_000
      assert_receive :claim_released, 1_000
    end

    test "ContinuousManager starts, updates, reassigns, and stops recorders according to policies and control state" do
      parent = self()
      policies_agent = start_supervised!(Supervisor.child_spec({Agent, fn -> [] end}, id: :policies_agent))
      stopped_agent = start_supervised!(Supervisor.child_spec({Agent, fn -> false end}, id: :stopped_agent))

      start_fn = fn policy ->
        pid =
          spawn(fn ->
            receive do
              :exit_now -> :ok
            end
          end)

        send(parent, {:manager_started, policy.camera_source_id, policy.nvr_member, pid})
        {:ok, pid}
      end

      stop_fn = fn pid, reason ->
        send(parent, {:manager_stopped, pid, reason})
        send(pid, :exit_now)
        :ok
      end

      update_fn = fn pid, policy ->
        send(parent, {:manager_updated, pid, policy.storage, policy.policy_revision})
        :ok
      end

      {:ok, manager} =
        ContinuousManager.start_link(
          name: nil,
          interval_ms: 60_000,
          enabled_fn: fn -> true end,
          control_stopped_fn: fn -> Agent.get(stopped_agent, & &1) end,
          list_policies_fn: fn -> {:ok, Agent.get(policies_agent, & &1)} end,
          start_recorder_fn: start_fn,
          stop_recorder_fn: stop_fn,
          update_policy_fn: update_fn
        )

      policy1 = base_policy(%{policy_revision: 1, storage: :local_and_archive})
      Agent.update(policies_agent, fn _ -> [policy1] end)
      assert :ok = ContinuousManager.reconcile(manager)
      assert_receive {:manager_started, @camera_id, @member, worker1}, 1_000

      # Storage-only change forwards update_policy in place
      policy2 = %{policy1 | policy_revision: 2, storage: :local_only}
      Agent.update(policies_agent, fn _ -> [policy2] end)
      assert :ok = ContinuousManager.reconcile(manager)
      assert_receive {:manager_updated, ^worker1, :local_only, 2}, 1_000

      # Member reassignment stops old worker cleanly
      policy3 = %{policy2 | policy_revision: 3, nvr_member: "serviceradar-nvr-1"}
      Agent.update(policies_agent, fn _ -> [policy3] end)
      assert :ok = ContinuousManager.reconcile(manager)
      assert_receive {:manager_stopped, ^worker1, :member_changed}, 1_000

      # Wait for DOWN to clear tracking, then reconcile starts on new member
      Process.sleep(20)
      assert :ok = ContinuousManager.reconcile(manager)
      assert_receive {:manager_started, @camera_id, "serviceradar-nvr-1", worker2}, 1_000

      # Durable control stop stops all running continuous recorders
      Agent.update(stopped_agent, fn _ -> true end)
      assert :ok = ContinuousManager.reconcile(manager)
      assert_receive {:manager_stopped, ^worker2, :recording_stopped}, 1_000
    end
  end

  # ---------------------------------------------------------------------------
  # Synthetic test harness
  # ---------------------------------------------------------------------------

  defp base_policy(overrides \\ %{}) do
    Map.merge(
      %{
        id: @policy_id,
        camera_source_id: @camera_id,
        stream_profile_id: @profile_id,
        mode: :continuous,
        nvr_member: @member,
        storage: :local_and_archive,
        policy_revision: 1
      },
      overrides
    )
  end

  defp start_harness(overrides) do
    parent = self()
    seq_agent = start_supervised!({Agent, fn -> 0 end})
    inbox_ref = make_ref()

    pipeline_pid =
      spawn_link(fn ->
        receive do
          :stop_pipeline -> :ok
        end
      end)

    client_config = %ClientConfig{
      host: "nvr-0.example.test",
      port: 8443,
      ca: "/nonexistent/ca.pem",
      cert: "/nonexistent/client.pem",
      key: "/nonexistent/client.key",
      token: "synthetic-continuous-recorder-token-0123456789"
    }

    now = DateTime.utc_now()
    lease_expires_at = DateTime.shift(now, second: 30)

    owner = %{
      id: @ingest_owner_id,
      camera_source_id: @camera_id,
      stream_profile_id: @profile_id,
      relay_session_id: @relay_id,
      epoch: 1
    }

    claim = %{
      id: @claim_id,
      recorder_epoch: 1,
      lease_expires_at: lease_expires_at,
      database_now: now
    }

    default_send_fn = fn _cfg, header, stream, _timeout ->
      units = Enum.to_list(stream)
      block_key = header_block_key(header)
      send(parent, {:sent_block, block_key, units})
      {:ok, %{status: :sealed_local, storage_id: @storage_id, block_ids: [block_key]}}
    end

    default_inbox_new = fn producer, relay_id, ingest_id, deadline_ms, inbox_opts ->
      {:ok, inbox} = Inbox.new(producer, relay_id, ingest_id, deadline_ms, inbox_opts)
      {:ok, %{inbox | id: inbox_ref}}
    end

    reserve_fn = fn _owner, _claim, clock, _opts ->
      seq = Agent.get_and_update(seq_agent, fn s -> {s, s + 1} end)

      block = %RecordingBlock{
        id: Ecto.UUID.generate(),
        camera_source_id: @camera_id,
        stream_profile_id: @profile_id,
        ingest_owner_id: @ingest_owner_id,
        ingest_epoch: 1,
        recorder_claim_id: @claim_id,
        recorder_epoch: 1,
        block_sequence: seq,
        relay_session_id: @relay_id,
        media_ingest_id: @media_ingest_id,
        storage_id: @storage_id,
        clock: clock
      }

      block_key =
        block
        |> RecordingBlock.identity()
        |> Descriptor.block_key()

      {:ok, %{block | block_key: block_key}}
    end

    base_opts = [
      name: nil,
      policy: base_policy(),
      notify: parent,
      enabled_fn: fn -> true end,
      target_resolver: fn @member ->
        {:ok, %{member: @member, storage_id: @storage_id, client_config: client_config}}
      end,
      recovery_gate_fn: fn -> {:ok, %{generation: @recovery_generation}} end,
      relay_open_fn: fn @camera_id, @profile_id, _actor ->
        {:ok, {:new, %{id: @relay_id, status: :active, media_ingest_id: @media_ingest_id}}}
      end,
      relay_close_fn: fn @relay_id, _reason, _actor ->
        send(parent, :relay_closed)
        :ok
      end,
      pipeline_resolver: fn @relay_id, @media_ingest_id -> {:ok, pipeline_pid} end,
      ingest_owner_fn: fn @relay_id, _actor -> {:ok, owner} end,
      acquire_claim_fn: fn _owner, _token, _ingest_id, _storage_id, _ttl, _opts -> {:ok, claim} end,
      renew_claim_fn: fn _owner, _claim, _ttl, _opts -> {:ok, claim} end,
      release_claim_fn: fn _owner, _claim, _opts ->
        send(parent, :claim_released)
        {:ok, :released}
      end,
      reserve_block_fn: reserve_fn,
      inbox_new_fn: default_inbox_new,
      attach_pipeline_fn: fn _pipeline, _inbox, _timeout -> :ok end,
      send_recording_fn: default_send_fn,
      block_descriptor_fn: fn _cfg, block_key, _timeout ->
        {:ok, %{"block_key" => block_key, "fragments" => [%{"start_ns" => 0, "duration_ns" => 2_000_000_000}]}}
      end,
      freeze_and_catalog_fn: fn _owner, _claim, block, _descriptor, catalog_attrs, _opts ->
        send(parent, {:cataloged, block.block_key, catalog_attrs})
        entry_id = Ecto.UUID.generate()
        {:ok, %{id: entry_id, archive_state: :pending, block_key: block.block_key}}
      end,
      enqueue_archive_fn: fn %{id: entry_id, archive_state: :pending} ->
        send(parent, {:archive_enqueued, entry_id})
        {:ok, :enqueued}
      end,
      record_gap_fn: fn attrs, _opts ->
        send(parent, {:gap_recorded, attrs})
        {:ok, attrs}
      end
    ]

    %{
      opts: Keyword.merge(base_opts, overrides),
      inbox_id: inbox_ref,
      pipeline_pid: pipeline_pid
    }
  end

  defp header_block_key(header) do
    clock = %{
      "clock_epoch" => header["clock_epoch"],
      "timebase" => 90_000,
      "dts_source" => "pts_no_reordering",
      "utc_mapping" => "unknown"
    }

    header["identity"]
    |> Map.put("clock", clock)
    |> Descriptor.block_key()
  end

  defp send_unit(worker, inbox_id, sequence, pts, admitted_at_us, payload) do
    unit = %{
      sequence: sequence,
      pts: pts,
      dts: pts,
      payload: payload,
      admitted_at_us: admitted_at_us
    }

    send(worker, {:recording_media, inbox_id, unit})
  end
end
