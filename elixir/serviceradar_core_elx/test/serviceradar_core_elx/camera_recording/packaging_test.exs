defmodule ServiceRadarCoreElx.CameraRecording.PackagingTest do
  use ExUnit.Case, async: true

  alias ServiceRadarCoreElx.CameraRecording.Packaging
  alias ServiceRadarCoreElx.CameraRecording.Spool
  alias ServiceRadarCoreElx.TestSupport.SyntheticCameraMedia

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
    %{baseline: baseline, main: main, long_gop: long_gop, changed: changed}
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

  test "unsupported reordering profile and clock resets stop only their recorder", ctx do
    {:ok, unsupported} = Packaging.start(clock: @clock)
    on_exit(fn -> Packaging.stop(unsupported) end)
    assert {:error, :unsupported_h264_profile} = Packaging.push(unsupported, hd(ctx.main.units))

    {:ok, pipeline} = Packaging.start(clock: @clock)
    on_exit(fn -> Packaging.stop(pipeline) end)
    [first | _] = ctx.baseline.units
    assert {:ok, _} = Packaging.push(pipeline, first)
    assert {:error, :non_monotonic_timestamp} = Packaging.push(pipeline, first)
    assert {:error, :non_monotonic_timestamp} = Packaging.finish(pipeline)
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

  defp push_all(pipeline, units) do
    Enum.flat_map(units, fn unit ->
      assert {:ok, events} = Packaging.push(pipeline, unit)
      events
    end)
  end

  defp persist_and_recover(init, fragments, root) do
    File.chmod!(root, 0o700)
    identity = %{source_id: "synthetic-camera", profile: "recording", recorder_epoch: 1, block_sequence: 0, clock: @clock}
    assert {:ok, spool} = Spool.create(root, identity, init.payload)
    first = hd(fragments)

    assert {:error, :invalid_tail_duration_source} =
             Spool.append(spool, first.payload, Map.put(first, :tail_duration_source, :unknown))

    spool =
      Enum.reduce(fragments, spool, fn fragment, spool ->
        assert {:ok, updated, _entry} = Spool.append(spool, fragment.payload, fragment)
        updated
      end)

    assert {:ok, sealed} = Spool.seal(spool)
    assert {:ok, recovered} = Spool.recover(sealed.directory, identity)
    snapshot = Spool.snapshot(recovered)
    assert snapshot.sealed?
    assert snapshot.identity["clock"]["utc_mapping"] == "unknown"
    assert List.last(snapshot.entries)["tail_duration_source"] == "previous_sample"
    refute Enum.any?(Enum.drop(snapshot.entries, -1), &Map.has_key?(&1, "tail_duration_source"))
    snapshot
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
end
