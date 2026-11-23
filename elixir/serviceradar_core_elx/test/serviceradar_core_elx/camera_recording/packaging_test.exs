defmodule ServiceRadarCoreElx.CameraRecording.PackagingTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadarCoreElx.CameraRecording.ContinuousRecorder
  alias ServiceRadarCoreElx.TestSupport.SyntheticCameraMedia
  alias ServiceRadarNVRClient.Config, as: ClientConfig
  alias ServiceRadarRecording.Inbox
  alias ServiceRadarRecording.Packaging
  alias ServiceRadarRecording.Spool
  alias ServiceRadarRecording.Storage
  alias ServiceRadarRecordingMetadata.Descriptor

  @clock %{clock_epoch: "synthetic-clock-1", timebase: 90_000, dts_source: :pts_no_reordering, utc_mapping: :unknown}
  @frame_bytes trunc(64 * 64 * 3 / 2)

  setup_all do
    {:ok, _} = Application.ensure_all_started(:membrane_core)
    directory = Path.join(System.tmp_dir!(), "synthetic-cmaf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    baseline = SyntheticCameraMedia.generate(directory, "baseline")
    main = SyntheticCameraMedia.generate(directory, "main", ["-profile:v", "main", "-bf", "2", "-g", "30"])
    long_gop = SyntheticCameraMedia.generate(directory, "long-gop", ["-g", "300", "-profile:v", "baseline", "-bf", "0"])
    changed_args = ["-profile:v", "baseline", "-bf", "0", "-g", "30", "-vf", "scale=96:64"]
    changed = SyntheticCameraMedia.generate(directory, "changed", changed_args)

    ordered_main =
      SyntheticCameraMedia.generate(directory, "ordered-main", ["-profile:v", "main", "-bf", "0", "-g", "30"])

    ordered_high =
      SyntheticCameraMedia.generate(directory, "ordered-high", ["-profile:v", "high", "-bf", "0", "-g", "30"])

    # x264 codes an interlaced stream with picture order count type 0, so this
    # one rules reordering out only through its VUI bitstream restriction.
    restricted_args = ["-profile:v", "main", "-bf", "0", "-g", "30", "-flags", "+ildct+ilme"]

    restricted_main =
      SyntheticCameraMedia.generate(directory, "restricted-main", restricted_args, "tff=1:aud=1:repeat-headers=1")

    %{
      baseline: baseline,
      main: main,
      long_gop: long_gop,
      changed: changed,
      ordered: [{"avc1.4d", ordered_main}, {"avc1.64", ordered_high}, {"avc1.4d", restricted_main}]
    }
  end

  @tag :tmp_dir
  test "Main and High streams that rule out reordering record and decode unchanged", ctx do
    assert [2, 2, 0] = Enum.map(ctx.ordered, fn {_, media} -> sps_field(media.path, "pic_order_cnt_type") end)
    assert [_, _, {_, restricted}] = ctx.ordered
    assert 0 = sps_field(restricted.path, "max_num_reorder_frames")

    for {{codec_prefix, media}, index} <- Enum.with_index(ctx.ordered) do
      {:ok, pipeline} = Packaging.start(clock: @clock)
      on_exit(fn -> Packaging.stop(pipeline) end)

      events = push_all(pipeline, media.units)
      assert {:ok, tail} = Packaging.finish(pipeline)
      assert [{:init, init} | fragments] = events ++ tail
      fragments = Enum.map(fragments, fn {:fragment, fragment} -> fragment end)
      assert Enum.sum(Enum.map(fragments, & &1.sample_count)) == 75

      root = Path.join(ctx.tmp_dir, "ordered-#{index}")
      File.mkdir_p!(root)
      File.chmod!(root, 0o700)
      {descriptor, snapshot} = seal_block(root, init, fragments)
      assert String.starts_with?(descriptor["format"]["codec"], codec_prefix)

      assert {:ok, init_payload} = Spool.read_init(snapshot)

      media_payload =
        Enum.map_join(0..(length(fragments) - 1), fn sequence ->
          assert {:ok, payload} = Spool.read_fragment(snapshot, sequence)
          payload
        end)

      path = Path.join(root, "block.mp4")
      File.write!(path, init_payload <> media_payload)
      assert decode(path) == decode(media.path)
    end
  end

  @tag :tmp_dir
  test "recovered CMAF byte ranges preserve every frame with independent random access", ctx do
    {:ok, pipeline} = Packaging.start(clock: @clock)
    on_exit(fn -> Packaging.stop(pipeline) end)

    events = push_all(pipeline, ctx.baseline.units)
    assert {:ok, tail} = Packaging.finish(pipeline)
    events = events ++ tail
    assert [{:init, init} | media] = events
    fragments = Enum.map(media, fn {:fragment, fragment} -> fragment end)
    assert Enum.sum(Enum.map(fragments, & &1.sample_count)) == 75
    assert Enum.count(fragments) >= 2
    assert init.sha256 == digest(init.payload)
    assert init.clock.utc_mapping == :unknown
    snapshot = persist_and_recover(init, fragments, ctx.tmp_dir)
    assert {:ok, init_payload} = Spool.read_init(snapshot)

    for [previous, next] <- Enum.chunk_every(fragments, 2, 1, :discard) do
      assert previous.start_ns + previous.duration_ns == next.start_ns
    end

    expected_frames = decode(ctx.baseline.path)
    assert byte_size(expected_frames) == 75 * @frame_bytes

    fragments
    |> Enum.with_index()
    |> Enum.reduce(0, fn {fragment, sequence}, offset ->
      assert fragment.independent?
      assert fragment.duration_ns > 0
      assert fragment.init_sha256 == init.sha256
      assert fragment.sha256 == digest(fragment.payload)
      path = Path.join(ctx.tmp_dir, "fragment-#{offset}.mp4")
      assert {:ok, payload} = Spool.read_fragment(snapshot, sequence)
      File.write!(path, init_payload <> payload)
      assert_decoded_fragment(path, fragment, expected_frames, offset)
    end)

    assert List.last(fragments).tail_duration_source == :previous_sample
  end

  test "a stream that can reorder frames and clock resets stop only their recorder", ctx do
    {:ok, reordering} = Packaging.start(clock: @clock)
    on_exit(fn -> Packaging.stop(reordering) end)
    assert {:error, :h264_frame_reordering} = Packaging.push(reordering, hd(ctx.main.units))

    {:ok, pipeline} = Packaging.start(clock: @clock)
    on_exit(fn -> Packaging.stop(pipeline) end)
    [first | _] = ctx.baseline.units
    assert {:ok, _} = Packaging.push(pipeline, first)
    assert {:error, :non_monotonic_timestamp} = Packaging.push(pipeline, first)
    assert {:error, :non_monotonic_timestamp} = Packaging.finish(pipeline)
  end

  @tag :tmp_dir
  test "block grouping conserves decoded media and reports actual logical byte overhead", ctx do
    # Repeat a complete invented GOP, not container bytes or fabricated fragment
    # metadata. The native parser/muxer sees every AU and its increasing clock.
    gop = Enum.take(ctx.baseline.units, 30)

    units =
      for cycle <- 0..31, {unit, frame} <- Enum.with_index(gop) do
        index = cycle * 30 + frame
        %{unit | pts: 90_000 + index * 6_000, dts: 90_000 + index * 6_000, sequence: index + 1}
      end

    {:ok, pipeline} = Packaging.start(clock: @clock)
    on_exit(fn -> Packaging.stop(pipeline) end)
    events = push_all(pipeline, units)
    assert {:ok, tail} = Packaging.finish(pipeline)
    assert [{:init, init} | media] = events ++ tail
    fragments = Enum.map(media, fn {:fragment, fragment} -> fragment end)
    assert length(fragments) == 32
    assert Enum.sum(Enum.map(fragments, & &1.sample_count)) == 960
    assert Enum.all?(fragments, &(&1.independent? and &1.duration_ns == 2_000_000_000))
    media_bytes = Enum.sum(Enum.map(fragments, &byte_size(&1.payload)))
    assert media_bytes <= 8_388_608

    expected = ctx.baseline.path |> decode() |> binary_part(0, 30 * @frame_bytes) |> :binary.copy(32)

    measurements =
      for per_block <- [1, 8, 32] do
        root = Path.join(ctx.tmp_dir, "grouping-#{per_block}")
        File.mkdir!(root)
        File.chmod!(root, 0o700)

        blocks =
          fragments
          |> Enum.chunk_every(per_block)
          |> Enum.with_index(fn group, index -> measure_block(root, index, init, group) end)

        decoded = blocks |> Enum.map(& &1.decoded) |> IO.iodata_to_binary()
        assert byte_size(decoded) == 960 * @frame_bytes
        assert digest(decoded) == digest(expected)

        totals =
          Map.new(
            [:media_bytes, :init_bytes, :journal_bytes, :descriptor_bytes, :logical_spool_bytes, :fragments],
            fn key ->
              {key, Enum.sum(Enum.map(blocks, &Map.fetch!(&1, key)))}
            end
          )

        assert totals.media_bytes == media_bytes
        assert totals.fragments == 32
        assert totals.init_bytes == div(32, per_block) * byte_size(init.payload)

        Map.merge(totals, %{
          fragments_per_block: per_block,
          blocks: length(blocks),
          max_descriptor_bytes: blocks |> Enum.map(& &1.descriptor_bytes) |> Enum.max()
        })
      end

    IO.puts(
      Jason.encode!(%{
        measurement: "synthetic_logical_block_bytes",
        frames: 960,
        media_duration_ns: 64_000_000_000,
        groupings: measurements
      })
    )
  end

  @tag :tmp_dir
  test "mid-stream acquisition ignores metadata hints and starts at the next independently decodable IDR", ctx do
    {:ok, pipeline} = Packaging.start(clock: @clock, wait_for_keyframe?: true)
    on_exit(fn -> Packaging.stop(pipeline) end)
    [first | remaining] = Enum.drop(ctx.baseline.units, 15)
    assert {:ok, []} = Packaging.push(pipeline, Map.put(first, :keyframe, true))
    events = push_all(pipeline, remaining)
    assert {:ok, tail} = Packaging.finish(pipeline)
    assert [{:init, init} | media] = events ++ tail
    fragments = Enum.map(media, fn {:fragment, fragment} -> fragment end)
    assert Enum.sum(Enum.map(fragments, & &1.sample_count)) == 45
    assert hd(fragments).start_ns == 3_000_000_000
    expected = binary_part(decode(ctx.baseline.path), 30 * @frame_bytes, 45 * @frame_bytes)

    Enum.reduce(fragments, 0, fn fragment, offset ->
      path = Path.join(ctx.tmp_dir, "acquired-#{offset}.mp4")
      File.write!(path, init.payload <> fragment.payload)
      assert_decoded_fragment(path, fragment, expected, offset)
    end)
  end

  test "a unit dropped before the first keyframe may share that keyframe's timestamp", ctx do
    # A source that opens mid-GOP can stamp its leading frame and its first
    # keyframe alike. Frame 30 is an IDR; frame 29 cannot be decoded without frame 0.
    [leading, keyframe, following | rest] = Enum.drop(ctx.baseline.units, 29)
    leading = %{leading | pts: keyframe.pts, dts: keyframe.dts}

    {:ok, pipeline} = Packaging.start(clock: @clock, wait_for_keyframe?: true)
    on_exit(fn -> Packaging.stop(pipeline) end)
    assert {:ok, []} = Packaging.push(pipeline, leading)
    events = push_all(pipeline, [keyframe, following | rest])
    assert {:ok, tail} = Packaging.finish(pipeline)
    assert [{:init, _init} | media] = events ++ tail
    fragments = Enum.map(media, fn {:fragment, fragment} -> fragment end)
    assert Enum.sum(Enum.map(fragments, & &1.sample_count)) == 45
    assert hd(fragments).start_ns == 3_000_000_000

    # Time still never runs backwards while waiting, and never repeats once recording.
    {:ok, backwards} = Packaging.start(clock: @clock, wait_for_keyframe?: true)
    on_exit(fn -> Packaging.stop(backwards) end)
    assert {:ok, []} = Packaging.push(backwards, leading)

    assert {:error, :non_monotonic_timestamp} =
             Packaging.push(backwards, %{keyframe | pts: keyframe.pts - 1, dts: keyframe.dts - 1})

    {:ok, recording} = Packaging.start(clock: @clock, wait_for_keyframe?: true)
    on_exit(fn -> Packaging.stop(recording) end)
    assert {:ok, _events} = Packaging.push(recording, keyframe)

    assert {:error, :non_monotonic_timestamp} =
             Packaging.push(recording, %{following | pts: keyframe.pts, dts: keyframe.dts})
  end

  test "initial dropped units still consume byte, sample and media-time budgets", ctx do
    [first, second | _] = Enum.drop(ctx.baseline.units, 1)

    limits = [
      {[max_buffered_bytes: byte_size(first.payload) + byte_size(second.payload) - 1], :initial_acquisition_byte_limit},
      {[max_buffered_samples: 1], :initial_acquisition_sample_limit},
      {[max_keyframe_interval_ns: 1], :initial_keyframe_interval_exceeded}
    ]

    for {options, reason} <- limits do
      {:ok, pipeline} = Packaging.start([clock: @clock, wait_for_keyframe?: true] ++ options)
      on_exit(fn -> Packaging.stop(pipeline) end)
      assert {:ok, []} = Packaging.push(pipeline, first)
      assert {:error, ^reason} = Packaging.push(pipeline, second)
    end

    {:ok, timed} = Packaging.start(clock: @clock, wait_for_keyframe?: true, max_keyframe_wait_ms: 200)
    on_exit(fn -> Packaging.stop(timed) end)
    assert {:ok, []} = Packaging.push(timed, first)
    assert_receive {Packaging, ^timed, {:error, :initial_keyframe_wait_exceeded}}, 1_000
  end

  test "media, wall-clock and byte bounds independently reject incomplete recording", ctx do
    [first, second | _] = ctx.baseline.units
    {:ok, byte_limited} = Packaging.start(clock: @clock, max_access_unit_bytes: 1)
    on_exit(fn -> Packaging.stop(byte_limited) end)
    assert {:error, :access_unit_too_large} = Packaging.push(byte_limited, first)

    {:ok, buffer_limited} = Packaging.start(clock: @clock, max_buffered_bytes: 1)
    on_exit(fn -> Packaging.stop(buffer_limited) end)
    assert {:error, :buffered_media_limit} = Packaging.push(buffer_limited, first)

    {:ok, sample_limited} = Packaging.start(clock: @clock, max_buffered_samples: 1)
    on_exit(fn -> Packaging.stop(sample_limited) end)
    assert {:ok, _} = Packaging.push(sample_limited, first)
    assert {:error, :buffered_sample_limit} = Packaging.push(sample_limited, second)

    {:ok, timed} = Packaging.start(clock: @clock, max_keyframe_wait_ms: 200)
    on_exit(fn -> Packaging.stop(timed) end)
    assert {:ok, _} = Packaging.push(timed, first)
    assert_receive {Packaging, ^timed, {:error, :keyframe_wait_exceeded}}, 1_000
    assert {:error, :keyframe_wait_exceeded} = Packaging.push(timed, second)

    {:ok, missing_key} = Packaging.start(clock: @clock, max_keyframe_interval_ns: 500_000_000)
    on_exit(fn -> Packaging.stop(missing_key) end)
    results = Enum.map(Enum.take(ctx.long_gop.units, 10), &Packaging.push(missing_key, &1))
    assert {:error, :keyframe_interval_exceeded} in results

    refute Enum.any?(results, fn
             {:ok, events} -> Enum.any?(events, &match?({:fragment, _}, &1))
             _ -> false
           end)
  end

  test "unknown clock mapping is explicit and a one-sample tail is not assigned a duration", ctx do
    assert {:error, :invalid_packaging_options} = Packaging.start(clock: Map.delete(@clock, :utc_mapping))
    {:ok, pipeline} = Packaging.start(clock: @clock)
    on_exit(fn -> Packaging.stop(pipeline) end)
    assert {:ok, [{:init, %{clock: @clock}}]} = Packaging.push(pipeline, hd(ctx.baseline.units))
    assert {:error, :insufficient_tail_samples} = Packaging.finish(pipeline)
  end

  test "clock and media timestamp bounds admit only persistable provenance", ctx do
    overflow = 9_223_372_036_854_775_808

    invalid_clocks = [
      %{@clock | clock_epoch: String.duplicate("x", 129)},
      %{@clock | utc_mapping: %{origin_media_ticks: 0, origin_utc_usec: 0, uncertainty_usec: -1}},
      %{@clock | utc_mapping: %{origin_media_ticks: 0, origin_utc_usec: overflow, uncertainty_usec: 0}},
      %{@clock | utc_mapping: %{origin_media_ticks: 9_223_372_036_854_775_807, origin_utc_usec: 0, uncertainty_usec: 0}}
    ]

    for clock <- invalid_clocks do
      assert {:error, :invalid_packaging_options} = Packaging.start(clock: clock)
    end

    assert {:error, :invalid_packaging_options} = Packaging.start(clock: @clock, max_buffered_bytes: 33_554_433)
    assert {:error, :invalid_packaging_options} = Packaging.start(clock: @clock, unknown_limit: 1)
    {:ok, pipeline} = Packaging.start(clock: @clock)
    on_exit(fn -> Packaging.stop(pipeline) end)
    unit = %{hd(ctx.baseline.units) | pts: 9_223_372_036_854_775_807, dts: 9_223_372_036_854_775_807}
    assert {:error, :timestamp_out_of_range} = Packaging.push(pipeline, unit)
  end

  test "changed codec initialization cannot enter an existing recording epoch", ctx do
    {:ok, pipeline} = Packaging.start(clock: @clock)
    on_exit(fn -> Packaging.stop(pipeline) end)
    assert {:ok, _} = Packaging.push(pipeline, hd(ctx.baseline.units))
    changed = %{hd(ctx.changed.units) | pts: 96_000, dts: 96_000}
    assert {:error, :stream_configuration_changed} = Packaging.push(pipeline, changed)
  end

  test "15s keyframe interval limit admits >5s GOP jitter, rejects >15s, and supports raised sample buffers", ctx do
    # 75 frames from long_gop (single IDR at index 0) spaced at 6_200 ticks (~5.098s span)
    jitter_units =
      ctx.long_gop.units
      |> Enum.with_index()
      |> Enum.map(fn {unit, idx} ->
        ts = 90_000 + idx * 6_200
        %{unit | pts: ts, dts: ts}
      end)

    # Old 5s default rejects >5.0s span
    {:ok, default_pipe} = Packaging.start(clock: @clock)
    on_exit(fn -> Packaging.stop(default_pipe) end)

    default_results = Enum.map(jitter_units, &Packaging.push(default_pipe, &1))
    assert {:error, :keyframe_interval_exceeded} in default_results

    # Configured 15s limit + 4_096 buffered samples admits >5.0s jitter cleanly
    {:ok, relaxed_pipe} =
      Packaging.start(
        clock: @clock,
        max_keyframe_interval_ns: 15_000_000_000,
        max_keyframe_wait_ms: 20_000,
        max_buffered_samples: 4_096
      )

    on_exit(fn -> Packaging.stop(relaxed_pipe) end)

    events = push_all(relaxed_pipe, jitter_units)
    assert {:ok, tail} = Packaging.finish(relaxed_pipe)
    fragments = for {:fragment, fragment} <- events ++ tail, do: fragment
    assert Enum.sum(Enum.map(fragments, & &1.sample_count)) == 75

    # >15s media gap still fails under the 15s limit
    over_limit_units =
      ctx.long_gop.units
      |> Enum.with_index()
      |> Enum.map(fn {unit, idx} ->
        ts = 90_000 + idx * 18_500
        %{unit | pts: ts, dts: ts}
      end)

    {:ok, over_pipe} =
      Packaging.start(
        clock: @clock,
        max_keyframe_interval_ns: 15_000_000_000,
        max_buffered_samples: 8_192
      )

    on_exit(fn -> Packaging.stop(over_pipe) end)
    over_results = Enum.map(over_limit_units, &Packaging.push(over_pipe, &1))
    assert {:error, :keyframe_interval_exceeded} in over_results

    assert {:error, :invalid_packaging_options} = Packaging.start(clock: @clock, max_buffered_samples: 8_193)
    assert {:error, :invalid_packaging_options} = Packaging.start(clock: @clock, max_keyframe_interval_ns: 60_000_000_001)
    assert {:error, :invalid_packaging_options} = Packaging.start(clock: @clock, max_keyframe_wait_ms: 60_001)
  end

  describe "ContinuousRecorder integration with real Packaging" do
    test "recovers from 1-frame stream idle timeout and max_frames: 1 without stopping the run", ctx do
      [idr0, p1, p2 | _] = ctx.baseline.units

      for {label, extra_opts, expected_detail} <- [
            {"stream_idle", [bounds: %{soft_frames: 10, max_frames: 20}, stream_idle_timeout_ms: 40],
             "stream_idle_insufficient_frames"},
            {"max_frames_one", [bounds: %{soft_frames: 1, max_frames: 1}], "max_frames_one_insufficient_frames"}
          ] do
        harness =
          start_continuous_packaging_harness(
            [
              max_keyframe_interval_ns: 15_000_000_000,
              max_keyframe_wait_ms: 35_000
            ] ++ extra_opts
          )

        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
          assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

          base_us = 1_763_800_000_000_000
          send_packaging_unit(pid, harness.inbox_id, 0, idr0.pts, base_us, idr0.payload)

          assert_receive {:gap_recorded, gap}, 1_000
          assert {gap.reason, gap.detail_class} == {:incomplete_tail, expected_detail}

          assert_receive {:continuous_recorder, ^pid,
                          {:uncertain_resolved, %{resolution: :incomplete, recovered?: true}}},
                         1_000

          refute_receive {:continuous_recorder, ^pid, {:run_stopped, _}}, 50
          assert Process.alive?(pid)

          if label == "stream_idle" do
            # Next multi-frame block seals cleanly through real Packaging after recovery
            send_packaging_unit(pid, harness.inbox_id, 1, p1.pts + 90_000, base_us + 1_000_000, idr0.payload)
            send_packaging_unit(pid, harness.inbox_id, 2, p2.pts + 90_000, base_us + 1_033_333, p1.payload)
            ContinuousRecorder.stop(pid, :policy_disabled)
            assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{catalog: {:registered, _}}}}, 1_000
          else
            ContinuousRecorder.stop(pid, :policy_disabled)
          end

          assert_receive {:continuous_recorder, ^pid, {:run_stopped, %{reason: :policy_disabled}}}, 1_000
        end)
      end
    end

    test "stream_idle_timeout_ms seals mid-GOP stall cleanly before Packaging max_keyframe_wait_ms", ctx do
      # Scaled 15s : 15s : 35s ratio (1:50 -> 300ms GOP, 300ms idle, 700ms keyframe wait)
      harness =
        start_continuous_packaging_harness(
          bounds: %{soft_frames: 100, max_frames: 200},
          stream_idle_timeout_ms: 300,
          max_keyframe_interval_ns: 300_000_000,
          max_keyframe_wait_ms: 700
        )

      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, pid} = ContinuousRecorder.start_link(harness.opts)
        assert_receive {:continuous_recorder, ^pid, {:run_started, _}}, 1_000

        base_us = 1_763_800_000_000_000
        [idr0 | p_frames] = Enum.take(ctx.baseline.units, 5)
        send_packaging_unit(pid, harness.inbox_id, 0, idr0.pts, base_us, idr0.payload)

        # Feed P-frames up to 240ms after the IDR (80% of 300ms max_keyframe_interval_ns), then stall
        for {unit, idx} <- Enum.with_index(p_frames, 1) do
          Process.sleep(60)
          send_packaging_unit(pid, harness.inbox_id, idx, unit.pts, base_us + idx * 60_000, unit.payload)
        end

        # Idle timeout (300ms -> ~540ms from IDR) seals cleanly BEFORE 700ms max_keyframe_wait_ms
        assert_receive {:continuous_recorder, ^pid, {:block_sealed, %{catalog: {:registered, _}}}}, 1_500
        refute_receive {:continuous_recorder, ^pid, {:run_stopped, _}}, 300
        assert Process.alive?(pid)

        ContinuousRecorder.stop(pid, :policy_disabled)
        assert_receive {:continuous_recorder, ^pid, {:run_stopped, %{reason: :policy_disabled}}}, 1_000
      end)
    end
  end

  defp push_all(pipeline, units) do
    Enum.flat_map(units, fn unit ->
      assert {:ok, events} = Packaging.push(pipeline, unit)
      events
    end)
  end

  defp persist_and_recover(init, fragments, root) do
    File.chmod!(root, 0o700)
    identity = %{source_id: "synthetic-camera", profile: "recording", recorder_epoch: 1, block_sequence: 0, clock: @clock}
    assert {:ok, storage} = Storage.initialize(root, "00000000-0000-4000-8000-000000000011")
    assert {:ok, spool} = Spool.create(storage, identity, init.payload)
    first = hd(fragments)

    assert {:error, :invalid_tail_duration_source} =
             Spool.append(spool, first.payload, Map.put(first, :tail_duration_source, :unknown))

    spool =
      Enum.reduce(fragments, spool, fn fragment, spool ->
        assert {:ok, updated, _entry} = Spool.append(spool, fragment.payload, fragment)
        updated
      end)

    assert {:ok, sealed} = Spool.seal(spool)
    assert {:ok, recovered} = Spool.recover(storage, sealed.directory, identity)
    snapshot = Spool.snapshot(recovered)
    assert snapshot.sealed?
    assert snapshot.identity["clock"]["utc_mapping"] == "unknown"
    assert List.last(snapshot.entries)["tail_duration_source"] == "previous_sample"
    refute Enum.any?(Enum.drop(snapshot.entries, -1), &Map.has_key?(&1, "tail_duration_source"))
    snapshot
  end

  defp seal_block(root, init, fragments) do
    identity = %{
      source_id: "00000000-0000-4000-8000-000000000001",
      profile: "recording",
      recorder_epoch: 1,
      block_sequence: 0,
      clock: @clock
    }

    assert {:ok, storage} = Storage.initialize(root, "00000000-0000-4000-8000-000000000011")
    assert {:ok, spool} = Spool.create(storage, identity, init.payload)

    spool =
      Enum.reduce(fragments, spool, fn fragment, spool ->
        assert {:ok, updated, _} = Spool.append(spool, fragment.payload, fragment)
        updated
      end)

    assert {:ok, sealed} = Spool.seal(spool)
    assert {:ok, recovered} = Spool.recover(storage, sealed.directory, identity)
    snapshot = Spool.snapshot(recovered)
    assert {:ok, descriptor} = Descriptor.from_snapshot(snapshot, init)
    {descriptor, snapshot}
  end

  defp measure_block(root, index, init, group) do
    identity = %{
      source_id: "00000000-0000-4000-8000-000000000001",
      profile: "recording",
      recorder_epoch: 1,
      block_sequence: index,
      clock: @clock
    }

    assert {:ok, storage} = Storage.initialize(root, "00000000-0000-4000-8000-000000000011")
    assert {:ok, spool} = Spool.create(storage, identity, init.payload)

    spool =
      Enum.reduce(group, spool, fn fragment, spool ->
        assert {:ok, updated, _} = Spool.append(spool, fragment.payload, fragment)
        updated
      end)

    assert {:ok, sealed} = Spool.seal(spool)
    assert {:ok, recovered} = Spool.recover(storage, sealed.directory, identity)
    snapshot = Spool.snapshot(recovered)
    assert {:ok, descriptor} = Descriptor.from_snapshot(snapshot, init)
    assert {:ok, descriptor_bytes} = Descriptor.encode(descriptor)

    # File sizes measure logical content, not disk allocation or database cost.
    sizes =
      Map.new(File.ls!(snapshot.directory), fn name ->
        stat = File.stat!(Path.join(snapshot.directory, name))
        assert stat.type == :regular
        {name, stat.size}
      end)

    assert {:ok, init_payload} = Spool.read_init(snapshot)

    media =
      Enum.map(snapshot.entries, fn entry ->
        assert {:ok, payload} = Spool.read_fragment(snapshot, entry["sequence"])
        payload
      end)

    assert IO.iodata_length(media) == Map.fetch!(sizes, "media.m4s")
    assert byte_size(init_payload) == Map.fetch!(sizes, "init.mp4")
    path = Path.join(root, "readback-block-#{index}.mp4")
    File.write!(path, [init_payload | media])

    %{
      decoded: decode(path),
      fragments: length(snapshot.entries),
      media_bytes: Map.fetch!(sizes, "media.m4s"),
      init_bytes: Map.fetch!(sizes, "init.mp4"),
      journal_bytes: Map.fetch!(sizes, "journal"),
      logical_spool_bytes: sizes |> Map.values() |> Enum.sum(),
      descriptor_bytes: byte_size(descriptor_bytes)
    }
  end

  defp sps_field(path, field) do
    args = ["-nostdin", "-i", path, "-c", "copy", "-bsf:v", "trace_headers", "-f", "null", "-"]
    assert {output, 0} = System.cmd(SyntheticCameraMedia.tool("ffmpeg"), args, stderr_to_stdout: true)
    assert [_, value] = Regex.run(~r/\s#{field}\s+[01]+ = (\d+)/, output)
    String.to_integer(value)
  end

  defp probe(path) do
    args = [
      "-v",
      "error",
      "-select_streams",
      "v:0",
      "-show_entries",
      "stream=codec_name,has_b_frames:packet=pts_time,dts_time,duration_time,flags",
      "-of",
      "json",
      path
    ]

    assert {output, 0} = System.cmd(SyntheticCameraMedia.tool("ffprobe"), args, stderr_to_stdout: true)
    JSON.decode!(output)
  end

  defp assert_decoded_fragment(path, fragment, expected_frames, offset) do
    info = probe(path)
    assert [%{"codec_name" => "h264", "has_b_frames" => 0}] = info["streams"]
    assert [%{"flags" => "K" <> _} = first | _] = info["packets"]
    assert Enum.count(info["packets"]) == fragment.sample_count
    start_ns = String.to_float(first["dts_time"]) * 1_000_000_000
    assert abs(fragment.start_ns - start_ns) < 2_000
    duration_ns = Enum.sum(Enum.map(info["packets"], &(String.to_float(&1["duration_time"]) * 1_000_000_000)))
    assert abs(fragment.duration_ns - duration_ns) < fragment.sample_count * 1_000
    bytes = fragment.sample_count * @frame_bytes
    assert decode(path) == binary_part(expected_frames, offset, bytes)
    offset + bytes
  end

  defp decode(path) do
    args = [
      "-nostdin",
      "-v",
      "error",
      "-xerror",
      "-threads",
      "1",
      "-filter_threads",
      "1",
      "-i",
      path,
      "-map",
      "0:v:0",
      "-fps_mode",
      "passthrough",
      "-f",
      "rawvideo",
      "-pix_fmt",
      "yuv420p",
      "pipe:1"
    ]

    assert {raw, 0} = System.cmd(SyntheticCameraMedia.tool("ffmpeg"), args)
    raw
  end

  defp digest(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp send_packaging_unit(worker, inbox_id, sequence, pts, admitted_at_us, payload) do
    send(
      worker,
      {:recording_media, inbox_id,
       %{sequence: sequence, pts: pts, dts: pts, payload: payload, admitted_at_us: admitted_at_us}}
    )
  end

  defp start_continuous_packaging_harness(opts) do
    parent = self()
    seq_agent = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: make_ref()))
    block_states = start_supervised!(Supervisor.child_spec({Agent, fn -> %{} end}, id: make_ref()))
    inbox_ref = make_ref()

    camera_id = "00000000-0000-4000-8000-000000000301"
    profile_id = "00000000-0000-4000-8000-000000000302"
    policy_id = "00000000-0000-4000-8000-000000000303"
    relay_id = "00000000-0000-4000-8000-000000000304"
    ingest_owner_id = "00000000-0000-4000-8000-000000000305"
    claim_id = "00000000-0000-4000-8000-000000000306"
    storage_id = "00000000-0000-4000-8000-000000000307"
    recovery_generation = "00000000-0000-4000-8000-000000000308"
    media_ingest_id = "synthetic-packaging-continuous-1"
    member = "serviceradar-nvr-0"

    max_kf_interval_ns = Keyword.get(opts, :max_keyframe_interval_ns, 15_000_000_000)
    max_kf_wait_ms = Keyword.get(opts, :max_keyframe_wait_ms, 35_000)

    pipeline_pid =
      spawn_link(fn ->
        receive do
          :stop -> :ok
        end
      end)

    now = DateTime.utc_now()

    owner = %{
      id: ingest_owner_id,
      camera_source_id: camera_id,
      stream_profile_id: profile_id,
      relay_session_id: relay_id,
      epoch: 1
    }

    claim = %{
      id: claim_id,
      recorder_epoch: 1,
      lease_expires_at: DateTime.shift(now, second: 30),
      database_now: now
    }

    client_config = %ClientConfig{
      host: "nvr-0.example.test",
      port: 8443,
      ca: "/nonexistent/ca.pem",
      cert: "/nonexistent/client.pem",
      key: "/nonexistent/client.key",
      token: "synthetic-continuous-recorder-token-0123456789"
    }

    send_fn = fn _cfg, header, stream, _timeout ->
      block_key =
        header["identity"]
        |> Map.put("clock", %{
          "clock_epoch" => header["clock_epoch"],
          "timebase" => 90_000,
          "dts_source" => "pts_no_reordering",
          "utc_mapping" => "unknown"
        })
        |> Descriptor.block_key()

      {:ok, pkg} =
        Packaging.start(
          clock: %{
            clock_epoch: header["clock_epoch"],
            timebase: 90_000,
            dts_source: :pts_no_reordering,
            utc_mapping: :unknown
          },
          max_keyframe_interval_ns: max_kf_interval_ns,
          max_keyframe_wait_ms: max_kf_wait_ms
        )

      try do
        push_status =
          Enum.reduce_while(stream, :ok, fn unit, :ok ->
            Agent.update(block_states, &Map.put_new(&1, block_key, :incomplete))

            case Packaging.push(pkg, unit) do
              {:ok, _events} -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)

        case push_status do
          :ok ->
            case Packaging.finish(pkg) do
              {:ok, _tail} ->
                Agent.update(block_states, &Map.put(&1, block_key, :sealed))
                {:ok, %{status: :sealed_local, storage_id: storage_id, block_ids: [block_key]}}

              {:error, _reason} ->
                {:error, {:ingest_status, 422}}
            end

          {:error, _reason} ->
            {:error, {:ingest_status, 422}}
        end
      after
        Packaging.stop(pkg)
      end
    end

    lookup_fn = fn _cfg, [block_key], _timeout ->
      state = Agent.get(block_states, &Map.get(&1, block_key, :absent))
      {:ok, %{storage_id: storage_id, blocks: [%{block_id: block_key, state: state}]}}
    end

    reserve_fn = fn _owner, _claim, clock, _opts ->
      seq = Agent.get_and_update(seq_agent, fn s -> {s, s + 1} end)

      block = %RecordingBlock{
        id: Ecto.UUID.generate(),
        camera_source_id: camera_id,
        stream_profile_id: profile_id,
        ingest_owner_id: ingest_owner_id,
        ingest_epoch: 1,
        recorder_claim_id: claim_id,
        recorder_epoch: 1,
        block_sequence: seq,
        relay_session_id: relay_id,
        media_ingest_id: media_ingest_id,
        storage_id: storage_id,
        clock: clock
      }

      block_key = block |> RecordingBlock.identity() |> Descriptor.block_key()
      {:ok, %{block | block_key: block_key}}
    end

    base_opts = [
      name: nil,
      policy: %{
        id: policy_id,
        camera_source_id: camera_id,
        stream_profile_id: profile_id,
        mode: :continuous,
        nvr_member: member,
        storage: :local_and_archive,
        policy_revision: 1
      },
      notify: parent,
      enabled_fn: fn -> true end,
      target_resolver: fn ^member ->
        {:ok, %{member: member, storage_id: storage_id, client_config: client_config}}
      end,
      recovery_gate_fn: fn -> {:ok, %{generation: recovery_generation}} end,
      relay_open_fn: fn ^camera_id, ^profile_id, _actor ->
        {:ok, {:new, %{id: relay_id, status: :active, media_ingest_id: media_ingest_id}}}
      end,
      relay_close_fn: fn ^relay_id, _reason, _actor -> :ok end,
      relay_host_fn: fn ^relay_id -> nil end,
      pipeline_resolver: fn ^relay_id, ^media_ingest_id -> {:ok, pipeline_pid} end,
      ingest_owner_fn: fn ^relay_id, _actor -> {:ok, owner} end,
      acquire_claim_fn: fn _owner, _token, _ingest_id, _storage_id, _ttl, _opts -> {:ok, claim} end,
      renew_claim_fn: fn _owner, _claim, _ttl, _opts -> {:ok, claim} end,
      release_claim_fn: fn _owner, _claim, _opts -> {:ok, :released} end,
      reserve_block_fn: reserve_fn,
      inbox_new_fn: fn producer, rid, ingest_id, deadline_ms, inbox_opts ->
        {:ok, inbox} = Inbox.new(producer, rid, ingest_id, deadline_ms, inbox_opts)
        {:ok, %{inbox | id: inbox_ref}}
      end,
      attach_pipeline_fn: fn _pipeline, _inbox, _timeout -> :ok end,
      send_recording_fn: send_fn,
      lookup_blocks_fn: lookup_fn,
      block_descriptor_fn: fn _cfg, block_key, _timeout ->
        {:ok, %{"block_key" => block_key, "fragments" => [%{"start_ns" => 0, "duration_ns" => 2_000_000_000}]}}
      end,
      freeze_and_catalog_fn: fn _owner, _claim, block, _descriptor, _catalog_attrs, _opts ->
        {:ok, %{id: Ecto.UUID.generate(), archive_state: :pending, block_key: block.block_key}}
      end,
      enqueue_archive_fn: fn _entry -> {:ok, :enqueued} end,
      record_gap_fn: fn attrs, _opts ->
        send(parent, {:gap_recorded, attrs})
        {:ok, attrs}
      end,
      close_gap_fn: fn gap, end_us, _opts -> {:ok, Map.put(gap, :end_us, end_us)} end,
      close_stale_open_gaps_fn: fn _cam, _prof, _run_id, _now_us, _opts -> {:ok, 0} end,
      nvr_refusal_cooldown_ms: 0
    ]

    recorder_opts = Keyword.drop(opts, [:max_keyframe_interval_ns, :max_keyframe_wait_ms])
    %{opts: Keyword.merge(base_opts, recorder_opts), inbox_id: inbox_ref}
  end
end
