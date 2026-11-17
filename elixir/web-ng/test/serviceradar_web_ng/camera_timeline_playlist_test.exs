defmodule ServiceRadarWebNG.CameraTimelinePlaylistTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.CameraTimelinePlaylist

  @moduletag :db_free

  @entry_1 "11111111-1111-4111-8111-111111111101"
  @entry_2 "11111111-1111-4111-8111-111111111102"
  @entry_3 "11111111-1111-4111-8111-111111111103"
  @entry_quarantined "11111111-1111-4111-8111-111111111199"

  @init_a String.duplicate("a", 64)
  @init_b String.duplicate("b", 64)
  @base_us 1_800_000_000_000_000

  test "spans archive and local blocks continuously while reusing EXT-X-MAP for identical init_sha256" do
    block_1 =
      synthetic_block(@entry_1,
        timeline_start_us: @base_us,
        media_start_ns: 0,
        durations_ns: [2_000_000_000, 2_000_000_000],
        init_sha256: @init_a,
        clock_epoch: "epoch-synth-1",
        local_state: :reclaimed,
        archive_state: :verified
      )

    block_2 =
      synthetic_block(@entry_2,
        timeline_start_us: @base_us + 4_000_000,
        media_start_ns: 4_000_000_000,
        durations_ns: [2_000_000_001],
        init_sha256: @init_a,
        clock_epoch: "epoch-synth-1",
        local_state: :present,
        archive_state: :pending
      )

    quarantined =
      synthetic_block(@entry_quarantined,
        timeline_start_us: @base_us + 6_000_000,
        media_start_ns: 6_000_001_000,
        durations_ns: [2_000_000_000],
        init_sha256: @init_a,
        clock_epoch: "epoch-synth-1",
        local_state: :quarantined,
        archive_state: :pending
      )

    window = %{
      from_us: @base_us,
      to_us: @base_us + 10_000_000,
      source_mode: :auto,
      blocks: [block_2, quarantined, block_1],
      gaps: []
    }

    assert {:ok, stats} = CameraTimelinePlaylist.render_with_stats(window)
    assert stats.segment_count == 3
    assert stats.discontinuity_count == 0
    assert stats.map_count == 1

    iso_start = @base_us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()

    assert stats.playlist ==
             """
             #EXTM3U
             #EXT-X-VERSION:7
             #EXT-X-PLAYLIST-TYPE:VOD
             #EXT-X-TARGETDURATION:3
             #EXT-X-MEDIA-SEQUENCE:0
             #EXT-X-MAP:URI="blocks/#{@entry_1}/init?source=auto"
             #EXT-X-PROGRAM-DATE-TIME:#{iso_start}
             #EXTINF:2.000000000,
             blocks/#{@entry_1}/fragments/0?source=auto
             #EXTINF:2.000000000,
             blocks/#{@entry_1}/fragments/1?source=auto
             #EXTINF:2.000000001,
             blocks/#{@entry_2}/fragments/0?source=auto
             #EXT-X-ENDLIST
             """

    refute stats.playlist =~ @entry_quarantined
  end

  test "emits EXT-X-DISCONTINUITY and EXT-X-PROGRAM-DATE-TIME on gap, epoch change, reanchor, timestamp jump, and init_sha256 change" do
    # 1. Recorded gap between blocks with same init_sha256 -> discontinuity without redundant EXT-X-MAP
    b1 =
      synthetic_block(@entry_1,
        timeline_start_us: @base_us,
        media_start_ns: 0,
        durations_ns: [2_000_000_000],
        init_sha256: @init_a,
        clock_epoch: "epoch-1"
      )

    b2_after_gap =
      synthetic_block(@entry_2,
        timeline_start_us: @base_us + 5_000_000,
        media_start_ns: 5_000_000_000,
        durations_ns: [2_000_000_000],
        init_sha256: @init_a,
        clock_epoch: "epoch-1"
      )

    b3_new_init =
      synthetic_block(@entry_3,
        timeline_start_us: @base_us + 7_000_000,
        media_start_ns: 7_000_000_000,
        durations_ns: [2_000_000_000],
        init_sha256: @init_b,
        clock_epoch: "epoch-1"
      )

    gap = %{start_us: @base_us + 2_000_000, end_us: @base_us + 5_000_000, reason: :handover_overflow}

    assert {:ok, stats} =
             CameraTimelinePlaylist.render_with_stats(%{
               from_us: @base_us,
               to_us: @base_us + 10_000_000,
               source_mode: :archive,
               blocks: [b1, b2_after_gap, b3_new_init],
               gaps: [gap]
             })

    assert stats.discontinuity_count == 2
    assert stats.map_count == 2
    assert length(Regex.scan(~r/^#EXT-X-DISCONTINUITY$/m, stats.playlist)) == 2
    assert length(Regex.scan(~r/^#EXT-X-PROGRAM-DATE-TIME:/m, stats.playlist)) == 3
    assert stats.playlist =~ ~s(#EXT-X-MAP:URI="blocks/#{@entry_1}/init?source=archive")
    assert stats.playlist =~ ~s(#EXT-X-MAP:URI="blocks/#{@entry_3}/init?source=archive")
    refute stats.playlist =~ ~s(#EXT-X-MAP:URI="blocks/#{@entry_2}/init?source=archive")

    # 2. Clock epoch change even when timeline & fMP4 timestamps look contiguous
    b2_epoch =
      synthetic_block(@entry_2,
        timeline_start_us: @base_us + 2_000_000,
        media_start_ns: 2_000_000_000,
        durations_ns: [2_000_000_000],
        init_sha256: @init_a,
        clock_epoch: "epoch-2"
      )

    assert {:ok, epoch_stats} =
             CameraTimelinePlaylist.render_with_stats(%{
               from_us: @base_us,
               to_us: @base_us + 6_000_000,
               blocks: [b1, b2_epoch],
               gaps: []
             })

    assert epoch_stats.discontinuity_count == 1
    assert epoch_stats.map_count == 1

    # 3. Clock reanchor without media gap marks discontinuity
    b2_reanchor =
      synthetic_block(@entry_2,
        timeline_start_us: @base_us + 2_000_000,
        media_start_ns: 2_000_000_000,
        durations_ns: [2_000_000_000],
        init_sha256: @init_a,
        clock_epoch: "epoch-1",
        reanchored: true
      )

    assert {:ok, reanchor_stats} =
             CameraTimelinePlaylist.render_with_stats(%{
               from_us: @base_us,
               to_us: @base_us + 6_000_000,
               blocks: [b1, b2_reanchor],
               gaps: []
             })

    assert reanchor_stats.discontinuity_count == 1

    # 4. fMP4 decode timestamp reset (0ns on second block) marks discontinuity
    b2_fmp4_reset =
      synthetic_block(@entry_2,
        timeline_start_us: @base_us + 2_000_000,
        media_start_ns: 0,
        durations_ns: [2_000_000_000],
        init_sha256: @init_a,
        clock_epoch: "epoch-1"
      )

    assert {:ok, fmp4_stats} =
             CameraTimelinePlaylist.render_with_stats(%{
               from_us: @base_us,
               to_us: @base_us + 6_000_000,
               blocks: [b1, b2_fmp4_reset],
               gaps: []
             })

    assert fmp4_stats.discontinuity_count == 1
  end

  test "enforces 60-minute window, 2,048-segment, 256 KiB playlist, 1 MiB init, and 4 MiB fragment bounds" do
    valid_block =
      synthetic_block(@entry_1,
        timeline_start_us: @base_us,
        media_start_ns: 0,
        durations_ns: [2_000_000_000],
        init_sha256: @init_a
      )

    # Window > 60 minutes (3_600_000_001 us)
    assert CameraTimelinePlaylist.render(%{
             from_us: @base_us,
             to_us: @base_us + 3_600_000_001,
             blocks: [valid_block]
           }) == {:error, :recording_window_too_large}

    # Segment count > 2,048
    many_frags_block =
      synthetic_block(@entry_1,
        timeline_start_us: @base_us,
        media_start_ns: 0,
        durations_ns: List.duplicate(1_000_000_000, 2_049),
        init_sha256: @init_a
      )

    assert CameraTimelinePlaylist.render(%{
             from_us: @base_us,
             to_us: @base_us + 3_000_000_000,
             blocks: [many_frags_block]
           }) == {:error, :recording_window_too_large}

    # Init > 1 MiB
    oversized_init =
      synthetic_block(@entry_1,
        timeline_start_us: @base_us,
        media_start_ns: 0,
        durations_ns: [2_000_000_000],
        init_length: 1_048_577,
        init_sha256: @init_a
      )

    assert CameraTimelinePlaylist.render(%{
             from_us: @base_us,
             to_us: @base_us + 10_000_000,
             blocks: [oversized_init]
           }) == {:error, :recording_window_too_large}

    # Fragment > 4 MiB inside requested window
    oversized_frag =
      synthetic_block(@entry_1,
        timeline_start_us: @base_us,
        media_start_ns: 0,
        durations_ns: [2_000_000_000],
        fragment_length: 4_194_305,
        init_sha256: @init_a
      )

    assert CameraTimelinePlaylist.render(%{
             from_us: @base_us,
             to_us: @base_us + 10_000_000,
             blocks: [oversized_frag]
           }) == {:error, :recording_window_too_large}

    # Rendered playlist > 256 KiB (2_000 blocks each changing init & epoch -> > 262_144 bytes)
    huge_blocks =
      for idx <- 1..2_000 do
        id =
          idx
          |> Integer.to_string(16)
          |> String.pad_leading(12, "0")
          |> then(&"22222222-2222-4222-8222-#{&1}")

        init_hash =
          idx
          |> Integer.to_string(16)
          |> String.pad_leading(64, "0")
          |> String.downcase()

        synthetic_block(id,
          timeline_start_us: @base_us + (idx - 1) * 1_000_000,
          media_start_ns: 0,
          durations_ns: [1_000_000_000],
          init_sha256: init_hash,
          clock_epoch: "epoch-#{idx}"
        )
      end

    assert CameraTimelinePlaylist.render(%{
             from_us: @base_us,
             to_us: @base_us + 2_500_000_000,
             blocks: huge_blocks
           }) == {:error, :recording_window_too_large}

    # Zero playable segments in window -> :recording_unavailable
    assert CameraTimelinePlaylist.render(%{
             from_us: @base_us + 50_000_000,
             to_us: @base_us + 60_000_000,
             blocks: [valid_block]
           }) == {:error, :recording_unavailable}
  end

  defp synthetic_block(id, opts) do
    timeline_start_us = Keyword.fetch!(opts, :timeline_start_us)
    media_start_ns = Keyword.get(opts, :media_start_ns, 0)
    durations_ns = Keyword.fetch!(opts, :durations_ns)
    init_length = Keyword.get(opts, :init_length, 512)
    fragment_length = Keyword.get(opts, :fragment_length, 4_096)
    init_sha256 = Keyword.get(opts, :init_sha256, @init_a)
    clock_epoch = Keyword.get(opts, :clock_epoch, "epoch-synth")

    {fragments, {media_bytes, end_ns}} =
      durations_ns
      |> Enum.with_index()
      |> Enum.map_reduce({0, media_start_ns}, fn {dur_ns, seq}, {offset, start_ns} ->
        frag = %{
          "sequence" => seq,
          "offset" => offset,
          "length" => fragment_length,
          "start_ns" => start_ns,
          "duration_ns" => dur_ns,
          "sha256" => String.duplicate("c", 64),
          "tail_duration_source" => nil,
          "motion" => "unknown"
        }

        {frag, {offset + fragment_length, start_ns + dur_ns}}
      end)

    %{
      id: id,
      block_key: String.duplicate("d", 64),
      clock_epoch: clock_epoch,
      reanchored: Keyword.get(opts, :reanchored, false),
      local_state: Keyword.get(opts, :local_state),
      archive_state: Keyword.get(opts, :archive_state),
      media_start_ns: media_start_ns,
      media_end_ns: end_ns,
      timeline_start_us: timeline_start_us,
      timeline_end_us: timeline_start_us + div(end_ns - media_start_ns, 1_000),
      init_sha256: init_sha256,
      descriptor: %{
        "version" => 1,
        "identity" => %{
          "source_id" => "5334048e-68af-4bad-960a-bdd191305bb2",
          "profile" => "33882f0b-1160-480f-b84c-2ce368b56667",
          "recorder_epoch" => 1,
          "block_sequence" => 0,
          "clock" => %{
            "clock_epoch" => clock_epoch,
            "timebase" => 90_000,
            "dts_source" => "pts_no_reordering",
            "utc_mapping" => "unknown"
          }
        },
        "format" => %{"codec" => "avc1.42c00a", "timescale" => 90_000},
        "init" => %{"length" => init_length, "sha256" => init_sha256},
        "media" => %{"length" => media_bytes, "sha256" => String.duplicate("e", 64)},
        "fragments" => fragments
      }
    }
  end
end
