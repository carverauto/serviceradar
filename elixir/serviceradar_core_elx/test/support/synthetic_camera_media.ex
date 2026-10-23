defmodule ServiceRadarCoreElx.TestSupport.SyntheticCameraMedia do
  @moduledoc false

  @aud <<0, 0, 0, 1, 9>>

  def generate(directory, name, codec_args \\ ["-profile:v", "baseline", "-bf", "0", "-g", "30"]) do
    path = Path.join(directory, name <> ".h264")

    args =
      [
        "-nostdin",
        "-v",
        "error",
        "-f",
        "lavfi",
        "-i",
        "testsrc2=size=64x64:rate=15",
        "-frames:v",
        "75",
        "-c:v",
        "libx264",
        "-preset",
        "medium",
        "-sc_threshold",
        "0",
        "-x264-params",
        "aud=1:repeat-headers=1"
      ] ++ codec_args ++ ["-f", "h264", path]

    {"", 0} = System.cmd(tool("ffmpeg"), args, stderr_to_stdout: true)
    [<<>> | units] = :binary.split(File.read!(path), @aud, [:global])
    75 = length(units)

    units =
      Enum.with_index(units, fn payload, index ->
        %{
          payload: @aud <> payload,
          pts: 90_000 + index * 6_000,
          dts: 90_000 + index * 6_000,
          sequence: index + 1,
          codec: "h264",
          payload_format: "annexb",
          track_id: "video"
        }
      end)

    %{path: path, units: units}
  end

  def tool(name), do: Path.expand("../../third_party/membrane/media_test_tools/#{name}")
end
