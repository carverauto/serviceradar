defmodule ServiceRadarWebNG.CameraArchivePlaylist do
  @moduledoc """
  Finite HLS windows from fresh, canonically verified archive metadata.

  The caller owns current recording authorization and obtains metadata from
  `ArchiveUploads.archive_metadata/3`. This renderer performs no I/O or proof
  lookup. Relative URIs resolve beside the playlist to the existing init and
  fragment endpoints, each of which independently authorizes its byte response.
  Media timing stays within one block; no UTC or cross-block continuity is implied.
  """

  @second 1_000_000_000

  def render(%{archive_status: "available", descriptor: descriptor}, first, count)
      when is_integer(first) and first in 0..4095 and is_integer(count) and count in 1..64 do
    fragments = Enum.slice(descriptor["fragments"], first, count)

    cond do
      fragments == [] ->
        {:error, :invalid_recording_window}

      descriptor["init"]["length"] > 1_048_576 or
        descriptor["media"]["length"] > 16_777_216 or
        Enum.any?(fragments, &(&1["length"] > 4_194_304)) or
          Enum.sum(Enum.map(fragments, & &1["duration_ns"])) > 300 * @second ->
        {:error, :recording_window_too_large}

      true ->
        bytes = encode(fragments)

        if byte_size(bytes) <= 65_536,
          do: {:ok, bytes},
          else: {:error, :recording_window_too_large}
    end
  end

  def render(%{archive_status: "available"}, _first, _count), do: {:error, :invalid_recording_window}

  def render(%{archive_status: _status}, _first, _count), do: {:error, :archive_unavailable}

  defp encode([first | _] = fragments) do
    max_duration = fragments |> Enum.map(& &1["duration_ns"]) |> Enum.max()
    target_duration = div(max_duration + @second - 1, @second)

    IO.iodata_to_binary([
      "#EXTM3U\n",
      "#EXT-X-VERSION:7\n",
      "#EXT-X-PLAYLIST-TYPE:VOD\n",
      "#EXT-X-TARGETDURATION:#{target_duration}\n",
      "#EXT-X-MEDIA-SEQUENCE:#{first["sequence"]}\n",
      "#EXT-X-MAP:URI=\"init\"\n",
      Enum.map(fragments, fn fragment ->
        [
          "#EXTINF:",
          seconds(fragment["duration_ns"]),
          ",\nfragments/#{fragment["sequence"]}\n"
        ]
      end),
      "#EXT-X-ENDLIST\n"
    ])
  end

  defp seconds(nanoseconds) do
    fraction = nanoseconds |> rem(@second) |> Integer.to_string() |> String.pad_leading(9, "0")
    "#{div(nanoseconds, @second)}.#{fraction}"
  end
end
