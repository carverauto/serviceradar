defmodule CameraCodecCapability do
  @moduledoc false
  import ExUnit.Assertions
  import Membrane.ChildrenSpec

  alias Membrane.AAC.Parser.Esds
  alias Membrane.Buffer
  alias Membrane.MP4.Container
  alias Membrane.Pad
  alias Membrane.Testing

  require Pad

  # Finite dependency experiment, not the production recorder or a clock guarantee.
  # Fixture generation has a 120s RBE ceiling; the native test uses ExUnit's 60s
  # timeout. Each pipeline additionally has a 10s deadline.
  def generate(ffmpeg, output) do
    Logger.configure(level: :warning)
    {:ok, _} = Application.ensure_all_started(:membrane_core)
    ffmpeg = Path.expand(ffmpeg)
    root = Path.join(System.tmp_dir!(), "codec-capability-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)

    try do
      audio = encode_audio(ffmpeg, root)
      h264 = encode_video(ffmpeg, root, :h264)
      hevc = encode_video(ffmpeg, root, :hevc)

      cases = [
        candidate(ffmpeg, root, "h264_aac", h264, audio, 0),
        candidate(ffmpeg, root, "h264_aac_delayed", h264, audio, 500_000_000),
        candidate(ffmpeg, root, "hevc_main8", hevc, nil, 0)
      ]

      [control, delayed, _] = cases
      assert Enum.all?(control.audio_markers, &(abs(&1.offset_seconds) < 0.05))
      refute Enum.all?(delayed.audio_markers, &(abs(&1.offset_seconds) < 0.05))
      assert Enum.all?(delayed.audio_markers, &(abs(&1.offset_seconds - 0.5) < 0.05))
      report = %{scope: "native_library_capability_only", cases: cases}
      bytes = Jason.encode!(report)
      assert byte_size(bytes) < 8_388_608
      File.write!(output, bytes)
      IO.puts(Jason.encode!(%{native_codec_capability: Enum.map(cases, &Map.drop(&1, [:init, :fragments]))}))
      report
    after
      File.rm_rf!(root)
    end
  end

  defp encode_video(ffmpeg, root, kind) do
    raw = Path.join(root, "colors.rgb")
    File.write!(raw, Enum.map([<<255, 0, 0>>, <<0, 255, 0>>, <<0, 0, 255>>], &:binary.copy(&1, 64 * 64 * 30)))

    {codec, extension, aud, format, parser, options} =
      case kind do
        :h264 ->
          {"libx264", "h264", <<0, 0, 0, 1, 9>>, %Membrane.H264{alignment: :au, stream_structure: :annexb},
           %Membrane.H264.Parser{output_alignment: :au, output_stream_structure: :avc1},
           ["-profile:v", "baseline", "-x264-params", "aud=1:repeat-headers=1:scenecut=0"]}

        :hevc ->
          {"libx265", "hevc", <<0, 0, 0, 1, 70, 1>>, %Membrane.H265{alignment: :au, stream_structure: :annexb},
           %Membrane.H265.Parser{output_alignment: :au, output_stream_structure: :hvc1},
           [
             "-profile:v",
             "main",
             "-x265-params",
             "aud=1:repeat-headers=1:scenecut=0:pools=none:frame-threads=1:wpp=0:log-level=error"
           ]}
      end

    path = Path.join(root, "colors." <> extension)

    command(
      ffmpeg,
      [
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
        codec,
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
        "-bf",
        "0",
        "-g",
        "30",
        "-keyint_min",
        "30"
      ] ++ options ++ ["-f", extension, path]
    )

    [<<>> | units] = :binary.split(read_bounded(path, 1_048_576), aud, [:global])
    assert length(units) == 90

    buffers =
      Enum.with_index(units, fn payload, i ->
        %Buffer{payload: aud <> payload, pts: div(i * 1_000_000_000, 15), dts: div(i * 1_000_000_000, 15)}
      end)

    %{path: path, buffers: buffers, format: format, parser: parser}
  end

  defp encode_audio(ffmpeg, root) do
    raw = Path.join(root, "tones.f32")

    samples =
      for i <- 0..287_999, into: <<>> do
        time = i / 48_000

        value =
          if (time >= 2 and time < 2.08) or (time >= 4 and time < 4.08),
            do: 0.5 * :math.sin(2 * :math.pi() * 440 * time),
            else: 0.0

        <<value::float-little-32>>
      end

    File.write!(raw, samples)
    path = Path.join(root, "tones.aac")

    command(ffmpeg, [
      "-f",
      "f32le",
      "-ar",
      "48000",
      "-ac",
      "1",
      "-i",
      raw,
      "-c:a",
      "aac",
      "-profile:a",
      "aac_low",
      "-b:a",
      "96000",
      "-f",
      "adts",
      path
    ])

    read_bounded(path, 1_048_576)
  end

  defp candidate(ffmpeg, root, name, video, audio, delay) do
    tracks = if audio, do: [:video, :audio], else: [:video]

    spec = [
      :video
      |> child(%Testing.Source{output: video.buffers, stream_format: video.format})
      |> child(:video_parser, video.parser)
      |> via_in(Pad.ref(:input, :video))
      |> child(:muxer, %Membrane.MP4.Muxer.CMAF{segment_min_duration: 2_000_000_000})
      |> via_out(Pad.ref(:output, :combined), options: [tracks: tracks])
      |> child(:sink, Testing.Sink)
    ]

    spec =
      if audio do
        spec ++
          [
            :audio
            |> child(%Testing.Source{output: [%Buffer{payload: audio, pts: delay}]})
            |> child(:audio_parser, %Membrane.AAC.Parser{out_encapsulation: :none, output_config: :esds})
            |> via_in(Pad.ref(:input, :audio))
            |> get_child(:muxer)
          ]
      else
        spec
      end

    {:ok, _supervisor, pipeline} = Testing.Pipeline.start_link(spec: spec)

    {header, fragments} =
      try do
        collect(pipeline, nil, [], System.monotonic_time(:millisecond) + 10_000)
      after
        Testing.Pipeline.terminate(pipeline, force?: true)
      end

    assert byte_size(header) < 65_536
    assert length(fragments) in 1..4
    bytes = IO.iodata_to_binary([header | fragments])
    assert byte_size(bytes) < 2_097_152
    path = Path.join(root, name <> ".mp4")
    File.write!(path, bytes)
    probe = probe(ffmpeg, path)
    video_stream = Enum.find(probe["streams"], &(&1["codec_type"] == "video"))
    assert video_stream["codec_name"] == if(audio, do: "h264", else: "hevc")
    assert video_stream["profile"] == if(audio, do: "Constrained Baseline", else: "Main")
    assert video_stream["pix_fmt"] == "yuv420p"
    assert video_stream["has_b_frames"] == 0
    packets = Enum.filter(probe["packets"], &(&1["codec_type"] == "video"))
    assert length(packets) == 90

    packets
    |> Enum.with_index()
    |> Enum.each(fn {packet, i} ->
      assert abs(number(packet["pts_time"]) - i / 15) < 0.0001
      assert packet["pts_time"] == packet["dts_time"]
    end)

    decoded = decode(ffmpeg, path, "v:0", "rgb24", "rawvideo")
    assert byte_size(decoded) == 90 * 64 * 64 * 3
    assert decoded == decode(ffmpeg, video.path, "v:0", "rgb24", "rawvideo")
    markers = if audio, do: audio_markers(ffmpeg, path, probe, delay), else: []

    %{
      name: name,
      mime: "video/mp4; codecs=\"#{Enum.join(codecs(header), ",")}\"",
      init: Base.encode64(header),
      fragments: Enum.map(fragments, &Base.encode64/1),
      video_frames: length(packets),
      video_profile: video_stream["profile"],
      audio_markers: markers
    }
  end

  defp collect(pipeline, header, fragments, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {Testing.Pipeline, ^pipeline, {:handle_child_notification, {{:stream_format, :input, format}, :sink}}} ->
        assert header == nil
        collect(pipeline, format.header, fragments, deadline)

      {Testing.Pipeline, ^pipeline, {:handle_child_notification, {{:buffer, %Buffer{payload: payload}}, :sink}}} ->
        assert length(fragments) < 4 and byte_size(payload) < 2_097_152
        collect(pipeline, header, [payload | fragments], deadline)

      {Testing.Pipeline, ^pipeline, {:handle_child_notification, {{:end_of_stream, :input}, :sink}}} ->
        assert is_binary(header) and fragments != []
        {header, Enum.reverse(fragments)}

      {Testing.Pipeline, ^pipeline, _notification} ->
        collect(pipeline, header, fragments, deadline)
    after
      remaining -> flunk("native capability pipeline exceeded its 10-second deadline")
    end
  end

  defp audio_markers(ffmpeg, path, probe, delay) do
    [audio] = Enum.filter(probe["streams"], &(&1["codec_type"] == "audio"))
    assert {audio["codec_name"], audio["profile"], audio["sample_rate"], audio["channels"]} == {"aac", "LC", "48000", 1}
    packets = Enum.filter(probe["packets"], &(&1["codec_type"] == "audio"))
    assert length(packets) in 281..284
    first_pts = number(hd(packets)["pts_time"])
    assert abs(first_pts - delay / 1_000_000_000) < 0.0001

    packets
    |> Enum.with_index()
    |> Enum.each(fn {packet, i} ->
      assert abs(number(packet["pts_time"]) - first_pts - i * 1024 / 48_000) < 0.0001
    end)

    pcm = decode(ffmpeg, path, "a:0", "pcm_f32le", "f32le")
    assert byte_size(pcm) in (281 * 1024 * 4)..(284 * 1024 * 4)
    samples = for <<value::float-little-32 <- pcm>>, do: value

    Enum.map([2, 4], fn expected ->
      start = round((expected - 0.1) * 48_000)
      window = Enum.slice(samples, start, 14_400)
      first = Enum.find_index(window, &(abs(&1) > 0.1))
      assert is_integer(first), "missing independently generated audio marker"
      measured = first_pts + (start + first) / 48_000
      %{expected_seconds: expected, measured_seconds: measured, offset_seconds: measured - expected}
    end)
  end

  defp codecs(header) do
    {:ok, boxes, <<>>} = Container.parse(header)

    for track <- Keyword.get_values(Container.get_box(boxes, :moov).children, :trak) do
      entries = Container.get_box(track.children, [:mdia, :minf, :stbl, :stsd]).children

      case entries do
        [avc1: avc] ->
          <<1, profile, compatibility, level, _::binary>> = avc.children[:avcC].content
          "avc1." <> Base.encode16(<<profile, compatibility, level>>, case: :lower)

        [mp4a: aac] ->
          config = Esds.parse_esds(aac.children[:esds].fields.elementary_stream_descriptor)
          "mp4a.40.#{Membrane.AAC.profile_to_aot_id(config.profile)}"

        [hvc1: hevc] ->
          hevc_codec(hevc.children[:hvcC].content)
      end
    end
  end

  # ISO/IEC 14496-15 Annex E's HEVC codec string reverses hvcC's 32 flag bits.
  defp hevc_codec(
         <<1, space::2, tier::1, profile::5, compatible::binary-size(4), constraints::binary-size(6), level, _::binary>>
       ) do
    flags =
      compatible
      |> bits()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {bit, index}, acc -> acc + Bitwise.bsl(bit, index) end)

    suffix =
      constraints
      |> :binary.bin_to_list()
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == 0))
      |> Enum.reverse()
      |> Enum.map_join(".", &Base.encode16(<<&1>>))

    base =
      "hvc1.#{Enum.at(["", "A", "B", "C"], space)}#{profile}.#{Integer.to_string(flags, 16)}.#{if(tier == 0, do: "L", else: "H")}#{level}"

    if suffix == "", do: base, else: base <> "." <> suffix
  end

  defp bits(bytes), do: for(<<bit::1 <- bytes>>, do: bit)
  defp number(text), do: String.to_float(text)

  defp probe(ffmpeg, path) do
    ffprobe = Path.join(Path.dirname(ffmpeg), "ffprobe")

    {json, 0} =
      System.cmd(ffprobe, ["-v", "error", "-show_streams", "-show_packets", "-of", "json", path], stderr_to_stdout: true)

    assert byte_size(json) < 1_048_576
    Jason.decode!(json)
  end

  defp decode(ffmpeg, path, track, codec, format) do
    args = ["-i", path, "-map", "0:" <> track]
    args = if format == "rawvideo", do: args ++ ["-pix_fmt", codec], else: args ++ ["-c:a", codec]
    command(ffmpeg, args ++ ["-f", format, "pipe:1"])
  end

  defp command(tool, args) do
    {result, status} =
      System.cmd(tool, ["-nostdin", "-v", "error", "-filter_threads", "1", "-threads", "1"] ++ args,
        stderr_to_stdout: true
      )

    assert status == 0, "media tool failed: #{String.slice(result, 0, 4096)}"
    assert byte_size(result) < 2_097_152
    result
  end

  defp read_bounded(path, max_bytes) do
    assert File.stat!(path).size <= max_bytes
    File.read!(path)
  end
end
