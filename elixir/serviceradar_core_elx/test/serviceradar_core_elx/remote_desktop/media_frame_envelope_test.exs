defmodule ServiceRadarCoreElx.RemoteDesktop.MediaFrameEnvelopeTest do
  use ExUnit.Case, async: true

  alias ServiceRadarCoreElx.RemoteDesktop.MediaFrameEnvelope

  test "encodes desktop media chunks into the SRDP browser envelope" do
    metadata = ~s({"dirty":[[0,0,2,2]]})
    payload = <<1, 2, 3, 4>>

    assert {:ok, encoded} =
             MediaFrameEnvelope.encode(%Desktopmedia.DesktopMediaFrameChunk{
               desktop_session_id: "desktop-1",
               media_session_id: "media-1",
               sequence: 42,
               timestamp_unix_nano: 1_778_000_000_000,
               width: 1920,
               height: 1080,
               payload_family: "dirty_rect",
               encoding: "rgba",
               metadata: metadata,
               payload: payload,
               flags: 3
             })

    assert decoded(encoded) == %{
             encoding: "rgba",
             flags: 3,
             height: 1080,
             media_session_id: "media-1",
             metadata: metadata,
             payload: payload,
             payload_family_id: 2,
             sequence: 42,
             desktop_session_id: "desktop-1",
             timestamp_unix_nano: 1_778_000_000_000,
             width: 1920
           }
  end

  test "iodata encoder keeps stable strings, metadata, and payload as separate leaves" do
    frame = %Desktopmedia.DesktopMediaFrameChunk{
      desktop_session_id: "desktop-iodata",
      media_session_id: "media-iodata",
      sequence: 1,
      payload_family: "video",
      encoding: "h264",
      metadata: <<5, 6>>,
      payload: <<7, 8, 9>>,
      flags: 1
    }

    assert {:ok, [header, "desktop-iodata", "media-iodata", "h264", <<5, 6>>, <<7, 8, 9>>]} =
             MediaFrameEnvelope.encode_iodata(frame)

    assert byte_size(header) == MediaFrameEnvelope.header_size()
  end

  test "rejects invalid frame fields before binary construction" do
    assert {:error, {:missing_field, :desktop_session_id}} =
             MediaFrameEnvelope.encode(frame(desktop_session_id: ""))

    assert {:error, {:unsupported_payload_family, "unknown"}} =
             MediaFrameEnvelope.encode(frame(payload_family: "unknown"))

    assert {:error, {:field_out_of_range, :flags}} =
             MediaFrameEnvelope.encode(frame(flags: 256))

    assert {:error, {:unsupported_flags, :flags}} =
             MediaFrameEnvelope.encode(frame(flags: 32))

    assert {:error, {:field_too_large, :metadata}} =
             MediaFrameEnvelope.encode(frame(metadata: :binary.copy(<<0>>, 65_537)))
  end

  defp frame(overrides) do
    defaults = %{
      desktop_session_id: "desktop-1",
      media_session_id: "media-1",
      sequence: 1,
      timestamp_unix_nano: 0,
      width: 640,
      height: 480,
      payload_family: "metadata",
      encoding: "json",
      metadata: <<>>,
      payload: <<>>,
      flags: 0
    }

    struct!(Desktopmedia.DesktopMediaFrameChunk, Map.merge(defaults, Map.new(overrides)))
  end

  defp decoded(
         <<"SRDP", 1, flags::8, payload_family_id::8, 0::8, sequence::unsigned-big-64, timestamp_unix_nano::signed-big-64,
           width::unsigned-big-32, height::unsigned-big-32, metadata_length::unsigned-big-32,
           payload_length::unsigned-big-32, encoding_length::unsigned-big-16, desktop_session_length::unsigned-big-16,
           media_session_length::unsigned-big-16, 0::unsigned-big-16, body::binary>>
       ) do
    <<desktop_session_id::binary-size(desktop_session_length), media_session_id::binary-size(media_session_length),
      encoding::binary-size(encoding_length), metadata::binary-size(metadata_length),
      payload::binary-size(payload_length)>> = body

    %{
      desktop_session_id: desktop_session_id,
      media_session_id: media_session_id,
      encoding: encoding,
      flags: flags,
      height: height,
      metadata: metadata,
      payload: payload,
      payload_family_id: payload_family_id,
      sequence: sequence,
      timestamp_unix_nano: timestamp_unix_nano,
      width: width
    }
  end
end
