defmodule ServiceRadarCoreElx.CameraRecording.ContinuousRecorderLiveWireTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingGap
  alias ServiceRadarCoreElx.CameraRecording.ContinuousManager
  alias ServiceRadarCoreElx.CameraRecording.ContinuousRecorder
  alias ServiceRadarCoreElx.CameraRecording.Supervisor, as: RecordingSupervisor
  alias ServiceRadarCoreElx.CameraRelay.Pipeline
  alias ServiceRadarRecordingMetadata.CanonicalJSON
  alias ServiceRadarRecordingMetadata.Descriptor

  @moduletag :tmp_dir

  @camera_id "00000000-0000-4000-8000-000000000301"
  @profile_id "00000000-0000-4000-8000-000000000302"
  @policy_id "00000000-0000-4000-8000-000000000303"
  @relay_id "00000000-0000-4000-8000-000000000304"
  @ingest_owner_id "00000000-0000-4000-8000-000000000305"
  @claim_id "00000000-0000-4000-8000-000000000306"
  @storage_id "00000000-0000-4000-8000-000000000307"
  @recovery_generation "00000000-0000-4000-8000-000000000308"
  @media_ingest_id "synthetic-live-wire-ingest-1"
  @member "serviceradar-nvr-0"
  @token "synthetic-live-wire-nvr-token-0123456789abcdef"

  # Synthetic H.264 AnnexB access units (no :keyframe hint; Inbox strips extra fields).
  @idr_payload <<0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1E, 0, 0, 0, 1, 0x68, 0xCE, 0x3C, 0x80, 0, 0, 0, 1, 0x65, 0x88, 0x84>>
  @p_frame_payload <<0, 0, 0, 1, 0x41, 0x9A, 0x24, 0x6C, 0x11, 0x22, 0x33, 0x44>>
  @padded_idr_payload @idr_payload <> :binary.copy(<<0xAA>>, 41)
  @padded_p_payload @p_frame_payload <> :binary.copy(<<0xBB>>, 52)

  setup ctx do
    {:ok, _} = Application.ensure_all_started(:ssl)
    prev_enabled = Application.get_env(:serviceradar_core_elx, :camera_recording_enabled)
    prev_cfg = Application.get_env(:serviceradar_core_elx, :camera_nvr_client_config_file)
    prev_tok = Application.get_env(:serviceradar_core_elx, :camera_nvr_client_token_file)
    prev_gate = Application.get_env(:serviceradar_core, :nvr_recovery_gate)

    on_exit(fn ->
      restore_env(:serviceradar_core_elx, :camera_recording_enabled, prev_enabled)
      restore_env(:serviceradar_core_elx, :camera_nvr_client_config_file, prev_cfg)
      restore_env(:serviceradar_core_elx, :camera_nvr_client_token_file, prev_tok)
      restore_env(:serviceradar_core, :nvr_recovery_gate, prev_gate)
    end)

    dir = Path.expand(ctx.tmp_dir)
    gate_path = Path.join(dir, "recovery-state.json")
    write_gate(gate_path, "ready")

    nvr = start_nvr_wire_server(dir)
    Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, true)
    Application.put_env(:serviceradar_core_elx, :camera_nvr_client_config_file, nvr.config_file)
    Application.put_env(:serviceradar_core_elx, :camera_nvr_client_token_file, nvr.token_file)
    Application.put_env(:serviceradar_core, :nvr_recovery_gate, %{generation: @recovery_generation, path: gate_path})

    relay_id = @relay_id

    {:ok, _sup, pipeline} =
      Membrane.Pipeline.start(Pipeline, relay_session_id: relay_id, media_ingest_id: @media_ingest_id)

    on_exit(fn -> if Process.alive?(pipeline), do: Membrane.Pipeline.terminate(pipeline, force?: true) end)

    %{dir: dir, gate_path: gate_path, nvr: nvr, pipeline: pipeline}
  end

  test "supervised manager and recorder stream multi-block footage with zero viewers over mTLS", ctx do
    parent = self()
    policies_agent = start_supervised!(Supervisor.child_spec({Agent, fn -> [base_policy()] end}, id: make_ref()))
    recorder_opts = live_recorder_opts(ctx, bounds: %{soft_frames: 3, max_frames: 6})

    start_fn = fn policy, start_opts ->
      opts =
        recorder_opts
        |> Keyword.merge(start_opts)
        |> Keyword.put(:policy, policy)
        |> Keyword.delete(:name)

      case RecordingSupervisor.start_continuous_recorder(opts) do
        {:ok, pid} ->
          send(parent, {:supervised_started, pid})
          {:ok, pid}

        other ->
          other
      end
    end

    {:ok, manager} =
      ContinuousManager.start_link(
        name: nil,
        interval_ms: 60_000,
        enabled_fn: &RecordingSupervisor.enabled?/0,
        control_stopped_fn: fn -> false end,
        list_policies_fn: fn -> {:ok, Agent.get(policies_agent, & &1)} end,
        start_recorder_fn: start_fn
      )

    assert :ok = ContinuousManager.reconcile(manager)
    assert_receive {:supervised_started, worker_pid}, 2_000

    assert [{^worker_pid, nil}] =
             Registry.lookup(
               ServiceRadarCoreElx.CameraRecording.Registry,
               ContinuousRecorder.registry_key(@camera_id, @profile_id)
             )

    wait_until(fn ->
      match?(%{{@camera_id, @profile_id} => %{pid: ^worker_pid, started?: true}}, ContinuousManager.running(manager))
    end)

    status = ContinuousRecorder.status(worker_pid)
    assert status.storage_id == @storage_id
    assert status.run_id == "#{@relay_id}:1"

    # Zero viewers on Pipeline: media still flows through real Inbox into ContinuousRecorder -> real mTLS NVR client.
    push_pipeline_chunks(ctx.pipeline, [
      {0, 0, @idr_payload},
      {1, 3_000, @p_frame_payload},
      {2, 6_000, @p_frame_payload},
      {3, 9_000, @p_frame_payload},
      {4, 12_000, @idr_payload}
    ])

    assert_receive {:nvr_ingested, key0, wire_header0, units0}, 2_000
    assert wire_header0["storage_id"] == @storage_id
    assert wire_header0["recovery_generation"] == @recovery_generation
    assert wire_header0["identity"]["block_sequence"] == 0
    assert Enum.map(units0, & &1.sequence) == [0, 1, 2, 3]

    assert_receive {:nvr_descriptor_served, ^key0}, 2_000
    assert_receive {:cataloged, ^key0, desc0, attrs0}, 2_000
    assert {:ok, _canonical} = Descriptor.encode(desc0)

    assert {attrs0.contiguous_with_previous, attrs0.reanchored, attrs0.policy_storage} ==
             {false, false, :local_and_archive}

    assert_receive {:archive_enqueued, _entry0}, 2_000

    # In-place policy storage change via ContinuousManager without interrupting the run.
    updated_policy = base_policy(%{policy_revision: 2, storage: :local_only})
    Agent.update(policies_agent, fn _ -> [updated_policy] end)
    assert :ok = ContinuousManager.reconcile(manager)

    wait_until(fn -> ContinuousRecorder.status(worker_pid).policy_storage == :local_only end)

    push_pipeline_chunks(ctx.pipeline, [
      {5, 15_000, @p_frame_payload},
      {6, 18_000, @p_frame_payload},
      {7, 21_000, @idr_payload}
    ])

    assert_receive {:nvr_ingested, key1, wire_header1, units1}, 2_000
    assert wire_header1["identity"]["block_sequence"] == 1
    assert Enum.map(units1, & &1.sequence) == [4, 5, 6]
    assert_receive {:nvr_descriptor_served, ^key1}, 2_000
    assert_receive {:cataloged, ^key1, _desc1, attrs1}, 2_000
    assert {attrs1.contiguous_with_previous, attrs1.reanchored, attrs1.policy_storage} == {true, false, :local_only}
    refute_receive {:archive_enqueued, _}, 100

    # Policy removal via ContinuousManager gracefully seals Block 2, releases claim, and closes the newly opened relay.
    worker_ref = Process.monitor(worker_pid)
    Agent.update(policies_agent, fn _ -> [] end)
    assert :ok = ContinuousManager.reconcile(manager)

    assert_receive {:nvr_ingested, key2, _wire_header2, units2}, 2_000
    assert Enum.map(units2, & &1.sequence) == [7]
    assert_receive {:cataloged, ^key2, _desc2, attrs2}, 2_000
    assert attrs2.contiguous_with_previous == true
    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :normal}, 2_000
    assert_receive :claim_released, 2_000
    assert_receive :relay_closed, 2_000
    refute_receive {:gap_recorded, _}, 100
  end

  test "reconciles drop-after-seal, multi-block receipt, and absent block via mTLS lookup", ctx do
    # Block 0: socket dropped after seal -> lookup returns :sealed -> descriptor fetched -> cataloged
    # Block 1: NVR returns 2 block_ids [reserved, rotated] -> refused as direct seal -> lookup checks ONLY [reserved]
    # Block 2: socket dropped without sealing -> lookup returns :absent -> :block_absent gap recorded -> continues
    # Block 3: normal seal
    set_nvr_modes(ctx.nvr, %{
      0 => :drop_after_seal,
      1 => :multi_block_receipt,
      2 => :drop_absent,
      3 => :seal
    })

    opts = live_recorder_opts(ctx, bounds: %{soft_frames: 2, max_frames: 2})
    {:ok, pid} = ContinuousRecorder.start_link(opts)
    assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 2_000

    # Block 0 (seq 0..1)
    push_pipeline_chunks(ctx.pipeline, [{0, 0, @idr_payload}, {1, 3_000, @p_frame_payload}])
    assert_receive {:nvr_ingested, key0, _, _}, 2_000
    assert_receive {:nvr_lookup_served, [^key0]}, 2_000
    assert_receive {:nvr_descriptor_served, ^key0}, 2_000

    assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: ^key0, catalog: {:registered, entry0}}}},
                   2_000
    assert_receive {:archive_enqueued, ^entry0}, 2_000

    # Block 1 (seq 2..3): multi-block receipt must trigger lookup ONLY for key1, never cataloging the rotated block
    push_pipeline_chunks(ctx.pipeline, [{2, 6_000, @idr_payload}, {3, 9_000, @p_frame_payload}])
    assert_receive {:nvr_ingested, key1, _, _}, 2_000
    assert_receive {:nvr_multi_block_returned, ^key1, rotated_key}, 2_000
    assert_receive {:nvr_lookup_served, [^key1]}, 2_000
    assert_receive {:nvr_descriptor_served, ^key1}, 2_000
    assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{block_key: ^key1, catalog: {:registered, _}}}}, 2_000
    refute_receive {:cataloged, ^rotated_key, _, _}, 100

    # Block 2 (seq 4..5): dropped without sealing -> lookup returns :absent -> valid RecordingGap recorded
    push_pipeline_chunks(ctx.pipeline, [{4, 12_000, @idr_payload}, {5, 15_000, @p_frame_payload}])
    assert_receive {:nvr_ingested, key2, _, _}, 2_000
    assert_receive {:nvr_lookup_served, [^key2]}, 2_000
    assert_receive {:gap_recorded, gap}, 2_000
    assert gap.reason == :block_absent
    assert gap.detail_class == "uncertain_resolved_absent"
    assert valid_recording_gap?(gap)
    assert_receive {:continuous_recorder, ^pid, {:uncertain_resolved, %{block_key: ^key2, resolution: :absent}}}, 2_000

    # Block 3 (seq 6..7): continues seamlessly on next IDR
    push_pipeline_chunks(ctx.pipeline, [{6, 18_000, @idr_payload}, {7, 21_000, @p_frame_payload}])
    assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{catalog: {:registered, _}}}}, 2_000

    ContinuousRecorder.stop(pid, :policy_disabled)
    assert_receive {:continuous_recorder, ^pid, {:run_stopped, %{reason: :policy_disabled}}}, 2_000
    assert_receive :claim_released, 2_000
  end

  test "handles mTLS HTTP 503 refusal before EOF and stops when RecoveryGate closes", ctx do
    set_nvr_modes(ctx.nvr, %{
      0 => {:refuse_before_eof, 503},
      1 => :seal,
      2 => {:refuse_before_eof, 503}
    })

    opts = live_recorder_opts(ctx, bounds: %{soft_frames: 2, max_frames: 2})
    {:ok, pid} = ContinuousRecorder.start_link(opts)
    assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 2_000

    # Block 0: send seq 0 to open stream, wait until NVR writes 503 BEFORE EOF, then send seq 1
    push_pipeline_chunks(ctx.pipeline, [{0, 0, @idr_payload}])
    assert_receive {:nvr_refused_sent, 0, 503}, 2_000
    push_pipeline_chunks(ctx.pipeline, [{1, 3_000, @p_frame_payload}])
    assert_receive {:continuous_recorder, ^pid, {:nvr_refused, %{status: 503, detail_class: "http_503"}}}, 2_000
    assert_receive {:gap_recorded, gap0}, 2_000
    assert {gap0.reason, gap0.detail_class} == {:nvr_refused, "http_503"}
    assert valid_recording_gap?(gap0)

    # Block 1 succeeds
    push_pipeline_chunks(ctx.pipeline, [{2, 6_000, @idr_payload}, {3, 9_000, @p_frame_payload}])
    assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{catalog: {:registered, _}}}}, 2_000

    # Close real recovery-state.json on disk, then trigger 503 refusal BEFORE EOF on Block 2 -> stops run immediately
    push_pipeline_chunks(ctx.pipeline, [{4, 12_000, @idr_payload}])
    assert_receive {:nvr_refused_sent, 2, 503}, 2_000
    write_gate(ctx.gate_path, "closed")
    push_pipeline_chunks(ctx.pipeline, [{5, 15_000, @p_frame_payload}])

    assert_receive {:continuous_recorder, ^pid, {:nvr_refused, %{status: 503, detail_class: "nvr_recovery_closed"}}},
                   2_000

    assert_receive {:gap_recorded, gap2}, 2_000
    assert {gap2.reason, gap2.detail_class} == {:nvr_refused, "nvr_recovery_closed"}
    assert valid_recording_gap?(gap2)
    assert_receive {:continuous_recorder, ^pid, {:run_stopped, %{reason: :nvr_recovery_closed}}}, 2_000
    assert_receive :claim_released, 2_000
    assert_receive :relay_closed, 2_000
  end

  test "enforces soft/hard duration and byte bounds with keyframe_wait accounting over mTLS", ctx do
    # Part A: duration bounds (soft 200 ms = 18_000 ticks, hard 400 ms = 36_000 ticks)
    opts_dur = live_recorder_opts(ctx, bounds: %{soft_duration_ms: 200, max_duration_ms: 400})
    {:ok, pid_dur} = ContinuousRecorder.start_link(opts_dur)
    assert_receive {:continuous_recorder, ^pid_dur, {:run_started, _}}, 2_000

    # Block 0: pts 0 (IDR), 9_000 (P), 18_000 (P -> soft_duration reached), 27_000 (IDR -> contiguous soft cut!)
    push_pipeline_chunks(ctx.pipeline, [
      {0, 0, @idr_payload},
      {1, 9_000, @p_frame_payload},
      {2, 18_000, @p_frame_payload},
      {3, 27_000, @idr_payload}
    ])

    assert_receive {:nvr_ingested, key0, _, units0}, 2_000
    assert Enum.map(units0, & &1.sequence) == [0, 1, 2]
    assert_receive {:continuous_recorder, ^pid_dur, {:block_sealed, %{block_key: ^key0}}}, 2_000

    # Block 1 starts at seq 3 (pts 27_000); hit hard duration 400 ms (+36_000 -> pts 63_000) with non-IDR
    # Seq 6 (P at pts 72_000) dropped as :keyframe_wait; Seq 7 (IDR at pts 81_000) starts Block 2
    push_pipeline_chunks(ctx.pipeline, [
      {4, 45_000, @p_frame_payload},
      {5, 63_000, @p_frame_payload},
      {6, 72_000, @p_frame_payload},
      {7, 81_000, @idr_payload}
    ])

    assert_receive {:nvr_ingested, key1, _, units1}, 2_000
    assert Enum.map(units1, & &1.sequence) == [3, 4, 5]
    assert_receive {:cataloged, ^key1, _, attrs1}, 2_000
    assert attrs1.contiguous_with_previous == true
    assert_receive {:continuous_recorder, ^pid_dur, {:block_sealed, %{block_key: ^key1}}}, 2_000

    assert_receive {:gap_recorded, dur_gap}, 2_000
    assert dur_gap.reason == :keyframe_wait
    assert dur_gap.media_gap_ns == div(9_000 * 1_000_000_000, 90_000)
    assert valid_recording_gap?(dur_gap)

    ContinuousRecorder.stop(pid_dur, :policy_disabled)
    assert_receive {:nvr_ingested, key2, _, units2}, 2_000
    assert Enum.map(units2, & &1.sequence) == [7]
    assert_receive {:cataloged, ^key2, _, attrs2}, 2_000
    assert attrs2.contiguous_with_previous == false
    assert_receive {:continuous_recorder, ^pid_dur, {:block_sealed, %{block_key: ^key2}}}, 2_000
    assert_receive {:continuous_recorder, ^pid_dur, {:run_stopped, %{reason: :policy_disabled}}}, 2_000

    # Part B: byte bounds (64 B frames; soft_bytes: 128, max_bytes: 192 -> max 3 frames per block)
    {:ok, _sup2, pipeline2} =
      Membrane.Pipeline.start(Pipeline, relay_session_id: @relay_id, media_ingest_id: @media_ingest_id)

    on_exit(fn -> if Process.alive?(pipeline2), do: Membrane.Pipeline.terminate(pipeline2, force?: true) end)

    opts_bytes = live_recorder_opts(%{ctx | pipeline: pipeline2}, bounds: %{soft_bytes: 128, max_bytes: 192})
    {:ok, pid_bytes} = ContinuousRecorder.start_link(opts_bytes)
    assert_receive {:continuous_recorder, ^pid_bytes, {:run_started, _}}, 2_000

    # Block 0: 3x 64B = 192B (at max_bytes), 4th frame is non-IDR (would be 256B > 192B) -> hard byte cut + drop non-IDR
    # 5th frame is IDR -> starts Block 1 with :keyframe_wait / "hard_byte_bound_non_idr" gap
    push_pipeline_chunks(pipeline2, [
      {0, 0, @padded_idr_payload},
      {1, 3_000, @padded_p_payload},
      {2, 6_000, @padded_p_payload},
      {3, 9_000, @padded_p_payload},
      {4, 12_000, @padded_idr_payload}
    ])

    assert_receive {:nvr_ingested, bkey0, _, bunits0}, 2_000
    assert Enum.map(bunits0, & &1.sequence) == [0, 1, 2]
    assert Enum.reduce(bunits0, 0, &(byte_size(&1.payload) + &2)) <= 192
    assert_receive {:continuous_recorder, ^pid_bytes, {:block_sealed, %{block_key: ^bkey0}}}, 2_000

    assert_receive {:gap_recorded, byte_gap}, 2_000
    assert {byte_gap.reason, byte_gap.detail_class} == {:keyframe_wait, "hard_byte_bound_non_idr"}
    assert byte_gap.media_gap_ns == div(3_000 * 1_000_000_000, 90_000)
    assert valid_recording_gap?(byte_gap)

    # Block 1: 3x 64B = 192B, 4th frame is IDR -> hard byte cut keeps IDR contiguously (NO gap!)
    push_pipeline_chunks(pipeline2, [
      {5, 15_000, @padded_p_payload},
      {6, 18_000, @padded_p_payload},
      {7, 21_000, @padded_idr_payload}
    ])

    assert_receive {:nvr_ingested, bkey1, _, bunits1}, 2_000
    assert Enum.map(bunits1, & &1.sequence) == [4, 5, 6]
    assert Enum.reduce(bunits1, 0, &(byte_size(&1.payload) + &2)) <= 192
    assert_receive {:continuous_recorder, ^pid_bytes, {:block_sealed, %{block_key: ^bkey1}}}, 2_000

    ContinuousRecorder.stop(pid_bytes, :policy_disabled)
    assert_receive {:nvr_ingested, bkey2, _, bunits2}, 2_000
    assert Enum.map(bunits2, & &1.sequence) == [7]
    assert_receive {:cataloged, ^bkey2, _, battrs2}, 2_000
    assert battrs2.contiguous_with_previous == true
    assert_receive {:continuous_recorder, ^pid_bytes, {:run_stopped, %{reason: :policy_disabled}}}, 2_000
    refute_receive {:gap_recorded, _}, 100
  end

  # ---------------------------------------------------------------------------
  # Live recorder option builder (only DB/Ash persistence hooks are in-memory)
  # ---------------------------------------------------------------------------

  defp live_recorder_opts(ctx, overrides) do
    parent = self()
    seq_agent = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: make_ref()))
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

      block_key = block |> RecordingBlock.identity() |> Descriptor.block_key()
      {:ok, %{block | block_key: block_key}}
    end

    base_opts = [
      name: nil,
      policy: base_policy(),
      notify: parent,
      relay_open_fn: fn @camera_id, @profile_id, _actor ->
        {:ok, {:new, %{id: @relay_id, status: :active, media_ingest_id: @media_ingest_id}}}
      end,
      relay_close_fn: fn @relay_id, _reason, _actor ->
        send(parent, :relay_closed)
        :ok
      end,
      relay_host_fn: fn @relay_id -> nil end,
      pipeline_resolver: fn @relay_id, @media_ingest_id -> {:ok, ctx.pipeline} end,
      ingest_owner_fn: fn @relay_id, _actor -> {:ok, owner} end,
      acquire_claim_fn: fn _owner, _token, _ingest_id, _storage_id, _ttl, _opts -> {:ok, claim} end,
      renew_claim_fn: fn _owner, _claim, _ttl, _opts -> {:ok, claim} end,
      release_claim_fn: fn _owner, _claim, _opts ->
        send(parent, :claim_released)
        {:ok, :released}
      end,
      reserve_block_fn: reserve_fn,
      freeze_and_catalog_fn: fn _owner, _claim, block, descriptor, catalog_attrs, _opts ->
        send(parent, {:cataloged, block.block_key, descriptor, catalog_attrs})
        entry_id = Ecto.UUID.generate()
        archive_state = if catalog_attrs.policy_storage == :local_only, do: :not_required, else: :pending
        {:ok, %{id: entry_id, archive_state: archive_state, block_key: block.block_key}}
      end,
      enqueue_archive_fn: fn
        %{id: entry_id, archive_state: :pending} ->
          send(parent, {:archive_enqueued, entry_id})
          {:ok, :enqueued}

        _entry ->
          :skipped
      end,
      record_gap_fn: fn attrs, _opts ->
        send(parent, {:gap_recorded, attrs})
        {:ok, attrs}
      end
    ]

    Keyword.merge(base_opts, overrides)
  end

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

  defp push_pipeline_chunks(pipeline, specs) do
    Enum.each(specs, fn {seq, pts, payload} ->
      send(
        pipeline,
        {:media_chunk,
         %{
           media_ingest_id: @media_ingest_id,
           codec: "h264",
           payload_format: "annexb",
           track_id: "video",
           payload: payload,
           pts: pts,
           dts: pts,
           sequence: seq
         }}
      )
    end)
  end

  defp valid_recording_gap?(attrs) do
    changeset = Ash.Changeset.for_create(RecordingGap, :record, attrs)
    changeset.valid?
  end

  defp wait_until(fun, attempts \\ 100)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("timed out waiting for condition")

  # ---------------------------------------------------------------------------
  # Real mTLS HTTP/1.1 chunked NVR wire-protocol loopback server
  # ---------------------------------------------------------------------------

  defp start_nvr_wire_server(dir) do
    parent = self()
    algorithm = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}

    certs =
      :public_key.pkix_test_data(%{
        server_chain: %{root: algorithm, intermediates: [], peer: algorithm ++ [extensions: [san]]},
        client_chain: %{root: algorithm, intermediates: [], peer: algorithm}
      })

    store = start_supervised!(Supervisor.child_spec({Agent, fn -> %{blocks: %{}, modes: %{}} end}, id: make_ref()))
    tasks = start_supervised!(Supervisor.child_spec(Task.Supervisor, id: make_ref(), restart: :temporary))

    tls_opts =
      certs.server_config ++
        [
          verify: :verify_peer,
          fail_if_no_peer_cert: true,
          binary: true,
          active: false,
          reuseaddr: true,
          ip: {127, 0, 0, 1}
        ]

    {:ok, listener} = :ssl.listen(0, tls_opts)
    {:ok, {_, port}} = :ssl.sockname(listener)
    {:ok, _} = Task.Supervisor.start_child(tasks, fn -> accept_loop(listener, tasks, store, parent) end)
    on_exit(fn -> :ssl.close(listener) end)

    client = certs.client_config
    {key_type, key_der} = client[:key]
    roots = Enum.map(client[:cacerts], &{:Certificate, &1, :not_encrypted})
    ca = write_file(dir, "ca.pem", :public_key.pem_encode(roots))
    cert = write_file(dir, "client.pem", :public_key.pem_encode([{:Certificate, client[:cert], :not_encrypted}]))
    key = write_file(dir, "client-key.pem", :public_key.pem_encode([{key_type, key_der, :not_encrypted}]))
    token_file = write_file(dir, "nvr-token", @token)

    config_file =
      write_file(
        dir,
        "nvr-client.json",
        Jason.encode!(%{
          "version" => 1,
          "port" => port,
          "ca_file" => ca,
          "cert_file" => cert,
          "key_file" => key,
          "members" => %{@member => %{"host" => "localhost", "storage_id" => @storage_id}}
        })
      )

    %{port: port, store: store, config_file: config_file, token_file: token_file}
  end

  defp set_nvr_modes(nvr, modes) do
    Agent.update(nvr.store, &%{&1 | modes: modes})
  end

  defp accept_loop(listener, tasks, store, parent) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        {:ok, child} =
          Task.Supervisor.start_child(tasks, fn ->
            receive do
              {:socket, sock} ->
                capture_log(fn -> serve_connection(sock, store, parent) end)
            end
          end)

        :ok = :ssl.controlling_process(socket, child)
        send(child, {:socket, socket})
        accept_loop(listener, tasks, store, parent)

      _ ->
        :ok
    end
  end

  defp serve_connection(socket, store, parent) do
    with {:ok, socket} <- :ssl.handshake(socket, 2_000),
         {:ok, req_head, leftover} <- read_http_headers(socket, "") do
      dispatch_request(socket, req_head, leftover, store, parent)
    end

    :ssl.close(socket)
  end

  defp dispatch_request(socket, %{headers: %{"authorization" => "Bearer " <> @token}} = req, leftover, store, parent) do
    case {req.method, req.target} do
      {"POST", "/v1/recordings/ingest"} ->
        handle_ingest(socket, req, leftover, store, parent)

      {"POST", "/v1/blocks/lookup"} ->
        with {:ok, body} <- read_http_body(socket, req.headers, leftover) do
          handle_lookup(socket, body, store, parent)
        end

      {"GET", "/v1/blocks/" <> rest} ->
        case String.split(rest, "/") do
          [block_id, "descriptor"] -> handle_descriptor(socket, block_id, store, parent)
          _ -> send_json(socket, 404, %{"error" => "not_found"})
        end

      _ ->
        send_json(socket, 404, %{"error" => "not_found"})
    end
  end

  defp dispatch_request(socket, _req, _leftover, _store, _parent) do
    send_json(socket, 401, %{"error" => "unauthorized"})
  end

  defp handle_ingest(socket, req, leftover, store, parent) do
    # Peek wire header from the first chunk so we know block_sequence before deciding on early refusal.
    with {:ok, first_bytes, state_after_head} <- read_at_least_header(socket, req.headers, leftover),
         {:ok, wire_header, body_rest} <- parse_wire_header(first_bytes) do
      block_seq = wire_header["identity"]["block_sequence"]
      mode = Agent.get(store, fn s -> Map.get(s.modes, block_seq, :seal) end)
      run_ingest_mode(socket, mode, wire_header, body_rest, state_after_head, store, parent)
    else
      _ -> send_json(socket, 400, %{"error" => "invalid_ingest_stream"})
    end
  end

  defp run_ingest_mode(socket, {:refuse_before_eof, status}, wire_header, _body_rest, _stream_state, _store, parent) do
    block_seq = wire_header["identity"]["block_sequence"]
    send_json(socket, status, %{"error" => "nvr_storage_pressure"})
    send(parent, {:nvr_refused_sent, block_seq, status})
    Process.sleep(100)
  end

  defp run_ingest_mode(socket, mode, wire_header, body_rest, stream_state, store, parent) do
    with {:ok, tail_bytes} <- finish_chunked_body(socket, stream_state),
         {:ok, units} <- parse_wire_units(body_rest <> tail_bytes, []) do
      block_key = Descriptor.block_key(wire_header["identity"])
      send(parent, {:nvr_ingested, block_key, wire_header, units})

      case mode do
        :drop_absent ->
          :ok

        :drop_after_seal ->
          store_sealed_block(store, block_key, wire_header, units)
          :ok

        :multi_block_receipt ->
          store_sealed_block(store, block_key, wire_header, units)
          next_identity = Map.update!(wire_header["identity"], "block_sequence", &(&1 + 1))
          rotated_key = Descriptor.block_key(next_identity)
          send(parent, {:nvr_multi_block_returned, block_key, rotated_key})

          send_json(socket, 200, %{
            "version" => 1,
            "status" => "sealed_local",
            "storage_id" => @storage_id,
            "block_ids" => [block_key, rotated_key]
          })

        :seal ->
          store_sealed_block(store, block_key, wire_header, units)

          send_json(socket, 200, %{
            "version" => 1,
            "status" => "sealed_local",
            "storage_id" => @storage_id,
            "block_ids" => [block_key]
          })
      end
    else
      _ -> send_json(socket, 422, %{"error" => "incomplete_media"})
    end
  end

  defp store_sealed_block(store, block_key, wire_header, units) do
    {descriptor_bytes, descriptor_sha256, media_bytes} = build_canonical_descriptor(wire_header, units)

    Agent.update(store, fn s ->
      put_in(s.blocks[block_key], %{
        descriptor_bytes: descriptor_bytes,
        descriptor_sha256: descriptor_sha256,
        bytes: media_bytes
      })
    end)
  end

  defp build_canonical_descriptor(wire_header, units) do
    clock = %{
      "clock_epoch" => wire_header["clock_epoch"],
      "timebase" => 90_000,
      "dts_source" => "pts_no_reordering",
      "utc_mapping" => "unknown"
    }

    identity = Map.put(wire_header["identity"], "clock", clock)
    media_bin = IO.iodata_to_binary(Enum.map(units, & &1.payload))
    media_len = byte_size(media_bin)
    media_sha = :sha256 |> :crypto.hash(media_bin) |> Base.encode16(case: :lower)
    init_sha = :sha256 |> :crypto.hash("synthetic-init-mp4") |> Base.encode16(case: :lower)
    first_pts = hd(units).pts
    last_pts = List.last(units).pts
    start_ns = div(first_pts * 1_000_000_000, 90_000)
    duration_ns = max(33_333_333, div((last_pts - first_pts + 3_000) * 1_000_000_000, 90_000))

    descriptor = %{
      "version" => 1,
      "identity" => identity,
      "format" => %{"codec" => "avc1.42001e", "timescale" => 90_000},
      "init" => %{"length" => 18, "sha256" => init_sha},
      "media" => %{"length" => media_len, "sha256" => media_sha},
      "fragments" => [
        %{
          "sequence" => 0,
          "offset" => 0,
          "length" => media_len,
          "start_ns" => start_ns,
          "duration_ns" => duration_ns,
          "sha256" => media_sha,
          "tail_duration_source" => "previous_sample",
          "motion" => "unknown"
        }
      ]
    }

    {:ok, bytes} = Descriptor.encode(descriptor)
    sha = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
    {bytes, sha, media_len}
  end

  defp handle_descriptor(socket, block_id, store, parent) do
    case Agent.get(store, &Map.get(&1.blocks, block_id)) do
      %{descriptor_bytes: bytes} ->
        send(parent, {:nvr_descriptor_served, block_id})
        send_raw(socket, 200, "application/json", bytes)

      nil ->
        send_json(socket, 404, %{"error" => "block_not_found"})
    end
  end

  defp handle_lookup(socket, body, store, parent) do
    with {:ok, %{"block_ids" => block_ids}} <- Jason.decode(body) do
      send(parent, {:nvr_lookup_served, block_ids})
      blocks_map = Agent.get(store, & &1.blocks)

      entries =
        Enum.map(block_ids, fn id ->
          case Map.get(blocks_map, id) do
            %{descriptor_sha256: sha, bytes: bytes} ->
              %{
                "block_id" => id,
                "state" => "sealed",
                "writing" => false,
                "bytes" => bytes,
                "descriptor_sha256" => sha
              }

            nil ->
              %{"block_id" => id, "state" => "absent", "writing" => false, "bytes" => nil}
          end
        end)

      {:ok, payload} =
        CanonicalJSON.encode(%{
          "version" => 1,
          "storage_id" => @storage_id,
          "blocks" => entries
        })

      send_raw(socket, 200, "application/json", payload)
    else
      _ -> send_json(socket, 400, %{"error" => "invalid_lookup_request"})
    end
  end

  # ---------------------------------------------------------------------------
  # Minimal HTTP/1.1 + chunked reader and v1 binary wire parser
  # ---------------------------------------------------------------------------

  defp read_http_headers(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        [request_line | header_lines] = String.split(head, "\r\n")
        [method, target, _version] = String.split(request_line, " ")

        headers =
          Map.new(header_lines, fn line ->
            [k, v] = String.split(line, ":", parts: 2)
            {String.downcase(k), String.trim(v)}
          end)

        {:ok, %{method: method, target: target, headers: headers}, rest}

      [_] when byte_size(acc) < 16_384 ->
        with {:ok, more} <- :ssl.recv(socket, 0, 2_000), do: read_http_headers(socket, acc <> more)

      _ ->
        {:error, :invalid_headers}
    end
  end

  defp read_http_body(socket, headers, leftover) do
    len = String.to_integer(Map.get(headers, "content-length", "0"))
    read_exact(socket, leftover, len)
  end

  defp read_exact(_socket, buf, len) when byte_size(buf) >= len, do: {:ok, binary_part(buf, 0, len)}

  defp read_exact(socket, buf, len) do
    with {:ok, more} <- :ssl.recv(socket, 0, 2_000), do: read_exact(socket, buf <> more, len)
  end

  defp read_at_least_header(socket, headers, leftover) do
    if String.contains?(Map.get(headers, "transfer-encoding", ""), "chunked") do
      read_chunked_until_header(socket, leftover, <<>>)
    else
      with {:ok, body} <- read_http_body(socket, headers, leftover) do
        {:ok, body, :done}
      end
    end
  end

  defp read_chunked_until_header(socket, raw_buf, decoded_acc) do
    case decoded_acc do
      <<header_len::32, rest::binary>> when byte_size(rest) >= header_len ->
        {:ok, decoded_acc, {:chunked, raw_buf}}

      _ ->
        case pull_one_chunk(socket, raw_buf) do
          {:chunk, data, next_raw} -> read_chunked_until_header(socket, next_raw, decoded_acc <> data)
          :eof -> {:ok, decoded_acc, :done}
          error -> error
        end
    end
  end

  defp finish_chunked_body(_socket, :done), do: {:ok, <<>>}

  defp finish_chunked_body(socket, {:chunked, raw_buf}) do
    collect_chunks(socket, raw_buf, [])
  end

  defp collect_chunks(socket, raw_buf, acc) do
    case pull_one_chunk(socket, raw_buf) do
      {:chunk, data, next_raw} -> collect_chunks(socket, next_raw, [data | acc])
      :eof -> {:ok, IO.iodata_to_binary(Enum.reverse(acc))}
      error -> error
    end
  end

  defp pull_one_chunk(socket, raw_buf) do
    case :binary.split(raw_buf, "\r\n") do
      [size_hex, rest] ->
        chunk_size = size_hex |> String.trim() |> String.to_integer(16)

        if chunk_size == 0 do
          with {:ok, _tail} <- ensure_bytes(socket, rest, 2), do: :eof
        else
          with {:ok, buf} <- ensure_bytes(socket, rest, chunk_size + 2) do
            <<data::binary-size(chunk_size), "\r\n", next_raw::binary>> = buf
            {:chunk, data, next_raw}
          end
        end

      [_] ->
        with {:ok, more} <- :ssl.recv(socket, 0, 5_000), do: pull_one_chunk(socket, raw_buf <> more)
    end
  end

  defp ensure_bytes(_socket, buf, needed) when byte_size(buf) >= needed, do: {:ok, buf}

  defp ensure_bytes(socket, buf, needed) do
    with {:ok, more} <- :ssl.recv(socket, 0, 5_000), do: ensure_bytes(socket, buf <> more, needed)
  end

  defp parse_wire_header(<<header_len::32, json::binary-size(header_len), rest::binary>>) do
    with {:ok, header} <- Jason.decode(json) do
      {:ok, header, rest}
    end
  end

  defp parse_wire_header(_), do: {:error, :invalid_wire_header}

  defp parse_wire_units(<<0::32>>, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_wire_units(
         <<len::32, seq::64, pts::64, dts::64, payload::binary-size(len), rest::binary>>,
         acc
       )
       when len > 0 do
    unit = %{sequence: seq, pts: pts, dts: dts, payload: payload}
    parse_wire_units(rest, [unit | acc])
  end

  defp parse_wire_units(_, _acc), do: {:error, :invalid_wire_units}

  defp send_json(socket, status, map) do
    send_raw(socket, status, "application/json", Jason.encode!(map))
  end

  defp send_raw(socket, status, content_type, body) do
    :ssl.send(socket, [
      "HTTP/1.1 #{status} OK\r\n",
      "content-type: #{content_type}\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ])
  end

  defp write_gate(path, state) do
    File.write!(path, ~s({"generation":"#{@recovery_generation}","state":"#{state}"}))
  end

  defp write_file(dir, name, bytes) do
    path = Path.join(dir, name)
    File.write!(path, bytes)
    path
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, val), do: Application.put_env(app, key, val)
end
