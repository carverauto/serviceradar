defmodule CameraBrowserFixture do
  @moduledoc false

  alias ServiceRadarCoreElx.CameraRecording.Packaging
  alias ServiceRadarCoreElx.CameraRecording.Spool
  alias ServiceRadarCoreElx.CameraRecording.Storage

  @clock %{
    clock_epoch: "synthetic-browser-clock",
    timebase: 90_000,
    dts_source: :pts_no_reordering,
    utc_mapping: :unknown
  }
  @aud <<0, 0, 0, 1, 9>>

  def generate(ffmpeg, output) do
    Logger.configure(level: :warning)
    {:ok, _} = Application.ensure_all_started(:membrane_core)
    root = Path.join(System.tmp_dir!(), "camera-browser-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    {:ok, storage} = Storage.initialize(root, Ecto.UUID.generate())

    try do
      units = encode_colors(Path.expand(ffmpeg), root)
      {:ok, pipeline} = Packaging.start(clock: @clock)

      try do
        events =
          Enum.flat_map(units, fn unit ->
            {:ok, events} = Packaging.push(pipeline, unit)
            events
          end)

        {:ok, tail} = Packaging.finish(pipeline)
        [{:init, init} | media] = events ++ tail
        fragments = Enum.map(media, fn {:fragment, fragment} -> fragment end)
        recovered = recover(storage, init, fragments)
        {:ok, init_bytes} = Spool.read_init(recovered)

        reads =
          Enum.map(recovered.entries, fn entry ->
            {:ok, bytes} = Spool.read_fragment(recovered, entry["sequence"])
            Map.put(entry, "base64", Base.encode64(bytes))
          end)

        File.write!(
          output,
          Jason.encode!(%{
            init: Base.encode64(init_bytes),
            codecs: init.codecs,
            high_water: recovered.high_water,
            fragments: reads
          })
        )
      after
        Packaging.stop(pipeline)
      end
    after
      File.rm_rf!(root)
    end
  end

  defp encode_colors(ffmpeg, root) do
    raw = Path.join(root, "colors.rgb")
    encoded = Path.join(root, "colors.h264")
    colors = [<<255, 0, 0>>, <<0, 255, 0>>, <<0, 0, 255>>]
    File.write!(raw, Enum.map(colors, &:binary.copy(&1, 64 * 64 * 30)))

    args = [
      "-nostdin",
      "-v",
      "error",
      "-filter_threads",
      "1",
      "-f",
      "rawvideo",
      "-pixel_format",
      "rgb24",
      "-video_size",
      "64x64",
      "-framerate",
      "15",
      "-i",
      raw,
      "-frames:v",
      "90",
      "-c:v",
      "libx264",
      "-threads",
      "1",
      "-pix_fmt",
      "yuv420p",
      "-vf",
      "scale=out_color_matrix=bt709:out_range=tv",
      "-colorspace",
      "bt709",
      "-color_primaries",
      "bt709",
      "-color_trc",
      "bt709",
      "-profile:v",
      "baseline",
      "-bf",
      "0",
      "-g",
      "30",
      "-keyint_min",
      "30",
      "-sc_threshold",
      "0",
      "-x264-params",
      "aud=1:repeat-headers=1",
      "-f",
      "h264",
      encoded
    ]

    {"", 0} = System.cmd(ffmpeg, args, stderr_to_stdout: true)
    [<<>> | units] = :binary.split(File.read!(encoded), @aud, [:global])
    90 = length(units)
    Enum.with_index(units, fn payload, index -> %{payload: @aud <> payload, pts: index * 6_000, dts: index * 6_000} end)
  end

  defp recover(storage, init, fragments) do
    identity = %{
      source_id: "synthetic-browser-camera",
      profile: "recording",
      recorder_epoch: 1,
      block_sequence: 0,
      clock: @clock
    }

    {:ok, spool} = Spool.create(storage, identity, init.payload)

    spool =
      Enum.reduce(fragments, spool, fn fragment, spool ->
        {:ok, updated, _entry} = Spool.append(spool, fragment.payload, fragment)
        updated
      end)

    {:ok, sealed} = Spool.seal(spool)
    {:ok, recovered} = Spool.recover(storage, sealed.directory, identity)
    %{sealed?: true} = Spool.snapshot(recovered)
  end
end

[ffmpeg, output] = System.argv()
CameraBrowserFixture.generate(ffmpeg, output)
