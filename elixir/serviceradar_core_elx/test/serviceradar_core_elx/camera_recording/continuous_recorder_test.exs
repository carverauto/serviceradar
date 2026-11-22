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
        units =
          Enum.map(stream, fn unit ->
            send(parent, {:pulled, unit.sequence})
            unit
          end)

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
      assert_receive {:pulled, 1}, 1_000
      send_unit(pid, harness.inbox_id, 2, 6_000, @base_utc_us + 66_666, @idr_payload)

      assert_receive {:block0_waiting_to_seal, sender0_pid}, 1_000

      # While Block 0 is sealing, handover_queue already has seq 2 (1/2).
      # Seq 3 fits (2/2). Seq 4 and Seq 5 overflow -> dropped!
      send_unit(pid, harness.inbox_id, 3, 9_000, @base_utc_us + 100_000, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 4, 12_000, @base_utc_us + 133_333, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 5, 15_000, @base_utc_us + 166_666, @p_frame_payload)

      # Release Block 0 seal -> drains seq 2, 3 into Block 1 and cuts at the overflow barrier
      send(sender0_pid, {gate, :release_seal})
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: _key0}}}, 1_000
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key1}}}, 1_000
      assert_receive {:sent_block, ^key1, block1_units}, 1_000
      assert Enum.map(block1_units, & &1.sequence) == [2, 3]

      # Seq 6 (IDR) arrives after the drop -> records :handover_overflow gap, starts Block 2
      send_unit(pid, harness.inbox_id, 6, 18_000, @base_utc_us + 200_000, @idr_payload)

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
    test "records nvr_refused gap with http status detail_class and continues on next block" do
      parent = self()

      send_fn = fn _cfg, header, stream, _timeout ->
        units = Enum.to_list(stream)
        block_key = header_block_key(header)
        send(parent, {:sent_block, block_key, units})

        if header["identity"]["block_sequence"] == 0 do
          {:error, {:ingest_refused, 503}}
        else
          {:ok, %{status: :sealed_local, storage_id: @storage_id, block_ids: [block_key]}}
        end
      end

      harness = start_harness(bounds: %{soft_frames: 2, max_frames: 2}, send_recording_fn: send_fn)
      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

      send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
      send_unit(pid, harness.inbox_id, 1, 3_000, @base_utc_us + 33_333, @p_frame_payload)

      assert_receive {:continuous_recorder, ^pid, {:nvr_refused, %{status: 503, detail_class: "http_503"}}},
                     1_000

      assert_receive {:gap_recorded, gap}, 1_000
      assert gap.reason == :nvr_refused
      assert gap.detail_class == "http_503"
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

    test "re-checks recovery gate on NVR refusal and stops run immediately when gate is closed" do
      gate_open = start_supervised!(Supervisor.child_spec({Agent, fn -> true end}, id: :refusal_gate_agent))

      send_fn = fn _cfg, _header, stream, _timeout ->
        _units = Enum.to_list(stream)
        Agent.update(gate_open, fn _ -> false end)
        {:error, {:ingest_refused, 503}}
      end

      recovery_gate_fn = fn ->
        if Agent.get(gate_open, & &1) do
          {:ok, %{generation: @recovery_generation}}
        else
          {:error, :nvr_recovery_closed}
        end
      end

      harness =
        start_harness(
          bounds: %{soft_frames: 2, max_frames: 2},
          send_recording_fn: send_fn,
          recovery_gate_fn: recovery_gate_fn
        )

      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

      send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
      send_unit(pid, harness.inbox_id, 1, 3_000, @base_utc_us + 33_333, @p_frame_payload)

      assert_receive {:continuous_recorder, ^pid, {:nvr_refused, %{status: 503, detail_class: "nvr_recovery_closed"}}},
                     1_000

      assert_receive {:gap_recorded, gap}, 1_000
      assert gap.reason == :nvr_refused
      assert gap.detail_class == "nvr_recovery_closed"
      assert_receive {:continuous_recorder, ^pid, {:run_stopped, %{reason: :nvr_recovery_closed}}}, 1_000
      assert_receive :claim_released, 1_000
      assert_receive :relay_closed, 1_000
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

  describe "default handover sizing and non-blocking async catalog/lookup with real Inbox" do
    test "defaults handover limits strictly below Inbox credit and keeps Inbox.offer flowing during slow catalog" do
      parent = self()
      gate = make_ref()
      inbox_agent = start_supervised!(Supervisor.child_spec({Agent, fn -> nil end}, id: :real_inbox_catalog_agent))

      producer =
        spawn_link(fn ->
          real_inbox_producer_loop(parent)
        end)

      descriptor_fn = fn _cfg, block_key, _timeout ->
        send(parent, {:descriptor_started, self(), block_key})

        receive do
          {^gate, :release_descriptor} ->
            {:ok, %{"block_key" => block_key, "fragments" => [%{"start_ns" => 0, "duration_ns" => 2_000_000_000}]}}
        end
      end

      harness =
        start_harness(
          bounds: %{soft_frames: 2, max_frames: 112},
          pipeline_resolver: fn @relay_id, @media_ingest_id -> {:ok, producer} end,
          inbox_new_fn: fn prod, relay_id, ingest_id, deadline_ms, inbox_opts ->
            {:ok, inbox} = Inbox.new(prod, relay_id, ingest_id, deadline_ms, inbox_opts)
            Agent.update(inbox_agent, fn _ -> inbox end)
            {:ok, inbox}
          end,
          block_descriptor_fn: descriptor_fn
        )

      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

      status = ContinuousRecorder.status(pid)
      assert {status.handover_max_samples, status.handover_max_bytes} == {112, 14_680_064}

      inbox = Agent.get(inbox_agent, & &1)

      # Block 0 takes seq 0..1, seq 2 (IDR) triggers soft cut -> seals and enters async :cataloging
      assert :ok == offer_via_producer(producer, inbox, 0, 0, @idr_payload)
      assert :ok == offer_via_producer(producer, inbox, 1, 3_000, @p_frame_payload)
      assert :ok == offer_via_producer(producer, inbox, 2, 6_000, @idr_payload)

      assert_receive {:descriptor_started, desc_pid, key0}, 1_000
      assert ContinuousRecorder.status(pid).phase == :cataloging

      # Feed 149 more frames (total > Inbox 128 default) while descriptor/catalog is blocked.
      # Every Inbox.offer MUST return :ok because handover drops at 112 and releases Inbox credit immediately.
      offer_results =
        for seq <- 3..151 do
          offer_via_producer(producer, inbox, seq, seq * 3_000, @p_frame_payload)
        end

      assert Enum.all?(offer_results, &(&1 == :ok))

      # Sync with GenServer mailbox to ensure all frames were processed while cataloging
      assert ContinuousRecorder.status(pid).handover_samples == 112

      send(desc_pid, {gate, :release_descriptor})

      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: ^key0, catalog: {:registered, _}}}},
                     1_000

      # Block 1 drains seq 2..113 (112 frames = max_frames) and seals
      assert_receive {:descriptor_started, desc_pid1, _key1}, 1_000
      send(desc_pid1, {gate, :release_descriptor})
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{catalog: {:registered, _}}}}, 1_000

      assert :ok == offer_via_producer(producer, inbox, 152, 152 * 3_000, @idr_payload)

      assert_receive {:gap_recorded, gap}, 1_000

      # Dropped frames start at seq 114 (pts 342_000) through seq 152 (pts 456_000) = 114_000 ticks
      assert {gap.reason, gap.detail_class, gap.media_gap_ns} ==
               {:handover_overflow, "handover_queue_full", div((152 - 114) * 3_000 * 1_000_000_000, 90_000)}

      ContinuousRecorder.stop(pid, :policy_disabled)
      assert_receive {:descriptor_started, desc_pid2, _key2}, 1_000
      send(desc_pid2, {gate, :release_descriptor})
      assert_receive {:continuous_recorder, ^pid, {:run_stopped, %{reason: :policy_disabled}}}, 1_000
      refute_receive {:continuous_recorder, ^pid, {:run_stopped, %{reason: :inbox_overflow}}}, 50
    end

    test "keeps Inbox.offer flowing during slow async lookup_blocks resolution" do
      parent = self()
      gate = make_ref()
      inbox_agent = start_supervised!(Supervisor.child_spec({Agent, fn -> nil end}, id: :real_inbox_lookup_agent))
      attempts_agent = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: :lookup_async_attempts))

      producer =
        spawn_link(fn ->
          real_inbox_producer_loop(parent)
        end)

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
        attempt = Agent.get_and_update(attempts_agent, fn n -> {n + 1, n + 1} end)

        if attempt == 1 do
          send(parent, {:lookup_blocked, self(), block_key})

          receive do
            {^gate, :release_lookup} -> {:error, :unavailable}
          end
        else
          {:ok, %{storage_id: @storage_id, blocks: [%{block_id: block_key, state: :sealed}]}}
        end
      end

      harness =
        start_harness(
          bounds: %{soft_frames: 2, max_frames: 112},
          lookup_max_attempts: 2,
          lookup_retry_delay_ms: 5,
          pipeline_resolver: fn @relay_id, @media_ingest_id -> {:ok, producer} end,
          inbox_new_fn: fn prod, relay_id, ingest_id, deadline_ms, inbox_opts ->
            {:ok, inbox} = Inbox.new(prod, relay_id, ingest_id, deadline_ms, inbox_opts)
            Agent.update(inbox_agent, fn _ -> inbox end)
            {:ok, inbox}
          end,
          send_recording_fn: send_fn,
          lookup_blocks_fn: lookup_fn
        )

      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000
      inbox = Agent.get(inbox_agent, & &1)

      assert :ok = offer_via_producer(producer, inbox, 0, 0, @idr_payload)
      assert :ok = offer_via_producer(producer, inbox, 1, 3_000, @p_frame_payload)
      assert :ok = offer_via_producer(producer, inbox, 2, 6_000, @idr_payload)

      assert_receive {:lookup_blocked, lookup_pid, key0}, 1_000
      assert ContinuousRecorder.status(pid).phase == :resolving

      offer_results =
        for seq <- 3..140 do
          offer_via_producer(producer, inbox, seq, seq * 3_000, @p_frame_payload)
        end

      assert Enum.all?(offer_results, &(&1 == :ok))
      assert ContinuousRecorder.status(pid).handover_samples == 112

      send(lookup_pid, {gate, :release_lookup})

      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: ^key0, catalog: {:registered, _}}}},
                     1_000

      # Block 1 drains seq 2..113 and cuts at the overflow barrier
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{catalog: {:registered, _}}}}, 1_000

      assert :ok == offer_via_producer(producer, inbox, 141, 141 * 3_000, @idr_payload)
      assert_receive {:gap_recorded, gap}, 1_000
      assert gap.reason == :handover_overflow

      ContinuousRecorder.stop(pid, :policy_disabled)
      assert_receive {:continuous_recorder, ^pid, {:run_stopped, %{reason: :policy_disabled}}}, 1_000
    end

    test "counts unsent sealing block queue against handover cap so NVR backpressure avoids Inbox queue_full" do
      parent = self()
      gate = make_ref()
      inbox_agent = start_supervised!(Supervisor.child_spec({Agent, fn -> nil end}, id: :backpressure_inbox_agent))

      producer =
        spawn_link(fn ->
          real_inbox_producer_loop(parent)
        end)

      send_fn = fn _cfg, header, stream, _timeout ->
        if header["identity"]["block_sequence"] == 0 do
          send(parent, {:sender0_paused, self()})

          receive do
            {^gate, :release_sender0} -> :ok
          end
        end

        units = Enum.to_list(stream)
        block_key = header_block_key(header)
        send(parent, {:sent_block, block_key, units})
        {:ok, %{status: :sealed_local, storage_id: @storage_id, block_ids: [block_key]}}
      end

      harness =
        start_harness(
          bounds: %{soft_frames: 20, max_frames: 112},
          pipeline_resolver: fn @relay_id, @media_ingest_id -> {:ok, producer} end,
          inbox_new_fn: fn prod, relay_id, ingest_id, deadline_ms, inbox_opts ->
            {:ok, inbox} = Inbox.new(prod, relay_id, ingest_id, deadline_ms, inbox_opts)
            Agent.update(inbox_agent, fn _ -> inbox end)
            {:ok, inbox}
          end,
          send_recording_fn: send_fn
        )

      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000
      inbox = Agent.get(inbox_agent, & &1)

      # Offer seq 0 to spawn sender0 and pause it BEFORE pulling any units (NVR backpressure)
      assert :ok == offer_via_producer(producer, inbox, 0, 0, @idr_payload)
      assert_receive {:sender0_paused, sender0_pid}, 1_000

      # Fill Block 0 with 19 more unsent frames (20 unsent total), then soft-cut with seq 20 (IDR),
      # then offer 120 more frames while sender0 is still stalled (total 141 > Inbox 128 default).
      offer_results =
        for seq <- 1..140 do
          payload = if seq == 20, do: @idr_payload, else: @p_frame_payload
          offer_via_producer(producer, inbox, seq, seq * 3_000, payload)
        end

      assert Enum.all?(offer_results, &(&1 == :ok))

      # Handover queue must stop at 112 - 20 = 92 samples while 20 unsent frames remain in Block 0's queue
      status = ContinuousRecorder.status(pid)
      assert {status.phase, status.handover_samples} == {:sealing, 92}

      send(sender0_pid, {gate, :release_sender0})
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key0}}}, 1_000
      assert_receive {:sent_block, ^key0, block0_units}, 1_000
      assert length(block0_units) == 20

      # Block 1 drains the 92 buffered frames [20..111] and hits the overflow barrier
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key1}}}, 1_000
      assert_receive {:sent_block, ^key1, block1_units}, 1_000
      assert {hd(block1_units).sequence, List.last(block1_units).sequence} == {20, 111}

      assert :ok == offer_via_producer(producer, inbox, 141, 141 * 3_000, @idr_payload)
      assert_receive {:gap_recorded, %{reason: :handover_overflow, detail_class: "handover_queue_full"}}, 1_000

      ContinuousRecorder.stop(pid, :policy_disabled)
      assert_receive {:continuous_recorder, ^pid, {:run_stopped, %{reason: :policy_disabled}}}, 1_000
      refute_receive {:continuous_recorder, ^pid, {:run_stopped, %{reason: :inbox_overflow}}}, 50
    end

    test "restores drained unit to head of handover queue on mid-drain soft cut preserving order and IDR start" do
      parent = self()
      gate = make_ref()
      desc_count = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: :mid_drain_cut_desc_agent))

      descriptor_fn = fn _cfg, block_key, _timeout ->
        call_num = Agent.get_and_update(desc_count, fn n -> {n + 1, n + 1} end)

        if call_num == 1 do
          send(parent, {:block0_mid_drain_paused, self()})

          receive do
            {^gate, :release_catalog} -> :ok
          end
        end

        {:ok, %{"block_key" => block_key, "fragments" => [%{"start_ns" => 0, "duration_ns" => 2_000_000_000}]}}
      end

      harness =
        start_harness(
          bounds: %{soft_frames: 2, max_frames: 10},
          handover_max_samples: 5,
          block_descriptor_fn: descriptor_fn
        )

      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

      # Block 0 takes seq 0..1; seq 2 (IDR) triggers soft cut into :cataloging
      send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
      send_unit(pid, harness.inbox_id, 1, 3_000, @base_utc_us + 33_333, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 2, 6_000, @base_utc_us + 66_666, @idr_payload)
      assert_receive {:block0_mid_drain_paused, catalog_pid}, 1_000

      # Buffer 4 more units in handover_queue while Block 0 catalogs (5 total = handover_max_samples):
      # [seq 2(IDR), seq 3(P), seq 4(IDR), seq 5(P), seq 6(P)].
      # Draining hits soft_frames=2 at seq 4(IDR) while seq 5..6 are still queued.
      send_unit(pid, harness.inbox_id, 3, 9_000, @base_utc_us + 100_000, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 4, 12_000, @base_utc_us + 133_333, @idr_payload)
      send_unit(pid, harness.inbox_id, 5, 15_000, @base_utc_us + 166_666, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 6, 18_000, @base_utc_us + 200_000, @p_frame_payload)
      assert ContinuousRecorder.status(pid).handover_samples == 5

      send(catalog_pid, {gate, :release_catalog})
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key0}}}, 1_000
      assert_receive {:sent_block, ^key0, _}, 1_000

      # Block 1 must contain [2, 3], cut cleanly at seq 4(IDR)
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key1}}}, 1_000
      assert_receive {:sent_block, ^key1, block1_units}, 1_000
      assert_receive {:cataloged, ^key1, attrs1}, 1_000
      assert Enum.map(block1_units, & &1.sequence) == [2, 3]
      assert attrs1.contiguous_with_previous == true

      # Stop -> Block 2 must start on seq 4(IDR) followed by [5, 6] in exact order, contiguous with Block 1
      ContinuousRecorder.stop(pid, :policy_disabled)
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key2}}}, 1_000
      assert_receive {:sent_block, ^key2, block2_units}, 1_000
      assert_receive {:cataloged, ^key2, attrs2}, 1_000
      assert Enum.map(block2_units, & &1.sequence) == [4, 5, 6]
      assert ContinuousRecorder.keyframe_unit?(hd(block2_units))
      assert attrs2.contiguous_with_previous == true
      assert_receive {:continuous_recorder, ^pid, {:run_stopped, %{reason: :policy_disabled}}}, 1_000
      refute_receive {:gap_recorded, _}, 50
    end
  end

  describe "gap origin and IDR alignment after discontinuities" do
    test "sequence skip while streaming records true non-zero media_gap_ns and waits for IDR" do
      harness = start_harness(bounds: %{soft_frames: 5, max_frames: 10})
      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

      # Admit units 10 (pts 30_000) and 11 (pts 33_000) -> last_unit_duration_ticks = 3_000
      send_unit(pid, harness.inbox_id, 10, 30_000, @base_utc_us, @idr_payload)
      send_unit(pid, harness.inbox_id, 11, 33_000, @base_utc_us + 33_333, @p_frame_payload)

      # Skip units 12..19; unit 20 arrives as a P-frame (non-IDR) at pts 60_000
      send_unit(pid, harness.inbox_id, 20, 60_000, @base_utc_us + 333_333, @p_frame_payload)

      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key0}}}, 1_000
      assert_receive {:sent_block, ^key0, block0_units}, 1_000
      assert Enum.map(block0_units, & &1.sequence) == [10, 11]

      # Unit 20 (P-frame) must NOT start Block 1; unit 21 (IDR, pts 63_000) starts Block 1
      send_unit(pid, harness.inbox_id, 21, 63_000, @base_utc_us + 366_666, @idr_payload)

      assert_receive {:gap_recorded, gap}, 1_000
      assert gap.reason == :source_unavailable
      assert gap.detail_class == "media_sequence_discontinuity"
      # Gap starts at 33_000 + 3_000 = 36_000 ticks, ends at unit 21 pts 63_000 -> 27_000 ticks (300 ms)
      assert gap.media_gap_ns == div(27_000 * 1_000_000_000, 90_000)
      assert gap.end_us > gap.start_us

      ContinuousRecorder.stop(pid, :policy_disabled)
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key1}}}, 1_000
      assert_receive {:sent_block, ^key1, block1_units}, 1_000
      assert Enum.map(block1_units, & &1.sequence) == [21]
      assert_receive {:cataloged, ^key1, attrs1}, 1_000
      assert attrs1.contiguous_with_previous == false
      assert_receive {:continuous_recorder, ^pid, {:run_stopped, _}}, 1_000
    end

    test "sequence skip while idle records exact non-zero gap and requires IDR before starting next block" do
      harness = start_harness(bounds: %{soft_frames: 2, max_frames: 2})
      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

      # Block 0 hits max_frames=2 on seq 1 -> seals and returns to :idle
      send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
      send_unit(pid, harness.inbox_id, 1, 3_000, @base_utc_us + 33_333, @p_frame_payload)
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, _}}, 1_000
      assert ContinuousRecorder.status(pid).phase == :idle

      # Skip seq 2..9; seq 10 arrives as P-frame at pts 30_000, then seq 11 arrives as IDR at pts 33_000
      send_unit(pid, harness.inbox_id, 10, 30_000, @base_utc_us + 333_333, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 11, 33_000, @base_utc_us + 366_666, @idr_payload)

      assert_receive {:gap_recorded, gap}, 1_000
      assert gap.reason == :source_unavailable
      assert gap.detail_class == "media_sequence_discontinuity"
      # Gap starts at 3_000 + 3_000 = 6_000 ticks, ends at seq 11 pts 33_000 -> 27_000 ticks
      assert gap.media_gap_ns == div(27_000 * 1_000_000_000, 90_000)
      assert gap.end_us > gap.start_us

      ContinuousRecorder.stop(pid, :policy_disabled)
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key1}}}, 1_000
      assert_receive {:sent_block, ^key1, block1_units}, 1_000
      assert Enum.map(block1_units, & &1.sequence) == [11]
      assert_receive {:continuous_recorder, ^pid, {:run_stopped, _}}, 1_000
    end

    test "in-block sequence mismatch after handover overflow drops non-IDR and waits for IDR" do
      parent = self()
      gate = make_ref()

      send_fn = fn _cfg, header, stream, _timeout ->
        units =
          Enum.map(stream, fn unit ->
            send(parent, {:pulled, unit.sequence})
            unit
          end)

        block_key = header_block_key(header)
        send(parent, {:sent_block, block_key, units})

        if header["identity"]["block_sequence"] == 0 do
          send(parent, {:block0_waiting, self()})

          receive do
            {^gate, :release} -> :ok
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

      send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
      send_unit(pid, harness.inbox_id, 1, 3_000, @base_utc_us + 33_333, @p_frame_payload)
      assert_receive {:pulled, 1}, 1_000
      send_unit(pid, harness.inbox_id, 2, 6_000, @base_utc_us + 66_666, @idr_payload)
      assert_receive {:block0_waiting, sender0}, 1_000

      # Fill handover queue with seq 3, overflow seq 4 and 5
      send_unit(pid, harness.inbox_id, 3, 9_000, @base_utc_us + 100_000, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 4, 12_000, @base_utc_us + 133_333, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 5, 15_000, @base_utc_us + 166_666, @p_frame_payload)

      send(sender0, {gate, :release})
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, _}}, 1_000

      # Seq 6 arrives as a P-frame (non-IDR) -> triggers in-block mismatch on Block 1 ([2, 3]),
      # MUST NOT start Block 2; seq 7 (IDR) starts Block 2.
      send_unit(pid, harness.inbox_id, 6, 18_000, @base_utc_us + 200_000, @p_frame_payload)
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key1}}}, 1_000
      assert_receive {:sent_block, ^key1, block1_units}, 1_000
      assert Enum.map(block1_units, & &1.sequence) == [2, 3]

      send_unit(pid, harness.inbox_id, 7, 21_000, @base_utc_us + 233_333, @idr_payload)
      assert_receive {:gap_recorded, gap}, 1_000
      assert gap.reason == :handover_overflow
      assert gap.media_gap_ns == div((21_000 - 12_000) * 1_000_000_000, 90_000)

      ContinuousRecorder.stop(pid, :policy_disabled)
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key2}}}, 1_000
      assert_receive {:sent_block, ^key2, block2_units}, 1_000
      assert Enum.map(block2_units, & &1.sequence) == [7]
      assert_receive {:continuous_recorder, ^pid, {:run_stopped, _}}, 1_000
    end

    test "timestamp discontinuity preserves prior streaming block anchor and re-anchors the next block" do
      harness = start_harness(bounds: %{soft_frames: 2, max_frames: 5})
      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

      # Block 0 (seq 0..1) establishes anchor 0; seq 2 (IDR) triggers contiguous soft cut into Block 1
      send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
      send_unit(pid, harness.inbox_id, 1, 3_000, @base_utc_us + 33_333, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 2, 6_000, @base_utc_us + 100_000, @idr_payload)

      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key0}}}, 1_000
      assert_receive {:cataloged, ^key0, attrs0}, 1_000
      assert {attrs0.anchor_id, attrs0.reanchored} == {"#{@relay_id}:1:0", false}

      # Admit seq 3 into Block 1, then trigger a backwards-PTS discontinuity mid-Block 1
      send_unit(pid, harness.inbox_id, 3, 9_000, @base_utc_us + 133_333, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 4, 1_000, @base_utc_us + 200_000, @p_frame_payload)

      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key1}}}, 1_000
      assert_receive {:sent_block, ^key1, block1_units}, 1_000
      assert_receive {:cataloged, ^key1, attrs1}, 1_000

      # Block 1 preceded the discontinuity: must retain anchor 0, reanchored: false, contiguous: true
      assert Enum.map(block1_units, & &1.sequence) == [2, 3]

      assert {attrs1.anchor_id, attrs1.reanchored, attrs1.contiguous_with_previous, attrs1.timeline_start_us} ==
               {"#{@relay_id}:1:0", false, true, @base_utc_us + div(6_000 * 1_000_000, 90_000)}

      # Post-discontinuity IDR starts Block 2 -> must re-anchor with contiguous: false
      post_utc_us = @base_utc_us + 250_000
      send_unit(pid, harness.inbox_id, 5, 4_000, post_utc_us, @idr_payload)
      assert_receive {:gap_recorded, %{reason: :source_unavailable, detail_class: "timestamp_discontinuity"}}, 1_000

      ContinuousRecorder.stop(pid, :policy_disabled)
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key2}}}, 1_000
      assert_receive {:sent_block, ^key2, block2_units}, 1_000
      assert_receive {:cataloged, ^key2, attrs2}, 1_000

      assert Enum.map(block2_units, & &1.sequence) == [5]

      assert {attrs2.anchor_id, attrs2.reanchored, attrs2.contiguous_with_previous, attrs2.timeline_start_us} ==
               {"#{@relay_id}:1:2", true, false, post_utc_us}

      assert_receive {:continuous_recorder, ^pid, {:run_stopped, _}}, 1_000
    end

    test "drops reordered_dts IDR units without admitting them and re-anchors on next valid IDR" do
      harness = start_harness(bounds: %{soft_frames: 2, max_frames: 5})
      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

      # Block 0 (seq 0..1) and contiguous soft cut to Block 1 (seq 2..3)
      send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
      send_unit(pid, harness.inbox_id, 1, 3_000, @base_utc_us + 33_333, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 2, 6_000, @base_utc_us + 66_666, @idr_payload)
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key0}}}, 1_000
      assert_receive {:sent_block, ^key0, _block0_units}, 1_000
      send_unit(pid, harness.inbox_id, 3, 9_000, @base_utc_us + 100_000, @p_frame_payload)

      # Reordered IDR (dts < pts) while streaming -> closes Block 1 cleanly and drops the reordered IDR
      send_reordered_unit(pid, harness.inbox_id, 4, 15_000, 12_000, @base_utc_us + 133_333, @idr_payload)

      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key1}}}, 1_000
      assert_receive {:sent_block, ^key1, block1_units}, 1_000
      assert_receive {:cataloged, ^key1, attrs1}, 1_000
      assert Enum.map(block1_units, & &1.sequence) == [2, 3]

      assert {attrs1.anchor_id, attrs1.reanchored, attrs1.contiguous_with_previous} ==
               {"#{@relay_id}:1:0", false, true}

      # Another reordered IDR while idle must ALSO be dropped without starting a block
      send_reordered_unit(pid, harness.inbox_id, 5, 18_000, 15_000, @base_utc_us + 166_666, @idr_payload)
      assert ContinuousRecorder.status(pid).phase == :idle
      refute_receive {:sent_block, _, _}, 50

      # First valid IDR (dts == pts, forward PTS, drift < 2s) starts Block 2 and MUST re-anchor
      valid_utc_us = @base_utc_us + 200_000
      send_unit(pid, harness.inbox_id, 6, 21_000, valid_utc_us, @idr_payload)
      assert_receive {:gap_recorded, %{reason: :source_unavailable, detail_class: "reordered_dts"}}, 1_000

      ContinuousRecorder.stop(pid, :policy_disabled)
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key2}}}, 1_000
      assert_receive {:sent_block, ^key2, block2_units}, 1_000
      assert_receive {:cataloged, ^key2, attrs2}, 1_000
      assert Enum.map(block2_units, & &1.sequence) == [6]

      assert {attrs2.anchor_id, attrs2.reanchored, attrs2.contiguous_with_previous, attrs2.timeline_start_us} ==
               {"#{@relay_id}:1:2", true, false, valid_utc_us}

      assert_receive {:continuous_recorder, ^pid, {:run_stopped, _}}, 1_000
    end

    test "positions backward-PTS discontinuity in handover queue so buffered pre-break units stay contiguous" do
      parent = self()
      gate = make_ref()
      desc_count = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: :ho_disc_desc_agent))

      descriptor_fn = fn _cfg, block_key, _timeout ->
        call_num = Agent.get_and_update(desc_count, fn n -> {n + 1, n + 1} end)

        if call_num == 1 do
          send(parent, {:block0_catalog_paused, self()})

          receive do
            {^gate, :release_catalog} -> :ok
          end
        end

        {:ok, %{"block_key" => block_key, "fragments" => [%{"start_ns" => 0, "duration_ns" => 2_000_000_000}]}}
      end

      harness = start_harness(bounds: %{soft_frames: 2, max_frames: 10}, block_descriptor_fn: descriptor_fn)
      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

      # Block 0 takes seq 0..1; seq 2 (IDR) soft-cuts Block 0 into :cataloging
      send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
      send_unit(pid, harness.inbox_id, 1, 3_000, @base_utc_us + 33_333, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 2, 6_000, @base_utc_us + 66_666, @idr_payload)
      assert_receive {:block0_catalog_paused, catalog_pid}, 1_000

      # While Block 0 is cataloging, seq 3 buffers normally before the break,
      # then seq 4 arrives with a backward PTS (1_000 < 9_000) as an IDR
      post_utc_us = @base_utc_us + 200_000
      send_unit(pid, harness.inbox_id, 3, 9_000, @base_utc_us + 100_000, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 4, 1_000, post_utc_us, @idr_payload)
      assert ContinuousRecorder.status(pid).handover_samples == 3

      send(catalog_pid, {gate, :release_catalog})
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key0}}}, 1_000
      assert_receive {:sent_block, ^key0, _}, 1_000
      assert_receive {:cataloged, ^key0, _}, 1_000

      # Block 1 must contain ONLY [2, 3] (no backward PTS seq 4!) with original anchor & contiguous: true
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key1}}}, 1_000
      assert_receive {:sent_block, ^key1, block1_units}, 1_000
      assert_receive {:cataloged, ^key1, attrs1}, 1_000
      assert Enum.map(block1_units, & &1.sequence) == [2, 3]

      assert {attrs1.anchor_id, attrs1.reanchored, attrs1.contiguous_with_previous} ==
               {"#{@relay_id}:1:0", false, true}

      # Seq 4 (post-break IDR) flushes gap and starts Block 2 with reanchored: true, contiguous: false
      assert_receive {:gap_recorded, %{reason: :source_unavailable, detail_class: "timestamp_discontinuity"}}, 1_000

      ContinuousRecorder.stop(pid, :policy_disabled)
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key2}}}, 1_000
      assert_receive {:sent_block, ^key2, block2_units}, 1_000
      assert_receive {:cataloged, ^key2, attrs2}, 1_000
      assert Enum.map(block2_units, & &1.sequence) == [4]

      assert {attrs2.anchor_id, attrs2.reanchored, attrs2.contiguous_with_previous, attrs2.timeline_start_us} ==
               {"#{@relay_id}:1:2", true, false, post_utc_us}

      assert_receive {:continuous_recorder, ^pid, {:run_stopped, _}}, 1_000
    end

    test "positions reordered_dts barrier in handover queue so buffered pre-break units keep original anchor" do
      parent = self()
      gate = make_ref()
      desc_count = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: :ho_reord_desc_agent))

      descriptor_fn = fn _cfg, block_key, _timeout ->
        call_num = Agent.get_and_update(desc_count, fn n -> {n + 1, n + 1} end)

        if call_num == 1 do
          send(parent, {:block0_reord_catalog_paused, self()})

          receive do
            {^gate, :release_catalog} -> :ok
          end
        end

        {:ok, %{"block_key" => block_key, "fragments" => [%{"start_ns" => 0, "duration_ns" => 2_000_000_000}]}}
      end

      harness = start_harness(bounds: %{soft_frames: 2, max_frames: 10}, block_descriptor_fn: descriptor_fn)
      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

      send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
      send_unit(pid, harness.inbox_id, 1, 3_000, @base_utc_us + 33_333, @p_frame_payload)
      send_unit(pid, harness.inbox_id, 2, 6_000, @base_utc_us + 66_666, @idr_payload)
      assert_receive {:block0_reord_catalog_paused, catalog_pid}, 1_000

      # Buffer seq 3 before break, drop reordered seq 4, buffer valid IDR seq 5 after break
      valid_utc_us = @base_utc_us + 200_000
      send_unit(pid, harness.inbox_id, 3, 9_000, @base_utc_us + 100_000, @p_frame_payload)
      send_reordered_unit(pid, harness.inbox_id, 4, 15_000, 12_000, @base_utc_us + 133_333, @idr_payload)
      send_unit(pid, harness.inbox_id, 5, 18_000, valid_utc_us, @idr_payload)

      send(catalog_pid, {gate, :release_catalog})
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key0}}}, 1_000
      assert_receive {:sent_block, ^key0, _}, 1_000
      assert_receive {:cataloged, ^key0, _}, 1_000

      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key1}}}, 1_000
      assert_receive {:sent_block, ^key1, block1_units}, 1_000
      assert_receive {:cataloged, ^key1, attrs1}, 1_000
      assert Enum.map(block1_units, & &1.sequence) == [2, 3]

      assert {attrs1.anchor_id, attrs1.reanchored, attrs1.contiguous_with_previous} ==
               {"#{@relay_id}:1:0", false, true}

      assert_receive {:gap_recorded, %{reason: :source_unavailable, detail_class: "reordered_dts"}}, 1_000

      ContinuousRecorder.stop(pid, :policy_disabled)
      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: key2}}}, 1_000
      assert_receive {:sent_block, ^key2, block2_units}, 1_000
      assert_receive {:cataloged, ^key2, attrs2}, 1_000
      assert Enum.map(block2_units, & &1.sequence) == [5]

      assert {attrs2.anchor_id, attrs2.reanchored, attrs2.contiguous_with_previous, attrs2.timeline_start_us} ==
               {"#{@relay_id}:1:2", true, false, valid_utc_us}

      assert_receive {:continuous_recorder, ^pid, {:run_stopped, _}}, 1_000
    end
  end

  describe "startup failure cleanup, multi-replica ownership, and manager backoff" do
    test "closes a newly opened relay on startup failure even when claim is nil" do
      harness =
        start_harness(
          relay_open_fn: fn @camera_id, @profile_id, _actor ->
            {:ok, {:new, %{id: @relay_id, status: :active, media_ingest_id: @media_ingest_id}}}
          end,
          pipeline_resolver: fn @relay_id, @media_ingest_id -> {:error, :recording_ingest_mismatch} end,
          relay_host_fn: fn @relay_id -> nil end
        )

      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)

      assert_receive {:gap_recorded, gap}, 1_000
      assert gap.reason == :source_unavailable

      assert_receive {:continuous_recorder, ^pid,
                      {:run_stopped,
                       %{reason: :recording_ingest_mismatch, startup_failed?: true, startup_gap_recorded?: true}}},
                     1_000

      assert_receive :relay_closed, 1_000
      refute_receive :claim_released, 100
    end

    test "does not close a reused relay or record a gap when another node owns the relay or claim" do
      harness_remote =
        start_harness(
          relay_open_fn: fn @camera_id, @profile_id, _actor ->
            {:ok, {:reuse, %{id: @relay_id, status: :active, media_ingest_id: @media_ingest_id}}}
          end,
          pipeline_resolver: fn @relay_id, @media_ingest_id -> {:error, :recording_ingest_mismatch} end,
          relay_host_fn: fn @relay_id -> :"peer@127.0.0.1" end
        )

      {:ok, pid1} = ContinuousRecorder.start_link(harness_remote.opts)

      assert_receive {:continuous_recorder, ^pid1,
                      {:run_stopped,
                       %{
                         reason: {:remote_relay_host, :"peer@127.0.0.1"},
                         startup_failed?: true,
                         startup_gap_recorded?: false
                       }}},
                     1_000

      refute_receive {:gap_recorded, _}, 100
      refute_receive :relay_closed, 100

      harness_owned =
        start_harness(
          relay_open_fn: fn @camera_id, @profile_id, _actor ->
            {:ok, {:reuse, %{id: @relay_id, status: :active, media_ingest_id: @media_ingest_id}}}
          end,
          acquire_claim_fn: fn _owner, _token, _ingest_id, _storage_id, _ttl, _opts ->
            {:error, :recorder_already_owned}
          end
        )

      {:ok, pid2} = ContinuousRecorder.start_link(harness_owned.opts)

      assert_receive {:continuous_recorder, ^pid2,
                      {:run_stopped,
                       %{
                         reason: :recorder_already_owned,
                         startup_failed?: true,
                         startup_gap_recorded?: false
                       }}},
                     1_000

      refute_receive {:gap_recorded, _}, 100
      refute_receive :relay_closed, 100
    end

    test "does not close a newly opened relay when startup fails due to peer ownership" do
      harness_new_remote =
        start_harness(
          relay_open_fn: fn @camera_id, @profile_id, _actor ->
            {:ok, {:new, %{id: @relay_id, status: :active, media_ingest_id: @media_ingest_id}}}
          end,
          pipeline_resolver: fn @relay_id, @media_ingest_id -> {:error, :recording_ingest_mismatch} end,
          relay_host_fn: fn @relay_id -> :"peer@127.0.0.1" end
        )

      {:ok, pid1} = ContinuousRecorder.start_link(harness_new_remote.opts)

      assert_receive {:continuous_recorder, ^pid1,
                      {:run_stopped,
                       %{
                         reason: {:remote_relay_host, :"peer@127.0.0.1"},
                         startup_failed?: true,
                         startup_gap_recorded?: false
                       }}},
                     1_000

      refute_receive {:gap_recorded, _}, 100
      refute_receive :relay_closed, 100

      harness_new_owned =
        start_harness(
          relay_open_fn: fn @camera_id, @profile_id, _actor ->
            {:ok, {:new, %{id: @relay_id, status: :active, media_ingest_id: @media_ingest_id}}}
          end,
          acquire_claim_fn: fn _owner, _token, _ingest_id, _storage_id, _ttl, _opts ->
            {:error, :recorder_already_owned}
          end
        )

      {:ok, pid2} = ContinuousRecorder.start_link(harness_new_owned.opts)

      assert_receive {:continuous_recorder, ^pid2,
                      {:run_stopped,
                       %{
                         reason: :recorder_already_owned,
                         startup_failed?: true,
                         startup_gap_recorded?: false
                       }}},
                     1_000

      refute_receive {:gap_recorded, _}, 100
      refute_receive :relay_closed, 100
    end

    test "ContinuousManager applies exponential backoff and records at most one startup gap per failure streak" do
      parent = self()
      clock = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: :backoff_clock_agent))
      fail_target = start_supervised!(Supervisor.child_spec({Agent, fn -> true end}, id: :fail_target_agent))
      policy = base_policy()

      base_harness =
        start_harness(
          policy: policy,
          target_resolver: fn @member ->
            if Agent.get(fail_target, & &1) do
              {:error, :nvr_member_unconfigured}
            else
              {:ok,
               %{
                 member: @member,
                 storage_id: @storage_id,
                 client_config: %ClientConfig{
                   host: "nvr-0.example.test",
                   port: 8443,
                   ca: "/nonexistent/ca.pem",
                   cert: "/nonexistent/client.pem",
                   key: "/nonexistent/client.key",
                   token: "synthetic-continuous-recorder-token-0123456789"
                 }
               }}
            end
          end,
          record_gap_fn: fn attrs, _opts ->
            send(parent, {:streak_gap, attrs})
            {:ok, attrs}
          end
        )

      start_fn = fn pol, start_opts ->
        opts = Keyword.merge(base_harness.opts, Keyword.put(start_opts, :policy, pol))
        {:ok, pid} = ContinuousRecorder.start_link(opts)
        send(parent, {:attempt_started, pid, Keyword.get(start_opts, :record_startup_gap?)})
        {:ok, pid}
      end

      {:ok, manager} =
        ContinuousManager.start_link(
          name: nil,
          interval_ms: 60_000,
          initial_backoff_ms: 1_000,
          max_backoff_ms: 8_000,
          now_ms_fn: fn -> Agent.get(clock, & &1) end,
          enabled_fn: fn -> true end,
          control_stopped_fn: fn -> false end,
          list_policies_fn: fn -> {:ok, [policy]} end,
          start_recorder_fn: start_fn
        )

      # Attempt 1 at t=0 -> fails and records exactly ONE gap; backoff is 1_000 ms (next retry at t=1_000)
      assert :ok = ContinuousManager.reconcile(manager)
      assert_receive {:attempt_started, pid1, true}, 1_000
      assert_receive {:streak_gap, %{reason: :source_unavailable}}, 1_000
      ref1 = Process.monitor(pid1)
      assert_receive {:DOWN, ^ref1, :process, ^pid1, reason1}, 1_000
      assert reason1 in [:normal, :noproc]
      # Let manager process DOWN before next reconcile
      _ = ContinuousManager.running(manager)

      # At t=500 (< 1_000): backoff suppresses restart
      Agent.update(clock, fn _ -> 500 end)
      assert :ok = ContinuousManager.reconcile(manager)
      refute_receive {:attempt_started, _, _}, 50

      # Attempt 2 at t=1_000 -> starts with record_startup_gap?: false, writes NO second gap;
      # backoff doubles to 2_000 ms (next retry at t=3_000)
      Agent.update(clock, fn _ -> 1_000 end)
      assert :ok = ContinuousManager.reconcile(manager)
      assert_receive {:attempt_started, pid2, false}, 1_000
      ref2 = Process.monitor(pid2)
      assert_receive {:DOWN, ^ref2, :process, ^pid2, reason2}, 1_000
      assert reason2 in [:normal, :noproc]
      refute_receive {:streak_gap, _}, 50
      _ = ContinuousManager.running(manager)

      # At t=2_500 (< 3_000): exponential backoff suppresses restart
      Agent.update(clock, fn _ -> 2_500 end)
      assert :ok = ContinuousManager.reconcile(manager)
      refute_receive {:attempt_started, _, _}, 50

      # At t=3_000 with target fixed: Attempt 3 succeeds and stays running!
      Agent.update(fail_target, fn _ -> false end)
      Agent.update(clock, fn _ -> 3_000 end)
      assert :ok = ContinuousManager.reconcile(manager)
      assert_receive {:attempt_started, pid3, false}, 1_000
      Process.sleep(30)
      assert Process.alive?(pid3)
      assert Map.has_key?(ContinuousManager.running(manager), {@camera_id, @profile_id})

      ContinuousRecorder.stop(pid3, :policy_disabled)
    end
  end

  describe "catalog retry and claim release on catalog failure" do
    test "retries transient catalog failure within bounded window and continues when retry succeeds" do
      parent = self()
      attempts = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: :catalog_retry_ok_agent))

      descriptor_fn = fn _cfg, block_key, _timeout ->
        attempt = Agent.get_and_update(attempts, fn n -> {n + 1, n + 1} end)
        send(parent, {:descriptor_attempt, block_key, attempt})

        if attempt < 3 do
          {:error, {:descriptor_status, 503, "descriptor_unavailable"}}
        else
          {:ok, %{"block_key" => block_key, "fragments" => [%{"start_ns" => 0, "duration_ns" => 2_000_000_000}]}}
        end
      end

      harness =
        start_harness(
          bounds: %{soft_frames: 2, max_frames: 2},
          catalog_max_attempts: 3,
          catalog_retry_delay_ms: 5,
          block_descriptor_fn: descriptor_fn
        )

      {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
      assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

      send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
      send_unit(pid, harness.inbox_id, 1, 3_000, @base_utc_us + 33_333, @p_frame_payload)

      assert_receive {:descriptor_attempt, key0, 1}, 1_000
      assert_receive {:descriptor_attempt, ^key0, 2}, 1_000
      assert_receive {:descriptor_attempt, ^key0, 3}, 1_000

      assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: ^key0, catalog: {:registered, entry0}}}},
                     1_000

      assert_receive {:archive_enqueued, ^entry0}, 1_000
      assert Process.alive?(pid)

      ContinuousRecorder.stop(pid, :policy_disabled)
      assert_receive {:continuous_recorder, ^pid, {:run_stopped, %{reason: :policy_disabled}}}, 1_000
    end

    test "stops run and releases claim cleanly when catalog fails after bounded retries" do
      parent = self()
      attempts = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: :catalog_retry_fail_agent))

      freeze_fn = fn _owner, _claim, block, _descriptor, _catalog_attrs, _opts ->
        attempt = Agent.get_and_update(attempts, fn n -> {n + 1, n + 1} end)
        send(parent, {:freeze_attempt, block.block_key, attempt})
        {:error, :db_timeout}
      end

      harness =
        start_harness(
          bounds: %{soft_frames: 2, max_frames: 2},
          catalog_max_attempts: 3,
          catalog_retry_delay_ms: 5,
          freeze_and_catalog_fn: freeze_fn
        )

      capture_log(fn ->
        {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
        assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

        send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
        send_unit(pid, harness.inbox_id, 1, 3_000, @base_utc_us + 33_333, @p_frame_payload)

        assert_receive {:freeze_attempt, key0, 1}, 1_000
        assert_receive {:freeze_attempt, ^key0, 2}, 1_000
        assert_receive {:freeze_attempt, ^key0, 3}, 1_000

        assert_receive {:continuous_recorder, ^pid,
                        {:block_sealed, %{block_key: ^key0, catalog: {:unregistered, :db_timeout}}}},
                       1_000

        assert_receive {:continuous_recorder, ^pid, {:run_stopped, %{reason: {:catalog_failed, :db_timeout}}}}, 1_000
        assert_receive :claim_released, 1_000
        assert_receive :relay_closed, 1_000
      end)
    end

    test "stops run immediately without retrying and releases claim on :nvr_recovery_closed_after_freeze" do
      parent = self()

      freeze_fn = fn _owner, _claim, block, _descriptor, _catalog_attrs, _opts ->
        send(parent, {:freeze_called, block.block_key})
        {:error, :nvr_recovery_closed_after_freeze}
      end

      harness =
        start_harness(
          bounds: %{soft_frames: 2, max_frames: 2},
          catalog_max_attempts: 3,
          catalog_retry_delay_ms: 5,
          freeze_and_catalog_fn: freeze_fn
        )

      capture_log(fn ->
        {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
        assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

        send_unit(pid, harness.inbox_id, 0, 0, @base_utc_us, @idr_payload)
        send_unit(pid, harness.inbox_id, 1, 3_000, @base_utc_us + 33_333, @p_frame_payload)

        assert_receive {:freeze_called, key0}, 1_000
        refute_receive {:freeze_called, _}, 50

        expected_reason = :nvr_recovery_closed_after_freeze

        assert_receive {:continuous_recorder, ^pid,
                        {:block_sealed, %{block_key: ^key0, catalog: {:unregistered, ^expected_reason}}}},
                       1_000

        assert_receive {:continuous_recorder, ^pid, {:run_stopped, %{reason: ^expected_reason}}}, 1_000

        assert_receive :claim_released, 1_000
        assert_receive :relay_closed, 1_000
      end)
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
    seq_agent = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: make_ref()))
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
      relay_host_fn: fn @relay_id -> nil end,
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
    send_reordered_unit(worker, inbox_id, sequence, pts, pts, admitted_at_us, payload)
  end

  defp send_reordered_unit(worker, inbox_id, sequence, pts, dts, admitted_at_us, payload) do
    unit = %{
      sequence: sequence,
      pts: pts,
      dts: dts,
      payload: payload,
      admitted_at_us: admitted_at_us
    }

    send(worker, {:recording_media, inbox_id, unit})
  end

  defp real_inbox_producer_loop(_parent) do
    receive do
      {:offer, from, ref, inbox, chunk} ->
        send(from, {ref, Inbox.offer(inbox, chunk)})
        real_inbox_producer_loop(nil)

      :stop_producer ->
        :ok
    end
  end

  defp offer_via_producer(producer, inbox, sequence, pts, payload) do
    ref = make_ref()

    chunk = %{
      media_ingest_id: @media_ingest_id,
      codec: "h264",
      payload_format: "annexb",
      payload: payload,
      pts: pts,
      dts: pts,
      sequence: sequence
    }

    send(producer, {:offer, self(), ref, inbox, chunk})

    receive do
      {^ref, result} -> result
    after
      1_000 -> {:error, :producer_timeout}
    end
  end
end
