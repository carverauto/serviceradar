defmodule ServiceRadarWebNG.CameraTimelinePlaylist do
  @moduledoc """
  Pure multi-block HLS v7 VOD playlist serializer for unified camera timeline
  playback (`D.2`, `D.3`, `D2`, `D4`).

  Performs zero storage or database I/O. Given an authorized timeline window with
  sealed non-quarantined catalog entries, their frozen descriptors, and recorded
  gaps, renders a bounded VOD playlist (`<= 60 minutes`, `<= 2,048` segments,
  `<= 256 KiB`) with:
  - `#EXT-X-MAP` emitted only when `init_sha256` changes so consecutive blocks
    sharing an initialization segment reuse one map URI;
  - `#EXT-X-DISCONTINUITY` on `init_sha256` changes, `clock_epoch` changes, clock
    re-anchors, recorded `RecordingGap` intervals between blocks, or non-contiguous
    fMP4/timeline timestamps;
  - `#EXT-X-PROGRAM-DATE-TIME` at playlist start and after every discontinuity;
  - exact 9-decimal `#EXTINF` durations and relative block init/fragment URIs
    carrying `?source=<auto|local|archive>`.
  """

  @second_ns 1_000_000_000
  @max_window_us 3_600_000_000
  @max_segments 2_048
  @max_playlist_bytes 262_144
  @max_init_bytes 1_048_576
  @max_fragment_bytes 4_194_304
  @hex64 ~r/\A[0-9a-f]{64}\z/

  @type render_stats :: %{
          playlist: binary(),
          segment_count: pos_integer(),
          discontinuity_count: non_neg_integer(),
          map_count: pos_integer()
        }

  @spec render(map(), keyword()) :: {:ok, binary()} | {:error, atom()}
  def render(window, opts \\ []) when is_map(window) and is_list(opts) do
    with {:ok, %{playlist: playlist}} <- render_with_stats(window, opts) do
      {:ok, playlist}
    end
  end

  @spec render_with_stats(map(), keyword()) :: {:ok, render_stats()} | {:error, atom()}
  def render_with_stats(window, opts \\ []) when is_map(window) and is_list(opts) do
    from_us = Keyword.get_lazy(opts, :from_us, fn -> fetch_val(window, :from_us) end)
    to_us = Keyword.get_lazy(opts, :to_us, fn -> fetch_val(window, :to_us) end)

    raw_source =
      Keyword.get_lazy(opts, :source_mode, fn ->
        fetch_val(window, :source_mode) || fetch_val(window, :source) || :auto
      end)

    with {:ok, source_str} <- normalize_source(raw_source),
         :ok <- validate_window_bounds(from_us, to_us),
         {:ok, blocks} <- extract_playable_blocks(window, source_str),
         {:ok, gaps} <- extract_gaps(window),
         {:ok, segments} <- collect_segments(blocks, from_us, to_us),
         :ok <- validate_segment_count(segments) do
      encode_playlist(segments, gaps, source_str)
    end
  end

  defp normalize_source(source) when source in [:auto, "auto", nil, ""], do: {:ok, "auto"}
  defp normalize_source(source) when source in [:local, "local"], do: {:ok, "local"}
  defp normalize_source(source) when source in [:archive, "archive"], do: {:ok, "archive"}
  defp normalize_source(_), do: {:error, :invalid_source_mode}

  defp validate_window_bounds(from_us, to_us) when is_integer(from_us) and is_integer(to_us) do
    cond do
      to_us <= from_us -> {:error, :invalid_recording_window}
      to_us - from_us > @max_window_us -> {:error, :recording_window_too_large}
      true -> :ok
    end
  end

  defp validate_window_bounds(_, _), do: {:error, :invalid_recording_window}

  defp extract_playable_blocks(window, source_str) do
    raw_blocks = fetch_val(window, :blocks) || fetch_val(window, :entries) || []

    if is_list(raw_blocks) do
      playable =
        raw_blocks
        |> Enum.filter(&playable_for_source?(&1, source_str))
        |> Enum.sort_by(fn block ->
          {
            fetch_val(block, :timeline_start_us) || 0,
            to_string(fetch_val(block, :block_key) || ""),
            to_string(fetch_val(block, :id) || "")
          }
        end)

      {:ok, playable}
    else
      {:error, :invalid_recording_window}
    end
  end

  defp playable_for_source?(block, source_str) when is_map(block) do
    local_state = normalize_state(fetch_val(block, :local_state))
    archive_state = normalize_state(fetch_val(block, :archive_state))

    cond do
      local_state == "quarantined" ->
        false

      is_nil(local_state) and is_nil(archive_state) ->
        true

      source_str == "local" ->
        local_state == "present"

      source_str == "archive" ->
        archive_state == "verified"

      true ->
        local_state == "present" or archive_state == "verified"
    end
  end

  defp playable_for_source?(_, _), do: false

  defp normalize_state(nil), do: nil
  defp normalize_state(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_state(value) when is_binary(value), do: value
  defp normalize_state(_), do: nil

  defp extract_gaps(window) do
    case fetch_val(window, :gaps) || [] do
      gaps when is_list(gaps) ->
        normalized =
          for gap <- gaps,
              is_map(gap),
              start_us = fetch_val(gap, :start_us),
              is_integer(start_us) do
            %{start_us: start_us, end_us: fetch_val(gap, :end_us)}
          end

        {:ok, normalized}

      _ ->
        {:error, :invalid_recording_window}
    end
  end

  defp collect_segments(blocks, from_us, to_us) do
    blocks
    |> Enum.reduce_while({:ok, []}, fn block, {:ok, acc} ->
      case block_segments(block, from_us, to_us) do
        {:ok, []} -> {:cont, {:ok, acc}}
        {:ok, segs} -> {:cont, {:ok, [segs | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, nested} -> {:ok, nested |> Enum.reverse() |> List.flatten()}
      {:error, _} = err -> err
    end
  end

  defp block_segments(block, from_us, to_us) do
    with {:ok, entry_id} <- cast_entry_id(fetch_val(block, :id) || fetch_val(block, :entry_id)),
         {:ok, descriptor} <- resolve_descriptor(block),
         {:ok, timeline_start_us} <- require_integer(fetch_val(block, :timeline_start_us)),
         {:ok, fragments} <- resolve_fragments(descriptor),
         {:ok, block_media_start_ns} <- resolve_block_media_start_ns(block, fragments) do
      overlapping =
        Enum.flat_map(fragments, fn fragment ->
          build_overlapping_fragment(
            fragment,
            timeline_start_us,
            block_media_start_ns,
            from_us,
            to_us
          )
        end)

      if overlapping == [] do
        {:ok, []}
      else
        validate_and_decorate_block_segments(block, entry_id, descriptor, overlapping)
      end
    end
  end

  defp build_overlapping_fragment(fragment, timeline_start_us, block_media_start_ns, from_us, to_us)
       when is_map(fragment) do
    seq = fetch_val(fragment, :sequence)
    start_ns = fetch_val(fragment, :start_ns)
    duration_ns = fetch_val(fragment, :duration_ns)
    length = fetch_val(fragment, :length)

    if is_integer(seq) and seq >= 0 and is_integer(start_ns) and start_ns >= 0 and
         is_integer(duration_ns) and duration_ns >= 1 and is_integer(length) do
      offset_ns = max(start_ns - block_media_start_ns, 0)
      frag_start_us = timeline_start_us + div(offset_ns, 1_000)
      raw_end_us = timeline_start_us + div(offset_ns + duration_ns, 1_000)
      overlap_end_us = max(raw_end_us, frag_start_us + 1)

      if overlap_end_us > from_us and frag_start_us < to_us do
        [
          %{
            sequence: seq,
            start_ns: start_ns,
            end_ns: start_ns + duration_ns,
            duration_ns: duration_ns,
            length: length,
            start_us: frag_start_us,
            end_us: raw_end_us
          }
        ]
      else
        []
      end
    else
      [:invalid_fragment]
    end
  end

  defp build_overlapping_fragment(_, _, _, _, _), do: [:invalid_fragment]

  defp validate_and_decorate_block_segments(block, entry_id, descriptor, overlapping) do
    init = fetch_val(descriptor, :init)
    init_length = if is_map(init), do: fetch_val(init, :length)

    init_sha256 =
      fetch_val(block, :init_sha256) || if is_map(init), do: fetch_val(init, :sha256)

    clock_epoch =
      fetch_val(block, :clock_epoch) ||
        descriptor_clock_epoch(descriptor)

    reanchored? = fetch_val(block, :reanchored) == true or fetch_val(block, :reanchored?) == true

    cond do
      Enum.any?(overlapping, &(&1 == :invalid_fragment)) ->
        {:error, :invalid_recording_window}

      not is_integer(init_length) or init_length < 1 ->
        {:error, :invalid_recording_window}

      init_length > @max_init_bytes ->
        {:error, :recording_window_too_large}

      not valid_sha256?(init_sha256) ->
        {:error, :invalid_recording_window}

      Enum.any?(overlapping, &(&1.length < 1)) ->
        {:error, :invalid_recording_window}

      Enum.any?(overlapping, &(&1.length > @max_fragment_bytes)) ->
        {:error, :recording_window_too_large}

      true ->
        [first_seg | rest] = overlapping

        decorated = [
          decorate_segment(first_seg, entry_id, init_sha256, clock_epoch, reanchored?)
          | Enum.map(rest, &decorate_segment(&1, entry_id, init_sha256, clock_epoch, false))
        ]

        {:ok, decorated}
    end
  end

  defp decorate_segment(seg, entry_id, init_sha256, clock_epoch, reanchored?) do
    Map.merge(seg, %{
      entry_id: entry_id,
      init_sha256: init_sha256,
      clock_epoch: clock_epoch,
      reanchored?: reanchored?
    })
  end

  defp descriptor_clock_epoch(descriptor) do
    with identity when is_map(identity) <- fetch_val(descriptor, :identity),
         clock when is_map(clock) <- fetch_val(identity, :clock) do
      fetch_val(clock, :clock_epoch)
    else
      _ -> nil
    end
  end

  defp validate_segment_count([]), do: {:error, :recording_unavailable}

  defp validate_segment_count(segments) when length(segments) > @max_segments, do: {:error, :recording_window_too_large}

  defp validate_segment_count(_segments), do: :ok

  defp encode_playlist([first | rest] = segments, gaps, source_str) do
    max_duration_ns = segments |> Enum.map(& &1.duration_ns) |> Enum.max()
    target_duration = max(div(max_duration_ns + @second_ns - 1, @second_ns), 1)

    first_io = [
      map_tag(first.entry_id, source_str),
      program_date_time_tag(first.start_us),
      extinf_tag(first, source_str)
    ]

    {rest_io, {_prev, disc_count, map_count}} =
      Enum.map_reduce(rest, {first, 0, 1}, fn seg, {prev, discs, maps} ->
        init_changed? = seg.init_sha256 != prev.init_sha256
        discontinuity? = discontinuity_between?(prev, seg, gaps, init_changed?)

        tags = [
          if(discontinuity?, do: "#EXT-X-DISCONTINUITY\n", else: []),
          if(init_changed?, do: map_tag(seg.entry_id, source_str), else: []),
          if(discontinuity?, do: program_date_time_tag(seg.start_us), else: []),
          extinf_tag(seg, source_str)
        ]

        next_discs = if discontinuity?, do: discs + 1, else: discs
        next_maps = if init_changed?, do: maps + 1, else: maps

        {tags, {seg, next_discs, next_maps}}
      end)

    playlist =
      IO.iodata_to_binary([
        "#EXTM3U\n",
        "#EXT-X-VERSION:7\n",
        "#EXT-X-PLAYLIST-TYPE:VOD\n",
        "#EXT-X-TARGETDURATION:#{target_duration}\n",
        "#EXT-X-MEDIA-SEQUENCE:0\n",
        first_io,
        rest_io,
        "#EXT-X-ENDLIST\n"
      ])

    if byte_size(playlist) <= @max_playlist_bytes do
      {:ok,
       %{
         playlist: playlist,
         segment_count: length(segments),
         discontinuity_count: disc_count,
         map_count: map_count
       }}
    else
      {:error, :recording_window_too_large}
    end
  end

  defp discontinuity_between?(prev, curr, gaps, init_changed?) do
    epoch_changed? = curr.clock_epoch != prev.clock_epoch
    reanchored_boundary? = curr.entry_id != prev.entry_id and curr.reanchored?
    gap? = gap_between?(gaps, prev.start_us, prev.end_us, curr.start_us)
    media_ts_discontinuous? = curr.start_ns != prev.end_ns
    timeline_ts_discontinuous? = abs(curr.start_us - prev.end_us) > 1

    init_changed? or epoch_changed? or reanchored_boundary? or gap? or media_ts_discontinuous? or
      timeline_ts_discontinuous?
  end

  defp gap_between?(gaps, prev_start_us, prev_end_us, curr_start_us) do
    Enum.any?(gaps, fn %{start_us: g_start, end_us: g_end} ->
      g_start <= curr_start_us and
        (is_nil(g_end) or g_end >= prev_end_us) and
        not (is_integer(g_end) and g_end <= prev_start_us)
    end)
  end

  defp map_tag(entry_id, source_str) do
    "#EXT-X-MAP:URI=\"blocks/#{entry_id}/init?source=#{source_str}\"\n"
  end

  defp program_date_time_tag(timestamp_us) do
    iso = timestamp_us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()
    "#EXT-X-PROGRAM-DATE-TIME:#{iso}\n"
  end

  defp extinf_tag(seg, source_str) do
    [
      "#EXTINF:",
      seconds(seg.duration_ns),
      ",\nblocks/#{seg.entry_id}/fragments/#{seg.sequence}?source=#{source_str}\n"
    ]
  end

  defp seconds(nanoseconds) do
    fraction = nanoseconds |> rem(@second_ns) |> Integer.to_string() |> String.pad_leading(9, "0")
    "#{div(nanoseconds, @second_ns)}.#{fraction}"
  end

  defp cast_entry_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_recording_window}
    end
  end

  defp cast_entry_id(_), do: {:error, :invalid_recording_window}

  defp resolve_descriptor(block) do
    descriptor =
      fetch_val(block, :descriptor) ||
        fetch_val(block, :frozen_descriptor) ||
        case fetch_val(block, :recording_block) do
          rb when is_map(rb) -> fetch_val(rb, :frozen_descriptor)
          _ -> nil
        end

    if is_map(descriptor), do: {:ok, descriptor}, else: {:error, :recording_unavailable}
  end

  defp resolve_fragments(descriptor) do
    case fetch_val(descriptor, :fragments) do
      fragments when is_list(fragments) and fragments != [] -> {:ok, fragments}
      _ -> {:error, :recording_unavailable}
    end
  end

  defp resolve_block_media_start_ns(block, [first_fragment | _]) do
    case fetch_val(block, :media_start_ns) || fetch_val(first_fragment, :start_ns) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, :invalid_recording_window}
    end
  end

  defp require_integer(value) when is_integer(value), do: {:ok, value}
  defp require_integer(_), do: {:error, :invalid_recording_window}

  defp valid_sha256?(value) when is_binary(value), do: Regex.match?(@hex64, value)
  defp valid_sha256?(_), do: false

  defp fetch_val(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
