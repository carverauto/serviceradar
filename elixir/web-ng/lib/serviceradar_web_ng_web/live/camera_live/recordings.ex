defmodule ServiceRadarWebNGWeb.CameraLive.Recordings do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias Ash.Error.Forbidden
  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveUploads
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingEventClips
  alias ServiceRadar.Camera.RecordingHolds
  alias ServiceRadar.Camera.RecordingPubSub
  alias ServiceRadar.Camera.RecordingTimeline
  alias ServiceRadar.Repo
  alias ServiceRadar.TimeZone
  alias ServiceRadarWebNG.CameraArchiveWindow
  alias ServiceRadarWebNG.CameraRecordingSettings
  alias ServiceRadarWebNG.CameraTimelineReader
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.CameraArchiveAccess
  alias ServiceRadarWebNGWeb.CameraLive.RecordingsComponents
  alias ServiceRadarWebNGWeb.CameraSemanticSearch

  require Ash.Query
  require Logger

  @recording_view_permissions ["devices.view", "devices.cameras.recordings.view"]
  @recording_hold_permissions [
    "devices.view",
    "devices.cameras.recordings.view",
    "devices.cameras.recordings.hold"
  ]

  @recording_settings_permissions [
    "settings.recording.view",
    "settings.recording.manage",
    "settings.recording.operate"
  ]

  @max_playlist_window_us 3_600_000_000
  @default_refresh_interval_ms 15_000
  @default_debounce_ms 500

  @span_durations_us %{
    "1h" => 3_600_000_000,
    "6h" => 6 * 3_600_000_000,
    "24h" => 24 * 3_600_000_000,
    "7d" => 7 * 24 * 3_600_000_000
  }

  @impl true
  def mount(%{"camera_source_id" => source_id}, _session, socket) do
    path = "/cameras/#{source_id}/recordings"

    socket =
      socket
      |> assign(
        page_title: "Camera Recordings",
        current_path: path,
        srql: %{enabled: false, page_path: path},
        camera_source_id: source_id,
        source: nil,
        mode: :published,
        requested_mode: nil,
        items: [],
        next_cursor: nil,
        selected: nil,
        stream_profiles: [],
        timeline_profile_id: "",
        timeline_span: "1h",
        timeline_source: "auto",
        timeline_custom_from_us: nil,
        timeline_anchor_to_us: nil,
        timeline_coverage: nil,
        timeline_playlist_path: nil,
        timeline_play_from_us: nil,
        timeline_play_to_us: nil,
        timeline_playlist_origin_us: nil,
        timeline_seek_us: nil,
        timeline_seek_offset_seconds: 0.0,
        timeline_highlight_frame_id: nil,
        timeline_search_query: "",
        timeline_search_object_class: "",
        timeline_search_results: [],
        timeline_search_executed?: false,
        timeline_search_error: nil,
        timeline_embedder_unavailable?: false,
        timeline_overlay_detections: [],
        timeline_jump_at: "",
        timeline_has_adjacent_window: false,
        timeline_holds: [],
        timeline_event_clips: [],
        timeline_clips_mode: "all",
        timeline_clips_category: "all",
        timeline_selected_clip_id: nil,
        timeline_user_selected_window?: false,
        recording_subscribed_source_id: nil,
        recording_refresh_timer_ref: nil,
        recording_refresh_token: nil,
        recording_debounce_timer_ref: nil,
        recording_debounce_token: nil,
        hold_form: to_form(default_hold_form_params(nil, nil, "Etc/UTC", false), as: :hold),
        error: nil,
        loading: true
      )
      |> assign_new(:recording_refresh_interval_ms, fn -> @default_refresh_interval_ms end)
      |> assign_new(:recording_debounce_ms, fn -> @default_debounce_ms end)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    source_id =
      case params["camera_source_id"] do
        id when is_binary(id) and id != "" -> id
        _ -> socket.assigns.camera_source_id
      end

    path = "/cameras/#{source_id}/recordings"
    requested_mode = parse_mode_param(params["mode"])
    span = parse_span_param(params["span"])
    source_mode = parse_source_param(params["source"])
    profile_id = parse_profile_param(params["profile"])
    custom_from_us = parse_optional_int(params["from"])
    custom_to_us = parse_optional_int(params["to"])
    seek_us = parse_non_neg_int(params["seek"])
    highlight_frame_id = parse_optional_uuid(params["highlight_frame"])
    search_query = parse_search_query_param(params["q"])
    search_object_class = parse_object_class_param(params["object_class"])

    inferred_mode =
      cond do
        requested_mode in [:timeline, :published] ->
          requested_mode

        not is_nil(seek_us) or not is_nil(highlight_frame_id) or search_query != "" ->
          :timeline

        true ->
          nil
      end

    socket =
      assign(socket,
        camera_source_id: source_id,
        current_path: path,
        srql: %{enabled: false, page_path: path},
        requested_mode: inferred_mode,
        mode: inferred_mode || socket.assigns.mode,
        timeline_span: span,
        timeline_source: source_mode,
        timeline_profile_id: profile_id,
        timeline_custom_from_us: custom_from_us,
        timeline_anchor_to_us: custom_to_us,
        timeline_seek_us: seek_us,
        timeline_highlight_frame_id: highlight_frame_id,
        timeline_selected_clip_id: nil,
        timeline_user_selected_window?: false,
        timeline_search_query:
          if(Map.has_key?(params, "q"), do: search_query, else: socket.assigns.timeline_search_query),
        timeline_search_object_class:
          if(Map.has_key?(params, "object_class"),
            do: search_object_class,
            else: socket.assigns.timeline_search_object_class
          )
      )

    if connected?(socket) do
      {:noreply, load_initial_or_switched_mode(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <RecordingsComponents.recordings
        source={@source}
        mode={@mode}
        items={@items}
        next_cursor={@next_cursor}
        selected={@selected}
        error={@error}
        loading={@loading}
        timezone={@current_scope.user.timezone || "Etc/UTC"}
        can_view_recording_settings={can_view_recording_settings?(@current_scope)}
        can_manage_holds={RBAC.can?(@current_scope, "devices.cameras.recordings.hold")}
        stream_profiles={@stream_profiles}
        timeline_profile_id={@timeline_profile_id}
        timeline_span={@timeline_span}
        timeline_source={@timeline_source}
        timeline_coverage={@timeline_coverage}
        archive_playback_available={CameraTimelineReader.archive_reader_installed?()}
        timeline_playlist_path={@timeline_playlist_path}
        timeline_play_from_us={@timeline_play_from_us}
        timeline_play_to_us={@timeline_play_to_us}
        timeline_playlist_origin_us={@timeline_playlist_origin_us}
        timeline_seek_offset_seconds={@timeline_seek_offset_seconds}
        timeline_highlight_frame_id={@timeline_highlight_frame_id}
        timeline_search_query={@timeline_search_query}
        timeline_search_object_class={@timeline_search_object_class}
        timeline_search_results={@timeline_search_results}
        timeline_search_executed?={@timeline_search_executed?}
        timeline_search_error={@timeline_search_error}
        timeline_embedder_unavailable?={@timeline_embedder_unavailable?}
        timeline_overlay_detections={@timeline_overlay_detections}
        timeline_jump_at={@timeline_jump_at}
        timeline_has_adjacent_window={@timeline_has_adjacent_window}
        timeline_holds={@timeline_holds}
        timeline_event_clips={@timeline_event_clips}
        timeline_clips_mode={@timeline_clips_mode}
        timeline_clips_category={@timeline_clips_category}
        timeline_selected_clip_id={@timeline_selected_clip_id}
        hold_form={@hold_form}
      />
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("switch_recordings_mode", %{"mode" => raw_mode}, socket) do
    case parse_mode_param(raw_mode) do
      :timeline ->
        socket = assign(socket, mode: :timeline, requested_mode: :timeline, error: nil)
        {:noreply, load_timeline(socket)}

      :published ->
        socket = assign(socket, mode: :published, requested_mode: :published, error: nil)
        {:noreply, load_inventory(socket, nil)}

      nil ->
        {:noreply, authorize_only_or_unavailable(socket)}
    end
  end

  def handle_event("refresh_recordings", _, socket), do: {:noreply, load_inventory(socket, nil)}

  def handle_event("next_recordings", _, socket), do: {:noreply, load_inventory(socket, socket.assigns.next_cursor)}

  def handle_event("select_recording", %{"id" => block_id}, socket), do: {:noreply, select_recording(socket, block_id, 0)}

  def handle_event("recording_window", %{"direction" => direction}, socket) when direction in ["previous", "next"] do
    case socket.assigns.selected do
      nil ->
        {:noreply, load_inventory(socket, nil)}

      selected ->
        index = selected.window.index + if(direction == "next", do: 1, else: -1)
        {:noreply, select_recording(socket, selected.block_id, index)}
    end
  end

  def handle_event("refresh_timeline", _, socket) do
    {:noreply, load_timeline(socket)}
  end

  def handle_event("select_timeline_profile", params, socket) do
    profile_id = parse_profile_param(params["stream_profile_id"])

    socket =
      assign(socket,
        timeline_profile_id: profile_id,
        error: nil
      )

    {:noreply, load_timeline(socket)}
  end

  def handle_event("select_timeline_span", %{"span" => span}, socket) do
    if Map.has_key?(@span_durations_us, span) do
      socket =
        assign(socket,
          timeline_span: span,
          timeline_custom_from_us: nil,
          error: nil
        )

      {:noreply, load_timeline(socket)}
    else
      {:noreply, authorize_only_or_unavailable(socket)}
    end
  end

  def handle_event("select_timeline_source", %{"source" => source}, socket) do
    if source in ["auto", "local", "archive"] do
      socket = assign(socket, timeline_source: source, error: nil)
      {:noreply, load_timeline(socket)}
    else
      {:noreply, authorize_only_or_unavailable(socket)}
    end
  end

  def handle_event("navigate_timeline_window", %{"direction" => direction}, socket) do
    span_us = Map.fetch!(@span_durations_us, socket.assigns.timeline_span)
    now_us = System.system_time(:microsecond)
    current_to_us = socket.assigns.timeline_anchor_to_us || now_us

    next_anchor_to_us =
      case direction do
        "previous" -> max(current_to_us - span_us, span_us)
        "next" -> min(current_to_us + span_us, now_us)
        "latest" -> nil
        _ -> current_to_us
      end

    socket =
      assign(socket,
        timeline_custom_from_us: nil,
        timeline_anchor_to_us: next_anchor_to_us,
        error: nil
      )

    {:noreply, load_timeline(socket)}
  end

  def handle_event("jump_timeline_to", params, socket) do
    raw_jump_at = Map.get(params, "jump_at", "")

    with {:ok, scope, source} <- authorize_timeline_view(socket),
         tz = user_timezone(scope),
         {:ok, target_us} <- parse_datetime_local_to_us(raw_jump_at, tz) do
      span_us = Map.fetch!(@span_durations_us, socket.assigns.timeline_span)
      now_us = System.system_time(:microsecond)

      {custom_from_us, anchor_to_us} =
        if target_us >= now_us do
          {nil, nil}
        else
          upper_us = min(target_us + span_us, now_us)
          {target_us, max(upper_us, target_us + 1_000_000)}
        end

      socket =
        socket
        |> assign(
          current_scope: scope,
          source: source,
          timeline_custom_from_us: custom_from_us,
          timeline_anchor_to_us: anchor_to_us,
          timeline_jump_at: format_us_for_datetime_local(target_us, tz, :floor, true),
          error: nil
        )
        |> load_timeline_for_authorized(scope, source)

      {:noreply, socket}
    else
      {:error, reason}
      when reason in [:unauthorized, :permission_revoked, :recording_block_not_found, :invalid_id] ->
        {:noreply, unavailable(socket, reason)}

      {:error, _reason} ->
        {:noreply, assign(socket, error: "Enter a valid calendar date and time to jump to.")}
    end
  end

  def handle_event("change_hold_form", params, socket) do
    hold_params = Map.get(params, "hold", params)

    case authorize_timeline_hold(socket) do
      {:ok, scope, source} ->
        merged =
          Map.merge(socket.assigns.hold_form.params, Map.take(hold_params, ["kind", "start_at", "end_at", "reason"]))

        {:noreply,
         assign(socket,
           current_scope: scope,
           source: source,
           hold_form: to_form(merged, as: :hold),
           error: nil
         )}

      {:error, reason} ->
        {:noreply, unavailable(socket, reason)}
    end
  end

  def handle_event("select_hold_preset", %{"preset" => preset}, socket) do
    case authorize_timeline_hold(socket) do
      {:ok, scope, source} ->
        tz = user_timezone(scope)
        now_us = System.system_time(:microsecond)

        {start_us, end_us} =
          case preset do
            "window" ->
              {socket.assigns.timeline_play_from_us || now_us - 15 * 60_000_000,
               socket.assigns.timeline_play_to_us || now_us}

            "15m" ->
              {now_us - 15 * 60_000_000, now_us}

            "1h" ->
              {now_us - 3_600_000_000, now_us}

            "24h" ->
              {now_us - 24 * 3_600_000_000, now_us}

            _ ->
              {socket.assigns.timeline_play_from_us, socket.assigns.timeline_play_to_us}
          end

        existing_params = socket.assigns.hold_form.params

        updated_params =
          start_us
          |> default_hold_form_params(end_us, tz, true)
          |> Map.put("kind", Map.get(existing_params, "kind", "investigation"))
          |> Map.put("reason", Map.get(existing_params, "reason", ""))

        {:noreply,
         assign(socket,
           current_scope: scope,
           source: source,
           hold_form: to_form(updated_params, as: :hold),
           error: nil
         )}

      {:error, reason} ->
        {:noreply, unavailable(socket, reason)}
    end
  end

  def handle_event("select_timeline_bucket", params, socket) do
    with {:ok, scope, source} <- authorize_timeline_view(socket),
         {:ok, bucket_start} <- parse_required_int(params["start_us"]),
         {:ok, bucket_end} <- parse_required_int(params["end_us"]),
         true <- bucket_end > bucket_start do
      tz = user_timezone(scope)
      cov = socket.assigns.timeline_coverage
      cov_to_us = (cov && cov.to_us) || bucket_end
      play_from_us = bucket_start
      play_to_us = min(bucket_start + @max_playlist_window_us, max(cov_to_us, bucket_end))

      playlist_path =
        build_playlist_path_if_playable(
          source.id,
          cov,
          play_from_us,
          play_to_us,
          socket.assigns.timeline_profile_id,
          socket.assigns.timeline_source
        )

      playlist_origin_us =
        compute_playlist_origin_us(cov, play_from_us, play_to_us, socket.assigns.timeline_source)

      overlay_detections =
        resolve_overlay_detections(
          source.id,
          play_from_us,
          play_to_us,
          nil,
          socket.assigns.timeline_search_results
        )

      has_adjacent? = adjacent_window_available?(play_to_us, cov_to_us, socket)

      {:noreply,
       assign(socket,
         current_scope: scope,
         source: source,
         timeline_selected_clip_id: nil,
         timeline_user_selected_window?: true,
         timeline_play_from_us: play_from_us,
         timeline_play_to_us: play_to_us,
         timeline_playlist_origin_us: playlist_origin_us,
         timeline_seek_us: nil,
         timeline_seek_offset_seconds: 0.0,
         timeline_highlight_frame_id: nil,
         timeline_overlay_detections: overlay_detections,
         timeline_jump_at: format_us_for_datetime_local(play_from_us, tz, :floor, true),
         timeline_playlist_path: playlist_path,
         timeline_has_adjacent_window: has_adjacent?,
         hold_form: to_form(default_hold_form_params(play_from_us, play_to_us, tz, true), as: :hold),
         error: nil
       )}
    else
      {:error, reason} -> {:noreply, unavailable(socket, reason)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("timeline_semantic_search", params, socket) do
    search_params = Map.get(params, "search", params)
    raw_query = String.trim(to_string(search_params["q"] || ""))
    object_class = parse_object_class_param(search_params["object_class"])

    socket =
      assign(socket,
        timeline_search_query: raw_query,
        timeline_search_object_class: object_class
      )

    case authorize_timeline_view(socket) do
      {:ok, scope, source} ->
        {cov_from_us, cov_to_us} = current_or_resolved_coverage_bounds(socket)

        socket =
          socket
          |> assign(current_scope: scope, source: source)
          |> run_timeline_semantic_search(scope, source.id, cov_from_us, cov_to_us)

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, unavailable(socket, reason)}
    end
  end

  def handle_event("clear_timeline_semantic_search", _params, socket) do
    case authorize_timeline_view(socket) do
      {:ok, scope, source} ->
        overlay_detections =
          resolve_overlay_detections(
            source.id,
            socket.assigns.timeline_play_from_us,
            socket.assigns.timeline_play_to_us,
            socket.assigns.timeline_highlight_frame_id,
            []
          )

        {:noreply,
         assign(socket,
           current_scope: scope,
           source: source,
           timeline_search_query: "",
           timeline_search_object_class: "",
           timeline_search_results: [],
           timeline_search_executed?: false,
           timeline_search_error: nil,
           timeline_embedder_unavailable?: false,
           timeline_overlay_detections: overlay_detections
         )}

      {:error, reason} ->
        {:noreply, unavailable(socket, reason)}
    end
  end

  def handle_event("select_timeline_semantic_hit", params, socket) do
    with {:ok, scope, source} <- authorize_timeline_view(socket),
         {:ok, seek_us} <- parse_required_int(params["seek_us"]) do
      clip_start_us = parse_non_neg_int(params["start_us"]) || seek_us
      clip_end_us = parse_non_neg_int(params["end_us"]) || max(clip_start_us + 2_000_000, seek_us)
      highlight_frame_id = parse_optional_uuid(params["frame_id"])
      cov = socket.assigns.timeline_coverage

      socket =
        assign(socket,
          current_scope: scope,
          source: source,
          timeline_selected_clip_id: nil,
          timeline_seek_us: seek_us,
          timeline_highlight_frame_id: highlight_frame_id,
          error: nil
        )

      socket =
        if is_map(cov) and seek_us >= cov.from_us and seek_us <= cov.to_us do
          focus_playback_on_hit(socket, scope, source, cov, clip_start_us, clip_end_us, seek_us)
        else
          reloaded =
            socket
            |> assign(
              timeline_custom_from_us: max(clip_start_us - 30_000_000, 0),
              timeline_anchor_to_us: clip_end_us + 30_000_000
            )
            |> load_timeline_for_authorized(scope, source)

          if is_nil(reloaded.assigns.error) do
            assign(reloaded, timeline_user_selected_window?: true)
          else
            reloaded
          end
        end

      {:noreply, socket}
    else
      {:error, reason}
      when reason in [:unauthorized, :permission_revoked, :recording_block_not_found, :invalid_id] ->
        {:noreply, unavailable(socket, reason)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("advance_timeline_window", _params, socket) do
    case authorize_timeline_view(socket) do
      {:ok, scope, source} ->
        socket = assign(socket, current_scope: scope, source: source)
        {:noreply, advance_playback_window(socket, source)}

      {:error, reason} ->
        {:noreply, unavailable(socket, reason)}
    end
  end

  def handle_event("filter_event_clips_mode", %{"mode" => raw_mode}, socket) do
    mode = parse_clips_mode(raw_mode)
    {:noreply, assign(socket, timeline_clips_mode: mode)}
  end

  def handle_event("filter_event_clips_category", %{"category" => raw_category}, socket) do
    category = parse_clips_category(raw_category)
    {:noreply, assign(socket, timeline_clips_category: category)}
  end

  def handle_event("reset_event_clip_filters", _params, socket) do
    {:noreply, assign(socket, timeline_clips_mode: "all", timeline_clips_category: "all")}
  end

  def handle_event("select_event_clip", %{"clip_id" => clip_id}, socket) do
    with {:ok, scope, source} <- authorize_timeline_view(socket),
         clip when is_map(clip) <- find_event_clip(socket.assigns.timeline_event_clips, clip_id) do
      cov = socket.assigns.timeline_coverage
      {:noreply, focus_playback_on_event_clip(socket, scope, source, cov, clip)}
    else
      {:error, reason} -> {:noreply, unavailable(socket, reason)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("place_timeline_hold", params, socket) do
    hold_params = Map.get(params, "hold", params)

    with {:ok, scope, source} <- authorize_timeline_hold(socket),
         {:ok, kind} <- parse_hold_kind(hold_params["kind"]),
         {:ok, start_us, end_us} <- parse_hold_bounds(hold_params, socket),
         reason = String.trim(to_string(hold_params["reason"] || "")),
         {:ok, _hold} <-
           RecordingHolds.place_hold(
             %{
               camera_source_id: source.id,
               stream_profile_id: blank_to_nil(socket.assigns.timeline_profile_id),
               start_us: start_us,
               end_us: end_us,
               kind: kind,
               reason: reason
             },
             scope: scope
           ) do
      socket =
        socket
        |> assign(current_scope: scope, source: source, error: nil)
        |> put_flash(:info, "Recording hold placed.")
        |> load_timeline()

      {:noreply, socket}
    else
      {:error, reason}
      when reason in [:unauthorized, :permission_revoked, :recording_block_not_found, :invalid_id] ->
        {:noreply, unavailable(socket, reason)}

      {:error, %Forbidden{}} ->
        {:noreply, unavailable(socket, :permission_revoked)}

      {:error, reason} ->
        {:noreply, assign(socket, error: hold_error_message(reason))}
    end
  end

  def handle_event("release_timeline_hold", params, socket) do
    release_params = Map.get(params, "release", params)
    hold_id = to_string(release_params["hold_id"] || "")
    release_reason = blank_to_nil(release_params["release_reason"])

    with {:ok, scope, source} <- authorize_timeline_hold(socket),
         {:ok, _released} <-
           RecordingHolds.release_hold(
             hold_id,
             %{release_reason: release_reason},
             scope: scope
           ) do
      socket =
        socket
        |> assign(current_scope: scope, source: source, error: nil)
        |> put_flash(:info, "Recording hold released.")
        |> load_timeline()

      {:noreply, socket}
    else
      {:error, reason}
      when reason in [:unauthorized, :permission_revoked, :recording_block_not_found, :invalid_id] ->
        {:noreply, unavailable(socket, reason)}

      {:error, %Forbidden{}} ->
        {:noreply, unavailable(socket, :permission_revoked)}

      {:error, reason} ->
        {:noreply, assign(socket, error: hold_error_message(reason))}
    end
  end

  @impl true
  def handle_info({:camera_recording_updated, %{camera_source_id: source_id}}, socket) do
    if connected?(socket) and source_id == current_source_id(socket) do
      {:noreply, schedule_debounced_refresh(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:debounced_recording_refresh, token}, socket) do
    if connected?(socket) and is_reference(token) and
         token == socket.assigns.recording_debounce_token do
      socket =
        assign(socket,
          recording_debounce_timer_ref: nil,
          recording_debounce_token: nil
        )

      {:noreply, perform_live_refresh(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:refresh_timeline_tick, token}, socket) do
    if connected?(socket) and is_reference(token) and
         token == socket.assigns.recording_refresh_token do
      socket =
        socket
        |> assign(
          recording_refresh_timer_ref: nil,
          recording_refresh_token: nil
        )
        |> perform_live_refresh()
        |> maybe_reschedule_periodic_refresh()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  defp load_initial_or_switched_mode(socket) do
    case authorize_timeline_view(socket) do
      {:ok, scope, source} ->
        socket = ensure_live_refresh(socket, source.id)

        effective_mode =
          case socket.assigns.requested_mode do
            mode when mode in [:timeline, :published] ->
              mode

            nil ->
              if deps(socket).has_timeline_data?.(source.id, scope) do
                :timeline
              else
                :published
              end
          end

        socket = assign(socket, current_scope: scope, source: source, mode: effective_mode)

        case effective_mode do
          :timeline -> load_timeline_for_authorized(socket, scope, source)
          :published -> load_inventory(socket, nil)
        end

      {:error, reason} ->
        unavailable(socket, reason)
    end
  end

  defp load_inventory(socket, cursor) do
    with {:ok, scope, source} <-
           CameraArchiveAccess.source(
             socket.assigns.current_scope,
             socket.assigns.camera_source_id
           ),
         {:ok, inventory} <-
           ArchiveUploads.archive_inventory(source.id, [limit: 10, cursor: cursor],
             actor: SystemActor.system(:camera_archive_metadata)
           ) do
      socket
      |> maybe_rearm_live_refresh(source.id)
      |> assign(
        current_scope: scope,
        source: source,
        mode: :published,
        items: inventory.items,
        next_cursor: inventory.next_cursor,
        selected: nil,
        timeline_user_selected_window?: false,
        error: nil,
        loading: false
      )
    else
      {:error, reason} -> unavailable(socket, reason)
    end
  end

  defp select_recording(socket, block_id, index) do
    with {:ok, scope, source_id, block_id} <-
           CameraArchiveAccess.recording(
             socket.assigns.current_scope,
             socket.assigns.camera_source_id,
             block_id
           ),
         {:ok, metadata} <-
           ArchiveUploads.archive_metadata(source_id, block_id, actor: SystemActor.system(:camera_archive_metadata)),
         {:ok, window} <- CameraArchiveWindow.select(metadata, index) do
      selected = %{
        block_id: block_id,
        window: window,
        playlist_path:
          "/api/cameras/#{source_id}/recordings/#{block_id}/playlist.m3u8?first=#{window.first}&count=#{window.count}"
      }

      assign(socket, current_scope: scope, selected: selected, error: nil)
    else
      {:error, reason} -> unavailable(socket, reason)
    end
  end

  defp load_timeline(socket) do
    case authorize_timeline_view(socket) do
      {:ok, scope, source} ->
        load_timeline_for_authorized(socket, scope, source)

      {:error, reason} ->
        unavailable(socket, reason)
    end
  end

  defp load_timeline_for_authorized(socket, scope, source) do
    {cov_from_us, cov_to_us} = resolve_coverage_bounds(socket)
    profile_id = blank_to_nil(socket.assigns.timeline_profile_id)
    profiles = deps(socket).list_relay_profiles.(scope, source.id)

    coverage_params = %{
      from_us: cov_from_us,
      to_us: cov_to_us,
      stream_profile_id: profile_id,
      bucket_count: 120
    }

    with {:ok, coverage} <-
           deps(socket).coverage.(source.id, coverage_params, scope),
         {:ok, all_holds} <- load_enriched_camera_holds(socket, source.id, coverage, scope) do
      socket =
        maybe_run_initial_query_search(socket, scope, source.id, cov_from_us, cov_to_us)

      {play_from_us, play_to_us} =
        initial_playback_window(
          coverage,
          cov_from_us,
          cov_to_us,
          socket.assigns.timeline_source,
          socket.assigns.timeline_seek_us
        )

      playlist_path =
        build_playlist_path_if_playable(
          source.id,
          coverage,
          play_from_us,
          play_to_us,
          socket.assigns.timeline_profile_id,
          socket.assigns.timeline_source
        )

      playlist_origin_us =
        compute_playlist_origin_us(
          coverage,
          play_from_us,
          play_to_us,
          socket.assigns.timeline_source
        )

      seek_offset_seconds =
        compute_seek_offset_seconds(
          socket.assigns.timeline_seek_us,
          playlist_origin_us,
          play_to_us
        )

      overlay_detections =
        resolve_overlay_detections(
          source.id,
          play_from_us,
          play_to_us,
          socket.assigns.timeline_highlight_frame_id,
          socket.assigns.timeline_search_results
        )

      has_adjacent? = adjacent_window_available?(play_to_us, cov_to_us, socket)
      tz = user_timezone(scope)

      event_clips =
        load_event_clips(
          socket,
          source.id,
          cov_from_us,
          cov_to_us,
          profile_id,
          coverage.blocks,
          scope
        )

      selected_clip_id =
        case find_event_clip(event_clips, socket.assigns.timeline_selected_clip_id) do
          %{} = clip ->
            if clip_in_play_window?(clip, play_from_us, play_to_us), do: clip.id

          nil ->
            nil
        end

      socket
      |> maybe_rearm_live_refresh(source.id)
      |> assign(
        current_scope: scope,
        source: source,
        mode: :timeline,
        stream_profiles: profiles,
        timeline_coverage: coverage,
        timeline_play_from_us: play_from_us,
        timeline_play_to_us: play_to_us,
        timeline_playlist_origin_us: playlist_origin_us,
        timeline_seek_offset_seconds: seek_offset_seconds,
        timeline_overlay_detections: overlay_detections,
        timeline_jump_at: format_us_for_datetime_local(play_from_us, tz, :floor, true),
        timeline_playlist_path: playlist_path,
        timeline_has_adjacent_window: has_adjacent?,
        timeline_holds: all_holds,
        timeline_event_clips: event_clips,
        timeline_selected_clip_id: selected_clip_id,
        timeline_user_selected_window?: false,
        hold_form: to_form(default_hold_form_params(play_from_us, play_to_us, tz, true), as: :hold),
        error: nil,
        loading: false
      )
    else
      {:error, reason} -> unavailable(socket, reason)
    end
  end

  defp advance_playback_window(socket, source) do
    cov = socket.assigns.timeline_coverage
    current_from = socket.assigns.timeline_play_from_us
    current_to = socket.assigns.timeline_play_to_us

    if is_map(cov) and is_integer(current_from) and is_integer(current_to) do
      step_us = min(max(current_to - current_from, 60_000_000), @max_playlist_window_us)
      now_us = System.system_time(:microsecond)
      upper_us = max(cov.to_us, now_us)
      next_from = current_to
      next_to = min(next_from + step_us, upper_us)

      cond do
        next_to <= next_from ->
          assign(socket, timeline_has_adjacent_window: false)

        next_to > cov.to_us ->
          span_us = Map.fetch!(@span_durations_us, socket.assigns.timeline_span)

          socket
          |> assign(
            timeline_custom_from_us: max(next_to - span_us, 0),
            timeline_anchor_to_us: next_to
          )
          |> load_timeline()
          |> assign_advanced_subwindow(source.id, next_from, next_to)

        true ->
          assign_advanced_subwindow(socket, source.id, next_from, next_to)
      end
    else
      socket
    end
  end

  defp assign_advanced_subwindow(socket, source_id, next_from, next_to) do
    cov = socket.assigns.timeline_coverage
    cov_to_us = (cov && cov.to_us) || next_to

    playlist_path =
      build_playlist_path_if_playable(
        source_id,
        cov,
        next_from,
        next_to,
        socket.assigns.timeline_profile_id,
        socket.assigns.timeline_source
      )

    playlist_origin_us =
      compute_playlist_origin_us(cov, next_from, next_to, socket.assigns.timeline_source)

    overlay_detections =
      resolve_overlay_detections(
        source_id,
        next_from,
        next_to,
        socket.assigns.timeline_highlight_frame_id,
        socket.assigns.timeline_search_results
      )

    assign(socket,
      timeline_selected_clip_id: nil,
      timeline_user_selected_window?: is_nil(socket.assigns.error),
      timeline_play_from_us: next_from,
      timeline_play_to_us: next_to,
      timeline_playlist_origin_us: playlist_origin_us,
      timeline_seek_us: nil,
      timeline_seek_offset_seconds: 0.0,
      timeline_overlay_detections: overlay_detections,
      timeline_jump_at:
        format_us_for_datetime_local(
          next_from,
          user_timezone(socket.assigns.current_scope),
          :floor,
          true
        ),
      timeline_playlist_path: playlist_path,
      timeline_has_adjacent_window: adjacent_window_available?(next_to, cov_to_us, socket),
      hold_form:
        to_form(
          default_hold_form_params(
            next_from,
            next_to,
            user_timezone(socket.assigns.current_scope),
            true
          ),
          as: :hold
        )
    )
  end

  defp resolve_coverage_bounds(socket) do
    span_us = Map.fetch!(@span_durations_us, socket.assigns.timeline_span)
    now_us = now_us(socket)
    raw_to = socket.assigns.timeline_anchor_to_us
    raw_from = socket.assigns.timeline_custom_from_us

    cond do
      is_integer(raw_from) and raw_from >= 0 and is_integer(raw_to) and raw_to > raw_from ->
        {raw_from, raw_to}

      is_integer(raw_from) and raw_from >= 0 and is_integer(raw_to) and raw_to > 0 and
          raw_to <= raw_from ->
        {max(raw_from - 4_000_000, 0), raw_from + 4_000_000}

      true ->
        to_us = raw_to || now_us

        from_us =
          case raw_from do
            custom when is_integer(custom) and custom >= 0 and custom < to_us -> custom
            _ -> max(to_us - span_us, 0)
          end

        {from_us, to_us}
    end
  end

  defp initial_playback_window(coverage, cov_from_us, cov_to_us, source_str, seek_us) do
    cond do
      cov_to_us - cov_from_us <= @max_playlist_window_us ->
        {cov_from_us, cov_to_us}

      is_integer(seek_us) and seek_us >= cov_from_us and seek_us <= cov_to_us ->
        start_us =
          seek_us
          |> Kernel.-(60_000_000)
          |> min(cov_to_us - @max_playlist_window_us)
          |> max(cov_from_us)

        {start_us, min(start_us + @max_playlist_window_us, cov_to_us)}

      true ->
        playable_blocks =
          Enum.filter(coverage.blocks, &block_playable_for_source?(&1, source_str))

        case playable_blocks do
          [first | _] ->
            start_us = max(first.timeline_start_us, cov_from_us)
            {start_us, min(start_us + @max_playlist_window_us, cov_to_us)}

          [] ->
            {max(cov_to_us - @max_playlist_window_us, cov_from_us), cov_to_us}
        end
    end
  end

  defp build_playlist_path_if_playable(source_id, coverage, play_from_us, play_to_us, profile_id, source_str) do
    has_playable? =
      is_map(coverage) and
        Enum.any?(coverage.blocks, fn block ->
          block.timeline_end_us > play_from_us and
            block.timeline_start_us < play_to_us and
            block_playable_for_source?(block, source_str)
        end)

    if has_playable? do
      query_items =
        [
          {"from", Integer.to_string(play_from_us)},
          {"to", Integer.to_string(play_to_us)},
          {"source", playlist_source_param(source_str)}
        ] ++
          if(profile_id in [nil, ""], do: [], else: [{"profile", profile_id}])

      "/api/cameras/#{source_id}/timeline/playlist.m3u8?" <> URI.encode_query(query_items)
    end
  end

  defp playlist_source_param("local"), do: "local"
  defp playlist_source_param("archive"), do: "archive"

  defp playlist_source_param(_auto) do
    if CameraTimelineReader.archive_reader_installed?(), do: "auto", else: "local"
  end

  defp block_playable_for_source?(block, "local"), do: block.local_state == :present
  defp block_playable_for_source?(block, "archive"), do: archive_playable?(block)
  defp block_playable_for_source?(block, _auto), do: block.local_state == :present or archive_playable?(block)

  # A verified archive copy plays only through an installed archive reader (D.2).
  defp archive_playable?(block), do: block.archive_state == :verified and CameraTimelineReader.archive_reader_installed?()

  defp adjacent_window_available?(play_to_us, cov_to_us, socket) do
    play_to_us < cov_to_us or cov_to_us < now_us(socket) - 1_000_000
  end

  defp load_enriched_camera_holds(socket, camera_source_id, coverage, scope) do
    in_window_by_id = Map.new(coverage.holds || [], &{to_string(&1.id), &1})

    with {:ok, holds} <- deps(socket).list_holds.(camera_source_id, scope) do
      enriched =
        Enum.map(holds, fn hold ->
          case Map.get(in_window_by_id, to_string(hold.id)) do
            %{} = formatted ->
              formatted

            nil ->
              format_out_of_window_hold(hold)
          end
        end)

      {:ok, enriched}
    end
  end

  defp format_out_of_window_hold(hold) do
    covered =
      if hold.state == :accepted do
        load_covered_entries_for_hold(hold)
      else
        []
      end

    pinned_copies =
      covered
      |> Enum.filter(&RecordingHolds.hold_protects_entry?(hold, &1))
      |> Enum.map(&RecordingHolds.pinned_copy_for_entry/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    pinned_copy =
      cond do
        hold.state != :accepted -> nil
        :local in pinned_copies -> :local
        :archive in pinned_copies -> :archive
        true -> nil
      end

    archive_missing? =
      hold.state == :accepted and
        Enum.any?(covered, fn entry ->
          RecordingHolds.hold_protects_entry?(hold, entry) and entry.archive_state == :missing
        end)

    %{
      id: hold.id,
      camera_source_id: hold.camera_source_id,
      stream_profile_id: hold.stream_profile_id,
      start_us: hold.start_us,
      end_us: hold.end_us,
      kind: hold.kind,
      state: hold.state,
      reason: hold.reason,
      created_by_id: hold.created_by_id,
      accepted_at: hold.accepted_at,
      released_by_id: hold.released_by_id,
      released_at: hold.released_at,
      release_reason: hold.release_reason,
      unavailable_blocks: hold.unavailable_blocks || [],
      pinned_copy: pinned_copy,
      archive_missing?: archive_missing?
    }
  end

  defp load_covered_entries_for_hold(hold) do
    RecordingCatalogEntry
    |> Ash.Query.for_read(:read, %{}, actor: SystemActor.system(:camera_recording_timeline))
    |> Ash.Query.filter(
      camera_source_id == ^hold.camera_source_id and
        local_state != :quarantined and
        not is_nil(timeline_start_us) and
        not is_nil(timeline_end_us) and
        timeline_end_us > ^hold.start_us and
        timeline_start_us < ^hold.end_us
    )
    |> Ash.read(actor: SystemActor.system(:camera_recording_timeline))
    |> case do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp authorize_timeline_view(socket) do
    deps(socket).authorize_timeline_view.(socket)
  end

  defp default_authorize_timeline_view(socket) do
    with {:ok, refreshed_scope} <-
           RBAC.authorize_current(socket.assigns.current_scope, @recording_view_permissions) do
      CameraArchiveAccess.source(refreshed_scope, socket.assigns.camera_source_id)
    end
  end

  defp authorize_timeline_hold(socket) do
    with {:ok, refreshed_scope} <-
           RBAC.authorize_current(socket.assigns.current_scope, @recording_hold_permissions) do
      CameraArchiveAccess.source(refreshed_scope, socket.assigns.camera_source_id)
    end
  end

  defp authorize_only_or_unavailable(socket) do
    case authorize_timeline_view(socket) do
      {:ok, scope, source} -> assign(socket, current_scope: scope, source: source)
      {:error, reason} -> unavailable(socket, reason)
    end
  end

  defp default_hold_form_params(start_us, end_us, timezone, connected?) do
    %{
      "kind" => "investigation",
      "start_at" => format_us_for_datetime_local(start_us, timezone, :floor, connected?),
      "end_at" => format_us_for_datetime_local(end_us, timezone, :ceil, connected?),
      "reason" => ""
    }
  end

  defp user_timezone(%{user: %{timezone: tz}}) when is_binary(tz) and tz != "", do: tz
  defp user_timezone(_scope), do: "Etc/UTC"

  defp utc_timezone?(tz) when is_binary(tz) do
    String.upcase(String.trim(tz)) in ["", "UTC", "ETC/UTC", "GMT", "ETC/GMT", "Z", "ZULU", "ETC/ZULU"]
  end

  defp utc_timezone?(_), do: true

  defp format_us_for_datetime_local(us, timezone, rounding, connected?) when is_integer(us) do
    adjusted_us =
      case rounding do
        :ceil ->
          if rem(us, 1_000_000) > 0, do: (div(us, 1_000_000) + 1) * 1_000_000, else: us

        _ ->
          div(us, 1_000_000) * 1_000_000
      end

    case DateTime.from_unix(adjusted_us, :microsecond) do
      {:ok, utc_dt} ->
        naive =
          if connected? and not utc_timezone?(timezone) do
            case TimeZone.local_datetime(utc_dt, timezone) do
              {:ok, local_naive} -> local_naive
              {:error, _} -> DateTime.to_naive(utc_dt)
            end
          else
            DateTime.to_naive(utc_dt)
          end

        format_datetime_local_value(naive)

      _ ->
        ""
    end
  end

  defp format_us_for_datetime_local(_us, _timezone, _rounding, _connected?), do: ""

  defp format_datetime_local_value(%NaiveDateTime{} = naive) do
    naive |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()
  end

  defp parse_mode_param("timeline"), do: :timeline
  defp parse_mode_param("published"), do: :published
  defp parse_mode_param(_), do: nil

  defp parse_span_param(span) when span in ["1h", "6h", "24h", "7d"], do: span
  defp parse_span_param(_), do: "1h"

  defp parse_source_param(source) when source in ["auto", "local", "archive"], do: source
  defp parse_source_param(_), do: "auto"

  defp parse_profile_param(val) when is_binary(val) do
    case Ecto.UUID.cast(String.trim(val)) do
      {:ok, uuid} -> uuid
      :error -> ""
    end
  end

  defp parse_profile_param(_), do: ""

  defp parse_hold_kind("investigation"), do: {:ok, :investigation}
  defp parse_hold_kind("export"), do: {:ok, :export}
  defp parse_hold_kind(_), do: {:error, :invalid_hold_kind}

  defp parse_hold_bounds(hold_params, socket) do
    tz = user_timezone(socket.assigns.current_scope)

    with {:ok, start_us} <-
           resolve_hold_bound_us(
             hold_params,
             "start_at",
             "start_us",
             socket.assigns.timeline_play_from_us,
             tz
           ),
         {:ok, end_us} <-
           resolve_hold_bound_us(
             hold_params,
             "end_at",
             "end_us",
             socket.assigns.timeline_play_to_us,
             tz
           ),
         true <- is_integer(start_us) and is_integer(end_us) and end_us > start_us do
      {:ok, start_us, end_us}
    else
      _ -> {:error, :invalid_hold_window}
    end
  end

  defp resolve_hold_bound_us(hold_params, dt_key, us_key, fallback_us, tz) do
    cond do
      present_string?(hold_params[us_key]) or is_integer(hold_params[us_key]) ->
        case parse_optional_int(hold_params[us_key]) do
          n when is_integer(n) -> {:ok, n}
          nil -> {:error, :invalid_hold_window}
        end

      present_string?(hold_params[dt_key]) ->
        parse_datetime_local_to_us(hold_params[dt_key], tz)

      is_integer(fallback_us) ->
        {:ok, fallback_us}

      true ->
        {:error, :invalid_hold_window}
    end
  end

  defp present_string?(val) when is_binary(val), do: String.trim(val) != ""
  defp present_string?(_), do: false

  defp parse_datetime_local_to_us(raw, tz) when is_binary(raw) do
    trimmed = String.trim(raw)

    iso_str =
      if Regex.match?(~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}\z/, trimmed) do
        trimmed <> ":00"
      else
        trimmed
      end

    with {:ok, naive} <- NaiveDateTime.from_iso8601(iso_str) do
      naive_in_timezone_to_us(naive, tz)
    end
  end

  defp parse_datetime_local_to_us(_, _tz), do: {:error, :invalid_datetime}

  defp naive_in_timezone_to_us(%NaiveDateTime{} = naive, tz) do
    if utc_timezone?(tz) do
      {:ok, naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)}
    else
      zone = String.trim(tz)

      case SQL.query(
             Repo,
             "SELECT (EXTRACT(EPOCH FROM ($1::timestamp AT TIME ZONE $2)) * 1000000)::bigint",
             [naive, zone]
           ) do
        {:ok, %{rows: [[epoch_us]]}} when is_integer(epoch_us) ->
          {:ok, epoch_us}

        _ ->
          {:error, :invalid_timezone}
      end
    end
  end

  defp parse_required_int(val) do
    case parse_optional_int(val) do
      n when is_integer(n) -> {:ok, n}
      nil -> {:error, :invalid_integer}
    end
  end

  defp parse_optional_int(val) when is_integer(val), do: val

  defp parse_optional_int(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_optional_int(_), do: nil

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: nil, else: trimmed
  end

  defp unavailable(socket, reason) do
    socket =
      if fatal_live_refresh_error?(reason) do
        teardown_live_refresh(socket)
      else
        socket
      end

    assign(socket,
      source: nil,
      items: [],
      next_cursor: nil,
      selected: nil,
      timeline_coverage: nil,
      timeline_playlist_path: nil,
      timeline_playlist_origin_us: nil,
      timeline_seek_offset_seconds: 0.0,
      timeline_overlay_detections: [],
      timeline_holds: [],
      timeline_event_clips: [],
      timeline_selected_clip_id: nil,
      timeline_user_selected_window?: false,
      loading: false,
      error: message(reason)
    )
  end

  defp maybe_rearm_live_refresh(socket, source_id) do
    needs_subscription? = socket.assigns.recording_subscribed_source_id != source_id

    needs_periodic_timer? =
      is_integer(socket.assigns.recording_refresh_interval_ms) and
        socket.assigns.recording_refresh_interval_ms > 0 and
        not is_reference(socket.assigns.recording_refresh_timer_ref)

    if connected?(socket) and (needs_subscription? or needs_periodic_timer?) do
      ensure_live_refresh(socket, source_id)
    else
      socket
    end
  end

  defp ensure_live_refresh(socket, source_id) do
    socket
    |> ensure_recording_subscription(source_id)
    |> cancel_debounced_refresh()
    |> schedule_periodic_refresh()
  end

  defp ensure_recording_subscription(socket, source_id) when is_binary(source_id) and source_id != "" do
    prev_id = socket.assigns.recording_subscribed_source_id

    cond do
      prev_id == source_id ->
        socket

      is_binary(prev_id) and prev_id != "" ->
        _ = deps(socket).unsubscribe.(prev_id)
        _ = deps(socket).subscribe.(source_id)
        assign(socket, recording_subscribed_source_id: source_id)

      true ->
        _ = deps(socket).subscribe.(source_id)
        assign(socket, recording_subscribed_source_id: source_id)
    end
  end

  defp ensure_recording_subscription(socket, _source_id), do: socket

  defp teardown_live_refresh(socket) do
    if is_binary(socket.assigns.recording_subscribed_source_id) do
      _ = deps(socket).unsubscribe.(socket.assigns.recording_subscribed_source_id)
    end

    cancel_timer_ref(socket.assigns.recording_refresh_timer_ref)
    cancel_timer_ref(socket.assigns.recording_debounce_timer_ref)

    assign(socket,
      recording_subscribed_source_id: nil,
      recording_refresh_timer_ref: nil,
      recording_refresh_token: nil,
      recording_debounce_timer_ref: nil,
      recording_debounce_token: nil
    )
  end

  defp cancel_debounced_refresh(socket) do
    cancel_timer_ref(socket.assigns.recording_debounce_timer_ref)

    assign(socket,
      recording_debounce_timer_ref: nil,
      recording_debounce_token: nil
    )
  end

  defp schedule_periodic_refresh(socket) do
    cancel_timer_ref(socket.assigns.recording_refresh_timer_ref)
    interval_ms = socket.assigns.recording_refresh_interval_ms

    {timer_ref, token} =
      if is_integer(interval_ms) and interval_ms > 0 do
        token = make_ref()
        {Process.send_after(self(), {:refresh_timeline_tick, token}, interval_ms), token}
      else
        {nil, nil}
      end

    assign(socket,
      recording_refresh_timer_ref: timer_ref,
      recording_refresh_token: token
    )
  end

  defp maybe_reschedule_periodic_refresh(socket) do
    if is_nil(socket.assigns.error) and is_binary(socket.assigns.recording_subscribed_source_id) do
      schedule_periodic_refresh(socket)
    else
      socket
    end
  end

  defp schedule_debounced_refresh(socket) do
    if is_reference(socket.assigns.recording_debounce_timer_ref) do
      socket
    else
      debounce_ms = socket.assigns.recording_debounce_ms

      if is_integer(debounce_ms) and debounce_ms > 0 do
        token = make_ref()
        timer_ref = Process.send_after(self(), {:debounced_recording_refresh, token}, debounce_ms)

        assign(socket,
          recording_debounce_timer_ref: timer_ref,
          recording_debounce_token: token
        )
      else
        perform_live_refresh(socket)
      end
    end
  end

  defp cancel_timer_ref(ref) when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp cancel_timer_ref(_), do: :ok

  defp current_source_id(socket) do
    case socket.assigns.source do
      %{id: id} when is_binary(id) -> id
      _ -> socket.assigns.camera_source_id
    end
  end

  defp perform_live_refresh(socket) do
    socket = cancel_debounced_refresh(socket)

    case socket.assigns.mode do
      :timeline ->
        case authorize_timeline_view(socket) do
          {:ok, scope, source} ->
            refresh_timeline_live(socket, scope, source)

          {:error, reason} ->
            handle_live_refresh_error(socket, reason)
        end

      :published ->
        maybe_switch_empty_published_to_timeline(socket)
    end
  end

  defp maybe_switch_empty_published_to_timeline(%{assigns: %{requested_mode: nil, items: [], selected: nil}} = socket) do
    case authorize_timeline_view(socket) do
      {:ok, scope, source} ->
        if deps(socket).has_timeline_data?.(source.id, scope) do
          refresh_timeline_live(socket, scope, source)
        else
          socket
        end

      {:error, reason} ->
        handle_live_refresh_error(socket, reason)
    end
  end

  defp maybe_switch_empty_published_to_timeline(socket), do: socket

  defp refresh_timeline_live(socket, scope, source) do
    {cov_from_us, cov_to_us} = resolve_coverage_bounds(socket)
    profile_id = blank_to_nil(socket.assigns.timeline_profile_id)
    profiles = deps(socket).list_relay_profiles.(scope, source.id)

    coverage_params = %{
      from_us: cov_from_us,
      to_us: cov_to_us,
      stream_profile_id: profile_id,
      bucket_count: 120
    }

    with {:ok, coverage} <- deps(socket).coverage.(source.id, coverage_params, scope),
         {:ok, all_holds} <- load_enriched_camera_holds(socket, source.id, coverage, scope) do
      event_clips =
        load_event_clips(
          socket,
          source.id,
          cov_from_us,
          cov_to_us,
          profile_id,
          coverage.blocks,
          scope
        )

      if preserve_playback_window?(socket) do
        assign_live_refresh_preserving_window(socket, scope, source, %{
          profiles: profiles,
          coverage: coverage,
          cov_to_us: cov_to_us,
          all_holds: all_holds,
          event_clips: event_clips
        })
      else
        assign_live_refresh_without_active_playback(socket, scope, source, %{
          profiles: profiles,
          coverage: coverage,
          cov_from_us: cov_from_us,
          cov_to_us: cov_to_us,
          all_holds: all_holds,
          event_clips: event_clips
        })
      end
    else
      {:error, reason} -> handle_live_refresh_error(socket, reason)
    end
  end

  defp handle_live_refresh_error(socket, reason) do
    if fatal_live_refresh_error?(reason) do
      unavailable(socket, reason)
    else
      Logger.warning(
        "Transient camera recordings live refresh error for source #{current_source_id(socket)}: #{inspect(reason)}"
      )

      socket
    end
  end

  defp fatal_live_refresh_error?(%Forbidden{}), do: true

  defp fatal_live_refresh_error?(reason)
       when reason in [
              :unauthorized,
              :forbidden,
              :permission_revoked,
              :not_found,
              :recording_block_not_found,
              :camera_source_not_found,
              :invalid_id
            ], do: true

  defp fatal_live_refresh_error?(_reason), do: false

  defp preserve_playback_window?(socket) do
    has_window? =
      is_integer(socket.assigns.timeline_play_from_us) and
        is_integer(socket.assigns.timeline_play_to_us)

    has_active_playlist? = is_binary(socket.assigns.timeline_playlist_path) and has_window?

    has_active_playlist? or
      not is_nil(socket.assigns.timeline_selected_clip_id) or
      (socket.assigns.timeline_user_selected_window? == true and has_window?)
  end

  defp assign_live_refresh_preserving_window(socket, scope, source, %{
         profiles: profiles,
         coverage: coverage,
         cov_to_us: cov_to_us,
         all_holds: all_holds,
         event_clips: event_clips
       }) do
    play_from_us = socket.assigns.timeline_play_from_us
    play_to_us = socket.assigns.timeline_play_to_us

    base_assigns = [
      current_scope: scope,
      source: source,
      mode: :timeline,
      stream_profiles: profiles,
      timeline_coverage: coverage,
      timeline_has_adjacent_window: adjacent_window_available?(play_to_us || cov_to_us, cov_to_us, socket),
      timeline_holds: all_holds,
      timeline_event_clips: event_clips,
      error: nil,
      loading: false
    ]

    extra_assigns =
      with nil <- socket.assigns.timeline_playlist_path,
           true <- is_integer(play_from_us) and is_integer(play_to_us),
           playlist_path when is_binary(playlist_path) <-
             build_playlist_path_if_playable(
               source.id,
               coverage,
               play_from_us,
               play_to_us,
               socket.assigns.timeline_profile_id,
               socket.assigns.timeline_source
             ) do
        playlist_origin_us =
          compute_playlist_origin_us(coverage, play_from_us, play_to_us, socket.assigns.timeline_source)

        seek_offset_seconds =
          compute_seek_offset_seconds(socket.assigns.timeline_seek_us, playlist_origin_us, play_to_us)

        [
          timeline_playlist_path: playlist_path,
          timeline_playlist_origin_us: playlist_origin_us,
          timeline_seek_offset_seconds: seek_offset_seconds
        ]
      else
        _ -> []
      end

    assign(socket, base_assigns ++ extra_assigns)
  end

  defp assign_live_refresh_without_active_playback(socket, scope, source, %{
         profiles: profiles,
         coverage: coverage,
         cov_from_us: cov_from_us,
         cov_to_us: cov_to_us,
         all_holds: all_holds,
         event_clips: event_clips
       }) do
    {play_from_us, play_to_us} =
      initial_playback_window(
        coverage,
        cov_from_us,
        cov_to_us,
        socket.assigns.timeline_source,
        socket.assigns.timeline_seek_us
      )

    playlist_path =
      build_playlist_path_if_playable(
        source.id,
        coverage,
        play_from_us,
        play_to_us,
        socket.assigns.timeline_profile_id,
        socket.assigns.timeline_source
      )

    playlist_origin_us =
      compute_playlist_origin_us(coverage, play_from_us, play_to_us, socket.assigns.timeline_source)

    seek_offset_seconds =
      compute_seek_offset_seconds(socket.assigns.timeline_seek_us, playlist_origin_us, play_to_us)

    overlay_detections =
      resolve_overlay_detections(
        source.id,
        play_from_us,
        play_to_us,
        socket.assigns.timeline_highlight_frame_id,
        socket.assigns.timeline_search_results
      )

    tz = user_timezone(scope)

    base_assigns = [
      current_scope: scope,
      source: source,
      mode: :timeline,
      stream_profiles: profiles,
      timeline_coverage: coverage,
      timeline_play_from_us: play_from_us,
      timeline_play_to_us: play_to_us,
      timeline_playlist_origin_us: playlist_origin_us,
      timeline_seek_offset_seconds: seek_offset_seconds,
      timeline_overlay_detections: overlay_detections,
      timeline_playlist_path: playlist_path,
      timeline_has_adjacent_window: adjacent_window_available?(play_to_us, cov_to_us, socket),
      timeline_holds: all_holds,
      timeline_event_clips: event_clips,
      error: nil,
      loading: false
    ]

    if is_binary(playlist_path) do
      assign(
        socket,
        base_assigns ++
          [
            timeline_jump_at: format_us_for_datetime_local(play_from_us, tz, :floor, true),
            hold_form: to_form(default_hold_form_params(play_from_us, play_to_us, tz, true), as: :hold)
          ]
      )
    else
      assign(socket, base_assigns)
    end
  end

  defp deps(socket) do
    Map.merge(default_deps(), Map.get(socket.assigns, :recordings_deps, %{}))
  end

  defp default_deps do
    %{
      authorize_timeline_view: &default_authorize_timeline_view/1,
      has_timeline_data?: fn source_id, scope ->
        RecordingTimeline.has_timeline_data?(source_id, scope: scope)
      end,
      coverage: fn source_id, params, scope ->
        RecordingTimeline.coverage(source_id, params, scope: scope)
      end,
      list_relay_profiles: &CameraRecordingSettings.list_relay_profiles/2,
      list_holds: fn source_id, scope ->
        RecordingHolds.list_holds(source_id, scope: scope)
      end,
      list_event_clips: fn source_id, params, scope ->
        RecordingEventClips.list_clips(source_id, params, actor: scope.user)
      end,
      subscribe: &RecordingPubSub.subscribe/1,
      unsubscribe: &RecordingPubSub.unsubscribe/1,
      now_us: fn -> System.system_time(:microsecond) end
    }
  end

  defp now_us(socket), do: deps(socket).now_us.()

  defp maybe_run_initial_query_search(socket, scope, source_id, cov_from_us, cov_to_us) do
    query = String.trim(socket.assigns.timeline_search_query || "")

    if query != "" and not socket.assigns.timeline_search_executed? do
      run_timeline_semantic_search(socket, scope, source_id, cov_from_us, cov_to_us)
    else
      socket
    end
  end

  defp run_timeline_semantic_search(socket, scope, source_id, from_us, to_us) do
    query = String.trim(socket.assigns.timeline_search_query || "")
    object_class = socket.assigns.timeline_search_object_class || ""

    if query == "" do
      overlay_detections =
        resolve_overlay_detections(
          source_id,
          socket.assigns.timeline_play_from_us,
          socket.assigns.timeline_play_to_us,
          socket.assigns.timeline_highlight_frame_id,
          []
        )

      assign(socket,
        timeline_search_results: [],
        timeline_search_executed?: false,
        timeline_search_error: "Enter a search query between 1 and 256 characters.",
        timeline_embedder_unavailable?: false,
        timeline_overlay_detections: overlay_detections
      )
    else
      search_input = %{
        "q" => query,
        "camera_source_id" => source_id,
        "from" => from_us,
        "to" => to_us,
        "object_class" => object_class,
        "limit" => 20
      }

      opts =
        socket
        |> search_opts()
        |> Keyword.put_new(:authorize_fn, fn _ -> {:ok, scope} end)

      case CameraSemanticSearch.execute(scope, search_input, opts) do
        {:ok, %{results: results}} ->
          overlay_detections =
            resolve_overlay_detections(
              source_id,
              socket.assigns.timeline_play_from_us,
              socket.assigns.timeline_play_to_us,
              socket.assigns.timeline_highlight_frame_id,
              results
            )

          assign(socket,
            timeline_search_results: results,
            timeline_search_executed?: true,
            timeline_search_error: nil,
            timeline_embedder_unavailable?: false,
            timeline_overlay_detections: overlay_detections
          )

        {:error, :search_embedder_unavailable} ->
          assign(socket,
            timeline_search_results: [],
            timeline_search_executed?: true,
            timeline_search_error: nil,
            timeline_embedder_unavailable?: true
          )

        {:error, :invalid_query} ->
          assign(socket,
            timeline_search_results: [],
            timeline_search_executed?: false,
            timeline_search_error: "Enter a search query between 1 and 256 characters.",
            timeline_embedder_unavailable?: false
          )

        {:error, reason} when reason in [:unauthorized, :forbidden] ->
          unavailable(socket, :permission_revoked)

        {:error, _reason} ->
          assign(socket,
            timeline_search_results: [],
            timeline_search_executed?: true,
            timeline_search_error: "Semantic clip search is temporarily unavailable.",
            timeline_embedder_unavailable?: false
          )
      end
    end
  end

  defp focus_playback_on_hit(socket, scope, source, cov, clip_start_us, clip_end_us, seek_us) do
    tz = user_timezone(scope)

    {play_from_us, play_to_us} =
      if cov.to_us - cov.from_us <= @max_playlist_window_us do
        {cov.from_us, cov.to_us}
      else
        start_us =
          clip_start_us
          |> min(seek_us)
          |> Kernel.-(30_000_000)
          |> min(cov.to_us - @max_playlist_window_us)
          |> max(cov.from_us)

        end_us = min(max(start_us + @max_playlist_window_us, clip_end_us), cov.to_us)
        {start_us, end_us}
      end

    playlist_path =
      build_playlist_path_if_playable(
        source.id,
        cov,
        play_from_us,
        play_to_us,
        socket.assigns.timeline_profile_id,
        socket.assigns.timeline_source
      )

    playlist_origin_us =
      compute_playlist_origin_us(cov, play_from_us, play_to_us, socket.assigns.timeline_source)

    seek_offset_seconds =
      compute_seek_offset_seconds(seek_us, playlist_origin_us, play_to_us)

    overlay_detections =
      resolve_overlay_detections(
        source.id,
        play_from_us,
        play_to_us,
        socket.assigns.timeline_highlight_frame_id,
        socket.assigns.timeline_search_results
      )

    assign(socket,
      timeline_selected_clip_id: nil,
      timeline_user_selected_window?: true,
      timeline_play_from_us: play_from_us,
      timeline_play_to_us: play_to_us,
      timeline_playlist_origin_us: playlist_origin_us,
      timeline_seek_offset_seconds: seek_offset_seconds,
      timeline_overlay_detections: overlay_detections,
      timeline_jump_at: format_us_for_datetime_local(play_from_us, tz, :floor, true),
      timeline_playlist_path: playlist_path,
      timeline_has_adjacent_window: adjacent_window_available?(play_to_us, cov.to_us, socket),
      hold_form: to_form(default_hold_form_params(play_from_us, play_to_us, tz, true), as: :hold)
    )
  end

  defp current_or_resolved_coverage_bounds(socket) do
    case socket.assigns.timeline_coverage do
      %{from_us: from_us, to_us: to_us} when is_integer(from_us) and is_integer(to_us) ->
        {from_us, to_us}

      _ ->
        resolve_coverage_bounds(socket)
    end
  end

  defp compute_playlist_origin_us(coverage, play_from_us, play_to_us, source_str)
       when is_integer(play_from_us) and is_integer(play_to_us) do
    playable_overlapping =
      if is_map(coverage) and is_list(coverage.blocks) do
        coverage.blocks
        |> Enum.filter(fn block ->
          block.timeline_end_us > play_from_us and
            block.timeline_start_us < play_to_us and
            block_playable_for_source?(block, source_str)
        end)
        |> Enum.sort_by(& &1.timeline_start_us)
      else
        []
      end

    case playable_overlapping do
      [first | _] -> max(first.timeline_start_us, play_from_us)
      [] -> play_from_us
    end
  end

  defp compute_playlist_origin_us(_coverage, play_from_us, _play_to_us, _source_str), do: play_from_us

  defp compute_seek_offset_seconds(seek_us, playlist_origin_us, play_to_us)
       when is_integer(seek_us) and is_integer(playlist_origin_us) and is_integer(play_to_us) do
    if seek_us > playlist_origin_us and seek_us <= play_to_us + 2_000_000 do
      Float.round(max((seek_us - playlist_origin_us) / 1_000_000.0, 0.0), 3)
    else
      0.0
    end
  end

  defp compute_seek_offset_seconds(_seek_us, _playlist_origin_us, _play_to_us), do: 0.0

  defp resolve_overlay_detections(source_id, play_from_us, play_to_us, highlight_frame_id, search_results) do
    from_results = detections_from_search_results(search_results, play_from_us, play_to_us)

    has_highlighted_in_results? =
      is_binary(highlight_frame_id) and
        Enum.any?(from_results, &(to_string(&1[:visual_frame_id] || "") == highlight_frame_id))

    from_db =
      if is_binary(highlight_frame_id) and not has_highlighted_in_results? do
        load_highlighted_frame_detections(source_id, highlight_frame_id)
      else
        []
      end

    deduplicate_overlay_detections(from_db ++ from_results)
  end

  defp detections_from_search_results(results, play_from_us, play_to_us) when is_list(results) do
    results
    |> Enum.filter(fn hit ->
      if is_integer(play_from_us) and is_integer(play_to_us) do
        (hit.clip_end_us || hit.best_timeline_ts_us || 0) >= play_from_us and
          (hit.clip_start_us || hit.best_timeline_ts_us || 0) <= play_to_us
      else
        true
      end
    end)
    |> Enum.flat_map(&detections_from_single_hit/1)
  end

  defp detections_from_search_results(_results, _play_from_us, _play_to_us), do: []

  defp detections_from_single_hit(hit) when is_map(hit) do
    frame_dets = List.wrap(hit[:frame_detections])

    cond do
      frame_dets != [] ->
        frame_dets
        |> Enum.map(fn det ->
          bbox =
            normalize_detection_bbox(det[:bbox] || det["bbox"] || det[:bbox_norm] || det["bbox_norm"] || det)

          if is_list(bbox) do
            %{
              visual_frame_id: det[:visual_frame_id] || det["visual_frame_id"] || hit[:visual_frame_id],
              timeline_ts_us: det[:timeline_ts_us] || det["timeline_ts_us"] || hit[:best_timeline_ts_us],
              start_us: hit[:clip_start_us],
              end_us: hit[:clip_end_us],
              bbox: bbox,
              object_class: to_string(det[:object_class] || det["object_class"] || hit[:object_class] || "subject"),
              score:
                det[:score] || det["score"] || det[:detector_confidence] ||
                  det["detector_confidence"] || hit[:score] || 0.0,
              dominant_colors: List.wrap(det[:dominant_colors] || det["dominant_colors"] || hit[:dominant_colors]),
              time_basis: to_string(det[:time_basis] || det["time_basis"] || hit[:time_basis] || "received")
            }
          end
        end)
        |> Enum.reject(&is_nil/1)

      is_list(hit[:bbox]) ->
        [
          %{
            visual_frame_id: hit[:visual_frame_id],
            timeline_ts_us: hit[:best_timeline_ts_us],
            start_us: hit[:clip_start_us],
            end_us: hit[:clip_end_us],
            bbox: hit[:bbox],
            object_class: to_string(hit[:object_class] || hit[:region_kind] || "subject"),
            score: hit[:score] || 0.0,
            dominant_colors: List.wrap(hit[:dominant_colors]),
            time_basis: to_string(hit[:time_basis] || "received")
          }
        ]

      true ->
        []
    end
  end

  defp load_highlighted_frame_detections(source_id, highlight_frame_id)
       when is_binary(source_id) and is_binary(highlight_frame_id) do
    case ServiceRadar.Camera.SemanticSearch.get_frame_overlay(
           source_id,
           highlight_frame_id,
           actor: SystemActor.system(:camera_semantic_search)
         ) do
      {:ok, detections} when is_list(detections) -> detections
      _ -> []
    end
  rescue
    _ -> []
  end

  defp load_highlighted_frame_detections(_source_id, _highlight_frame_id), do: []

  defp deduplicate_overlay_detections(detections) do
    Enum.uniq_by(detections, fn det ->
      {det[:visual_frame_id], det[:timeline_ts_us], det[:bbox], det[:object_class]}
    end)
  end

  defp normalize_detection_bbox([x1, y1, x2, y2])
       when is_number(x1) and is_number(y1) and is_number(x2) and is_number(y2) do
    [x1 * 1.0, y1 * 1.0, x2 * 1.0, y2 * 1.0]
  end

  defp normalize_detection_bbox(%{} = map) do
    x1 = map[:x1] || map["x1"] || map[:bbox_x1] || map["bbox_x1"]
    y1 = map[:y1] || map["y1"] || map[:bbox_y1] || map["bbox_y1"]
    x2 = map[:x2] || map["x2"] || map[:bbox_x2] || map["bbox_x2"]
    y2 = map[:y2] || map["y2"] || map[:bbox_y2] || map["bbox_y2"]

    if is_number(x1) and is_number(y1) and is_number(x2) and is_number(y2) do
      [x1 * 1.0, y1 * 1.0, x2 * 1.0, y2 * 1.0]
    end
  end

  defp normalize_detection_bbox(_), do: nil

  defp search_opts(socket) do
    Map.get_lazy(socket.assigns, :camera_semantic_search_opts, fn ->
      Application.get_env(:serviceradar_web_ng, :camera_semantic_search_opts, [])
    end)
  end

  defp load_event_clips(socket, source_id, from_us, to_us, profile_id, catalog_blocks, scope) do
    params = %{
      from_us: from_us,
      to_us: to_us,
      stream_profile_id: profile_id,
      catalog_blocks: catalog_blocks
    }

    case deps(socket).list_event_clips.(source_id, params, scope) do
      {:ok, %{clips: clips}} when is_list(clips) -> clips
      _ -> []
    end
  end

  defp find_event_clip(clips, clip_id) when is_list(clips) and is_binary(clip_id) do
    Enum.find(clips, fn clip -> to_string(clip.id) == clip_id end)
  end

  defp find_event_clip(_, _), do: nil

  defp clip_in_play_window?(clip, play_from_us, play_to_us)
       when is_map(clip) and is_integer(play_from_us) and is_integer(play_to_us) do
    is_integer(clip[:start_us]) and is_integer(clip[:end_us]) and
      play_from_us <= clip.start_us and play_to_us >= clip.end_us
  end

  defp clip_in_play_window?(_, _, _), do: false

  defp focus_playback_on_event_clip(socket, scope, source, cov, clip) do
    tz = user_timezone(scope)
    padded_start_us = max(clip.start_us - 5_000_000, 0)
    padded_end_us = clip.end_us + 10_000_000

    {play_from_us, play_to_us} =
      case cov do
        %{from_us: cov_from, to_us: cov_to} when is_integer(cov_from) and is_integer(cov_to) ->
          clamped_from = max(padded_start_us, cov_from)
          clamped_to = min(padded_end_us, min(clamped_from + @max_playlist_window_us, cov_to))
          {clamped_from, max(clamped_to, clamped_from + 1_000_000)}

        _ ->
          {padded_start_us, min(padded_end_us, padded_start_us + @max_playlist_window_us)}
      end

    seek_us = clip.peak_ts_us || clip.start_us

    playlist_path =
      build_playlist_path_if_playable(
        source.id,
        cov,
        play_from_us,
        play_to_us,
        socket.assigns.timeline_profile_id,
        socket.assigns.timeline_source
      )

    playlist_origin_us =
      compute_playlist_origin_us(cov, play_from_us, play_to_us, socket.assigns.timeline_source)

    seek_offset_seconds =
      compute_seek_offset_seconds(seek_us, playlist_origin_us, play_to_us)

    overlay_detections =
      resolve_overlay_detections(
        source.id,
        play_from_us,
        play_to_us,
        clip.visual_frame_id,
        socket.assigns.timeline_search_results
      )

    cov_to_us = (cov && cov.to_us) || play_to_us

    assign(socket,
      current_scope: scope,
      source: source,
      timeline_selected_clip_id: clip.id,
      timeline_user_selected_window?: true,
      timeline_play_from_us: play_from_us,
      timeline_play_to_us: play_to_us,
      timeline_playlist_origin_us: playlist_origin_us,
      timeline_seek_us: seek_us,
      timeline_seek_offset_seconds: seek_offset_seconds,
      timeline_highlight_frame_id: clip.visual_frame_id,
      timeline_overlay_detections: overlay_detections,
      timeline_jump_at: format_us_for_datetime_local(play_from_us, tz, :floor, true),
      timeline_playlist_path: playlist_path,
      timeline_has_adjacent_window: adjacent_window_available?(play_to_us, cov_to_us, socket),
      hold_form: to_form(default_hold_form_params(play_from_us, play_to_us, tz, true), as: :hold),
      error: nil
    )
  end

  defp parse_clips_mode(mode) when mode in ["all", "smart", "basic"], do: mode
  defp parse_clips_mode(_), do: "all"

  defp parse_clips_category(cat) when cat in ["all", "person", "vehicle", "animal", "package", "motion", "recording"],
    do: cat

  defp parse_clips_category(_), do: "all"

  defp parse_non_neg_int(val) do
    case parse_optional_int(val) do
      n when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  defp parse_optional_uuid(val) when is_binary(val) do
    case Ecto.UUID.cast(String.trim(val)) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp parse_optional_uuid(_), do: nil

  defp parse_search_query_param(val) when is_binary(val) do
    trimmed = String.trim(val)
    if String.length(trimmed) <= 256, do: trimmed, else: String.slice(trimmed, 0, 256)
  end

  defp parse_search_query_param(_), do: ""

  defp parse_object_class_param(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed in CameraSemanticSearch.allowed_object_classes(), do: trimmed, else: ""
  end

  defp parse_object_class_param(_), do: ""

  defp hold_error_message(:invalid_hold_kind), do: "Select a valid hold kind."

  defp hold_error_message(:invalid_hold_window), do: "Hold end time must be strictly after start time."

  defp hold_error_message(:hold_already_released), do: "This hold has already been released."
  defp hold_error_message(_), do: "Unable to complete recording hold action. Check hold inputs."

  defp message(reason) when reason in [:unauthorized, :permission_revoked, :forbidden],
    do: "You no longer have permission to view camera recordings."

  defp message(%Forbidden{}), do: message(:permission_revoked)
  defp message(:invalid_id), do: "The camera or recording identifier is invalid."

  defp message(reason) when reason in [:recording_block_not_found, :camera_source_not_found, :not_found],
    do: "The camera or recording could not be found."

  defp message(:archive_unavailable), do: "This recording is no longer available for playback."

  defp message(reason)
       when reason in [
              :invalid_recording_window,
              :recording_window_too_large,
              :timeline_window_too_large,
              :playlist_window_too_large
            ], do: "This recording window cannot be played within the current playback limits."

  defp message(_), do: "Camera recordings are temporarily unavailable. Try refreshing."

  defp can_view_recording_settings?(scope) do
    RBAC.can_any?(scope, @recording_settings_permissions)
  end
end
