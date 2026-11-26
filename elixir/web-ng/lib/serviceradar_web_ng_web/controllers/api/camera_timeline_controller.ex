defmodule ServiceRadarWebNGWeb.Api.CameraTimelineController do
  @moduledoc """
  Authenticated timeline coverage, multi-block HLS v7 VOD playlists, bounded
  copy-resolved init/fragment reads, and bounded JPEG clip thumbnails for
  recorded cameras (`D.3`, `D.4`, `design.md` `D1`–`D7`, `spec.md:614-677`).
  """

  use ServiceRadarWebNGWeb, :controller

  alias Ash.Error.Forbidden
  alias ServiceRadar.Camera.RecordingTimeline
  alias ServiceRadar.Camera.Thumbnail
  alias ServiceRadarWebNG.CameraTimelineAdmission
  alias ServiceRadarWebNG.CameraTimelinePlaylist
  alias ServiceRadarWebNG.CameraTimelineReader
  alias ServiceRadarWebNGWeb.CameraArchiveAccess

  @request_deadline_ms 12_000

  def coverage(conn, %{"camera_source_id" => source_id} = params) do
    conn = private_media(conn)
    extra_core_opts = Map.get(conn.private, :camera_timeline_core_opts, [])

    with {:ok, scope, source} <-
           CameraArchiveAccess.source(conn.assigns[:current_scope], source_id),
         {:ok, data} <-
           RecordingTimeline.coverage(
             source.id,
             params,
             Keyword.put(extra_core_opts, :scope, scope)
           ) do
      json(conn, %{data: serialize_coverage(data)})
    else
      {:error, reason} -> timeline_error(conn, reason)
    end
  end

  def playlist(conn, %{"camera_source_id" => source_id} = params) do
    conn = private_media(conn)
    extra_core_opts = Map.get(conn.private, :camera_timeline_core_opts, [])

    with {:ok, scope, source} <-
           CameraArchiveAccess.source(conn.assigns[:current_scope], source_id),
         true <- get_req_header(conn, "range") == [] || {:error, :invalid_range_header},
         core_opts = Keyword.merge(extra_core_opts, scope: scope, record_audit?: false),
         {:ok, window} <-
           RecordingTimeline.issue_playlist_window(source.id, params, core_opts),
         {:ok, stats} <-
           CameraTimelinePlaylist.render_with_stats(window, source_mode: window.source_mode),
         {:ok, _audit} <-
           RecordingTimeline.record_playlist_audit(
             %{
               camera_source_id: source.id,
               stream_profile_id: window.stream_profile_id,
               window_start_us: window.from_us,
               window_end_us: window.to_us,
               source_mode: window.source_mode,
               time_basis: window.time_basis,
               segment_count: stats.segment_count,
               details: %{
                 "entry_count" => length(window.entries),
                 "discontinuity_count" => stats.discontinuity_count,
                 "map_count" => stats.map_count
               }
             },
             Keyword.put(extra_core_opts, :scope, scope)
           ) do
      conn
      |> put_resp_content_type("application/vnd.apple.mpegurl", nil)
      |> send_resp(200, stats.playlist)
    else
      {:error, reason} -> timeline_error(conn, reason)
    end
  end

  def init_object(conn, params), do: read_object(conn, params, :init)

  def fragment(conn, params) do
    selector =
      case decimal(params["index"], 0, 4_095) do
        {:ok, index} -> {:fragment, index}
        _ -> :invalid
      end

    read_object(conn, params, selector)
  end

  def thumbnail(conn, %{"camera_source_id" => source_id, "kind" => kind, "id" => raw_id}) do
    with {:ok, _scope, source} <-
           CameraArchiveAccess.source(conn.assigns[:current_scope], source_id),
         {:ok, normalized_kind} <- parse_thumbnail_kind(kind),
         {:ok, record_id} <- parse_thumbnail_id(raw_id),
         {:ok, jpeg_bytes} <-
           Thumbnail.fetch_for_camera(source.id, normalized_kind, record_id) do
      conn
      |> put_resp_header("cache-control", "private, max-age=300")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_content_type("image/jpeg", nil)
      |> send_resp(200, jpeg_bytes)
    else
      {:error, reason} ->
        conn
        |> private_media()
        |> timeline_error(reason)
    end
  end

  defp read_object(conn, %{"camera_source_id" => source_id, "entry_id" => entry_id} = params, selector) do
    conn = private_media(conn)
    request_deadline_ms = System.monotonic_time(:millisecond) + @request_deadline_ms
    extra_core_opts = Map.get(conn.private, :camera_timeline_core_opts, [])
    admission_opts = Map.get(conn.private, :camera_timeline_admission, [])
    readers = Map.get(conn.private, :camera_timeline_readers)

    with {:ok, scope, source} <-
           CameraArchiveAccess.source(conn.assigns[:current_scope], source_id),
         true <-
           (selector != :invalid and get_req_header(conn, "range") == []) ||
             {:error, :invalid_id},
         {:ok, source_mode} <- parse_source_mode(params["source"]) do
      user_id = scope.user.id
      camera_uuid = source.id

      result =
        CameraTimelineAdmission.with_slot(user_id, camera_uuid, admission_opts, fn ->
          core_opts = Keyword.put(extra_core_opts, :scope, scope)

          reader_opts = [
            readers: readers,
            core_opts: core_opts,
            request_deadline_ms: request_deadline_ms
          ]

          with {:ok, plans} <-
                 RecordingTimeline.resolve_read_plans(
                   camera_uuid,
                   entry_id,
                   selector,
                   source_mode,
                   core_opts
                 ),
               {:ok, fetched} <-
                 CameraTimelineReader.execute_plans(plans, source_mode, reader_opts),
               {:ok, _refreshed_scope, refreshed_source} <-
                 CameraArchiveAccess.source(scope, camera_uuid),
               true <-
                 (refreshed_source.id == camera_uuid and
                    System.monotonic_time(:millisecond) < request_deadline_ms) ||
                   {:error, :reader_unavailable} do
            {:ok, fetched}
          end
        end)

      case result do
        {:ok, %{bytes: bytes, copy_header: copy_header}} ->
          conn
          |> put_resp_header("x-recording-copy", copy_header)
          |> put_resp_content_type("video/mp4", nil)
          |> send_resp(200, bytes)

        {:error, reason} ->
          timeline_error(conn, reason)
      end
    else
      {:error, reason} -> timeline_error(conn, reason)
    end
  end

  defp parse_source_mode(val) when val in [nil, "", "auto"], do: {:ok, :auto}
  defp parse_source_mode("local"), do: {:ok, :local}
  defp parse_source_mode("archive"), do: {:ok, :archive}
  defp parse_source_mode(_), do: {:error, :invalid_source_mode}

  defp parse_thumbnail_kind("frame"), do: {:ok, :frame}
  defp parse_thumbnail_kind("block"), do: {:ok, :block}
  defp parse_thumbnail_kind("vantage"), do: {:ok, :vantage}
  defp parse_thumbnail_kind(_), do: {:error, :invalid_id}

  defp parse_thumbnail_id(raw_id) when is_binary(raw_id) do
    trimmed =
      if String.ends_with?(raw_id, ".jpg") do
        String.replace_suffix(raw_id, ".jpg", "")
      else
        raw_id
      end

    case Ecto.UUID.cast(trimmed) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_id}
    end
  end

  defp parse_thumbnail_id(_), do: {:error, :invalid_id}

  defp decimal(value, minimum, maximum) when is_binary(value) and byte_size(value) in 1..4 do
    case Integer.parse(value) do
      {integer, ""} when integer >= minimum and integer <= maximum ->
        if Integer.to_string(integer) == value, do: {:ok, integer}, else: {:error, :invalid_id}

      _ ->
        {:error, :invalid_id}
    end
  end

  defp decimal(_, _, _), do: {:error, :invalid_id}

  defp private_media(conn) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
  end

  defp serialize_coverage(data) when is_map(data) do
    %{
      camera_source_id: data.camera_source_id,
      stream_profile_id: data.stream_profile_id,
      from_us: data.from_us,
      to_us: data.to_us,
      bucket_count: data.bucket_count,
      scheduled_continuous?: data.scheduled_continuous?,
      time_basis: to_string(data.time_basis),
      time_uncertainty: to_string(data.time_uncertainty),
      buckets: Enum.map(data.buckets, &serialize_bucket/1),
      blocks: Enum.map(data.blocks, &serialize_block/1),
      gaps: Enum.map(data.gaps, &serialize_gap/1),
      holds: Enum.map(data.holds, &serialize_hold/1),
      reanchors: data.reanchors
    }
  end

  defp serialize_bucket(bucket) do
    %{
      index: bucket.index,
      start_us: bucket.start_us,
      end_us: bucket.end_us,
      state: to_string(bucket.state),
      states: Enum.map(bucket.states, &to_string/1),
      block_count: bucket.block_count,
      gap_count: bucket.gap_count,
      gap_reasons: Enum.map(bucket.gap_reasons, &to_string/1),
      provisional?: bucket.provisional?,
      reanchored?: bucket.reanchored?,
      held?: bucket.held?
    }
  end

  defp serialize_block(block) do
    %{
      id: block.id,
      entry_id: block.entry_id,
      recording_block_id: block.recording_block_id,
      camera_source_id: block.camera_source_id,
      stream_profile_id: block.stream_profile_id,
      storage_id: block.storage_id,
      block_key: block.block_key,
      clock_epoch: block.clock_epoch,
      run_id: block.run_id,
      anchor_id: block.anchor_id,
      timeline_start_us: block.timeline_start_us,
      timeline_end_us: block.timeline_end_us,
      media_start_ns: block.media_start_ns,
      media_end_ns: block.media_end_ns,
      fragment_count: block.fragment_count,
      media_bytes: block.media_bytes,
      local_state: atom_or_nil_string(block.local_state),
      archive_state: atom_or_nil_string(block.archive_state),
      archive_deleted_reason: atom_or_nil_string(block.archive_deleted_reason),
      copy_state: to_string(block.copy_state),
      playable?: block.playable?,
      provisional?: block.provisional?,
      reanchored?: block.reanchored?,
      contiguous_with_previous?: block.contiguous_with_previous?,
      time_basis: to_string(block.time_basis),
      time_uncertainty: to_string(block.time_uncertainty),
      time_uncertainty_us: block.time_uncertainty_us,
      hold_summary: serialize_hold_summary(block.hold_summary)
    }
  end

  defp serialize_hold_summary(summary) when is_map(summary) do
    %{
      pinned_copy: atom_or_nil_string(summary.pinned_copy),
      hold_count: summary.hold_count,
      kinds: Enum.map(summary.kinds, &to_string/1),
      hold_ids: summary.hold_ids,
      archive_missing?: summary.archive_missing?
    }
  end

  defp serialize_gap(gap) do
    %{
      id: gap.id,
      camera_source_id: gap.camera_source_id,
      stream_profile_id: gap.stream_profile_id,
      storage_id: gap.storage_id,
      run_id: gap.run_id,
      clock_epoch: gap.clock_epoch,
      start_us: gap.start_us,
      end_us: gap.end_us,
      effective_end_us: gap.effective_end_us,
      open?: gap.open?,
      media_gap_ns: gap.media_gap_ns,
      reason: atom_or_nil_string(gap.reason),
      detail_class: gap.detail_class,
      time_basis: to_string(gap.time_basis),
      time_uncertainty: to_string(gap.time_uncertainty)
    }
  end

  defp serialize_hold(hold) do
    %{
      id: hold.id,
      camera_source_id: hold.camera_source_id,
      stream_profile_id: hold.stream_profile_id,
      start_us: hold.start_us,
      end_us: hold.end_us,
      kind: atom_or_nil_string(hold.kind),
      state: atom_or_nil_string(hold.state),
      reason: hold.reason,
      created_by_id: hold.created_by_id,
      accepted_at: hold.accepted_at,
      released_by_id: hold.released_by_id,
      released_at: hold.released_at,
      release_reason: hold.release_reason,
      unavailable_blocks: hold.unavailable_blocks,
      pinned_copy: atom_or_nil_string(hold.pinned_copy),
      archive_missing?: hold.archive_missing?
    }
  end

  defp atom_or_nil_string(nil), do: nil
  defp atom_or_nil_string(val), do: to_string(val)

  defp timeline_error(conn, :playback_capacity_exhausted) do
    conn
    |> put_resp_header("retry-after", "1")
    |> put_status(:service_unavailable)
    |> json(%{error: "playback_capacity_exhausted"})
  end

  defp timeline_error(conn, :unauthorized), do: error(conn, :unauthorized, "unauthorized")
  defp timeline_error(conn, :permission_revoked), do: error(conn, :forbidden, "forbidden")
  defp timeline_error(conn, %Forbidden{}), do: error(conn, :forbidden, "forbidden")

  defp timeline_error(conn, reason)
       when reason in [
              :invalid_id,
              :invalid_camera_source_id,
              :invalid_entry_id,
              :invalid_stream_profile_id,
              :invalid_bucket_count,
              :invalid_source_mode,
              :invalid_selector,
              :invalid_range_header,
              :invalid_timeline_window,
              :invalid_playlist_window
            ], do: error(conn, :bad_request, "invalid_request")

  defp timeline_error(conn, :thumbnail_not_found), do: error(conn, :not_found, "thumbnail_not_found")

  defp timeline_error(conn, reason)
       when reason in [:recording_block_not_found, :catalog_entry_not_found, :fragment_not_found],
       do: error(conn, :not_found, "recording_not_found")

  defp timeline_error(conn, :recording_integrity_failed), do: error(conn, :conflict, "recording_integrity_failed")

  # No archive reader is installed; this is a lasting configuration state, not a retry.
  defp timeline_error(conn, :archive_reader_not_installed), do: error(conn, :conflict, "archive_playback_not_available")

  defp timeline_error(conn, reason)
       when reason in [
              :recording_unavailable,
              :archive_unavailable,
              :archive_key_family_mismatch,
              :archive_receipt_mismatch
            ], do: error(conn, :conflict, "recording_unavailable")

  defp timeline_error(conn, reason) when reason in [:invalid_recording_range, :recording_range_too_large],
    do: error(conn, 416, "recording_range_not_satisfiable")

  defp timeline_error(conn, reason)
       when reason in [
              :invalid_recording_window,
              :recording_window_too_large,
              :timeline_window_too_large,
              :playlist_window_too_large
            ], do: error(conn, 416, "recording_window_not_satisfiable")

  defp timeline_error(conn, _reason), do: error(conn, :service_unavailable, "recording_read_unavailable")

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
