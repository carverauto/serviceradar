defmodule ServiceRadarCoreElx.RemoteDesktop.MediaFrameEnvelope do
  @moduledoc """
  SRDP desktop media frame envelope encoder for browser WebRTC DataChannels.

  This mirrors the Go agent envelope and web-ng browser parser. The iodata
  encoder keeps frame metadata and payload as caller-owned binaries so the
  eventual DataChannel provider can avoid another large copy until the actual
  WebRTC send boundary.
  """

  import Bitwise

  @version 1
  @header_size 48
  @max_uint16 65_535
  @max_uint32 4_294_967_295
  @max_uint64 18_446_744_073_709_551_615
  @min_int64 -9_223_372_036_854_775_808
  @max_int64 9_223_372_036_854_775_807
  @max_metadata_bytes 64 * 1_024
  @allowed_flags 0x01 ||| 0x02 ||| 0x04 ||| 0x08 ||| 0x10

  @payload_family_ids %{
    "video" => 1,
    "dirty_rect" => 2,
    "tile" => 3,
    "cursor" => 4,
    "metadata" => 5
  }

  def encode(%Desktopmedia.DesktopMediaFrameChunk{} = frame) do
    with {:ok, iodata} <- encode_iodata(frame) do
      {:ok, IO.iodata_to_binary(iodata)}
    end
  end

  def encode_iodata(%Desktopmedia.DesktopMediaFrameChunk{} = frame) do
    with {:ok, fields} <- frame_fields(frame) do
      {:ok,
       [
         header(fields),
         fields.desktop_session_id,
         fields.media_session_id,
         fields.encoding,
         fields.metadata,
         fields.payload
       ]}
    end
  end

  def header_size, do: @header_size

  defp frame_fields(frame) do
    fields = %{
      desktop_session_id: normalize_binary(frame.desktop_session_id),
      media_session_id: normalize_binary(frame.media_session_id),
      encoding: normalize_binary(frame.encoding),
      metadata: normalize_binary(frame.metadata),
      payload: normalize_binary(frame.payload),
      flags: normalize_uint(frame.flags),
      height: normalize_uint(frame.height),
      payload_family: normalize_binary(frame.payload_family),
      sequence: normalize_uint(frame.sequence),
      timestamp_unix_nano: normalize_int(frame.timestamp_unix_nano),
      width: normalize_uint(frame.width)
    }

    with :ok <- require_nonempty(fields.desktop_session_id, :desktop_session_id),
         :ok <- require_nonempty(fields.media_session_id, :media_session_id),
         {:ok, payload_family_id} <- payload_family_id(fields.payload_family),
         :ok <- require_uint8(fields.flags, :flags),
         :ok <- require_supported_flags(fields.flags),
         :ok <- require_uint64(fields.sequence, :sequence),
         :ok <- require_int64(fields.timestamp_unix_nano, :timestamp_unix_nano),
         :ok <- require_uint32_value(fields.width, :width),
         :ok <- require_uint32_value(fields.height, :height),
         :ok <- require_uint16(fields.desktop_session_id, :desktop_session_id),
         :ok <- require_uint16(fields.media_session_id, :media_session_id),
         :ok <- require_uint16(fields.encoding, :encoding),
         :ok <- require_uint32(fields.metadata, :metadata),
         :ok <- require_uint32(fields.payload, :payload),
         :ok <- require_metadata_limit(fields.metadata) do
      {:ok, Map.put(fields, :payload_family_id, payload_family_id)}
    end
  end

  defp header(fields) do
    <<"SRDP", @version::8, fields.flags::8, fields.payload_family_id::8, 0::8, fields.sequence::unsigned-big-64,
      fields.timestamp_unix_nano::signed-big-64, fields.width::unsigned-big-32, fields.height::unsigned-big-32,
      byte_size(fields.metadata)::unsigned-big-32, byte_size(fields.payload)::unsigned-big-32,
      byte_size(fields.encoding)::unsigned-big-16, byte_size(fields.desktop_session_id)::unsigned-big-16,
      byte_size(fields.media_session_id)::unsigned-big-16, 0::unsigned-big-16>>
  end

  defp payload_family_id(payload_family) do
    case Map.fetch(@payload_family_ids, payload_family) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, {:unsupported_payload_family, payload_family}}
    end
  end

  defp require_nonempty("", field), do: {:error, {:missing_field, field}}
  defp require_nonempty(_value, _field), do: :ok

  defp require_uint8(value, _field) when value >= 0 and value <= 255, do: :ok
  defp require_uint8(_value, field), do: {:error, {:field_out_of_range, field}}

  defp require_supported_flags(value) when (value &&& bnot(@allowed_flags)) == 0, do: :ok
  defp require_supported_flags(_value), do: {:error, {:unsupported_flags, :flags}}

  defp require_uint32_value(value, _field) when value >= 0 and value <= @max_uint32, do: :ok
  defp require_uint32_value(_value, field), do: {:error, {:field_out_of_range, field}}

  defp require_uint64(value, _field) when value >= 0 and value <= @max_uint64, do: :ok
  defp require_uint64(_value, field), do: {:error, {:field_out_of_range, field}}

  defp require_int64(value, _field) when value >= @min_int64 and value <= @max_int64, do: :ok
  defp require_int64(_value, field), do: {:error, {:field_out_of_range, field}}

  defp require_uint16(value, _field) when byte_size(value) <= @max_uint16, do: :ok
  defp require_uint16(_value, field), do: {:error, {:field_too_large, field}}

  defp require_uint32(value, _field) when byte_size(value) <= @max_uint32, do: :ok
  defp require_uint32(_value, field), do: {:error, {:field_too_large, field}}

  defp require_metadata_limit(metadata) when byte_size(metadata) <= @max_metadata_bytes, do: :ok
  defp require_metadata_limit(_metadata), do: {:error, {:field_too_large, :metadata}}

  defp normalize_binary(value) when is_binary(value), do: value
  defp normalize_binary(nil), do: ""

  defp normalize_uint(value) when is_integer(value) and value >= 0, do: value
  defp normalize_uint(_value), do: 0

  defp normalize_int(value) when is_integer(value), do: value
  defp normalize_int(_value), do: 0
end
