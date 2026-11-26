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
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Repo
  alias ServiceRadar.TimeZone
  alias ServiceRadarWebNG.CameraArchiveWindow
  alias ServiceRadarWebNG.CameraRecordingSettings
  alias ServiceRadarWebNG.CameraTimelineReader
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.CameraArchiveAccess
  alias ServiceRadarWebNGWeb.CameraLive.RecordingsComponents
  alias ServiceRadarWebNGWeb.CameraMultiview
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

  @roi_edit_permissions [
    "settings.recording.manage",
    "settings.recording.operate",
    "devices.cameras.recordings.hold"
  ]

  @max_playlist_window_us 3_600_000_000
  @default_refresh_interval_ms 15_000
  @default_debounce_ms 500
  @default_switcher_per_page 20
  @gaps_per_page 10
  @default_min_confidence 50
  @min_confidence_min 30
  @min_confidence_max 95
  @roi_grid_cols 12
  @roi_grid_rows 8
  @roi_grid_cell_count @roi_grid_cols * @roi_grid_rows

  @span_order ["15m", "1h", "6h", "24h", "7d"]
  @smart_clip_categories ~w(person vehicle animal package object)
  @basic_clip_categories ~w(motion recording)

  @span_durations_us %{
    "15m" => 15 * 60_000_000,
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
        page_title: "Vantage",
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
        timeline_event_markers: [],
        timeline_clips_mode: "smart",
        timeline_clips_mode_user_set?: false,
        timeline_clips_category: "all",
        timeline_min_confidence: @default_min_confidence,
        timeline_clips_page: 1,
        timeline_clips_per_page: RecordingEventClips.default_per_page(),
        timeline_clips_total_count: 0,
        timeline_clips_total_pages: 1,
        timeline_clips_counts: default_clip_counts(),
        timeline_selected_clip_id: nil,
        clip_modal: nil,
        live_mode?: false,
        live_tile: nil,
        live_relay_subscriptions: MapSet.new(),
        roi_drawer_open?: false,
        roi_paint_mode: "focus",
        roi_focus_cells: MapSet.new(),
        roi_ignore_cells: MapSet.new(),
        roi_saved_focus_cells: MapSet.new(),
        roi_saved_ignore_cells: MapSet.new(),
        roi_feedback: nil,
        gaps_page: 1,
        gaps_per_page: @gaps_per_page,
        timeline_user_selected_window?: false,
        timeline_manage_drawer_open?: false,
        switcher_cameras: [],
        switcher_search: "",
        switcher_page: 1,
        switcher_per_page: @default_switcher_per_page,
        switcher_total_count: 0,
        switcher_total_pages: 1,
        switcher_open_mobile?: false,
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
    camera_changed? = source_id != socket.assigns.camera_source_id
    query_param_present? = Map.has_key?(params, "q")
    object_class_param_present? = Map.has_key?(params, "object_class")

    next_search_query =
      cond do
        query_param_present? -> search_query
        camera_changed? -> ""
        true -> socket.assigns.timeline_search_query
      end

    next_search_object_class =
      cond do
        object_class_param_present? -> search_object_class
        camera_changed? -> ""
        true -> socket.assigns.timeline_search_object_class
      end

    reset_search_state? =
      camera_changed? or
        (query_param_present? and next_search_query != socket.assigns.timeline_search_query) or
        (object_class_param_present? and next_search_object_class != socket.assigns.timeline_search_object_class)

    enter_live_from_param? = requested_mode == :live

    inferred_mode =
      cond do
        requested_mode == :live ->
          :timeline

        requested_mode in [:timeline, :published] ->
          requested_mode

        not is_nil(seek_us) or not is_nil(highlight_frame_id) or search_query != "" ->
          :timeline

        true ->
          nil
      end

    base_assigns = [
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
      clip_modal: nil,
      timeline_clips_page: 1,
      gaps_page: 1,
      timeline_user_selected_window?: false,
      timeline_search_query: next_search_query,
      timeline_search_object_class: next_search_object_class
    ]

    search_reset_assigns =
      if reset_search_state? do
        [
          timeline_search_results: [],
          timeline_search_executed?: false,
          timeline_search_error: nil,
          timeline_embedder_unavailable?: false,
          timeline_overlay_detections: []
        ]
      else
        []
      end

    switcher_reset_assigns =
      if camera_changed? do
        [
          switcher_open_mobile?: false,
          live_mode?: enter_live_from_param?,
          live_tile: nil,
          timeline_clips_mode: "smart",
          timeline_clips_mode_user_set?: false,
          timeline_clips_category: "all",
          roi_drawer_open?: false,
          roi_feedback: nil
        ]
      else
        if enter_live_from_param? do
          [live_mode?: true]
        else
          []
        end
      end

    socket = assign(socket, base_assigns ++ search_reset_assigns ++ switcher_reset_assigns)

    if connected?(socket) do
      socket = load_initial_or_switched_mode(socket)

      socket =
        if enter_live_from_param? and is_nil(socket.assigns.error) do
          start_live_stream(socket)
        else
          socket
        end

      {:noreply, socket}
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
        can_view_live={RBAC.can?(@current_scope, "devices.cameras.view")}
        can_edit_detection_zones={can_edit_detection_zones?(@current_scope)}
        stream_profiles={@stream_profiles}
        live_mode?={@live_mode?}
        live_tile={@live_tile}
        roi_drawer_open?={@roi_drawer_open?}
        roi_paint_mode={@roi_paint_mode}
        roi_focus_cells={@roi_focus_cells}
        roi_ignore_cells={@roi_ignore_cells}
        roi_saved_focus_cells={@roi_saved_focus_cells}
        roi_saved_ignore_cells={@roi_saved_ignore_cells}
        roi_feedback={@roi_feedback}
        roi_grid_cols={12}
        roi_grid_rows={8}
        timeline_profile_id={@timeline_profile_id}
        timeline_span={@timeline_span}
        timeline_source={@timeline_source}
        timeline_anchored_latest?={
          is_nil(@timeline_anchor_to_us) and is_nil(@timeline_custom_from_us)
        }
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
        timeline_event_markers={@timeline_event_markers}
        timeline_clips_mode={@timeline_clips_mode}
        timeline_clips_category={@timeline_clips_category}
        timeline_min_confidence={@timeline_min_confidence}
        timeline_clips_page={@timeline_clips_page}
        timeline_clips_total_count={@timeline_clips_total_count}
        timeline_clips_total_pages={@timeline_clips_total_pages}
        timeline_clips_counts={@timeline_clips_counts}
        timeline_selected_clip_id={@timeline_selected_clip_id}
        clip_modal={@clip_modal}
        gaps_page={@gaps_page}
        gaps_per_page={@gaps_per_page}
        timeline_manage_drawer_open?={@timeline_manage_drawer_open?}
        switcher_cameras={@switcher_cameras}
        switcher_search={@switcher_search}
        switcher_page={@switcher_page}
        switcher_total_count={@switcher_total_count}
        switcher_total_pages={@switcher_total_pages}
        switcher_open_mobile?={@switcher_open_mobile?}
        hold_form={@hold_form}
      />
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("switch_recordings_mode", %{"mode" => raw_mode}, socket) do
    case parse_mode_param(raw_mode) do
      :live ->
        socket =
          socket
          |> assign(
            mode: :timeline,
            requested_mode: :timeline,
            live_mode?: true,
            clip_modal: nil,
            error: nil
          )
          |> start_live_stream()

        {:noreply, socket}

      :timeline ->
        socket =
          assign(socket,
            mode: :timeline,
            requested_mode: :timeline,
            live_mode?: false,
            live_tile: nil,
            clip_modal: nil,
            error: nil
          )

        {:noreply, load_timeline(socket)}

      :published ->
        socket =
          assign(socket,
            mode: :published,
            requested_mode: :published,
            live_mode?: false,
            live_tile: nil,
            clip_modal: nil,
            error: nil
          )

        {:noreply, load_inventory(socket, nil)}

      nil ->
        {:noreply, authorize_only_or_unavailable(socket)}
    end
  end

  def handle_event("enter_live_mode", _params, socket) do
    socket =
      socket
      |> assign(
        mode: :timeline,
        live_mode?: true,
        timeline_selected_clip_id: nil,
        timeline_custom_from_us: nil,
        timeline_anchor_to_us: nil,
        timeline_seek_us: nil,
        timeline_highlight_frame_id: nil,
        timeline_user_selected_window?: false,
        timeline_clips_page: 1,
        gaps_page: 1,
        clip_modal: nil,
        error: nil
      )
      |> load_timeline()
      |> start_live_stream()

    {:noreply, socket}
  end

  def handle_event("exit_live_mode", _params, socket) do
    {:noreply, assign(socket, live_mode?: false, live_tile: nil)}
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
        timeline_clips_page: 1,
        gaps_page: 1,
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
          timeline_clips_page: 1,
          gaps_page: 1,
          error: nil
        )

      {:noreply, load_timeline(socket)}
    else
      {:noreply, authorize_only_or_unavailable(socket)}
    end
  end

  def handle_event("zoom_timeline_span", %{"direction" => direction}, socket) when direction in ["in", "out"] do
    current_idx = Enum.find_index(@span_order, &(&1 == socket.assigns.timeline_span)) || 1

    next_idx =
      case direction do
        "in" -> max(current_idx - 1, 0)
        "out" -> min(current_idx + 1, length(@span_order) - 1)
      end

    next_span = Enum.at(@span_order, next_idx)

    if next_span == socket.assigns.timeline_span do
      {:noreply, socket}
    else
      socket =
        assign(socket,
          timeline_span: next_span,
          timeline_custom_from_us: nil,
          timeline_clips_page: 1,
          gaps_page: 1,
          error: nil
        )

      {:noreply, load_timeline(socket)}
    end
  end

  def handle_event("set_timeline_zoom", %{"zoom" => raw_zoom}, socket) do
    # Zoom slider maps 0 (widest / 7d) .. 4 (tightest / 15m)
    zoom_spans = Enum.reverse(@span_order)

    next_span =
      case Integer.parse(to_string(raw_zoom)) do
        {idx, ""} when idx >= 0 and idx < length(zoom_spans) -> Enum.at(zoom_spans, idx)
        _ -> nil
      end

    cond do
      is_nil(next_span) ->
        {:noreply, authorize_only_or_unavailable(socket)}

      next_span == socket.assigns.timeline_span ->
        {:noreply, socket}

      true ->
        socket =
          assign(socket,
            timeline_span: next_span,
            timeline_custom_from_us: nil,
            timeline_clips_page: 1,
            gaps_page: 1,
            error: nil
          )

        {:noreply, load_timeline(socket)}
    end
  end

  def handle_event("seek_timeline_fraction", %{"fraction" => raw_fraction}, socket) do
    with {:ok, scope, source} <- authorize_timeline_view(socket),
         {:ok, fraction} <- parse_fraction(raw_fraction),
         %{from_us: cov_from_us, to_us: cov_to_us} = cov
         when is_integer(cov_from_us) and is_integer(cov_to_us) and cov_to_us > cov_from_us <-
           socket.assigns.timeline_coverage do
      # Vertical timeline: top (0.0) = newest (cov_to_us), bottom (1.0) = oldest (cov_from_us)
      target_us = round(cov_to_us - fraction * (cov_to_us - cov_from_us))
      target_us = min(max(target_us, cov_from_us), cov_to_us)

      socket =
        socket
        |> exit_live_mode_assigns()
        |> assign(:clip_modal, nil)
        |> focus_playback_on_timestamp(scope, source, cov, target_us)

      {:noreply, socket}
    else
      {:error, reason}
      when reason in [:unauthorized, :permission_revoked, :recording_block_not_found, :invalid_id] ->
        {:noreply, unavailable(socket, reason)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_manage_drawer", _params, socket) do
    {:noreply, assign(socket, timeline_manage_drawer_open?: not socket.assigns.timeline_manage_drawer_open?)}
  end

  def handle_event("close_manage_drawer", _params, socket) do
    {:noreply, assign(socket, timeline_manage_drawer_open?: false)}
  end

  def handle_event("toggle_switcher_mobile", _params, socket) do
    {:noreply, assign(socket, switcher_open_mobile?: not socket.assigns.switcher_open_mobile?)}
  end

  def handle_event("switcher_search", params, socket) do
    search =
      params
      |> Map.get("search", Map.get(params, "q", ""))
      |> to_string()
      |> String.trim()
      |> String.slice(0, 128)

    socket =
      socket
      |> assign(switcher_search: search, switcher_page: 1)
      |> load_camera_switcher()

    {:noreply, socket}
  end

  def handle_event("switcher_paginate", %{"page" => raw_page}, socket) do
    page =
      raw_page
      |> parse_positive_int(1)
      |> min(max(socket.assigns.switcher_total_pages, 1))

    socket =
      socket
      |> assign(switcher_page: page)
      |> load_camera_switcher()

    {:noreply, socket}
  end

  def handle_event("select_timeline_source", %{"source" => source}, socket) do
    if source in ["auto", "local", "archive"] do
      socket = assign(socket, timeline_source: source, gaps_page: 1, error: nil)
      {:noreply, load_timeline(socket)}
    else
      {:noreply, authorize_only_or_unavailable(socket)}
    end
  end

  def handle_event("select_gaps_page", %{"page" => raw_page}, socket) do
    gaps_count =
      case socket.assigns.timeline_coverage do
        %{gaps: gaps} when is_list(gaps) -> length(gaps)
        %{"gaps" => gaps} when is_list(gaps) -> length(gaps)
        _ -> 0
      end

    total_pages = max(div(gaps_count + @gaps_per_page - 1, @gaps_per_page), 1)

    page =
      raw_page
      |> parse_positive_int(1)
      |> min(total_pages)

    {:noreply, assign(socket, gaps_page: page)}
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
      socket
      |> exit_live_mode_assigns()
      |> assign(
        timeline_custom_from_us: nil,
        timeline_anchor_to_us: next_anchor_to_us,
        timeline_clips_page: 1,
        gaps_page: 1,
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
        |> exit_live_mode_assigns()
        |> assign(
          current_scope: scope,
          source: source,
          timeline_custom_from_us: custom_from_us,
          timeline_anchor_to_us: anchor_to_us,
          timeline_jump_at: format_us_for_datetime_local(target_us, tz, :floor, true),
          gaps_page: 1,
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
          socket,
          scope,
          source.id,
          play_from_us,
          play_to_us,
          nil,
          socket.assigns.timeline_search_results
        )

      has_adjacent? = adjacent_window_available?(play_to_us, cov_to_us, socket)

      {:noreply,
       socket
       |> exit_live_mode_assigns()
       |> assign(
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
            socket,
            scope,
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

  def handle_event("select_semantic_hit", params, socket) do
    handle_event("select_timeline_semantic_hit", params, socket)
  end

  def handle_event("select_timeline_semantic_hit", params, socket) do
    with {:ok, scope, source} <- authorize_timeline_view(socket),
         {:ok, seek_us} <- parse_required_int(params["seek_us"]) do
      clip_start_us = parse_non_neg_int(params["start_us"]) || seek_us
      clip_end_us = parse_non_neg_int(params["end_us"]) || max(clip_start_us + 2_000_000, seek_us)
      highlight_frame_id = parse_optional_uuid(params["frame_id"])
      cov = socket.assigns.timeline_coverage

      hit =
        find_matching_semantic_hit(
          socket.assigns.timeline_search_results,
          highlight_frame_id,
          seek_us
        )

      modal =
        build_clip_modal_from_hit(socket, scope, source, cov, %{
          clip_start_us: clip_start_us,
          clip_end_us: clip_end_us,
          seek_us: seek_us,
          highlight_frame_id: highlight_frame_id,
          hit: hit
        })

      {:noreply,
       assign(socket,
         current_scope: scope,
         source: source,
         clip_modal: modal,
         error: nil
       )}
    else
      {:error, reason}
      when reason in [:unauthorized, :permission_revoked, :recording_block_not_found, :invalid_id] ->
        {:noreply, unavailable(socket, reason)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("close_clip_modal", _params, socket) do
    {:noreply, assign(socket, clip_modal: nil)}
  end

  def handle_event("open_clip_in_timeline", _params, socket) do
    case socket.assigns.clip_modal do
      nil ->
        {:noreply, socket}

      modal ->
        case authorize_timeline_view(socket) do
          {:ok, scope, source} ->
            cov = socket.assigns.timeline_coverage

            socket =
              socket
              |> exit_live_mode_assigns()
              |> assign(current_scope: scope, source: source, clip_modal: nil, error: nil)
              |> focus_main_timeline_from_modal(scope, source, cov, modal)

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, unavailable(socket, reason)}
        end
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
    category = reconcile_category_for_mode(mode, socket.assigns.timeline_clips_category)

    socket =
      socket
      |> assign(
        timeline_clips_mode: mode,
        timeline_clips_category: category,
        timeline_clips_mode_user_set?: true,
        timeline_clips_page: 1
      )
      |> reload_event_clips_page()

    {:noreply, socket}
  end

  def handle_event("filter_event_clips_category", %{"category" => raw_category}, socket) do
    category = parse_clips_category(raw_category)
    mode = reconcile_mode_for_category(category, socket.assigns.timeline_clips_mode)

    socket =
      socket
      |> assign(
        timeline_clips_mode: mode,
        timeline_clips_category: category,
        timeline_clips_mode_user_set?: true,
        timeline_clips_page: 1
      )
      |> reload_event_clips_page()

    {:noreply, socket}
  end

  def handle_event("set_min_confidence", params, socket) do
    raw = Map.get(params, "min_confidence", Map.get(params, "value"))
    min_confidence = parse_min_confidence(raw, socket.assigns.timeline_min_confidence)

    socket =
      socket
      |> assign(
        timeline_min_confidence: min_confidence,
        timeline_clips_page: 1
      )
      |> reload_event_clips_page()
      |> refresh_overlay_detections_for_current_window()

    {:noreply, socket}
  end

  def handle_event("reset_event_clip_filters", _params, socket) do
    socket =
      socket
      |> assign(
        timeline_clips_mode: "all",
        timeline_clips_mode_user_set?: true,
        timeline_clips_category: "all",
        timeline_min_confidence: @default_min_confidence,
        timeline_clips_page: 1
      )
      |> reload_event_clips_page()
      |> refresh_overlay_detections_for_current_window()

    {:noreply, socket}
  end

  def handle_event("toggle_roi_drawer", _params, socket) do
    next_open? = not socket.assigns.roi_drawer_open?

    socket =
      if next_open? do
        socket
        |> assign(roi_drawer_open?: true, roi_feedback: nil)
        |> hydrate_roi_from_source(socket.assigns.source, reset_draft?: true)
      else
        assign(socket, roi_drawer_open?: false, roi_feedback: nil)
      end

    {:noreply, socket}
  end

  def handle_event("close_roi_drawer", _params, socket) do
    {:noreply, assign(socket, roi_drawer_open?: false, roi_feedback: nil)}
  end

  def handle_event("roi_set_paint_mode", %{"mode" => mode}, socket) when mode in ["focus", "ignore", "erase"] do
    {:noreply, assign(socket, roi_paint_mode: mode, roi_feedback: nil)}
  end

  def handle_event("roi_set_paint_mode", _params, socket), do: {:noreply, socket}

  def handle_event("roi_toggle_cell", %{"cell" => raw_cell}, socket) do
    case parse_roi_cell_index(raw_cell) do
      {:ok, idx} ->
        focus = socket.assigns.roi_focus_cells
        ignore = socket.assigns.roi_ignore_cells

        {next_focus, next_ignore} =
          case socket.assigns.roi_paint_mode do
            "focus" ->
              if MapSet.member?(focus, idx) do
                {MapSet.delete(focus, idx), ignore}
              else
                {MapSet.put(focus, idx), MapSet.delete(ignore, idx)}
              end

            "ignore" ->
              if MapSet.member?(ignore, idx) do
                {focus, MapSet.delete(ignore, idx)}
              else
                {MapSet.delete(focus, idx), MapSet.put(ignore, idx)}
              end

            "erase" ->
              {MapSet.delete(focus, idx), MapSet.delete(ignore, idx)}
          end

        {:noreply, assign(socket, roi_focus_cells: next_focus, roi_ignore_cells: next_ignore, roi_feedback: nil)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("roi_clear_grid", _params, socket) do
    {:noreply,
     assign(socket,
       roi_focus_cells: MapSet.new(),
       roi_ignore_cells: MapSet.new(),
       roi_feedback: nil
     )}
  end

  def handle_event("roi_reset_grid", _params, socket) do
    {:noreply,
     assign(socket,
       roi_focus_cells: socket.assigns.roi_saved_focus_cells,
       roi_ignore_cells: socket.assigns.roi_saved_ignore_cells,
       roi_feedback: nil
     )}
  end

  def handle_event("roi_save_grid", _params, socket) do
    with {:ok, scope, source} <- authorize_timeline_view(socket),
         true <- can_edit_detection_zones?(scope),
         false <- ptz_camera?(source) do
      roi_payload = build_roi_grid_payload(socket.assigns.roi_focus_cells, socket.assigns.roi_ignore_cells)

      case deps(socket).save_roi_grid.(source, roi_payload, scope) do
        {:ok, updated_source} ->
          {:noreply,
           assign(socket,
             current_scope: scope,
             source: updated_source,
             roi_saved_focus_cells: socket.assigns.roi_focus_cells,
             roi_saved_ignore_cells: socket.assigns.roi_ignore_cells,
             roi_feedback: "Detection zones saved."
           )}

        {:error, reason} ->
          Logger.warning("Failed to save camera ROI grid for #{source.id}: #{inspect(reason)}")
          {:noreply, assign(socket, roi_feedback: "Could not save detection zones.")}
      end
    else
      false ->
        {:noreply, assign(socket, roi_feedback: "Not authorized to edit detection zones.")}

      true ->
        {:noreply, assign(socket, roi_feedback: "Detection zones are not applicable for PTZ cameras.")}

      {:error, reason} ->
        {:noreply, unavailable(socket, reason)}
    end
  end

  def handle_event("paginate_event_clips", %{"page" => raw_page}, socket) do
    page =
      raw_page
      |> parse_positive_int(1)
      |> min(max(socket.assigns.timeline_clips_total_pages, 1))

    socket =
      socket
      |> assign(timeline_clips_page: page)
      |> reload_event_clips_page()

    {:noreply, socket}
  end

  def handle_event("select_event_clip", %{"clip_id" => clip_id}, socket) do
    with {:ok, scope, source} <- authorize_timeline_view(socket),
         clip when is_map(clip) <-
           find_event_clip(socket.assigns.timeline_event_clips, clip_id) ||
             find_event_clip(socket.assigns.timeline_event_markers, clip_id) do
      cov = socket.assigns.timeline_coverage
      modal = build_clip_modal_from_clip(socket, scope, source, cov, clip)

      {:noreply,
       assign(socket,
         current_scope: scope,
         source: source,
         timeline_selected_clip_id: clip.id,
         clip_modal: modal,
         error: nil
       )}
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
  def handle_async(:camera_live_open, {:ok, tile}, socket) do
    if socket.assigns.live_mode? do
      schedule_live_relay_refresh(tile)
      {:noreply, socket |> assign(:live_tile, tile) |> subscribe_live_tile(tile)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:camera_live_open, {:exit, reason}, socket) do
    Logger.warning("Camera workspace live relay open failed: #{inspect(reason, limit: 20, printable_limit: 200)}")

    if socket.assigns.live_mode? do
      {:noreply,
       assign(socket, :live_tile, %{
         label: (socket.assigns.source && socket.assigns.source.display_name) || "Camera",
         detail: "Primary stream",
         session: nil,
         error: "Camera relay session could not be opened"
       })}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:refresh_camera_live_relay_session, relay_session_id}, socket) do
    {:noreply, refresh_live_tile(socket, relay_session_id, rearm: true)}
  end

  def handle_info({:camera_relay_state, %{relay_session_id: relay_session_id}}, socket)
      when is_binary(relay_session_id) do
    {:noreply, refresh_live_tile(socket, relay_session_id, rearm: false)}
  end

  def handle_info({:camera_relay_state, _payload}, socket), do: {:noreply, socket}
  def handle_info({:camera_relay_webrtc_closed, _payload}, socket), do: {:noreply, socket}
  def handle_info({:camera_relay_chunk, _payload}, socket), do: {:noreply, socket}
  def handle_info({:camera_relay_viewer_chunk, _payload}, socket), do: {:noreply, socket}

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

        socket =
          socket
          |> assign(current_scope: scope, source: source, mode: effective_mode)
          |> load_camera_switcher_for_scope(scope)

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
          socket,
          scope,
          source.id,
          play_from_us,
          play_to_us,
          socket.assigns.timeline_highlight_frame_id,
          socket.assigns.timeline_search_results
        )

      has_adjacent? = adjacent_window_available?(play_to_us, cov_to_us, socket)
      tz = user_timezone(scope)

      {effective_clips_mode, effective_clips_category, clips_page} =
        load_event_clips_with_smart_default(
          socket,
          source.id,
          cov_from_us,
          cov_to_us,
          profile_id,
          coverage.blocks,
          scope
        )

      selected_clip_id =
        case find_event_clip(clips_page.clips, socket.assigns.timeline_selected_clip_id) ||
               find_event_clip(clips_page.markers, socket.assigns.timeline_selected_clip_id) do
          %{} = clip ->
            if clip_in_play_window?(clip, play_from_us, play_to_us), do: clip.id

          nil ->
            nil
        end

      socket
      |> maybe_rearm_live_refresh(source.id)
      |> hydrate_roi_from_source(source, reset_draft?: not socket.assigns.roi_drawer_open?)
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
        timeline_event_clips: clips_page.clips,
        timeline_event_markers: clips_page.markers,
        timeline_clips_mode: effective_clips_mode,
        timeline_clips_category: effective_clips_category,
        timeline_clips_page: clips_page.page,
        timeline_clips_total_count: clips_page.total_count,
        timeline_clips_total_pages: clips_page.total_pages,
        timeline_clips_counts: clips_page.counts,
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
        socket,
        socket.assigns.current_scope,
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

  defp parse_mode_param("live"), do: :live
  defp parse_mode_param("timeline"), do: :timeline
  defp parse_mode_param("published"), do: :published
  defp parse_mode_param(_), do: nil

  defp parse_span_param(span) when span in ["15m", "1h", "6h", "24h", "7d"], do: span
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
      timeline_event_markers: [],
      timeline_clips_page: 1,
      timeline_clips_total_count: 0,
      timeline_clips_total_pages: 1,
      timeline_clips_counts: default_clip_counts(),
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
    if is_binary(socket.assigns.recording_subscribed_source_id) do
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
      clips_page =
        load_event_clips_page(
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
          clips_page: clips_page
        })
      else
        assign_live_refresh_without_active_playback(socket, scope, source, %{
          profiles: profiles,
          coverage: coverage,
          cov_from_us: cov_from_us,
          cov_to_us: cov_to_us,
          all_holds: all_holds,
          clips_page: clips_page
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
         clips_page: clips_page
       }) do
    play_from_us = socket.assigns.timeline_play_from_us
    play_to_us = socket.assigns.timeline_play_to_us

    overlay_detections =
      resolve_overlay_detections(
        socket,
        scope,
        source.id,
        play_from_us,
        play_to_us,
        socket.assigns.timeline_highlight_frame_id,
        socket.assigns.timeline_search_results
      )

    has_adjacent_window? =
      is_nil(socket.assigns.timeline_selected_clip_id) and
        is_nil(socket.assigns.timeline_highlight_frame_id) and
        adjacent_window_available?(play_to_us || cov_to_us, cov_to_us, socket)

    base_assigns = [
      current_scope: scope,
      source: source,
      mode: :timeline,
      stream_profiles: profiles,
      timeline_coverage: coverage,
      timeline_overlay_detections: overlay_detections,
      timeline_has_adjacent_window: has_adjacent_window?,
      timeline_holds: all_holds,
      timeline_event_clips: clips_page.clips,
      timeline_event_markers: clips_page.markers,
      timeline_clips_page: clips_page.page,
      timeline_clips_total_count: clips_page.total_count,
      timeline_clips_total_pages: clips_page.total_pages,
      timeline_clips_counts: clips_page.counts,
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
         clips_page: clips_page
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
        socket,
        scope,
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
      timeline_event_clips: clips_page.clips,
      timeline_event_markers: clips_page.markers,
      timeline_clips_page: clips_page.page,
      timeline_clips_total_count: clips_page.total_count,
      timeline_clips_total_pages: clips_page.total_pages,
      timeline_clips_counts: clips_page.counts,
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
        RecordingEventClips.list_page(source_id, params, actor: scope.user)
      end,
      list_cameras: &default_list_cameras/2,
      list_window_overlays: &default_list_window_overlays/5,
      get_frame_overlay: &default_get_frame_overlay/3,
      open_source_preview: &CameraMultiview.open_source_preview/3,
      save_roi_grid: &default_save_roi_grid/3,
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
          socket,
          scope,
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
              socket,
              scope,
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
    padded_start_us = max(min(clip_start_us, seek_us) - 5_000_000, 0)
    padded_end_us = max(clip_end_us, seek_us) + 10_000_000

    {play_from_us, play_to_us} =
      case cov do
        %{from_us: cov_from, to_us: cov_to} when is_integer(cov_from) and is_integer(cov_to) ->
          clamped_from = max(padded_start_us, cov_from)
          clamped_to = min(padded_end_us, min(clamped_from + @max_playlist_window_us, cov_to))
          {clamped_from, max(clamped_to, clamped_from + 1_000_000)}

        _ ->
          {padded_start_us, min(padded_end_us, padded_start_us + @max_playlist_window_us)}
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
        socket,
        scope,
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
      timeline_has_adjacent_window: false,
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

  defp resolve_overlay_detections(socket, scope, source_id, play_from_us, play_to_us, highlight_frame_id, search_results) do
    from_results = detections_from_search_results(search_results, play_from_us, play_to_us)

    from_window =
      if is_binary(source_id) and is_integer(play_from_us) and is_integer(play_to_us) and
           play_to_us > play_from_us do
        List.wrap(
          deps(socket).list_window_overlays.(
            source_id,
            play_from_us,
            play_to_us,
            socket.assigns.timeline_profile_id,
            scope
          )
        )
      else
        []
      end

    has_highlighted? =
      is_binary(highlight_frame_id) and
        Enum.any?(
          from_results ++ from_window,
          &(to_string(&1[:visual_frame_id] || "") == highlight_frame_id)
        )

    from_highlight =
      if is_binary(highlight_frame_id) and not has_highlighted? do
        List.wrap(deps(socket).get_frame_overlay.(source_id, highlight_frame_id, scope))
      else
        []
      end

    min_conf = (socket.assigns[:timeline_min_confidence] || @default_min_confidence) / 100.0

    (from_highlight ++ from_results ++ from_window)
    |> deduplicate_overlay_detections()
    |> filter_overlay_detections_by_confidence(min_conf)
  end

  defp filter_overlay_detections_by_confidence(detections, min_conf) when is_number(min_conf) do
    Enum.filter(detections, fn det ->
      score = det[:score] || det["score"]
      not is_number(score) or score >= min_conf
    end)
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

  defp default_list_window_overlays(source_id, from_us, to_us, profile_id, scope)
       when is_binary(source_id) and is_integer(from_us) and is_integer(to_us) and to_us > from_us do
    case CameraSemanticSearch.list_window_overlays(scope, source_id, from_us, to_us, profile_id) do
      {:ok, detections} when is_list(detections) -> detections
      _ -> []
    end
  rescue
    exception ->
      Logger.warning(
        "Failed to list window overlays for source #{inspect(source_id)}: #{Exception.format(:error, exception, __STACKTRACE__)}"
      )

      []
  end

  defp default_list_window_overlays(_source_id, _from_us, _to_us, _profile_id, _scope), do: []

  defp default_get_frame_overlay(source_id, highlight_frame_id, scope)
       when is_binary(source_id) and is_binary(highlight_frame_id) do
    case CameraSemanticSearch.get_frame_overlay(scope, source_id, highlight_frame_id) do
      {:ok, detections} when is_list(detections) -> detections
      _ -> []
    end
  rescue
    _ -> []
  end

  defp default_get_frame_overlay(_source_id, _highlight_frame_id, _scope), do: []

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

  defp load_event_clips_with_smart_default(socket, source_id, from_us, to_us, profile_id, catalog_blocks, scope) do
    if socket.assigns[:timeline_clips_mode_user_set?] do
      mode = socket.assigns.timeline_clips_mode
      category = reconcile_category_for_mode(mode, socket.assigns.timeline_clips_category)

      page =
        load_event_clips_page(
          socket,
          source_id,
          from_us,
          to_us,
          profile_id,
          catalog_blocks,
          scope,
          mode: mode,
          category: category
        )

      {mode, category, page}
    else
      smart_page =
        load_event_clips_page(
          socket,
          source_id,
          from_us,
          to_us,
          profile_id,
          catalog_blocks,
          scope,
          mode: "smart",
          category: "all"
        )

      counts = smart_page.counts || %{}

      cond do
        Map.get(counts, :smart, 0) > 0 ->
          {"smart", "all", smart_page}

        Map.get(counts, :motion, 0) > 0 ->
          motion_page =
            load_event_clips_page(
              socket,
              source_id,
              from_us,
              to_us,
              profile_id,
              catalog_blocks,
              scope,
              mode: "basic",
              category: "motion"
            )

          {"basic", "motion", motion_page}

        true ->
          all_page =
            load_event_clips_page(
              socket,
              source_id,
              from_us,
              to_us,
              profile_id,
              catalog_blocks,
              scope,
              mode: "all",
              category: "all"
            )

          {"all", "all", all_page}
      end
    end
  end

  defp load_event_clips_page(socket, source_id, from_us, to_us, profile_id, catalog_blocks, scope, overrides \\ []) do
    mode = Keyword.get(overrides, :mode, socket.assigns.timeline_clips_mode)
    category = Keyword.get(overrides, :category, socket.assigns.timeline_clips_category)
    min_confidence = (socket.assigns[:timeline_min_confidence] || @default_min_confidence) / 100.0

    params = %{
      from_us: from_us,
      to_us: to_us,
      stream_profile_id: profile_id,
      catalog_blocks: catalog_blocks,
      mode: mode,
      category: category,
      min_confidence: min_confidence,
      page: socket.assigns.timeline_clips_page,
      per_page: socket.assigns.timeline_clips_per_page
    }

    case deps(socket).list_event_clips.(source_id, params, scope) do
      {:ok, %{} = result} ->
        normalize_event_clips_page(result, params)

      _ ->
        empty_event_clips_page(params.per_page)
    end
  end

  defp refresh_overlay_detections_for_current_window(socket) do
    source = socket.assigns.source
    scope = socket.assigns.current_scope

    case source do
      %{id: source_id} when is_binary(source_id) ->
        overlay_detections =
          resolve_overlay_detections(
            socket,
            scope,
            source_id,
            socket.assigns.timeline_play_from_us,
            socket.assigns.timeline_play_to_us,
            socket.assigns.timeline_highlight_frame_id,
            socket.assigns.timeline_search_results
          )

        assign(socket, timeline_overlay_detections: overlay_detections)

      _ ->
        socket
    end
  end

  defp reload_event_clips_page(socket) do
    cov = socket.assigns.timeline_coverage
    source = socket.assigns.source
    scope = socket.assigns.current_scope

    if is_map(cov) and is_map(source) and is_integer(cov[:from_us]) and is_integer(cov[:to_us]) do
      profile_id = blank_to_nil(socket.assigns.timeline_profile_id)
      blocks = cov[:blocks] || []

      clips_page =
        load_event_clips_page(
          socket,
          source.id,
          cov.from_us,
          cov.to_us,
          profile_id,
          blocks,
          scope
        )

      assign(socket,
        timeline_event_clips: clips_page.clips,
        timeline_event_markers: clips_page.markers,
        timeline_clips_page: clips_page.page,
        timeline_clips_total_count: clips_page.total_count,
        timeline_clips_total_pages: clips_page.total_pages,
        timeline_clips_counts: clips_page.counts
      )
    else
      socket
    end
  end

  defp normalize_event_clips_page(
         %{clips: clips, counts: counts, total_count: total_count, markers: markers} = result,
         params
       )
       when is_list(clips) and is_map(counts) and is_integer(total_count) and is_list(markers) do
    per_page = result[:per_page] || params[:per_page] || RecordingEventClips.default_per_page()
    total_pages = result[:total_pages] || max(div(total_count + per_page - 1, per_page), 1)
    page = min(result[:page] || params[:page] || 1, total_pages)

    %{
      clips: clips,
      total_count: total_count,
      page: page,
      per_page: per_page,
      total_pages: total_pages,
      counts: Map.merge(default_clip_counts(), counts),
      markers: markers
    }
  end

  defp normalize_event_clips_page(_other, params) do
    empty_event_clips_page(params[:per_page] || RecordingEventClips.default_per_page())
  end

  defp empty_event_clips_page(per_page) do
    %{
      clips: [],
      total_count: 0,
      page: 1,
      per_page: per_page,
      total_pages: 1,
      counts: default_clip_counts(),
      markers: []
    }
  end

  defp default_clip_counts do
    %{
      all: 0,
      smart: 0,
      basic: 0,
      person: 0,
      vehicle: 0,
      animal: 0,
      package: 0,
      motion: 0,
      recording: 0
    }
  end

  defp load_camera_switcher(socket) do
    case authorize_timeline_view(socket) do
      {:ok, scope, source} ->
        socket
        |> assign(current_scope: scope, source: source)
        |> load_camera_switcher_for_scope(scope)

      {:error, reason} ->
        unavailable(socket, reason)
    end
  end

  defp load_camera_switcher_for_scope(socket, scope) do
    opts = %{
      search: socket.assigns.switcher_search,
      page: socket.assigns.switcher_page,
      per_page: socket.assigns.switcher_per_page
    }

    case deps(socket).list_cameras.(scope, opts) do
      {:ok, %{} = result} ->
        per_page = result[:per_page] || socket.assigns.switcher_per_page
        total_count = result[:total_count] || length(result[:cameras] || [])
        total_pages = result[:total_pages] || max(div(total_count + per_page - 1, per_page), 1)
        page = min(result[:page] || socket.assigns.switcher_page, total_pages)

        assign(socket,
          switcher_cameras: result[:cameras] || [],
          switcher_total_count: total_count,
          switcher_total_pages: total_pages,
          switcher_page: page
        )

      {:error, reason} ->
        Logger.warning("Failed to list cameras for switcher: #{inspect(reason)}")
        socket

      _ ->
        socket
    end
  end

  defp default_list_cameras(scope, opts) do
    search = String.trim(to_string(opts[:search] || ""))
    per_page = min(max(parse_positive_int(opts[:per_page], @default_switcher_per_page), 1), 50)
    requested_page = parse_positive_int(opts[:page], 1)

    base_query =
      Source
      |> Ash.Query.for_read(:read, %{})
      |> maybe_filter_cameras_search(search)

    with {:ok, total_count} <- Ash.count(base_query, scope: scope) do
      total_pages = max(div(total_count + per_page - 1, per_page), 1)
      page = min(requested_page, total_pages)
      offset = (page - 1) * per_page

      page_query =
        base_query
        |> Ash.Query.sort(display_name: :asc, id: :asc)
        |> Ash.Query.offset(offset)
        |> Ash.Query.limit(per_page)

      with {:ok, cameras} <- Ash.read(page_query, scope: scope) do
        {:ok,
         %{
           cameras: cameras,
           total_count: total_count,
           page: page,
           per_page: per_page,
           total_pages: total_pages
         }}
      end
    end
  rescue
    exception ->
      Logger.warning("Failed to list cameras for switcher: #{Exception.format(:error, exception, __STACKTRACE__)}")

      {:ok, %{cameras: [], total_count: 0, page: 1, per_page: @default_switcher_per_page, total_pages: 1}}
  end

  defp maybe_filter_cameras_search(query, ""), do: query

  defp maybe_filter_cameras_search(query, search) do
    pattern = "%" <> escape_like(search) <> "%"

    Ash.Query.filter(
      query,
      fragment("coalesce(?, '') ILIKE ? ESCAPE '!'", display_name, ^pattern) or
        fragment("coalesce(?, '') ILIKE ? ESCAPE '!'", vendor, ^pattern) or
        fragment("coalesce(?, '') ILIKE ? ESCAPE '!'", vendor_camera_id, ^pattern) or
        fragment("coalesce(?, '') ILIKE ? ESCAPE '!'", availability_status, ^pattern) or
        fragment("coalesce(?, '') ILIKE ? ESCAPE '!'", assigned_agent_id, ^pattern) or
        fragment("coalesce(?->>'site', '') ILIKE ? ESCAPE '!'", metadata, ^pattern)
    )
  end

  defp escape_like(value) do
    value
    |> String.replace("!", "!!")
    |> String.replace("%", "!%")
    |> String.replace("_", "!_")
  end

  defp focus_playback_on_timestamp(socket, scope, source, cov, target_us) do
    tz = user_timezone(scope)
    cov_from_us = cov.from_us
    cov_to_us = cov.to_us

    {play_from_us, play_to_us} =
      if cov_to_us - cov_from_us <= @max_playlist_window_us do
        {cov_from_us, cov_to_us}
      else
        lead_in_us = 300_000_000

        start_us =
          target_us
          |> Kernel.-(lead_in_us)
          |> min(cov_to_us - @max_playlist_window_us)
          |> max(cov_from_us)

        {start_us, min(start_us + @max_playlist_window_us, cov_to_us)}
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
      compute_seek_offset_seconds(target_us, playlist_origin_us, play_to_us)

    overlay_detections =
      resolve_overlay_detections(
        socket,
        scope,
        source.id,
        play_from_us,
        play_to_us,
        nil,
        socket.assigns.timeline_search_results
      )

    assign(socket,
      current_scope: scope,
      source: source,
      timeline_selected_clip_id: nil,
      timeline_user_selected_window?: true,
      timeline_play_from_us: play_from_us,
      timeline_play_to_us: play_to_us,
      timeline_playlist_origin_us: playlist_origin_us,
      timeline_seek_us: target_us,
      timeline_seek_offset_seconds: seek_offset_seconds,
      timeline_highlight_frame_id: nil,
      timeline_overlay_detections: overlay_detections,
      timeline_jump_at: format_us_for_datetime_local(target_us, tz, :floor, true),
      timeline_playlist_path: playlist_path,
      timeline_has_adjacent_window: adjacent_window_available?(play_to_us, cov_to_us, socket),
      hold_form: to_form(default_hold_form_params(play_from_us, play_to_us, tz, true), as: :hold),
      error: nil
    )
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

  defp build_clip_modal_from_clip(socket, scope, source, cov, clip) do
    {padded_start_us, padded_end_us} =
      if Map.get(clip, :category) in [:recording, "recording"] do
        {clip.start_us, clip.end_us}
      else
        {max(clip.start_us - 5_000_000, 0), clip.end_us + 10_000_000}
      end

    {play_from_us, play_to_us} = clamp_clip_window_to_coverage(cov, padded_start_us, padded_end_us)
    seek_us = Map.get(clip, :peak_ts_us) || clip.start_us
    visual_frame_id = Map.get(clip, :visual_frame_id)

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
        socket,
        scope,
        source.id,
        play_from_us,
        play_to_us,
        visual_frame_id,
        socket.assigns.timeline_search_results
      )

    category = normalize_modal_category(Map.get(clip, :category))
    timestamp_us = Map.get(clip, :start_us) || seek_us

    %{
      kind: :clip,
      clip_id: to_string(clip.id),
      camera_name: source.display_name || "Camera",
      category: category,
      label: Map.get(clip, :label) || modal_category_label(category),
      confidence: Map.get(clip, :confidence),
      timestamp_us: timestamp_us,
      started_at: Map.get(clip, :started_at) || us_to_datetime_safe(timestamp_us),
      start_us: clip.start_us,
      end_us: clip.end_us,
      play_from_us: play_from_us,
      play_to_us: play_to_us,
      playlist_origin_us: playlist_origin_us,
      playlist_path: playlist_path,
      seek_us: seek_us,
      seek_offset_seconds: seek_offset_seconds,
      highlight_frame_id: visual_frame_id,
      overlay_detections: overlay_detections,
      clip: clip
    }
  end

  defp build_clip_modal_from_hit(socket, scope, source, cov, %{
         clip_start_us: clip_start_us,
         clip_end_us: clip_end_us,
         seek_us: seek_us,
         highlight_frame_id: highlight_frame_id,
         hit: hit
       }) do
    padded_start_us = max(min(clip_start_us, seek_us) - 5_000_000, 0)
    padded_end_us = max(clip_end_us, seek_us) + 10_000_000

    inside_cov? =
      is_map(cov) and is_integer(cov.from_us) and is_integer(cov.to_us) and seek_us >= cov.from_us and
        seek_us <= cov.to_us

    {play_from_us, play_to_us} =
      if inside_cov? do
        clamp_clip_window_to_coverage(cov, padded_start_us, padded_end_us)
      else
        {padded_start_us, min(padded_end_us, padded_start_us + @max_playlist_window_us)}
      end

    playlist_path =
      if inside_cov? do
        build_playlist_path_if_playable(
          source.id,
          cov,
          play_from_us,
          play_to_us,
          socket.assigns.timeline_profile_id,
          socket.assigns.timeline_source
        )
      else
        build_direct_playlist_path(
          source.id,
          play_from_us,
          play_to_us,
          socket.assigns.timeline_profile_id,
          socket.assigns.timeline_source
        )
      end

    playlist_origin_us =
      if inside_cov? do
        compute_playlist_origin_us(cov, play_from_us, play_to_us, socket.assigns.timeline_source)
      else
        play_from_us
      end

    seek_offset_seconds =
      compute_seek_offset_seconds(seek_us, playlist_origin_us, play_to_us)

    overlay_detections =
      resolve_overlay_detections(
        socket,
        scope,
        source.id,
        play_from_us,
        play_to_us,
        highlight_frame_id,
        socket.assigns.timeline_search_results
      )

    raw_class = (is_map(hit) && Map.get(hit, :object_class)) || nil
    category = normalize_modal_category(raw_class)

    %{
      kind: :semantic_hit,
      clip_id: nil,
      camera_name: source.display_name || "Camera",
      category: category,
      label: modal_category_label(category),
      confidence: is_map(hit) && Map.get(hit, :score),
      timestamp_us: seek_us,
      started_at: us_to_datetime_safe(seek_us),
      start_us: clip_start_us,
      end_us: clip_end_us,
      play_from_us: play_from_us,
      play_to_us: play_to_us,
      playlist_origin_us: playlist_origin_us,
      playlist_path: playlist_path,
      seek_us: seek_us,
      seek_offset_seconds: seek_offset_seconds,
      highlight_frame_id: highlight_frame_id,
      overlay_detections: overlay_detections,
      clip: nil
    }
  end

  defp focus_main_timeline_from_modal(socket, scope, source, cov, %{kind: :clip, clip: clip}) when is_map(clip) do
    focus_playback_on_event_clip(socket, scope, source, cov, clip)
  end

  defp focus_main_timeline_from_modal(socket, scope, source, cov, modal) do
    seek_us = modal.seek_us
    clip_start_us = modal.start_us
    clip_end_us = modal.end_us

    socket =
      assign(socket,
        timeline_selected_clip_id: nil,
        timeline_seek_us: seek_us,
        timeline_highlight_frame_id: modal.highlight_frame_id
      )

    if is_map(cov) and is_integer(cov.from_us) and is_integer(cov.to_us) and
         seek_us >= cov.from_us and seek_us <= cov.to_us do
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
  end

  defp clamp_clip_window_to_coverage(cov, padded_start_us, padded_end_us) do
    case cov do
      %{from_us: cov_from, to_us: cov_to} when is_integer(cov_from) and is_integer(cov_to) ->
        clamped_from = max(padded_start_us, cov_from)
        clamped_to = min(padded_end_us, min(clamped_from + @max_playlist_window_us, cov_to))
        {clamped_from, max(clamped_to, clamped_from + 1_000_000)}

      _ ->
        {padded_start_us, min(padded_end_us, padded_start_us + @max_playlist_window_us)}
    end
  end

  defp build_direct_playlist_path(source_id, play_from_us, play_to_us, profile_id, source_str) do
    query_items =
      [
        {"from", Integer.to_string(play_from_us)},
        {"to", Integer.to_string(play_to_us)},
        {"source", playlist_source_param(source_str)}
      ] ++
        if(profile_id in [nil, ""], do: [], else: [{"profile", profile_id}])

    "/api/cameras/#{source_id}/timeline/playlist.m3u8?" <> URI.encode_query(query_items)
  end

  defp find_matching_semantic_hit(results, frame_id, seek_us) when is_list(results) do
    Enum.find(results, fn hit ->
      (is_binary(frame_id) and frame_id != "" and Map.get(hit, :visual_frame_id) == frame_id) or
        Map.get(hit, :best_timeline_ts_us) == seek_us
    end)
  end

  defp find_matching_semantic_hit(_, _, _), do: nil

  defp normalize_modal_category(cat) when cat in [:person, :animal, :vehicle, :package, :motion, :recording], do: cat

  defp normalize_modal_category(raw) when is_binary(raw) do
    case String.downcase(String.trim(raw)) do
      "person" -> :person
      "human" -> :person
      "pedestrian" -> :person
      "animal" -> :animal
      "dog" -> :animal
      "cat" -> :animal
      "vehicle" -> :vehicle
      "car" -> :vehicle
      "truck" -> :vehicle
      "bicycle" -> :vehicle
      "package" -> :package
      "motion" -> :motion
      "recording" -> :recording
      _ -> :motion
    end
  end

  defp normalize_modal_category(_), do: :motion

  defp modal_category_label(:person), do: "Person"
  defp modal_category_label(:animal), do: "Animal"
  defp modal_category_label(:vehicle), do: "Vehicle"
  defp modal_category_label(:package), do: "Package"
  defp modal_category_label(:motion), do: "Motion"
  defp modal_category_label(:recording), do: "Recording"
  defp modal_category_label(_), do: "Detection"

  defp us_to_datetime_safe(us) when is_integer(us) do
    case DateTime.from_unix(us, :microsecond) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp us_to_datetime_safe(_), do: nil

  defp focus_playback_on_event_clip(socket, scope, source, cov, clip) do
    tz = user_timezone(scope)

    {padded_start_us, padded_end_us} =
      if clip[:category] in [:recording, "recording"] do
        {clip.start_us, clip.end_us}
      else
        {max(clip.start_us - 5_000_000, 0), clip.end_us + 10_000_000}
      end

    {play_from_us, play_to_us} =
      case cov do
        %{from_us: cov_from, to_us: cov_to} when is_integer(cov_from) and is_integer(cov_to) ->
          clamped_from = max(padded_start_us, cov_from)
          clamped_to = min(padded_end_us, min(clamped_from + @max_playlist_window_us, cov_to))
          {clamped_from, max(clamped_to, clamped_from + 1_000_000)}

        _ ->
          {padded_start_us, min(padded_end_us, padded_start_us + @max_playlist_window_us)}
      end

    seek_us = clip[:peak_ts_us] || clip.start_us
    visual_frame_id = clip[:visual_frame_id]

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
        socket,
        scope,
        source.id,
        play_from_us,
        play_to_us,
        visual_frame_id,
        socket.assigns.timeline_search_results
      )

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
      timeline_highlight_frame_id: visual_frame_id,
      timeline_overlay_detections: overlay_detections,
      timeline_jump_at: format_us_for_datetime_local(play_from_us, tz, :floor, true),
      timeline_playlist_path: playlist_path,
      timeline_has_adjacent_window: false,
      hold_form: to_form(default_hold_form_params(play_from_us, play_to_us, tz, true), as: :hold),
      error: nil
    )
  end

  defp parse_clips_mode(mode) when mode in ["all", "smart", "basic"], do: mode
  defp parse_clips_mode(_), do: "all"

  defp parse_clips_category(cat) when cat in ["all", "person", "vehicle", "animal", "package", "motion", "recording"],
    do: cat

  defp parse_clips_category(_), do: "all"

  defp reconcile_category_for_mode("smart", category) when category in @basic_clip_categories, do: "all"
  defp reconcile_category_for_mode("basic", category) when category in @smart_clip_categories, do: "all"
  defp reconcile_category_for_mode(_mode, category), do: category

  defp reconcile_mode_for_category(category, "smart") when category in @basic_clip_categories, do: "basic"
  defp reconcile_mode_for_category(category, "basic") when category in @smart_clip_categories, do: "smart"
  defp reconcile_mode_for_category(_category, mode), do: mode

  defp parse_fraction(val) when is_float(val) and val >= 0.0 and val <= 1.0, do: {:ok, val}
  defp parse_fraction(val) when is_integer(val) and val in [0, 1], do: {:ok, val * 1.0}

  defp parse_fraction(val) when is_binary(val) do
    case Float.parse(String.trim(val)) do
      {f, ""} when f >= 0.0 and f <= 1.0 -> {:ok, f}
      _ -> :error
    end
  end

  defp parse_fraction(_), do: :error

  defp parse_positive_int(val, _default) when is_integer(val) and val >= 1, do: val

  defp parse_positive_int(val, default) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {n, ""} when n >= 1 -> n
      _ -> default
    end
  end

  defp parse_positive_int(_, default), do: default

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

  defp can_edit_detection_zones?(scope) do
    RBAC.can_any?(scope, @roi_edit_permissions)
  end

  defp exit_live_mode_assigns(socket) do
    if socket.assigns[:live_mode?] do
      assign(socket, live_mode?: false, live_tile: nil)
    else
      socket
    end
  end

  defp start_live_stream(socket) do
    scope = socket.assigns.current_scope
    source_id = current_source_id(socket)
    source_label = (socket.assigns.source && socket.assigns.source.display_name) || "Camera Feed"

    if RBAC.can?(scope, "devices.cameras.view") do
      profile_id = blank_to_nil(socket.assigns.timeline_profile_id)
      open_fn = deps(socket).open_source_preview

      socket
      |> assign(:live_tile, %{
        label: source_label,
        detail: "Opening live camera relay...",
        session: nil,
        error: "Opening camera relay"
      })
      |> start_async(:camera_live_open, fn ->
        open_fn.(scope, source_id, quality: "high", stream_profile_id: profile_id)
      end)
    else
      assign(socket, :live_tile, %{
        label: source_label,
        detail: "Live stream",
        session: nil,
        error: "Not authorized to view live camera streams"
      })
    end
  end

  defp refresh_live_tile(socket, relay_session_id, rearm: rearm?) do
    tile = socket.assigns[:live_tile]

    if socket.assigns[:live_mode?] and CameraMultiview.session_id(tile) == relay_session_id do
      refreshed = CameraMultiview.refresh_tile_session(socket.assigns.current_scope, tile)

      if rearm? or CameraMultiview.session_id(refreshed) != relay_session_id,
        do: schedule_live_relay_refresh(refreshed)

      socket
      |> assign(:live_tile, refreshed)
      |> subscribe_live_tile(refreshed)
    else
      socket
    end
  end

  defp subscribe_live_tile(socket, tile) do
    subscribed =
      CameraMultiview.subscribe_relay_state(
        socket.assigns[:live_relay_subscriptions] || MapSet.new(),
        tile
      )

    assign(socket, :live_relay_subscriptions, subscribed)
  end

  defp schedule_live_relay_refresh(tile) do
    case CameraMultiview.session_id(tile) do
      session_id when is_binary(session_id) ->
        Process.send_after(
          self(),
          {:refresh_camera_live_relay_session, session_id},
          CameraMultiview.fallback_refresh_ms()
        )

      _ ->
        :ok
    end
  end

  defp parse_min_confidence(val, fallback) when is_integer(val) do
    val |> max(@min_confidence_min) |> min(@min_confidence_max)
  rescue
    _ -> fallback
  end

  defp parse_min_confidence(val, fallback) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {n, ""} -> parse_min_confidence(n, fallback)
      _ -> fallback
    end
  end

  defp parse_min_confidence(_val, fallback), do: fallback

  defp parse_roi_cell_index(val) when is_integer(val) and val >= 0 and val < @roi_grid_cell_count, do: {:ok, val}

  defp parse_roi_cell_index(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {n, ""} when n >= 0 and n < @roi_grid_cell_count -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_roi_cell_index(_), do: :error

  defp hydrate_roi_from_source(socket, source, opts) do
    {focus_set, ignore_set} = extract_roi_sets(source)
    reset_draft? = Keyword.get(opts, :reset_draft?, true)

    base = [
      roi_saved_focus_cells: focus_set,
      roi_saved_ignore_cells: ignore_set
    ]

    draft =
      if reset_draft? do
        [roi_focus_cells: focus_set, roi_ignore_cells: ignore_set]
      else
        []
      end

    assign(socket, base ++ draft)
  end

  defp extract_roi_sets(%{metadata: %{} = metadata}) do
    case Map.get(metadata, "detection_roi_grid") || Map.get(metadata, :detection_roi_grid) do
      %{} = grid ->
        focus = parse_roi_cell_list(Map.get(grid, "focus") || Map.get(grid, :focus))
        ignore = parse_roi_cell_list(Map.get(grid, "ignore") || Map.get(grid, :ignore))
        {focus, MapSet.difference(ignore, focus)}

      _ ->
        {MapSet.new(), MapSet.new()}
    end
  end

  defp extract_roi_sets(_), do: {MapSet.new(), MapSet.new()}

  defp parse_roi_cell_list(list) when is_list(list) do
    list
    |> Enum.filter(&(is_integer(&1) and &1 >= 0 and &1 < @roi_grid_cell_count))
    |> MapSet.new()
  end

  defp parse_roi_cell_list(_), do: MapSet.new()

  defp build_roi_grid_payload(focus_cells, ignore_cells) do
    %{
      "version" => 1,
      "cols" => @roi_grid_cols,
      "rows" => @roi_grid_rows,
      "focus" => focus_cells |> MapSet.to_list() |> Enum.sort(),
      "ignore" => ignore_cells |> MapSet.to_list() |> Enum.sort()
    }
  end

  defp default_save_roi_grid(%Source{} = source, roi_payload, _scope) do
    updated_metadata = Map.put(source.metadata || %{}, "detection_roi_grid", roi_payload)

    Source.update_source(
      source,
      %{metadata: updated_metadata},
      actor: SystemActor.system(:camera_detection_zones)
    )
  end

  defp default_save_roi_grid(%{metadata: metadata} = source, roi_payload, _scope) when is_map(metadata) do
    {:ok, %{source | metadata: Map.put(metadata, "detection_roi_grid", roi_payload)}}
  end

  defp default_save_roi_grid(source, roi_payload, _scope) when is_map(source) do
    {:ok, Map.put(source, :metadata, %{"detection_roi_grid" => roi_payload})}
  end

  @doc false
  def ptz_camera?(%{metadata: %{} = metadata}) do
    ptz_flag? =
      Enum.any?(
        ["ptz", "ptz_capable", "has_ptz", "is_ptz", :ptz, :ptz_capable, :has_ptz, :is_ptz],
        fn key -> truthy_meta?(Map.get(metadata, key)) end
      )

    ptz_capability? =
      case Map.get(metadata, "capabilities") || Map.get(metadata, :capabilities) do
        caps when is_list(caps) ->
          Enum.any?(caps, fn cap ->
            cap |> to_string() |> String.downcase() |> String.contains?("ptz") or
              cap |> to_string() |> String.downcase() |> String.contains?("pan_tilt")
          end)

        %{} = caps ->
          truthy_meta?(Map.get(caps, "ptz") || Map.get(caps, :ptz) || Map.get(caps, "pan_tilt"))

        _ ->
          false
      end

    ptz_type? =
      ["camera_type", "model", :camera_type, :model]
      |> Enum.map(&Map.get(metadata, &1))
      |> Enum.any?(fn val ->
        is_binary(val) and String.contains?(String.downcase(val), "ptz")
      end)

    ptz_flag? or ptz_capability? or ptz_type?
  end

  def ptz_camera?(_), do: false

  defp truthy_meta?(true), do: true
  defp truthy_meta?("true"), do: true
  defp truthy_meta?("1"), do: true
  defp truthy_meta?(1), do: true
  defp truthy_meta?(_), do: false
end
