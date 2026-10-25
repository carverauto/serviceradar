defmodule ServiceRadarCoreElx.CameraRecording.RTSPRecordingTest do
  use ExUnit.Case, async: true

  alias ServiceRadarCoreElx.CameraRecording.Packaging
  alias ServiceRadarCoreElx.CameraRecording.Spool
  alias ServiceRadarCoreElx.CameraRecording.Storage
  alias ServiceRadarCoreElx.TestSupport.SyntheticCameraMedia

  @moduletag timeout: 20_000
  @moduletag capture_log: true

  setup_all do
    {:ok, _} = Application.ensure_all_started(:membrane_core)
    directory = Path.join(System.tmp_dir!(), "synthetic-rtsp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    codec = ["-profile:v", "baseline", "-bf", "0", "-threads", "1", "-filter_threads", "1"]
    baseline = SyntheticCameraMedia.generate(directory, "baseline", codec ++ ["-g", "30"])
    changed = SyntheticCameraMedia.generate(directory, "changed", codec ++ ["-g", "30", "-vf", "scale=96:64"])
    long_gop = SyntheticCameraMedia.generate(directory, "long-gop", codec ++ ["-g", "300"])
    request_path = Path.join(directory, "request.json")
    response_path = Path.join(directory, "received.json")

    File.write!(
      request_path,
      Jason.encode!([
        %{name: "interrupted", path: baseline.path, frames: 45},
        %{name: "reconnected", path: baseline.path, frames: 75},
        %{name: "changed", path: changed.path, frames: 75},
        %{name: "long-gop", path: long_gop.path, frames: 75}
      ])
    )

    # This tool embeds the real Go agent library and runs its private receiver
    # against a real loopback RTSP server. Its sequence, PTS and terminal error
    # are observed on that receiver, not supplied by this test as fake receipts.
    assert {_, 0} =
             System.cmd(
               Path.expand("../../go/pkg/agent/camera_rtsp_capture"),
               [
                 "-test.run=^TestCameraRTSPRecordingCapture$",
                 "-test.timeout=20s",
                 "-camera-rtsp-request=#{request_path}",
                 "-camera-rtsp-output=#{response_path}"
               ],
               stderr_to_stdout: true
             )

    captures =
      response_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.new(fn capture ->
        assert is_binary(capture["Terminal"]) and capture["Terminal"] != ""
        {capture["Name"], Enum.map(capture["Chunks"], &received_unit/1)}
      end)

    %{captures: captures, baseline: baseline.path, changed: changed.path}
  end

  @tag :tmp_dir
  test "a disconnected source cannot reuse its recording clock and a fresh source seals separately", ctx do
    old = start_packager("synthetic-rtsp-before")
    old_events = push_all(old, ctx.captures["interrupted"])
    assert {:error, :non_monotonic_timestamp} = Packaging.push(old, hd(ctx.captures["reconnected"]))

    # Failure discards the unclosed GOP. Only already complete fragments are
    # sealed here; no orderly-EOS duration is invented for the interrupted tail.
    old_snapshot = seal_recovered(old_events, ctx.tmp_dir, 1, "synthetic-rtsp-before")
    new = start_packager("synthetic-rtsp-after")
    new_events = push_all(new, ctx.captures["reconnected"])
    assert {:ok, tail} = Packaging.finish(new)
    new_snapshot = seal_recovered(new_events ++ tail, ctx.tmp_dir, 2, "synthetic-rtsp-after")

    assert old_snapshot.directory != new_snapshot.directory
    assert old_snapshot.identity["clock"]["clock_epoch"] == "synthetic-rtsp-before"
    assert new_snapshot.identity["clock"]["clock_epoch"] == "synthetic-rtsp-after"
    assert old_snapshot.identity["clock"]["utc_mapping"] == "unknown"
    assert new_snapshot.identity["clock"]["utc_mapping"] == "unknown"
    assert Enum.sum(Enum.map(old_snapshot.entries, & &1["duration_ns"])) == 2_000_000_000
    assert Enum.sum(Enum.map(new_snapshot.entries, & &1["duration_ns"])) == 5_000_000_000
    expected = decode(ctx.baseline)
    assert decode_snapshot(old_snapshot, ctx.tmp_dir, "old") == binary_part(expected, 0, div(30 * 64 * 64 * 3, 2))
    assert decode_snapshot(new_snapshot, ctx.tmp_dir, "new") == expected
  end

  @tag :tmp_dir
  test "changed RTSP codec initialization requires a separate packaging epoch", ctx do
    old = start_packager("synthetic-rtsp-config-before")
    assert {:ok, _} = Packaging.push(old, hd(ctx.captures["interrupted"]))

    # Use the later actual IDR from the reconnected receiver so timestamp
    # monotonicity cannot mask a missing codec-configuration fence.
    changed_idr = Enum.at(ctx.captures["changed"], 30)
    assert changed_idr.pts > hd(ctx.captures["interrupted"]).pts
    assert {:error, :stream_configuration_changed} = Packaging.push(old, changed_idr)
    fresh = start_packager("synthetic-rtsp-config-after")
    events = push_all(fresh, ctx.captures["changed"])
    assert {:ok, tail} = Packaging.finish(fresh)
    snapshot = seal_recovered(events ++ tail, ctx.tmp_dir, 3, "synthetic-rtsp-config-after")
    assert decode_snapshot(snapshot, ctx.tmp_dir, "changed") == decode(ctx.changed)
  end

  test "a real RTSP long GOP reaches the recording keyframe bound without committing incomplete media", ctx do
    pipeline = start_packager("synthetic-rtsp-no-keyframe", max_keyframe_interval_ns: 500_000_000)

    results =
      ctx.captures["long-gop"]
      |> Enum.take(10)
      |> Enum.map(&Packaging.push(pipeline, &1))

    assert {:error, :keyframe_interval_exceeded} in results

    refute Enum.any?(results, fn
             {:ok, events} -> Enum.any?(events, &match?({:fragment, _}, &1))
             _ -> false
           end)

    assert {:error, :keyframe_interval_exceeded} = Packaging.finish(pipeline)
  end

  defp received_unit(chunk) do
    %{
      payload: Base.decode64!(chunk["Payload"]),
      pts: chunk["PTS"],
      dts: chunk["DTS"],
      sequence: chunk["Sequence"],
      keyframe: chunk["Keyframe"],
      codec: chunk["Codec"],
      payload_format: chunk["PayloadFormat"],
      track_id: chunk["TrackID"]
    }
  end

  defp clock(epoch), do: %{clock_epoch: epoch, timebase: 90_000, dts_source: :pts_no_reordering, utc_mapping: :unknown}

  defp start_packager(epoch, opts \\ []) do
    assert {:ok, pipeline} = Packaging.start(Keyword.put(opts, :clock, clock(epoch)))
    on_exit(fn -> Packaging.stop(pipeline) end)
    pipeline
  end

  defp push_all(pipeline, units) do
    Enum.flat_map(units, fn unit ->
      assert {:ok, events} = Packaging.push(pipeline, unit)
      events
    end)
  end

  defp seal_recovered([{:init, init} | fragments], root, epoch, clock_epoch) do
    File.chmod!(root, 0o700)

    identity = %{
      source_id: "synthetic-rtsp-camera",
      profile: "recording",
      recorder_epoch: epoch,
      block_sequence: 0,
      clock: clock(clock_epoch)
    }

    assert {:ok, storage} = Storage.initialize(root, "00000000-0000-4000-8000-000000000011")
    assert {:ok, spool} = Spool.create(storage, identity, init.payload)

    spool =
      Enum.reduce(fragments, spool, fn {:fragment, fragment}, spool ->
        assert {:ok, updated, _} = Spool.append(spool, fragment.payload, fragment)
        updated
      end)

    assert {:ok, sealed} = Spool.seal(spool)
    assert {:ok, recovered} = Spool.recover(storage, sealed.directory, identity)
    Spool.snapshot(recovered)
  end

  defp decode_snapshot(snapshot, root, name) do
    assert {:ok, init} = Spool.read_init(snapshot)

    media =
      Enum.map(snapshot.entries, fn entry ->
        assert {:ok, bytes} = Spool.read_fragment(snapshot, entry["sequence"])
        bytes
      end)

    path = Path.join(root, name <> ".mp4")
    File.write!(path, [init | media])
    decode(path)
  end

  defp decode(path) do
    assert {bytes, 0} =
             System.cmd(SyntheticCameraMedia.tool("ffmpeg"), [
               "-nostdin",
               "-v",
               "error",
               "-threads",
               "1",
               "-filter_threads",
               "1",
               "-i",
               path,
               "-f",
               "rawvideo",
               "-pix_fmt",
               "yuv420p",
               "-threads",
               "1",
               "-"
             ])

    bytes
  end
end
