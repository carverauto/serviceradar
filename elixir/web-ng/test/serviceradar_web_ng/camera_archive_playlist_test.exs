defmodule ServiceRadarWebNG.CameraArchivePlaylistTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.CameraArchivePlaylist
  alias ServiceRadarWebNG.CameraArchiveWindow

  @moduletag :db_free

  test "a final window retains sequence and nanosecond precision without implying UTC or packed ranges" do
    metadata = metadata([{2_000_000_000, 3}, {2_000_000_001, 5}, {1, 7}])

    assert CameraArchivePlaylist.render(metadata, 1, 64) ==
             {:ok,
              """
              #EXTM3U
              #EXT-X-VERSION:7
              #EXT-X-PLAYLIST-TYPE:VOD
              #EXT-X-TARGETDURATION:3
              #EXT-X-MEDIA-SEQUENCE:1
              #EXT-X-MAP:URI="init"
              #EXTINF:2.000000001,
              fragments/1
              #EXTINF:0.000000001,
              fragments/2
              #EXT-X-ENDLIST
              """}
  end

  test "window limits admit the exact count, duration, init and full-object byte boundaries" do
    metadata = metadata(List.duplicate({4_687_500_000, 262_144}, 64), 1_048_576)
    assert {:ok, playlist} = CameraArchivePlaylist.render(metadata, 0, 64)

    assert String.starts_with?(playlist, """
           #EXTM3U
           #EXT-X-VERSION:7
           #EXT-X-PLAYLIST-TYPE:VOD
           #EXT-X-TARGETDURATION:5
           #EXT-X-MEDIA-SEQUENCE:0
           #EXT-X-MAP:URI="init"
           """)

    assert Regex.scan(~r/^#EXTINF:4\.687500000,$/m, playlist) ==
             List.duplicate(["#EXTINF:4.687500000,"], 64)

    assert Regex.scan(~r/^fragments\/\d+$/m, playlist) ==
             Enum.map(0..63, &["fragments/#{&1}"])

    assert String.ends_with?(playlist, "fragments/63\n#EXT-X-ENDLIST\n")

    assert {:ok, _} =
             [{1, 4_194_304}]
             |> metadata()
             |> CameraArchivePlaylist.render(0, 1)
  end

  test "read-path and duration ceilings reject a complete window instead of silently shortening it" do
    too_large = [
      metadata([{1, 1}], 1_048_577),
      metadata([{1, 4_194_305}]),
      metadata(List.duplicate({1, 262_144}, 64) ++ [{1, 1}]),
      metadata(List.duplicate({50_000_000_000, 1}, 5) ++ [{50_000_000_001, 1}])
    ]

    for metadata <- too_large do
      assert CameraArchivePlaylist.render(metadata, 0, 64) == {:error, :recording_window_too_large}
    end

    # An oversized fragment outside the selected window does not invalidate a
    # readable neighboring fragment in the same bounded media object.
    assert {:ok, _} =
             [{1, 4_194_305}, {1, 1}]
             |> metadata()
             |> CameraArchivePlaylist.render(1, 1)
  end

  test "unavailable archives and invalid or empty selections never produce a playlist" do
    available = metadata([{1, 1}])

    for {first, count} <- [{-1, 1}, {4096, 1}, {1, 1}, {0, 0}, {0, 65}, {"0", 1}, {0, nil}] do
      assert CameraArchivePlaylist.render(available, first, count) == {:error, :invalid_recording_window}
    end

    for status <- ["unavailable", "archive_verified", "reconciliation_required"] do
      metadata = %{available | archive_status: status, descriptor: nil}
      assert CameraArchivePlaylist.render(metadata, 0, 1) == {:error, :archive_unavailable}
    end
  end

  test "player windows advance without overlap across count and duration boundaries" do
    recording = metadata(List.duplicate({1_000_000_000, 1}, 65))

    assert {:ok, %{first: 0, count: 64, duration_ns: 64_000_000_000, index: 0, total: 2}} =
             CameraArchiveWindow.select(recording, 0)

    assert {:ok, %{first: 64, count: 1, duration_ns: 1_000_000_000, index: 1, total: 2}} =
             CameraArchiveWindow.select(recording, 1)

    assert CameraArchiveWindow.select(recording, 2) == {:error, :invalid_recording_window}

    recording = metadata([{150_000_000_000, 1}, {150_000_000_000, 1}, {1, 1}])

    assert {:ok, %{first: 0, count: 2, duration_ns: 300_000_000_000, total: 2}} =
             CameraArchiveWindow.select(recording, 0)

    assert {:ok, %{first: 2, count: 1, duration_ns: 1, total: 2}} = CameraArchiveWindow.select(recording, 1)

    assert CameraArchiveWindow.select(metadata([{300_000_000_001, 1}]), 0) ==
             {:error, :recording_window_too_large}

    assert CameraArchiveWindow.select(metadata([{1, 4_194_305}]), 0) ==
             {:error, :recording_window_too_large}

    assert CameraArchiveWindow.select(%{archive_status: "reconciliation_required", descriptor: nil}, 0) ==
             {:error, :archive_unavailable}
  end

  defp metadata(parts, init_length \\ 1) do
    {fragments, {size, _end_ns}} =
      parts
      |> Enum.with_index()
      |> Enum.map_reduce({0, 9_000_000_001}, fn {{duration, length}, sequence}, {offset, start} ->
        fragment = %{
          "sequence" => sequence,
          "offset" => offset,
          "length" => length,
          "start_ns" => start,
          "duration_ns" => duration,
          "sha256" => String.duplicate("a", 64),
          "tail_duration_source" => nil,
          "motion" => "unknown"
        }

        {fragment, {offset + length, start + duration}}
      end)

    %{
      archive_status: "available",
      descriptor: %{
        "version" => 1,
        "identity" => %{
          "source_id" => "5334048e-68af-4bad-960a-bdd191305bb2",
          "profile" => "33882f0b-1160-480f-b84c-2ce368b56667",
          "recorder_epoch" => 1,
          "block_sequence" => 0,
          "clock" => %{
            "clock_epoch" => "synthetic-playlist-clock",
            "timebase" => 90_000,
            "dts_source" => "pts_no_reordering",
            "utc_mapping" => "unknown"
          }
        },
        "format" => %{"codec" => "avc1.42c00a", "timescale" => 90_000},
        "init" => %{"length" => init_length, "sha256" => String.duplicate("b", 64)},
        "media" => %{"length" => size, "sha256" => String.duplicate("c", 64)},
        "fragments" => fragments
      }
    }
  end
end
