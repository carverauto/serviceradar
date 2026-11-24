defmodule ServiceRadarWebNGWeb.CameraLive.RecordingsComponents do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadar.Camera.Thumbnail
  alias ServiceRadarWebNGWeb.CameraLive.Recordings
  alias ServiceRadarWebNGWeb.CameraRelayComponents

  attr :source, :any, required: true
  attr :items, :list, required: true
  attr :next_cursor, :string, default: nil
  attr :selected, :map, default: nil
  attr :error, :string, default: nil
  attr :loading, :boolean, default: false
  attr :timezone, :string, required: true
  attr :can_view_recording_settings, :boolean, default: false
  attr :mode, :atom, default: :published
  attr :can_manage_holds, :boolean, default: false
  attr :can_view_live, :boolean, default: true
  attr :can_edit_detection_zones, :boolean, default: false
  attr :stream_profiles, :list, default: []
  attr :live_mode?, :boolean, default: false
  attr :live_tile, :map, default: nil
  attr :roi_drawer_open?, :boolean, default: false
  attr :roi_paint_mode, :string, default: "focus"
  attr :roi_focus_cells, :any, default: nil
  attr :roi_ignore_cells, :any, default: nil
  attr :roi_saved_focus_cells, :any, default: nil
  attr :roi_saved_ignore_cells, :any, default: nil
  attr :roi_feedback, :string, default: nil
  attr :roi_grid_cols, :integer, default: 12
  attr :roi_grid_rows, :integer, default: 8
  attr :timeline_profile_id, :string, default: ""
  attr :timeline_span, :string, default: "1h"
  attr :timeline_source, :string, default: "auto"
  attr :timeline_anchored_latest?, :boolean, default: true
  attr :timeline_coverage, :map, default: nil
  attr :archive_playback_available, :boolean, default: false
  attr :timeline_playlist_path, :string, default: nil
  attr :timeline_play_from_us, :integer, default: nil
  attr :timeline_play_to_us, :integer, default: nil
  attr :timeline_playlist_origin_us, :integer, default: nil
  attr :timeline_seek_offset_seconds, :float, default: 0.0
  attr :timeline_highlight_frame_id, :string, default: nil
  attr :timeline_search_query, :string, default: ""
  attr :timeline_search_object_class, :string, default: ""
  attr :timeline_search_results, :list, default: []
  attr :timeline_search_executed?, :boolean, default: false
  attr :timeline_search_error, :string, default: nil
  attr :timeline_embedder_unavailable?, :boolean, default: false
  attr :timeline_overlay_detections, :list, default: []
  attr :timeline_jump_at, :string, default: ""
  attr :timeline_has_adjacent_window, :boolean, default: false
  attr :timeline_holds, :list, default: []
  attr :timeline_event_clips, :list, default: []
  attr :timeline_event_markers, :list, default: []
  attr :timeline_clips_mode, :string, default: "all"
  attr :timeline_clips_category, :string, default: "all"
  attr :timeline_min_confidence, :integer, default: 50
  attr :timeline_clips_page, :integer, default: 1
  attr :timeline_clips_total_count, :integer, default: 0
  attr :timeline_clips_total_pages, :integer, default: 1
  attr :timeline_clips_counts, :map, default: %{}
  attr :timeline_selected_clip_id, :string, default: nil
  attr :clip_modal, :map, default: nil
  attr :gaps_page, :integer, default: 1
  attr :gaps_per_page, :integer, default: 10
  attr :timeline_manage_drawer_open?, :boolean, default: false
  attr :switcher_cameras, :list, default: []
  attr :switcher_search, :string, default: ""
  attr :switcher_page, :integer, default: 1
  attr :switcher_total_count, :integer, default: 0
  attr :switcher_total_pages, :integer, default: 1
  attr :switcher_open_mobile?, :boolean, default: false
  attr :hold_form, :any, default: nil

  def recordings(assigns) do
    ~H"""
    <div id="camera-recordings" class="mx-auto w-full max-w-[1800px] space-y-3 p-3 sm:p-4">
      <header class="flex flex-wrap items-center justify-between gap-3">
        <div class="flex min-w-0 items-center gap-2.5">
          <.ui_button
            :if={@mode == :timeline}
            id="camera-switcher-mobile-toggle"
            type="button"
            phx-click="toggle_switcher_mobile"
            variant="outline"
            size="xs"
            class="lg:hidden"
          >
            <.icon name="hero-video-camera" class="size-3.5" /> Cameras
          </.ui_button>
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <h1 class="truncate text-lg font-semibold text-sr-ink sm:text-xl">
                {if(@source,
                  do: @source.display_name || "Camera recordings",
                  else: "Camera recordings"
                )}
              </h1>
              <span
                :if={@live_mode?}
                id="camera-header-live-badge"
                class="inline-flex items-center gap-1 rounded-md border border-rose-500/40 bg-rose-600 px-1.5 py-0.5 text-[11px] font-semibold text-white"
              >
                <span class="size-1.5 animate-pulse rounded-full bg-white"></span>
                <span>LIVE</span>
              </span>
              <span
                :if={!@live_mode?}
                class="rounded-md border border-sr-line bg-sr-surface px-1.5 py-0.5 text-[11px] text-sr-muted"
              >
                {if(@mode == :timeline, do: "Timeline", else: "Archive")}
              </span>
            </div>
            <p
              :if={@mode == :published}
              id="camera-recordings-source-label"
              class="mt-0.5 text-xs text-sr-muted"
            >
              Source: <code class="font-mono">ArchiveUploads</code>
              published catalog. Publication time is not capture time.
            </p>
          </div>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <div class="inline-flex flex-wrap items-center gap-1 rounded-lg border border-sr-line bg-sr-surface p-0.5">
            <.ui_button
              id="camera-recordings-mode-timeline"
              type="button"
              phx-click="switch_recordings_mode"
              phx-value-mode="timeline"
              variant={if(@mode == :timeline, do: "primary", else: "ghost")}
              size="xs"
            >
              Timeline
            </.ui_button>
            <.ui_button
              id="camera-recordings-mode-published"
              type="button"
              phx-click="switch_recordings_mode"
              phx-value-mode="published"
              variant={if(@mode == :published, do: "primary", else: "ghost")}
              size="xs"
            >
              Published
            </.ui_button>
          </div>
          <.link
            :if={@can_view_recording_settings}
            id="camera-recording-settings-link"
            navigate={~p"/settings/recording"}
            class="sr-ops-button text-xs"
          >
            Recording &amp; storage
          </.link>
          <.link
            :if={@source}
            navigate={~p"/devices/#{@source.device_uid}"}
            class="sr-ops-button text-xs"
          >
            Back to device
          </.link>
        </div>
      </header>

      <div
        :if={@error}
        id="camera-recordings-error"
        role="alert"
        class="rounded-xl border border-rose-500/40 bg-rose-500/5 px-4 py-3 text-sm text-sr-ink"
      >
        {@error}
      </div>
      <div :if={@loading} id="camera-recordings-loading" role="status" class="text-sm text-sr-muted">
        Loading recordings...
      </div>

      <.published_view
        :if={!@loading && @mode == :published}
        items={@items}
        next_cursor={@next_cursor}
        selected={@selected}
        error={@error}
        timezone={@timezone}
      />

      <.timeline_view
        :if={!@loading && @mode == :timeline}
        source={@source}
        timezone={@timezone}
        can_view_recording_settings={@can_view_recording_settings}
        can_manage_holds={@can_manage_holds}
        can_view_live={@can_view_live}
        can_edit_detection_zones={@can_edit_detection_zones}
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
        roi_grid_cols={@roi_grid_cols}
        roi_grid_rows={@roi_grid_rows}
        timeline_profile_id={@timeline_profile_id}
        timeline_span={@timeline_span}
        timeline_source={@timeline_source}
        timeline_anchored_latest?={@timeline_anchored_latest?}
        timeline_coverage={@timeline_coverage}
        archive_playback_available={@archive_playback_available}
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
    </div>
    """
  end

  attr :items, :list, required: true
  attr :next_cursor, :string, default: nil
  attr :selected, :map, default: nil
  attr :error, :string, default: nil
  attr :timezone, :string, required: true

  defp published_view(assigns) do
    ~H"""
    <div class="grid gap-6 lg:grid-cols-[20rem_minmax(0,1fr)]">
      <section
        aria-label="Published recordings"
        class="rounded-xl border border-sr-line bg-sr-surface p-4"
      >
        <div class="flex items-center justify-between gap-3">
          <h2 class="font-semibold">Published recordings</h2>
          <.ui_button
            id="refresh-recordings"
            phx-click="refresh_recordings"
            variant="outline"
            size="sm"
          >
            Refresh
          </.ui_button>
        </div>
        <p
          :if={@items == [] && !@error}
          id="camera-recordings-empty"
          class="mt-4 text-sm text-sr-muted"
        >
          No available recordings on this page.
        </p>
        <ul id="camera-recordings-list" class="mt-4 space-y-2">
          <li :for={item <- @items} id={"recording-#{item.block_id}"}>
            <button
              id={"select-recording-#{item.block_id}"}
              type="button"
              phx-click="select_recording"
              phx-value-id={item.block_id}
              aria-pressed={@selected != nil && @selected.block_id == item.block_id}
              class={[
                "w-full rounded-lg border p-3 text-left transition-colors hover:bg-sr-canvas",
                if(@selected && @selected.block_id == item.block_id,
                  do: "border-sr-brand",
                  else: "border-sr-line"
                )
              ]}
            >
              <span class="block text-sm font-medium">Recording {String.slice(item.block_id, 0, 8)}</span>
              <span class="mt-1 block text-xs text-sr-muted">
                Published
                <.user_time
                  id={"recording-published-#{item.block_id}"}
                  value={item.published_at}
                  timezone={@timezone}
                />
              </span>
            </button>
          </li>
        </ul>
        <.ui_button
          :if={@next_cursor}
          id="next-recordings"
          phx-click="next_recordings"
          variant="outline"
          class="mt-4 w-full"
        >
          Next page
        </.ui_button>
      </section>

      <section
        class="min-w-0 rounded-xl border border-sr-line bg-sr-surface p-4"
        aria-label="Recording player"
      >
        <div
          :if={!@selected}
          id="camera-recordings-select"
          class="flex min-h-64 items-center justify-center text-sr-muted"
        >
          Select a recording to prepare playback.
        </div>
        <div :if={@selected} class="space-y-4">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div>
              <h2 class="font-semibold">
                Window {@selected.window.index + 1} of {@selected.window.total}
              </h2>
              <p id="camera-recording-window" class="text-sm text-sr-muted">
                {Float.round(
                  @selected.window.duration_ns / 1_000_000_000,
                  3
                )} seconds
              </p>
            </div>
            <div class="flex gap-2">
              <.ui_button
                id="previous-recording-window"
                phx-click="recording_window"
                phx-value-direction="previous"
                disabled={@selected.window.index == 0}
                variant="outline"
                size="sm"
              >
                Previous window
              </.ui_button>
              <.ui_button
                id="next-recording-window"
                phx-click="recording_window"
                phx-value-direction="next"
                disabled={@selected.window.index + 1 == @selected.window.total}
                variant="outline"
                size="sm"
              >
                Next window
              </.ui_button>
            </div>
          </div>
          <div
            id="camera-archive-player"
            phx-hook="CameraArchivePlayer"
            phx-update="ignore"
            data-playlist-path={@selected.playlist_path}
          >
            <video
              data-role="archive-video"
              controls
              playsinline
              class="aspect-video w-full rounded-lg bg-black"
              aria-label="Archived camera recording"
            ></video>
            <div class="mt-3 flex items-center justify-between gap-3">
              <p data-role="archive-status" role="status" class="text-sm text-sr-muted">
                Preparing recording...
              </p>
              <button type="button" data-role="archive-retry" class="sr-ops-button" hidden>
                Retry playback
              </button>
            </div>
          </div>
          <p id="camera-recording-time-note" class="text-xs text-sr-muted">
            Player time follows this recording's media clock. Each window ends independently.
            No capture-time timeline is available.
          </p>
        </div>
      </section>
    </div>
    """
  end

  attr :source, :any, required: true
  attr :timezone, :string, required: true
  attr :can_view_recording_settings, :boolean, default: false
  attr :can_manage_holds, :boolean, required: true
  attr :can_view_live, :boolean, default: true
  attr :can_edit_detection_zones, :boolean, default: false
  attr :stream_profiles, :list, required: true
  attr :live_mode?, :boolean, default: false
  attr :live_tile, :map, default: nil
  attr :roi_drawer_open?, :boolean, default: false
  attr :roi_paint_mode, :string, default: "focus"
  attr :roi_focus_cells, :any, default: nil
  attr :roi_ignore_cells, :any, default: nil
  attr :roi_saved_focus_cells, :any, default: nil
  attr :roi_saved_ignore_cells, :any, default: nil
  attr :roi_feedback, :string, default: nil
  attr :roi_grid_cols, :integer, default: 12
  attr :roi_grid_rows, :integer, default: 8
  attr :timeline_profile_id, :string, required: true
  attr :timeline_span, :string, required: true
  attr :timeline_source, :string, required: true
  attr :timeline_anchored_latest?, :boolean, default: true
  attr :timeline_coverage, :map, default: nil
  attr :archive_playback_available, :boolean, default: false
  attr :timeline_playlist_path, :string, default: nil
  attr :timeline_play_from_us, :integer, default: nil
  attr :timeline_play_to_us, :integer, default: nil
  attr :timeline_playlist_origin_us, :integer, default: nil
  attr :timeline_seek_offset_seconds, :float, default: 0.0
  attr :timeline_highlight_frame_id, :string, default: nil
  attr :timeline_search_query, :string, default: ""
  attr :timeline_search_object_class, :string, default: ""
  attr :timeline_search_results, :list, default: []
  attr :timeline_search_executed?, :boolean, default: false
  attr :timeline_search_error, :string, default: nil
  attr :timeline_embedder_unavailable?, :boolean, default: false
  attr :timeline_overlay_detections, :list, default: []
  attr :timeline_jump_at, :string, default: ""
  attr :timeline_has_adjacent_window, :boolean, default: false
  attr :timeline_holds, :list, default: []
  attr :timeline_event_clips, :list, default: []
  attr :timeline_event_markers, :list, default: []
  attr :timeline_clips_mode, :string, default: "all"
  attr :timeline_clips_category, :string, default: "all"
  attr :timeline_min_confidence, :integer, default: 50
  attr :timeline_clips_page, :integer, default: 1
  attr :timeline_clips_total_count, :integer, default: 0
  attr :timeline_clips_total_pages, :integer, default: 1
  attr :timeline_clips_counts, :map, default: %{}
  attr :timeline_selected_clip_id, :string, default: nil
  attr :clip_modal, :map, default: nil
  attr :gaps_page, :integer, default: 1
  attr :gaps_per_page, :integer, default: 10
  attr :timeline_manage_drawer_open?, :boolean, default: false
  attr :switcher_cameras, :list, default: []
  attr :switcher_search, :string, default: ""
  attr :switcher_page, :integer, default: 1
  attr :switcher_total_count, :integer, default: 0
  attr :switcher_total_pages, :integer, default: 1
  attr :switcher_open_mobile?, :boolean, default: false
  attr :hold_form, :any, default: nil

  defp timeline_view(assigns) do
    coverage = assigns.timeline_coverage || default_empty_coverage()
    buckets = coverage_list(coverage, :buckets)
    vertical_buckets = buckets |> Enum.with_index() |> Enum.reverse()
    blocks = coverage_list(coverage, :blocks)
    gaps = coverage_list(coverage, :gaps)
    sorted_gaps = sort_gaps_newest_first(gaps)
    gap_reason_summary = summarize_gaps_by_reason(sorted_gaps)
    gaps_per_page = max(assigns.gaps_per_page || 10, 1)
    gaps_total_count = length(sorted_gaps)
    gaps_total_pages = max(div(gaps_total_count + gaps_per_page - 1, gaps_per_page), 1)
    gaps_page = min(max(assigns.gaps_page || 1, 1), gaps_total_pages)
    paged_gaps = Enum.slice(sorted_gaps, (gaps_page - 1) * gaps_per_page, gaps_per_page)
    reanchors = extract_reanchors(coverage, blocks)
    time_basis = coverage_field(coverage, :time_basis) || "received"
    time_uncertainty = coverage_field(coverage, :time_uncertainty) || "unmeasured"
    cov_from_us = coverage_field(coverage, :from_us)
    cov_to_us = coverage_field(coverage, :to_us)

    clip_counts = assigns.timeline_clips_counts || %{}
    filtered_event_clips = assigns.timeline_event_clips
    filtered_event_clip_total = assigns.timeline_clips_total_count || 0
    clips_total_pages = max(assigns.timeline_clips_total_pages || 1, 1)
    clips_page = min(max(assigns.timeline_clips_page || 1, 1), clips_total_pages)

    now_us = System.system_time(:microsecond)
    active_source_id = assigns.source && to_string(assigns.source.id)

    event_markers =
      build_event_markers(
        assigns.timeline_event_markers || [],
        cov_from_us,
        cov_to_us,
        now_us
      )

    vertical_event_thumbs =
      build_vertical_thumbnail_markers(
        assigns.timeline_event_markers || [],
        assigns.timeline_event_clips || [],
        cov_from_us,
        cov_to_us,
        now_us
      )

    play_origin_us = assigns.timeline_playlist_origin_us || assigns.timeline_play_from_us

    window_scrubber_events =
      build_window_scrubber_events(
        assigns.timeline_event_markers || [],
        assigns.timeline_event_clips || [],
        play_origin_us,
        assigns.timeline_play_to_us
      )

    window_scrubber_thumbnails =
      build_window_scrubber_thumbnails(
        blocks,
        assigns.timeline_event_markers || [],
        assigns.timeline_event_clips || [],
        active_source_id,
        play_origin_us,
        assigns.timeline_play_to_us
      )

    hit_markers = build_hit_markers(assigns.timeline_search_results, cov_from_us, cov_to_us)

    play_window_band =
      build_play_window_band(assigns.timeline_play_from_us, assigns.timeline_play_to_us, cov_from_us, cov_to_us)

    time_ticks = build_vertical_time_ticks(cov_from_us, cov_to_us)
    timeline_date_us = cov_to_us || now_us

    other_switcher_cameras =
      Enum.reject(assigns.switcher_cameras || [], &(to_string(&1.id) == active_source_id))

    is_ptz? = Recordings.ptz_camera?(assigns.source)
    roi_focus_set = assigns.roi_focus_cells || MapSet.new()
    roi_ignore_set = assigns.roi_ignore_cells || MapSet.new()
    roi_saved_focus_set = assigns.roi_saved_focus_cells || MapSet.new()
    roi_saved_ignore_set = assigns.roi_saved_ignore_cells || MapSet.new()
    roi_active_count = MapSet.size(roi_focus_set) + MapSet.size(roi_ignore_set)
    roi_dirty? = roi_focus_set != roi_saved_focus_set or roi_ignore_set != roi_saved_ignore_set
    roi_preview_thumbnail = latest_clip_thumbnail_url(assigns.timeline_event_clips || [])
    roi_total_cells = (assigns.roi_grid_cols || 12) * (assigns.roi_grid_rows || 8)

    assigns =
      assigns
      |> assign(:coverage, coverage)
      |> assign(:buckets, buckets)
      |> assign(:vertical_buckets, vertical_buckets)
      |> assign(:blocks, blocks)
      |> assign(:gaps, sorted_gaps)
      |> assign(:paged_gaps, paged_gaps)
      |> assign(:gap_reason_summary, gap_reason_summary)
      |> assign(:gaps_total_count, gaps_total_count)
      |> assign(:gaps_page, gaps_page)
      |> assign(:gaps_total_pages, gaps_total_pages)
      |> assign(:reanchors, reanchors)
      |> assign(:hit_markers, hit_markers)
      |> assign(:event_markers, event_markers)
      |> assign(:vertical_event_thumbs, vertical_event_thumbs)
      |> assign(:window_scrubber_events, window_scrubber_events)
      |> assign(:window_scrubber_thumbnails, window_scrubber_thumbnails)
      |> assign(:play_window_band, play_window_band)
      |> assign(:time_ticks, time_ticks)
      |> assign(:timeline_date_us, timeline_date_us)
      |> assign(:clip_counts, clip_counts)
      |> assign(:filtered_event_clip_total, filtered_event_clip_total)
      |> assign(:filtered_event_clips, filtered_event_clips)
      |> assign(:clips_page, clips_page)
      |> assign(:clips_total_pages, clips_total_pages)
      |> assign(:has_any_window_clips?, Map.get(clip_counts, :all, 0) > 0)
      |> assign(:now_us, now_us)
      |> assign(:active_source_id, active_source_id)
      |> assign(:other_switcher_cameras, other_switcher_cameras)
      |> assign(:is_ptz?, is_ptz?)
      |> assign(:roi_focus_set, roi_focus_set)
      |> assign(:roi_ignore_set, roi_ignore_set)
      |> assign(:roi_active_count, roi_active_count)
      |> assign(:roi_dirty?, roi_dirty?)
      |> assign(:roi_preview_thumbnail, roi_preview_thumbnail)
      |> assign(:roi_total_cells, roi_total_cells)
      |> assign(:time_basis_label, format_time_basis(time_basis, time_uncertainty))
      |> assign(:time_basis_short, to_string(time_basis))
      |> assign(:has_provisional?, any_provisional?(buckets, blocks))
      |> assign(:has_local_only_after_archive?, any_local_only_after_archive?(buckets, blocks))
      |> assign(:scheduled_continuous?, coverage_field(coverage, :scheduled_continuous?) == true)
      |> assign(:recorder_running?, coverage_field(coverage, :continuous_recording_active?) == true)
      |> assign(
        :archive_only_unplayable?,
        archive_only_unplayable?(blocks, assigns.timeline_source, assigns.archive_playback_available)
      )

    ~H"""
    <div id="camera-timeline-view" class="space-y-3">
      <%!-- 3-Pane Scalable Workspace: Left Camera Switcher | Middle Vertical Timeline | Main Video Stage --%>
      <div
        id="camera-timeline-workspace"
        class="grid gap-3 lg:grid-cols-[14.5rem_11.5rem_minmax(0,1fr)]"
      >
        <%!-- PANE 1 (Left Rail): Scalable Server-Side Paginated Camera Switcher --%>
        <aside
          id="camera-switcher-rail"
          aria-label="Camera switcher"
          class={[
            "flex-col rounded-xl border border-sr-line bg-sr-surface p-2.5 lg:sticky lg:top-20 lg:self-start lg:max-h-[42rem]",
            if(@switcher_open_mobile?, do: "flex", else: "hidden lg:flex")
          ]}
        >
          <div class="flex items-center justify-between gap-2 pb-2">
            <span class="text-xs font-semibold uppercase tracking-wide text-sr-muted">
              Cameras
            </span>
            <span
              id="camera-switcher-total"
              class="rounded-full bg-sr-canvas px-1.5 py-0.5 font-mono text-[10px] text-sr-muted"
            >
              {@switcher_total_count}
            </span>
          </div>

          <form
            id="camera-switcher-search-form"
            phx-change="switcher_search"
            phx-submit="switcher_search"
          >
            <label for="camera-switcher-search" class="sr-only">Filter cameras</label>
            <input
              id="camera-switcher-search"
              type="search"
              name="search"
              value={@switcher_search}
              phx-debounce="250"
              placeholder="Search cameras, site..."
              class="h-8 w-full rounded-lg border border-sr-line bg-sr-control px-2.5 text-xs text-sr-ink placeholder:text-sr-muted focus:border-sr-brand focus:outline-none"
            />
          </form>

          <%!-- Pinned Active Camera --%>
          <div
            :if={@source}
            id="camera-switcher-active"
            class="mt-2 rounded-lg border border-sr-brand bg-sr-brand/10 px-2.5 py-2"
          >
            <div class="flex items-center justify-between gap-1.5">
              <span class="truncate text-xs font-semibold text-sr-ink">
                {@source.display_name || "Active camera"}
              </span>
              <span
                class={[
                  "size-2 shrink-0 rounded-full",
                  if(@recorder_running?, do: "bg-rose-500", else: "bg-emerald-500")
                ]}
                title={if(@recorder_running?, do: "Recording", else: "Active")}
              ></span>
            </div>
            <p class="mt-0.5 truncate text-[10px] text-sr-muted">
              {camera_subtitle(@source)}
            </p>
          </div>

          <%!-- Bounded Paginated Camera List (<= 20 items) --%>
          <div class="mt-2 min-h-0 flex-1 overflow-y-auto pr-0.5">
            <ul :if={@other_switcher_cameras != []} id="camera-switcher-list" class="space-y-1">
              <li
                :for={cam <- @other_switcher_cameras}
                id={"camera-switcher-row-#{cam.id}"}
              >
                <.link
                  id={"camera-switcher-item-#{cam.id}"}
                  patch={~p"/cameras/#{cam.id}/recordings?mode=timeline"}
                  class="flex items-center justify-between gap-2 rounded-lg border border-transparent px-2.5 py-1.5 text-left transition-colors hover:border-sr-line hover:bg-sr-canvas"
                >
                  <div class="min-w-0">
                    <span class="block truncate text-xs font-medium text-sr-ink">
                      {cam.display_name || cam.vendor_camera_id || "Camera"}
                    </span>
                    <span class="block truncate text-[10px] text-sr-muted">
                      {camera_subtitle(cam)}
                    </span>
                  </div>
                  <span
                    class={[
                      "size-2 shrink-0 rounded-full",
                      camera_status_dot_class(cam)
                    ]}
                    title={camera_status_title(cam)}
                  ></span>
                </.link>
              </li>
            </ul>
            <p
              :if={@other_switcher_cameras == []}
              id="camera-switcher-empty"
              class="px-2 py-4 text-center text-[11px] text-sr-muted"
            >
              {camera_switcher_empty_message(
                @switcher_search,
                @switcher_cameras,
                @switcher_total_count
              )}
            </p>
          </div>

          <%!-- Switcher Pagination Footer --%>
          <div
            :if={@switcher_total_pages > 1}
            id="camera-switcher-pagination"
            class="mt-2 flex items-center justify-between gap-1 border-t border-sr-line pt-2 text-[11px]"
          >
            <button
              id="camera-switcher-prev"
              type="button"
              phx-click="switcher_paginate"
              phx-value-page={max(@switcher_page - 1, 1)}
              disabled={@switcher_page <= 1}
              class="rounded border border-sr-line px-2 py-0.5 text-sr-ink disabled:opacity-40 hover:bg-sr-canvas"
            >
              Prev
            </button>
            <span id="camera-switcher-page" class="font-mono text-[10px] text-sr-muted">
              {@switcher_page}/{@switcher_total_pages}
            </span>
            <button
              id="camera-switcher-next"
              type="button"
              phx-click="switcher_paginate"
              phx-value-page={min(@switcher_page + 1, @switcher_total_pages)}
              disabled={@switcher_page >= @switcher_total_pages}
              class="rounded border border-sr-line px-2 py-0.5 text-sr-ink disabled:opacity-40 hover:bg-sr-canvas"
            >
              Next
            </button>
          </div>
        </aside>

        <%!-- PANE 2 (Middle Rail): UniFi-Style Precision Vertical Meter --%>
        <section
          id="camera-timeline-coverage-section"
          aria-label="Vertical timeline scrubber"
          class="flex flex-col overflow-hidden rounded-xl border border-sr-line bg-sr-surface p-2.5 lg:max-h-[42rem]"
        >
          <%!-- Minimalist Top Row: Date + Compact LIVE & Latest Controls --%>
          <div class="flex items-center justify-between gap-1 text-[10px]">
            <span
              id="camera-timeline-date-label"
              class="min-w-0 truncate font-medium tracking-tight text-sr-ink"
            >
              <.user_time
                id="camera-timeline-date-label-time"
                value={us_to_datetime(@timeline_date_us)}
                timezone={@timezone}
                style={:date}
              />
            </span>
            <div class="flex shrink-0 items-center gap-1">
              <button
                :if={@source && @can_view_live}
                id="camera-timeline-live-button"
                type="button"
                phx-click="enter_live_mode"
                aria-pressed={to_string(@live_mode?)}
                title="Switch main stage to live camera stream"
                class={[
                  "inline-flex items-center gap-1 rounded-full px-1.5 py-0.5 text-[9px] font-semibold tracking-wider text-white transition-colors",
                  if(@live_mode?,
                    do: "bg-rose-600 ring-1 ring-rose-400/80",
                    else: "bg-rose-600/85 hover:bg-rose-500"
                  )
                ]}
              >
                <span class={["size-1.5 rounded-full bg-white", @live_mode? && "animate-pulse"]}></span>
                <span>LIVE</span>
              </button>
              <button
                id="camera-timeline-latest-window"
                type="button"
                phx-click="navigate_timeline_window"
                phx-value-direction="latest"
                title="Jump to latest recorded edge"
                class="rounded-full border border-sr-line bg-sr-canvas px-1.5 py-0.5 text-[9px] font-medium text-sr-muted hover:border-sr-brand hover:text-sr-ink"
              >
                Now
              </button>
            </div>
          </div>

          <%!-- Sleek Dark Pill Zoom Slider (- ━━●━━ +) --%>
          <form
            id="camera-timeline-zoom-form"
            phx-change="set_timeline_zoom"
            class="mt-1.5 flex items-center gap-1 rounded-full border border-zinc-700/60 bg-zinc-900/90 px-1.5 py-0.5 text-zinc-100 shadow-xs"
          >
            <button
              id="camera-timeline-zoom-out"
              type="button"
              phx-click="zoom_timeline_span"
              phx-value-direction="out"
              disabled={@timeline_span == "7d"}
              title="Zoom out"
              class="flex size-4 shrink-0 items-center justify-center rounded-full text-xs font-semibold text-zinc-300 transition-colors hover:bg-white/10 hover:text-white disabled:opacity-35"
            >
              -
            </button>
            <label for="camera-timeline-zoom-slider" class="sr-only">Timeline zoom level</label>
            <input
              id="camera-timeline-zoom-slider"
              type="range"
              name="zoom"
              min="0"
              max="4"
              step="1"
              value={span_zoom_index(@timeline_span)}
              aria-label="Timeline zoom level"
              class="h-1 min-w-0 flex-1 cursor-pointer accent-sky-400"
            />
            <button
              id="camera-timeline-zoom-in"
              type="button"
              phx-click="zoom_timeline_span"
              phx-value-direction="in"
              disabled={@timeline_span == "15m"}
              title="Zoom in"
              class="flex size-4 shrink-0 items-center justify-center rounded-full text-xs font-semibold text-zinc-300 transition-colors hover:bg-white/10 hover:text-white disabled:opacity-35"
            >
              +
            </button>
            <span class="shrink-0 pl-0.5 font-mono text-[9px] font-medium text-zinc-400">
              {@timeline_span}
            </span>
          </form>

          <%!-- Collapsible Range & Jump Controls (keeps maximum height for the precision meter) --%>
          <details
            id="camera-timeline-nav-details"
            phx-hook="DetailsState"
            class="mt-1.5 shrink-0 text-[10px] text-sr-muted"
          >
            <summary class="cursor-pointer select-none text-[10px] font-medium hover:text-sr-ink">
              Range &amp; jump
            </summary>
            <div class="mt-1 space-y-1.5">
              <div
                id="camera-timeline-span-selector"
                role="group"
                aria-label="Coverage span"
                class="grid grid-cols-5 gap-0.5 rounded-md border border-sr-line bg-sr-canvas p-0.5"
              >
                <button
                  :for={span <- ["15m", "1h", "6h", "24h", "7d"]}
                  id={"camera-timeline-span-#{span}"}
                  type="button"
                  phx-click="select_timeline_span"
                  phx-value-span={span}
                  aria-pressed={to_string(@timeline_span == span)}
                  class={[
                    "rounded py-0.5 text-[10px] font-medium transition-colors",
                    if(@timeline_span == span,
                      do: "bg-sr-ink text-sr-surface",
                      else: "text-sr-muted hover:text-sr-ink"
                    )
                  ]}
                >
                  {span}
                </button>
              </div>

              <div id="camera-timeline-window-nav" class="grid grid-cols-2 gap-1">
                <button
                  id="camera-timeline-next-window"
                  type="button"
                  phx-click="navigate_timeline_window"
                  phx-value-direction="next"
                  class="rounded border border-sr-line bg-sr-canvas px-1.5 py-0.5 text-[10px] font-medium text-sr-ink hover:border-sr-brand"
                >
                  &uarr; Newer
                </button>
                <button
                  id="camera-timeline-prev-window"
                  type="button"
                  phx-click="navigate_timeline_window"
                  phx-value-direction="previous"
                  class="rounded border border-sr-line bg-sr-canvas px-1.5 py-0.5 text-[10px] font-medium text-sr-ink hover:border-sr-brand"
                >
                  &darr; Older
                </button>
              </div>

              <form
                id="camera-timeline-jump-form"
                phx-submit="jump_timeline_to"
                class="flex items-center gap-1"
              >
                <label for="camera-timeline-jump-at" class="sr-only">
                  Jump to date and time ({@timezone})
                </label>
                <input
                  id="camera-timeline-jump-at"
                  type="datetime-local"
                  step="1"
                  name="jump_at"
                  value={@timeline_jump_at}
                  aria-label={"Jump to date and time (#{@timezone})"}
                  class="h-7 min-w-0 flex-1 rounded border border-sr-line bg-sr-control px-1 text-[10px] text-sr-ink"
                />
                <button
                  id="camera-timeline-jump-submit"
                  type="submit"
                  class="h-7 shrink-0 rounded border border-sr-line bg-sr-canvas px-1.5 text-[10px] font-medium text-sr-ink hover:border-sr-brand"
                >
                  Go
                </button>
              </form>
            </div>
          </details>

          <%!-- Precision Vertical Meter (Newest Top -> Oldest Bottom) --%>
          <div class="mt-2 flex min-h-[16rem] flex-1 gap-1 overflow-hidden">
            <%!-- Left Precision Ruler: Tabular Wall-Clock Labels + Fine Minor Tick Marks --%>
            <div class="flex shrink-0 items-stretch gap-1 py-0.5">
              <div
                id="camera-timeline-tick-labels"
                phx-update="ignore"
                class="flex w-12 shrink-0 flex-col justify-between text-right font-mono text-[9px] leading-none tracking-tight whitespace-nowrap tabular-nums text-sr-muted/90"
              >
                <span
                  :if={coverage_field(@coverage, :to_us)}
                  id="camera-timeline-span-end"
                  data-role="vertical-tick-label"
                  data-tick-fraction="0"
                >
                  <.user_time
                    id="camera-timeline-span-end-time"
                    value={us_to_datetime(coverage_field(@coverage, :to_us))}
                    timezone={@timezone}
                    style={:axis}
                  />
                </span>
                <span
                  :for={{tick_us, idx} <- Enum.with_index(@time_ticks)}
                  data-role="vertical-tick-label"
                  data-tick-fraction={Float.to_string((idx + 1) * 0.25)}
                >
                  <.user_time
                    id={"camera-timeline-tick-#{idx}"}
                    value={us_to_datetime(tick_us)}
                    timezone={@timezone}
                    style={:axis}
                  />
                </span>
                <span
                  :if={coverage_field(@coverage, :from_us)}
                  id="camera-timeline-span-start"
                  data-role="vertical-tick-label"
                  data-tick-fraction="1"
                >
                  <.user_time
                    id="camera-timeline-span-start-time"
                    value={us_to_datetime(coverage_field(@coverage, :from_us))}
                    timezone={@timezone}
                    style={:axis}
                  />
                </span>
              </div>
              <div
                data-role="vertical-ruler-ticks"
                aria-hidden="true"
                class="pointer-events-none flex w-2.5 flex-col items-end justify-between py-0.5"
              >
                <span
                  :for={tick_idx <- 0..20}
                  class={[
                    "block h-[1px] rounded-full",
                    if(rem(tick_idx, 5) == 0,
                      do: "w-2.5 bg-sr-muted/65",
                      else: "w-1.5 bg-sr-muted/25"
                    )
                  ]}
                ></span>
              </div>
            </div>

            <%!-- Click-to-Seek Vertical Meter Rail: Continuous 10px Track, Object Pills & 40px Thumbnails --%>
            <div
              id="camera-timeline-coverage-bar"
              phx-hook="CameraVerticalTimeline"
              data-from-us={coverage_field(@coverage, :from_us)}
              data-to-us={coverage_field(@coverage, :to_us)}
              data-anchored-latest={to_string(@timeline_anchored_latest?)}
              data-timezone={@timezone}
              class="relative flex flex-1 cursor-crosshair flex-col overflow-hidden rounded-lg border border-sr-line/60 bg-sr-canvas/70 px-1.5 py-0.5"
              title="Click anywhere on the timeline to seek"
            >
              <%!-- Floating LIVE Badge + Crisp Horizontal Hairline across the Rail --%>
              <div
                :if={@timeline_anchored_latest?}
                id="camera-timeline-live-playhead"
                data-role="vertical-live-playhead"
                aria-hidden="true"
                class="pointer-events-none absolute inset-x-0 top-2.5 z-[14] flex items-center"
              >
                <span class="rounded-full bg-sky-500 px-1.5 py-[1px] font-mono text-[8px] font-bold leading-none tracking-wider text-white shadow-xs">
                  LIVE
                </span>
                <span class="h-[1px] flex-1 bg-sky-400/90 shadow-[0_0_6px_rgba(56,189,248,0.85)]"></span>
              </div>

              <%!-- Sleek Continuous 10px Vertical Meter Track with Top/Bottom Fade Mask --%>
              <div class="relative ml-0.5 flex h-full w-[10px] flex-col overflow-hidden rounded-full bg-slate-800/35 [mask-image:linear-gradient(to_bottom,transparent,black_6%,black_94%,transparent)] dark:bg-slate-800/70">
                <div
                  :if={@timeline_anchored_latest?}
                  aria-hidden="true"
                  class="h-2.5 w-full shrink-0 bg-slate-400/35 dark:bg-slate-700/60"
                >
                </div>
                <%= if @vertical_buckets == [] do %>
                  <div
                    data-bucket-state="not_scheduled"
                    class="flex h-full w-full items-center justify-center text-center text-[9px] text-sr-muted"
                  >
                  </div>
                <% else %>
                  <div
                    :for={{bucket, idx} <- @vertical_buckets}
                    id={"camera-timeline-bucket-#{idx}"}
                    data-bucket-state={bucket_state_name(bucket)}
                    data-provisional={to_string(bucket_provisional?(bucket))}
                    title={bucket_title(bucket)}
                    class={[
                      "w-full flex-1",
                      bucket_color_class(bucket_state_name(bucket))
                    ]}
                  >
                  </div>
                <% end %>
              </div>

              <%!-- Active Playback Window Indicator --%>
              <div
                :if={@play_window_band}
                id="camera-timeline-active-window-band"
                aria-hidden="true"
                style={"top: #{@play_window_band.top_pct}%; height: #{@play_window_band.height_pct}%"}
                class="pointer-events-none absolute inset-x-0 z-[3] border-y border-sky-400/80 bg-sky-400/10"
              >
              </div>

              <%!-- Hover Crosshair with Live Timestamp Pill --%>
              <div
                data-role="vertical-timeline-hover"
                hidden
                aria-hidden="true"
                class="pointer-events-none absolute inset-x-0 z-[15] flex items-center"
              >
                <span class="h-[1px] flex-1 bg-white/90 shadow-xs"></span>
                <span
                  data-role="vertical-timeline-hover-time"
                  class="rounded-xs bg-zinc-950/90 px-1 py-[1px] font-mono text-[8px] leading-none tabular-nums text-white"
                ></span>
              </div>

              <%!-- Brighter Rounded Object Detection Pills Overlaid on the 10px Track --%>
              <button
                :for={marker <- @event_markers}
                id={"camera-timeline-event-marker-#{marker.idx}"}
                type="button"
                data-role="event-clip-marker"
                data-clip-category={to_string(marker.category)}
                data-event-ts-us={marker.ts_us}
                phx-click="select_event_clip"
                phx-value-clip_id={marker.clip_id}
                title={marker.title}
                style={"top: #{marker.top_pct}%"}
                class={[
                  "absolute left-[7px] z-[7] h-2 w-[12px] -translate-y-1/2 rounded-full shadow-xs ring-1 ring-black/60 transition-all hover:scale-125 hover:ring-white",
                  event_marker_color_class(marker.category)
                ]}
              >
                <span class="sr-only">{marker.title}</span>
              </button>

              <%!-- 40px x 40px Rounded Square Object Detection Thumbnails (10px right of the 10px track) --%>
              <button
                :for={thumb <- @vertical_event_thumbs}
                id={"camera-timeline-event-thumb-#{thumb.idx}"}
                type="button"
                data-role="event-thumb-marker"
                data-clip-category={to_string(thumb.category)}
                data-event-ts-us={thumb.ts_us}
                phx-click="select_event_clip"
                phx-value-clip_id={thumb.clip_id}
                title={thumb.title}
                style={"top: #{thumb.top_pct}%"}
                class={[
                  "group absolute left-7 z-[8] size-10 -translate-y-1/2 overflow-hidden rounded-md border bg-zinc-950 shadow-sm transition-transform hover:z-[12] hover:scale-110 focus-visible:outline-2 focus-visible:outline-sky-400",
                  event_thumb_border_class(thumb.category)
                ]}
              >
                <img
                  src={thumb.thumbnail_url}
                  alt={thumb.title}
                  loading="lazy"
                  class="h-full w-full object-cover"
                />
              </button>

              <%!-- Semantic Hit Markers along Vertical Rail --%>
              <button
                :for={marker <- @hit_markers}
                id={"camera-timeline-hit-marker-#{marker.idx}"}
                type="button"
                data-role="semantic-hit-marker"
                phx-click="select_timeline_semantic_hit"
                phx-value-seek_us={marker.seek_us}
                phx-value-start_us={marker.start_us}
                phx-value-end_us={marker.end_us}
                phx-value-frame_id={marker.frame_id}
                title={marker.title}
                style={"top: #{marker.top_pct}%"}
                class="absolute left-[6px] z-[9] h-2 w-[14px] -translate-y-1/2 rounded-full bg-amber-400 shadow-xs ring-1 ring-black/70 transition-all hover:scale-125 hover:ring-white"
              >
                <span class="sr-only">{marker.title}</span>
              </button>
            </div>
          </div>

          <%!-- Compact Gaps Popover + Legend Footer --%>
          <div
            id="camera-timeline-rail-footer"
            class="mt-2 min-h-0 shrink-0 space-y-1.5 border-t border-sr-line pt-2 text-[10px] lg:max-h-56 lg:overflow-y-auto lg:pr-0.5"
          >
            <details
              :if={@gaps_total_count > 0}
              id="camera-timeline-gaps-details"
              phx-hook="DetailsState"
              class="rounded-md border border-rose-500/30 bg-rose-500/5 px-2 py-1"
            >
              <summary class="cursor-pointer font-semibold text-rose-700 dark:text-rose-300">
                Gaps ({@gaps_total_count})
              </summary>
              <div
                :if={@gap_reason_summary != []}
                id="camera-timeline-gaps-summary"
                class="mt-1.5 flex flex-wrap gap-1 border-b border-rose-500/20 pb-1.5"
              >
                <span
                  :for={{entry, summary_idx} <- Enum.with_index(@gap_reason_summary)}
                  id={"camera-timeline-gap-summary-#{summary_idx}"}
                  data-role="timeline-gap-summary-item"
                  data-gap-summary-reason={entry.reason}
                  class="inline-flex max-w-full items-center gap-0.5 rounded bg-rose-500/10 px-1 py-0.5 font-mono text-[9px] text-rose-700 dark:text-rose-300"
                >
                  <span class="truncate">{entry.label}:</span>
                  <span class="font-semibold">{entry.count}</span>
                </span>
              </div>
              <div id="camera-timeline-gaps" class="mt-1.5 max-h-36 space-y-1 overflow-y-auto">
                <div
                  :for={{gap, idx} <- Enum.with_index(@paged_gaps)}
                  id={"camera-timeline-gap-#{coverage_field(gap, :id) || idx}"}
                  data-role="timeline-gap-item"
                  data-gap-reason={to_string(coverage_field(gap, :reason))}
                  class="space-y-0.5 border-t border-rose-500/20 pt-1 text-[10px] text-sr-muted first:border-t-0 first:pt-0"
                >
                  <div class="flex flex-wrap items-center gap-1">
                    <.ui_badge variant="error" size="xs">
                      {to_string(coverage_field(gap, :reason))}
                    </.ui_badge>
                    <span :if={coverage_field(gap, :detail_class)} class="font-mono">
                      ({coverage_field(gap, :detail_class)})
                    </span>
                  </div>
                  <div class="truncate">
                    <.user_time
                      id={"camera-timeline-gap-start-#{coverage_field(gap, :id) || idx}"}
                      value={us_to_datetime(coverage_field(gap, :start_us))}
                      timezone={@timezone}
                      style={:compact}
                    />
                    <%= if coverage_field(gap, :end_us) do %>
                      &rarr;
                      <.user_time
                        id={"camera-timeline-gap-end-#{coverage_field(gap, :id) || idx}"}
                        value={us_to_datetime(coverage_field(gap, :end_us))}
                        timezone={@timezone}
                        style={:compact}
                      />
                    <% else %>
                      (open)
                    <% end %>
                  </div>
                </div>
              </div>
              <div
                :if={@gaps_total_pages > 1}
                id="camera-timeline-gaps-pagination"
                class="mt-1.5 flex items-center justify-between gap-1 border-t border-rose-500/20 pt-1.5 text-[10px]"
              >
                <button
                  id="camera-timeline-gaps-prev-page"
                  type="button"
                  phx-click="select_gaps_page"
                  phx-value-page={max(@gaps_page - 1, 1)}
                  disabled={@gaps_page <= 1}
                  class="rounded border border-rose-500/30 px-1.5 py-0.5 font-medium text-sr-ink disabled:opacity-40 hover:bg-rose-500/10"
                >
                  Prev
                </button>
                <span
                  id="camera-timeline-gaps-page-indicator"
                  class="font-mono text-[9px] text-sr-muted"
                >
                  Page {@gaps_page} / {@gaps_total_pages}
                </span>
                <button
                  id="camera-timeline-gaps-next-page"
                  type="button"
                  phx-click="select_gaps_page"
                  phx-value-page={min(@gaps_page + 1, @gaps_total_pages)}
                  disabled={@gaps_page >= @gaps_total_pages}
                  class="rounded border border-rose-500/30 px-1.5 py-0.5 font-medium text-sr-ink disabled:opacity-40 hover:bg-rose-500/10"
                >
                  Next
                </button>
              </div>
            </details>

            <details id="camera-timeline-legend-details" class="text-sr-muted">
              <summary class="cursor-pointer font-medium hover:text-sr-ink">Legend</summary>
              <div id="camera-timeline-legend" class="mt-1.5 max-h-36 space-y-1 overflow-y-auto">
                <div
                  :for={{state, label} <- legend_entries()}
                  data-legend-state={state}
                  class="flex items-center gap-1.5"
                >
                  <span class={["inline-block size-2 shrink-0 rounded-xs", bucket_color_class(state)]}></span>
                  <span class="truncate">{label}</span>
                </div>
              </div>
            </details>
          </div>
        </section>

        <%!-- PANE 3 (Main Stage): Full-Size Video Player + Compact Controls --%>
        <section
          id="camera-timeline-player-section"
          aria-label="Timeline player"
          class="flex min-w-0 flex-col space-y-2.5 rounded-xl border border-sr-line bg-sr-surface p-3"
        >
          <%!-- Compact Status & Controls Strip --%>
          <div
            id="camera-timeline-controls"
            class="flex flex-wrap items-center justify-between gap-2 border-b border-sr-line pb-2"
          >
            <div id="camera-timeline-basis-banner" class="flex flex-wrap items-center gap-1.5">
              <.ui_badge id="camera-timeline-time-basis" variant="info" size="xs">
                {@time_basis_label}
              </.ui_badge>
              <.ui_badge
                :if={@has_provisional?}
                id="camera-timeline-provisional-badge"
                data-role="provisional-copy-badge"
                variant="warning"
                size="xs"
              >
                provisional
              </.ui_badge>
              <.ui_badge
                :if={@reanchors != []}
                id="camera-timeline-reanchor-badge"
                variant="outline"
                size="xs"
              >
                Clock re-anchored ({length(@reanchors)})
              </.ui_badge>
              <.ui_badge
                :if={@scheduled_continuous?}
                id="camera-timeline-recorder-state"
                variant={if(@recorder_running?, do: "success", else: "warning")}
                size="xs"
              >
                {if @recorder_running?,
                  do: "Recording",
                  else: "Continuous policy set: not recording yet"}
              </.ui_badge>
            </div>

            <div class="flex flex-wrap items-center gap-1.5">
              <form id="camera-timeline-profile-form" phx-change="select_timeline_profile">
                <label for="camera-timeline-profile-select" class="sr-only">Stream profile</label>
                <select
                  id="camera-timeline-profile-select"
                  name="stream_profile_id"
                  class="h-7 rounded-md border border-sr-line bg-sr-control px-2 text-xs text-sr-ink"
                >
                  <option value="" selected={@timeline_profile_id == ""}>All profiles</option>
                  <option
                    :for={prof <- @stream_profiles}
                    value={prof.id}
                    selected={to_string(@timeline_profile_id) == to_string(prof.id)}
                  >
                    {prof.profile_name}
                  </option>
                </select>
              </form>

              <div
                id="camera-timeline-source-selector"
                role="group"
                aria-label="Playback source"
                class="inline-flex items-center gap-0.5 rounded-md border border-sr-line bg-sr-canvas p-0.5"
              >
                <button
                  :for={
                    {val, label} <- [
                      {"auto", "Auto"},
                      {"local", "Local"},
                      {"archive", "Archive"}
                    ]
                  }
                  id={"camera-timeline-source-#{val}"}
                  type="button"
                  phx-click="select_timeline_source"
                  phx-value-source={val}
                  aria-pressed={to_string(@timeline_source == val)}
                  class={[
                    "rounded px-2 py-0.5 text-[11px] font-medium transition-colors",
                    if(@timeline_source == val,
                      do: "bg-sr-ink text-sr-surface",
                      else: "text-sr-muted hover:text-sr-ink"
                    )
                  ]}
                >
                  {label}
                </button>
              </div>

              <.ui_button
                id="camera-timeline-refresh"
                type="button"
                phx-click="refresh_timeline"
                variant="ghost"
                size="xs"
              >
                Refresh
              </.ui_button>
            </div>
          </div>

          <div
            :if={@has_local_only_after_archive?}
            id="camera-timeline-local-only-after-archive-note"
            class="rounded-lg border border-amber-500/40 bg-amber-500/10 px-3 py-1.5 text-xs text-sr-ink"
          >
            <strong>Local only (archive expired/reaped):</strong>
            footage exists only on local NVR storage after object archive expiry or capacity reaping.
            These local bytes remain evictable under local retention and are never counted as unarchived.
          </div>

          <%!-- Full-Size 16:9 Video Player (Live or Recorded Timeline) --%>
          <div id="camera-timeline-player-card" class="flex-1">
            <%!-- In-Place Live Stream Stage --%>
            <div
              :if={@live_mode?}
              id="camera-timeline-live-stage"
              class="space-y-2"
            >
              <div class="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-rose-500/40 bg-rose-500/10 px-3 py-1.5 text-xs">
                <div class="flex items-center gap-2">
                  <span
                    id="camera-timeline-live-indicator"
                    class="inline-flex items-center gap-1.5 rounded-full bg-rose-600 px-2 py-0.5 text-[10px] font-bold tracking-wide text-white"
                  >
                    <span class="size-1.5 animate-pulse rounded-full bg-white"></span> LIVE
                  </span>
                  <span class="font-medium text-sr-ink">
                    {(@live_tile && @live_tile.detail) || "Live camera relay"}
                  </span>
                </div>
                <button
                  id="camera-timeline-exit-live"
                  type="button"
                  phx-click="exit_live_mode"
                  class="inline-flex items-center gap-1 rounded-md border border-sr-line bg-sr-surface px-2.5 py-1 text-[11px] font-medium text-sr-ink transition-colors hover:border-sr-brand"
                >
                  <.icon name="hero-arrow-uturn-left" class="size-3.5" />
                  <span>Back to Timeline</span>
                </button>
              </div>

              <div class="overflow-hidden rounded-lg border border-sr-line bg-black">
                <CameraRelayComponents.relay_player
                  :if={@live_tile && @live_tile.session}
                  session={@live_tile.session}
                  id_prefix="camera-workspace-live-relay"
                  compact={true}
                />
                <div
                  :if={!@live_tile || !@live_tile.session}
                  id="camera-timeline-live-placeholder"
                  role="status"
                  class="flex aspect-video w-full flex-col items-center justify-center gap-2 bg-zinc-950 p-6 text-center text-sm text-zinc-400"
                >
                  <.icon name="hero-video-camera" class="size-8 text-zinc-500" />
                  <span>{(@live_tile && @live_tile.error) || "Opening live camera relay..."}</span>
                </div>
              </div>
            </div>

            <div
              :if={!@live_mode? && @timeline_playlist_path in [nil, ""]}
              id="camera-timeline-empty-state"
              role="status"
              class="flex aspect-video w-full flex-col items-center justify-center gap-2 rounded-xl border border-dashed border-sr-line bg-sr-canvas p-6 text-center text-sm"
            >
              <%= cond do %>
                <% @archive_only_unplayable? -> %>
                  <div class="flex items-center gap-2 font-semibold text-sr-ink">
                    <.icon name="hero-archive-box" class="size-5 text-sr-muted" />
                    <span>Archive playback not available yet</span>
                  </div>
                  <p id="camera-timeline-archive-only" class="max-w-md text-xs text-sr-muted">
                    Archive copies cannot be played yet, so footage stored only in the archive
                    shows on the timeline but does not play. Local copies play as they are recorded.
                  </p>
                <% @scheduled_continuous? -> %>
                  <div class="flex items-center gap-2 font-semibold text-sr-ink">
                    <.icon name="hero-clock" class="size-5 text-sr-muted" />
                    <span>No playable footage in selected window</span>
                  </div>
                  <p
                    :if={not @recorder_running?}
                    id="camera-timeline-not-recording"
                    class="max-w-md text-xs text-sr-muted"
                  >
                    A <code class="font-mono">continuous</code>
                    recording policy is configured for this camera, but no recorder is running for it,
                    so no new footage is being captured. Footage appears here once recording runs.
                  </p>
                  <p :if={@recorder_running?} class="max-w-md text-xs text-sr-muted">
                    A recorder is running for this camera, and <strong class="text-sr-ink">0</strong>
                    sealed catalog blocks
                    (<code class="font-mono">RecordingCatalogEntry</code>) exist in the selected window yet.
                    Try a wider span (<code class="font-mono">24h</code>
                    / <code class="font-mono">7d</code>) or
                    check recorder and reconciliation status.
                  </p>
                  <div :if={@can_view_recording_settings} class="pt-1">
                    <.link
                      id="camera-timeline-empty-health-link"
                      navigate={~p"/settings/recording?tab=health"}
                      class="text-xs font-medium text-sr-brand underline"
                    >
                      Inspect Recording &amp; Storage health
                    </.link>
                  </div>
                <% true -> %>
                  <div class="flex items-center gap-2 font-semibold text-sr-ink">
                    <.icon name="hero-video-camera-slash" class="size-5 text-sr-muted" />
                    <span>No continuous recording policy active</span>
                  </div>
                  <p class="max-w-md text-xs text-sr-muted">
                    No <code class="font-mono">continuous</code> recording policy is active for this
                    camera/profile, and no playable catalog blocks exist in the selected window.
                  </p>
                  <div :if={@can_view_recording_settings} class="pt-1">
                    <.link
                      id="camera-timeline-empty-policy-link"
                      navigate={~p"/settings/recording?tab=policy"}
                      class="text-xs font-medium text-sr-brand underline"
                    >
                      Configure recording policy
                    </.link>
                  </div>
              <% end %>
            </div>

            <div
              :if={not @live_mode?}
              id="camera-timeline-player"
              phx-hook="CameraTimelinePlayer"
              phx-update="ignore"
              data-playlist-path={@timeline_playlist_path || ""}
              data-has-adjacent-window={to_string(@timeline_has_adjacent_window)}
              data-window-start-us={@timeline_playlist_origin_us || @timeline_play_from_us}
              data-window-end-us={@timeline_play_to_us}
              data-seek-offset-seconds={format_seek_offset_attr(@timeline_seek_offset_seconds)}
              data-highlight-frame-id={@timeline_highlight_frame_id || ""}
              data-overlay-detections={Jason.encode!(@timeline_overlay_detections)}
              data-window-events={Jason.encode!(@window_scrubber_events)}
              data-window-thumbnails={Jason.encode!(@window_scrubber_thumbnails)}
              class={[@timeline_playlist_path in [nil, ""] && "hidden"]}
            >
              <div
                data-role="timeline-video-container"
                class="relative overflow-hidden rounded-lg bg-black"
              >
                <video
                  data-role="timeline-video"
                  controls
                  playsinline
                  class="aspect-video w-full bg-black"
                  aria-label="Camera timeline playback"
                ></video>
                <svg
                  data-role="semantic-bbox-overlay"
                  aria-hidden="true"
                  class="pointer-events-none absolute inset-0 h-full w-full overflow-hidden"
                ></svg>
              </div>

              <%!-- Event-Highlighted Interactive Horizontal Playback Scrubber --%>
              <div
                id="camera-timeline-scrubber"
                data-role="playback-scrubber"
                role="slider"
                aria-label="Playback timeline scrubber"
                aria-valuemin="0"
                aria-valuenow="0"
                aria-valuemax="0"
                tabindex="0"
                class="mt-2 select-none rounded-lg border border-sr-line bg-zinc-950/90 px-2.5 pt-2 pb-1.5"
              >
                <div
                  data-role="scrubber-track"
                  class="relative h-8 w-full cursor-pointer rounded-md bg-zinc-800/80"
                >
                  <%!-- Subtle Verified Thumbnail Filmstrip Backdrop --%>
                  <div
                    data-role="scrubber-filmstrip"
                    aria-hidden="true"
                    class="pointer-events-none absolute inset-0 z-[1] flex items-center overflow-hidden rounded-md opacity-45"
                  >
                  </div>

                  <%!-- Bottom Contrast Scrim for Smart Bars & Motion Hairlines --%>
                  <div
                    data-role="scrubber-contrast-scrim"
                    aria-hidden="true"
                    class="pointer-events-none absolute inset-0 z-[2] rounded-md bg-gradient-to-t from-black/65 via-black/15 to-transparent"
                  >
                  </div>

                  <%!-- Buffered Range --%>
                  <div
                    data-role="scrubber-buffered"
                    style="width: 0%"
                    class="pointer-events-none absolute inset-y-0 left-0 z-[2] rounded-md bg-zinc-700/35"
                  >
                  </div>

                  <%!-- Elapsed Playback Progress Fill --%>
                  <div
                    data-role="scrubber-progress"
                    style="width: 0%"
                    class="pointer-events-none absolute inset-y-0 left-0 z-[3] rounded-l-md bg-sky-500/30"
                  >
                  </div>

                  <%!-- Event Indicator Rail: Smart bars + subtle Motion hairlines (populated by CameraTimelinePlayer) --%>
                  <div
                    data-role="scrubber-events"
                    class="absolute inset-0 z-[4]"
                  >
                  </div>

                  <%!-- Hover Hairline & Live Thumbnail Preview Card --%>
                  <div
                    data-role="scrubber-hover-line"
                    hidden
                    aria-hidden="true"
                    class="pointer-events-none absolute inset-y-0 z-[8] w-px bg-white/80"
                  >
                  </div>
                  <div
                    data-role="scrubber-hover-tooltip"
                    hidden
                    aria-hidden="true"
                    class="pointer-events-none absolute bottom-full mb-2 z-[12] -translate-x-1/2 rounded-md bg-zinc-900/95 p-1 font-mono text-[10px] font-medium text-white shadow-lg ring-1 ring-white/20"
                  >
                  </div>

                  <%!-- Smooth Real-Time Playhead Line --%>
                  <div
                    data-role="scrubber-playhead"
                    style="left: 0%"
                    aria-hidden="true"
                    class="pointer-events-none absolute -top-0.5 -bottom-0.5 z-[10] w-0.5 -translate-x-1/2 rounded-full bg-sky-400 shadow-[0_0_8px_rgba(56,189,248,0.95)]"
                  >
                    <span class="absolute -top-1 left-1/2 size-2 -translate-x-1/2 rounded-full bg-sky-400 ring-1 ring-white"></span>
                  </div>
                </div>

                <%!-- Subtle Scrubber Time Ticks --%>
                <div
                  data-role="scrubber-ticks"
                  class="mt-1 flex items-center justify-between font-mono text-[9px] text-zinc-400"
                >
                </div>
              </div>

              <%!-- Compact Player Transport Bar (managed by CameraTimelinePlayer hook) --%>
              <div class="mt-2 flex flex-wrap items-center justify-between gap-2 rounded-lg border border-sr-line bg-sr-canvas px-2.5 py-1.5 text-xs">
                <div class="flex flex-wrap items-center gap-1.5">
                  <button
                    id="camera-timeline-back-10"
                    type="button"
                    data-role="transport-back-10"
                    class="rounded border border-sr-line bg-sr-surface px-2 py-0.5 font-mono text-[11px] font-medium text-sr-ink hover:border-sr-brand"
                  >
                    -10s
                  </button>
                  <button
                    id="camera-timeline-play-pause"
                    type="button"
                    data-role="transport-play-pause"
                    aria-pressed="false"
                    class="rounded border border-sr-line bg-sr-ink px-2.5 py-0.5 text-[11px] font-medium text-sr-surface hover:opacity-90"
                  >
                    Play
                  </button>
                  <button
                    id="camera-timeline-fwd-10"
                    type="button"
                    data-role="transport-fwd-10"
                    class="rounded border border-sr-line bg-sr-surface px-2 py-0.5 font-mono text-[11px] font-medium text-sr-ink hover:border-sr-brand"
                  >
                    +10s
                  </button>
                  <span
                    data-role="transport-current-time"
                    class="ml-1 font-mono text-[11px] text-sr-muted"
                  >
                    00:00
                  </span>
                  <span data-role="timeline-status" role="status" class="text-[11px] text-sr-muted">
                    Preparing timeline...
                  </span>
                </div>

                <div class="flex flex-wrap items-center gap-1.5">
                  <span
                    id="camera-timeline-served-copy-badge"
                    data-role="served-copy-badge"
                    data-served-copy=""
                    class="inline-flex items-center rounded border border-sr-line bg-sr-surface px-1.5 py-0.5 font-mono text-[10px] text-sr-ink"
                  >
                    Serving: —
                  </span>
                  <button
                    id="camera-timeline-mute"
                    type="button"
                    data-role="transport-mute"
                    aria-pressed="false"
                    class="rounded border border-sr-line bg-sr-surface px-2 py-0.5 text-[11px] text-sr-ink hover:border-sr-brand"
                  >
                    Mute
                  </button>
                  <button
                    id="camera-timeline-fullscreen"
                    type="button"
                    data-role="transport-fullscreen"
                    class="rounded border border-sr-line bg-sr-surface px-2 py-0.5 text-[11px] text-sr-ink hover:border-sr-brand"
                  >
                    Fullscreen
                  </button>
                  <button
                    id="camera-timeline-toggle-bbox-overlay"
                    type="button"
                    data-role="toggle-bbox-overlay"
                    aria-pressed="true"
                    class="rounded border border-sr-line bg-sr-surface px-2 py-0.5 text-[11px] font-medium text-sr-ink hover:border-sr-brand"
                  >
                    AI boxes: On
                  </button>
                  <button
                    type="button"
                    data-role="timeline-retry"
                    class="sr-ops-button text-xs"
                    hidden
                  >
                    Retry playback
                  </button>
                </div>
              </div>
            </div>
          </div>

          <%!-- Window Time Range + Manage/Holds Drawer Trigger --%>
          <div class="flex flex-wrap items-center justify-between gap-2 pt-0.5 text-xs">
            <p :if={@timeline_play_from_us && @timeline_play_to_us} class="text-sr-muted">
              <span class="font-medium text-sr-ink">Window:</span>
              {@time_basis_short}
              <.user_time
                id="camera-timeline-play-from"
                value={us_to_datetime(@timeline_play_from_us)}
                timezone={@timezone}
              /> &rarr;
              <.user_time
                id="camera-timeline-play-to"
                value={us_to_datetime(@timeline_play_to_us)}
                timezone={@timezone}
              />
            </p>
            <div class="flex items-center gap-2">
              <.ui_button
                id="camera-timeline-roi-drawer-toggle"
                type="button"
                phx-click="toggle_roi_drawer"
                variant="outline"
                size="xs"
              >
                <.icon name="hero-squares-2x2" class="size-3.5" /> Detection Zones
                <span
                  :if={@is_ptz?}
                  class="ml-1 rounded-full bg-amber-500/15 px-1.5 py-0.5 font-mono text-[10px] text-amber-600 dark:text-amber-300"
                >
                  PTZ
                </span>
                <span
                  :if={!@is_ptz? && @roi_active_count > 0}
                  id="camera-roi-active-count"
                  class="ml-1 rounded-full bg-sr-canvas px-1.5 py-0.5 font-mono text-[10px]"
                >
                  {@roi_active_count}
                </span>
              </.ui_button>
              <.ui_button
                id="camera-timeline-manage-drawer-toggle"
                type="button"
                phx-click="toggle_manage_drawer"
                variant="outline"
                size="xs"
              >
                <.icon name="hero-shield-check" class="size-3.5" /> Manage / Holds
                <span class="ml-1 rounded-full bg-sr-canvas px-1.5 py-0.5 font-mono text-[10px]">
                  {length(@timeline_holds)}
                </span>
              </.ui_button>
            </div>
          </div>

          <%!-- Compact Inline Semantic Search Bar --%>
          <section
            id="camera-timeline-search-section"
            aria-label="Timeline semantic clip search"
            class="space-y-2 border-t border-sr-line pt-2"
          >
            <form
              id="camera-timeline-search-form"
              phx-submit="timeline_semantic_search"
              class="flex flex-wrap items-center gap-1.5"
            >
              <label for="camera-timeline-search-input" class="sr-only">
                Semantic search in camera timeline
              </label>
              <input
                id="camera-timeline-search-input"
                type="text"
                name="search[q]"
                value={@timeline_search_query}
                maxlength="256"
                placeholder="Search clips in timeline (e.g. person in red jacket, white van)"
                class="h-8 min-w-48 flex-1 rounded-lg border border-sr-line bg-sr-control px-2.5 text-xs text-sr-ink placeholder:text-sr-muted"
              />
              <label for="camera-timeline-search-object-class" class="sr-only">Object class</label>
              <select
                id="camera-timeline-search-object-class"
                name="search[object_class]"
                class="h-8 rounded-lg border border-sr-line bg-sr-control px-2 text-xs text-sr-ink"
              >
                <option value="" selected={@timeline_search_object_class == ""}>All subjects</option>
                <option
                  :for={
                    {val, label} <- [
                      {"person", "Person"},
                      {"vehicle", "Vehicle"},
                      {"bicycle", "Bicycle"},
                      {"animal", "Animal"},
                      {"package", "Package"}
                    ]
                  }
                  value={val}
                  selected={@timeline_search_object_class == val}
                >
                  {label}
                </option>
              </select>
              <.ui_button id="camera-timeline-search-submit" type="submit" variant="primary" size="xs">
                <.icon name="hero-magnifying-glass" class="size-3.5" /> Search
              </.ui_button>
              <.ui_button
                :if={@timeline_search_executed? or @timeline_search_query != ""}
                id="camera-timeline-search-clear"
                type="button"
                phx-click="clear_timeline_semantic_search"
                variant="ghost"
                size="xs"
              >
                Clear
              </.ui_button>
            </form>

            <div
              :if={@timeline_embedder_unavailable?}
              id="camera-timeline-search-unavailable"
              role="alert"
              class="rounded-lg border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-xs text-sr-ink"
            >
              <p class="font-semibold">Visual search workers unavailable</p>
              <p class="text-sr-muted">
                No compatible media worker responded within the interactive deadline. Timeline video playback remains unaffected.
              </p>
            </div>

            <div
              :if={@timeline_search_error}
              id="camera-timeline-search-error"
              role="alert"
              class="rounded-lg border border-rose-500/40 bg-rose-500/10 px-3 py-2 text-xs text-sr-ink"
            >
              <span>{@timeline_search_error}</span>
            </div>

            <p
              :if={
                @timeline_search_executed? and @timeline_search_results == [] and
                  not @timeline_embedder_unavailable? and is_nil(@timeline_search_error)
              }
              id="camera-timeline-search-empty"
              class="text-xs text-sr-muted"
            >
              No matching recorded clips found in the current coverage span.
            </p>

            <ul
              :if={@timeline_search_results != []}
              id="camera-timeline-search-results"
              class="grid gap-1.5 sm:grid-cols-2 lg:grid-cols-3"
            >
              <li
                :for={{hit, idx} <- Enum.with_index(@timeline_search_results)}
                id={"camera-timeline-hit-#{idx}"}
              >
                <button
                  id={"select-timeline-semantic-hit-#{idx}"}
                  type="button"
                  data-role="timeline-semantic-hit"
                  phx-click="select_timeline_semantic_hit"
                  phx-value-seek_us={hit.best_timeline_ts_us}
                  phx-value-start_us={hit.clip_start_us}
                  phx-value-end_us={hit.clip_end_us}
                  phx-value-frame_id={hit.visual_frame_id || ""}
                  class={[
                    "flex w-full items-center gap-2 rounded-lg border p-2 text-left text-xs transition-colors hover:bg-sr-canvas",
                    if(
                      not is_nil(@timeline_highlight_frame_id) and
                        @timeline_highlight_frame_id == hit.visual_frame_id,
                      do: "border-sr-brand bg-sr-brand/5",
                      else: "border-sr-line"
                    )
                  ]}
                >
                  <div class="relative flex h-9 w-12 shrink-0 items-center justify-center overflow-hidden rounded border border-sr-line bg-zinc-950">
                    <%= if thumb_url = hit_thumbnail_url(hit, @active_source_id) do %>
                      <img
                        src={thumb_url}
                        alt={"#{format_hit_object_class(hit.object_class) || "Match"} thumbnail"}
                        loading="lazy"
                        class="h-full w-full object-cover"
                      />
                    <% else %>
                      <.icon
                        name={clip_category_icon(hit_category_atom(hit.object_class))}
                        class="size-4 text-zinc-400"
                      />
                    <% end %>
                  </div>
                  <div class="min-w-0 flex-1">
                    <div class="flex flex-wrap items-center justify-between gap-1">
                      <div class="flex flex-wrap items-center gap-1">
                        <.ui_badge variant="primary" size="xs">
                          {format_hit_score(hit.score)}
                        </.ui_badge>
                        <.ui_badge
                          :if={format_hit_object_class(hit.object_class)}
                          data-role="semantic-hit-object-class"
                          variant="outline"
                          size="xs"
                        >
                          {format_hit_object_class(hit.object_class)}
                        </.ui_badge>
                      </div>
                      <span class="font-mono text-[10px] text-sr-muted">{hit.time_basis}</span>
                    </div>
                    <div class="mt-1 truncate text-[11px] text-sr-ink">
                      <.user_time
                        id={"timeline-hit-time-#{idx}"}
                        value={us_to_datetime(hit.best_timeline_ts_us)}
                        timezone={@timezone}
                        style={:compact}
                      />
                    </div>
                    <p
                      :if={
                        is_binary(Map.get(hit, :caption_text)) and
                          String.trim(Map.get(hit, :caption_text)) != ""
                      }
                      data-role="semantic-hit-caption"
                      class="mt-1 line-clamp-2 text-[11px] leading-snug text-sr-muted"
                    >
                      {hit.caption_text}
                    </p>
                  </div>
                </button>
              </li>
            </ul>
          </section>
        </section>
      </div>

      <%!-- BOTTOM STRIP: Compact 2-Row Server-Side Paginated Detections & Clips --%>
      <section
        id="camera-timeline-event-clips-section"
        aria-label="Detections and clips"
        class="space-y-2.5 rounded-xl border border-sr-line bg-sr-surface p-3"
      >
        <%!-- Compact Single-Line Filter + Pagination Header --%>
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div class="flex flex-wrap items-center gap-2">
            <div class="flex items-center gap-1.5">
              <h2 class="text-sm font-semibold text-sr-ink">Detections &amp; Clips</h2>
              <.ui_badge id="camera-clips-total-badge" variant="ghost" size="xs">
                {@filtered_event_clip_total}
              </.ui_badge>
            </div>

            <div
              id="camera-clips-mode-toggle"
              role="group"
              aria-label="Clip detection mode"
              class="inline-flex items-center gap-0.5 rounded-lg border border-sr-line bg-sr-canvas p-0.5"
            >
              <button
                :for={
                  {mode_val, mode_label, count_key} <- [
                    {"smart", "Smart", :smart},
                    {"basic", "Basic", :basic},
                    {"all", "All", :all}
                  ]
                }
                id={"camera-clips-mode-#{mode_val}"}
                type="button"
                phx-click="filter_event_clips_mode"
                phx-value-mode={mode_val}
                aria-pressed={to_string(@timeline_clips_mode == mode_val)}
                class={[
                  "inline-flex items-center gap-1 rounded-md px-2 py-0.5 text-[11px] font-medium transition-colors",
                  if(@timeline_clips_mode == mode_val,
                    do: "bg-sr-ink text-sr-surface",
                    else: "text-sr-muted hover:text-sr-ink"
                  )
                ]}
              >
                <span>{mode_label}</span>
                <span class="font-mono text-[10px] opacity-75">
                  {Map.get(@clip_counts, count_key, 0)}
                </span>
              </button>
            </div>

            <div
              id="camera-clips-category-filters"
              role="group"
              aria-label="Clip category filters"
              class="flex flex-wrap items-center gap-1"
            >
              <button
                :for={{cat_val, cat_label, cat_icon, count_key} <- clip_category_filter_specs()}
                id={"camera-clips-category-#{cat_val}"}
                type="button"
                phx-click="filter_event_clips_category"
                phx-value-category={cat_val}
                aria-pressed={to_string(@timeline_clips_category == cat_val)}
                class={[
                  "inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-medium transition-colors",
                  if(@timeline_clips_category == cat_val,
                    do: "border-sr-brand bg-sr-brand/10 text-sr-ink",
                    else:
                      "border-sr-line bg-sr-canvas text-sr-muted hover:border-sr-ink/40 hover:text-sr-ink"
                  )
                ]}
              >
                <.icon name={cat_icon} class="size-3 shrink-0" />
                <span>{cat_label}</span>
                <span
                  id={"camera-clips-category-count-#{cat_val}"}
                  class="font-mono text-[10px] opacity-75"
                >
                  {Map.get(@clip_counts, count_key, 0)}
                </span>
              </button>
            </div>

            <%!-- Confidence Threshold Slider --%>
            <form
              id="camera-clips-confidence-form"
              phx-change="set_min_confidence"
              class="inline-flex items-center gap-1.5 rounded-lg border border-sr-line bg-sr-canvas px-2 py-0.5 text-[11px]"
            >
              <label for="camera-clips-confidence-slider" class="font-medium text-sr-muted">
                Min conf
              </label>
              <input
                id="camera-clips-confidence-slider"
                type="range"
                name="min_confidence"
                min="30"
                max="95"
                step="5"
                value={@timeline_min_confidence}
                phx-debounce="100"
                aria-label="Minimum detection confidence threshold"
                class="h-1.5 w-20 cursor-pointer accent-emerald-500"
              />
              <span
                id="camera-clips-confidence-value"
                class="min-w-[2.2rem] text-right font-mono text-[10px] font-semibold text-sr-ink"
              >
                {@timeline_min_confidence}%
              </span>
            </form>
          </div>

          <%!-- Right-Aligned Compact Server-Side Pagination Controls --%>
          <div
            id="camera-clips-pagination"
            class="inline-flex items-center gap-1.5 text-xs"
          >
            <button
              id="camera-clips-prev-page"
              type="button"
              phx-click="paginate_event_clips"
              phx-value-page={max(@clips_page - 1, 1)}
              disabled={@clips_page <= 1}
              class="rounded-md border border-sr-line bg-sr-canvas px-2 py-1 text-[11px] font-medium text-sr-ink disabled:opacity-40 hover:border-sr-brand"
            >
              Prev
            </button>
            <span
              id="camera-clips-page-indicator"
              class="px-1 font-mono text-[11px] text-sr-muted"
            >
              Page {@clips_page} / {@clips_total_pages}
            </span>
            <button
              id="camera-clips-next-page"
              type="button"
              phx-click="paginate_event_clips"
              phx-value-page={min(@clips_page + 1, @clips_total_pages)}
              disabled={@clips_page >= @clips_total_pages}
              class="rounded-md border border-sr-line bg-sr-canvas px-2 py-1 text-[11px] font-medium text-sr-ink disabled:opacity-40 hover:border-sr-brand"
            >
              Next
            </button>
          </div>
        </div>

        <div
          :if={@filtered_event_clips == []}
          id="camera-clips-empty"
          role="status"
          class="flex flex-col items-center justify-center gap-1.5 rounded-xl border border-dashed border-sr-line bg-sr-canvas px-4 py-6 text-center"
        >
          <.icon name="hero-film" class="size-5 text-sr-muted" />
          <p class="text-xs font-medium text-sr-ink">
            {if(@has_any_window_clips?,
              do: "No clips match the current filter.",
              else: "No detections or recorded clips in this coverage window."
            )}
          </p>
          <.ui_button
            :if={@has_any_window_clips?}
            id="camera-clips-reset-filters"
            type="button"
            phx-click="reset_event_clip_filters"
            variant="outline"
            size="xs"
          >
            Reset filters
          </.ui_button>
        </div>

        <%!-- Strictly 2-Row Compact Grid (per_page: 12 => 2 rows x 6 cards on desktop) --%>
        <div
          :if={@filtered_event_clips != []}
          id="camera-clips-grid"
          class="grid grid-cols-2 gap-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6"
        >
          <button
            :for={clip <- @filtered_event_clips}
            id={"camera-clip-card-#{clip.id}"}
            type="button"
            data-role="event-clip-card"
            data-clip-category={to_string(clip.category)}
            data-clip-smart-type={to_string(clip.smart_type)}
            phx-click="select_event_clip"
            phx-value-clip_id={clip.id}
            aria-pressed={
              to_string(
                clip_selected?(
                  clip,
                  @timeline_selected_clip_id,
                  @timeline_play_from_us,
                  @timeline_play_to_us
                )
              )
            }
            class={[
              "group flex flex-col overflow-hidden rounded-lg border bg-sr-canvas text-left transition-all hover:border-sr-brand/70 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-sr-brand",
              if(
                clip_selected?(
                  clip,
                  @timeline_selected_clip_id,
                  @timeline_play_from_us,
                  @timeline_play_to_us
                ),
                do: "border-sr-brand ring-2 ring-sr-brand/70",
                else: "border-sr-line"
              )
            ]}
          >
            <div class="relative aspect-video w-full overflow-hidden bg-zinc-950">
              <%= if is_binary(clip.thumbnail_url) and clip.thumbnail_url != "" do %>
                <img
                  src={clip.thumbnail_url}
                  alt={"#{clip.label} detection clip"}
                  loading="lazy"
                  class="h-full w-full object-cover transition-transform duration-200 group-hover:scale-105"
                />
              <% else %>
                <div class="flex h-full w-full items-center justify-center bg-gradient-to-br from-zinc-900 via-zinc-950 to-zinc-900 text-zinc-500">
                  <.icon
                    name={clip_category_icon(clip.category)}
                    class="size-5 transition-transform duration-200 group-hover:scale-110 group-hover:text-zinc-300"
                  />
                </div>
              <% end %>

              <%!-- Top-left relative time pill --%>
              <span class="absolute top-1 left-1 rounded bg-black/75 px-1 py-0.5 text-[10px] font-medium leading-none text-white backdrop-blur-xs">
                {format_relative_age(clip.start_us, @now_us)}
              </span>

              <%!-- Top-right duration pill --%>
              <span class="absolute top-1 right-1 rounded bg-black/75 px-1 py-0.5 font-mono text-[10px] leading-none text-zinc-200 backdrop-blur-xs">
                {format_clip_duration(clip.duration_seconds)}
              </span>

              <%!-- Bottom-left compact type badge --%>
              <span class={[
                "absolute bottom-1 left-1 inline-flex items-center gap-0.5 rounded px-1 py-0.5 text-[10px] font-medium leading-none text-white backdrop-blur-xs",
                clip_badge_bg_class(clip.category)
              ]}>
                <.icon name={clip_category_icon(clip.category)} class="size-2.5 shrink-0" />
                <span>{clip.label}</span>
                <span
                  :if={is_number(Map.get(clip, :confidence))}
                  class="font-mono text-[9px] opacity-85"
                >
                  {format_confidence_pct(clip.confidence)}
                </span>
              </span>
            </div>

            <div class="flex items-center justify-between gap-1 px-1.5 py-1 text-[10px]">
              <span class="truncate text-sr-ink">
                <.user_time
                  id={"camera-clip-time-#{clip.id}"}
                  value={clip.started_at}
                  timezone={@timezone}
                  style={:compact}
                />
              </span>
              <span class="shrink-0 font-mono text-[9px] text-sr-muted">
                {clip_storage_badge(clip)}
              </span>
            </div>
          </button>
        </div>
      </section>

      <%!-- Slide-Over Drawer: Recording Holds, Catalog Blocks & Clock Re-anchors --%>
      <div
        id="camera-timeline-manage-drawer"
        aria-hidden={to_string(not @timeline_manage_drawer_open?)}
        class={[
          "fixed inset-0 z-[80] flex justify-end",
          if(@timeline_manage_drawer_open?, do: "", else: "hidden")
        ]}
      >
        <div
          id="camera-timeline-manage-drawer-backdrop"
          phx-click="close_manage_drawer"
          class="fixed inset-0 bg-black/50 backdrop-blur-xs"
        >
        </div>

        <aside
          aria-label="Manage holds and catalog blocks"
          class="relative z-10 flex h-full w-full max-w-md flex-col overflow-y-auto border-l border-sr-line bg-sr-surface p-4 shadow-xl"
        >
          <div class="flex items-center justify-between gap-2 border-b border-sr-line pb-3">
            <div>
              <h2 class="text-sm font-semibold text-sr-ink">Manage Holds &amp; Catalog</h2>
              <p class="text-xs text-sr-muted">
                Recording holds, catalog blocks in span, and clock re-anchor markers.
              </p>
            </div>
            <.ui_button
              id="camera-timeline-manage-drawer-close"
              type="button"
              phx-click="close_manage_drawer"
              variant="ghost"
              size="xs"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </.ui_button>
          </div>

          <div class="mt-4 space-y-5">
            <%!-- Recording Holds --%>
            <section
              id="camera-timeline-holds-section"
              aria-label="Recording holds"
              class="space-y-3"
            >
              <div class="flex items-center justify-between gap-2">
                <h3 class="text-xs font-semibold uppercase tracking-wide text-sr-muted">
                  Recording holds
                </h3>
                <.ui_badge variant="ghost" size="xs">{length(@timeline_holds)}</.ui_badge>
              </div>

              <%= if @can_manage_holds && @hold_form do %>
                <.form
                  for={@hold_form}
                  id="place-timeline-hold-form"
                  phx-change="change_hold_form"
                  phx-submit="place_timeline_hold"
                  class="space-y-2.5 rounded-lg border border-sr-line bg-sr-canvas p-3"
                >
                  <div class="flex flex-wrap items-center justify-between gap-2">
                    <p class="text-xs font-semibold text-sr-ink">Place hold on window</p>
                    <div
                      id="timeline-hold-presets"
                      role="group"
                      aria-label="Hold window presets"
                      class="inline-flex flex-wrap items-center gap-1"
                    >
                      <button
                        :for={
                          {preset, label} <- [
                            {"window", "Current window"},
                            {"15m", "Last 15m"},
                            {"1h", "Last 1h"},
                            {"24h", "Last 24h"}
                          ]
                        }
                        id={"timeline-hold-preset-#{preset}"}
                        type="button"
                        phx-click="select_hold_preset"
                        phx-value-preset={preset}
                        class="rounded border border-sr-line bg-sr-surface px-1.5 py-0.5 text-[11px] font-medium text-sr-ink hover:bg-sr-subtle"
                      >
                        {label}
                      </button>
                    </div>
                  </div>
                  <.input
                    field={@hold_form[:kind]}
                    id="timeline-hold-kind"
                    type="select"
                    label="Hold kind"
                    options={[{"Investigation", "investigation"}, {"Export", "export"}]}
                  />
                  <div class="space-y-2">
                    <.input
                      field={@hold_form[:start_at]}
                      id="timeline-hold-start-at"
                      type="datetime-local"
                      step="1"
                      label={"Start (#{@timezone})"}
                      required
                    />
                    <.input
                      field={@hold_form[:end_at]}
                      id="timeline-hold-end-at"
                      type="datetime-local"
                      step="1"
                      label={"End (#{@timezone})"}
                      required
                    />
                  </div>
                  <.input
                    field={@hold_form[:reason]}
                    id="timeline-hold-reason"
                    type="text"
                    label="Reason"
                    placeholder="Incident or export ticket reference"
                    required
                  />
                  <.ui_button
                    id="place-timeline-hold-submit"
                    type="submit"
                    variant="primary"
                    size="sm"
                    class="w-full"
                  >
                    Place hold
                  </.ui_button>
                </.form>
              <% end %>

              <p
                :if={@timeline_holds == []}
                id="camera-timeline-holds-empty"
                class="text-xs text-sr-muted"
              >
                No holds recorded for this camera.
              </p>

              <ul :if={@timeline_holds != []} id="camera-timeline-holds-list" class="space-y-2.5">
                <li
                  :for={hold <- @timeline_holds}
                  id={"timeline-hold-#{hold.id}"}
                  data-hold-state={to_string(hold.state)}
                  class="space-y-2 rounded-lg border border-sr-line p-2.5 text-xs"
                >
                  <div class="flex flex-wrap items-center gap-1.5">
                    <.ui_badge
                      variant={if(hold.state == :accepted, do: "primary", else: "ghost")}
                      size="xs"
                    >
                      {to_string(hold.state)}
                    </.ui_badge>
                    <.ui_badge variant="outline" size="xs">{to_string(hold.kind)}</.ui_badge>
                    <.ui_badge
                      :if={hold.pinned_copy}
                      id={"timeline-hold-pin-#{hold.id}"}
                      variant="info"
                      size="xs"
                    >
                      Pinned: {to_string(hold.pinned_copy)}
                    </.ui_badge>
                  </div>

                  <p class="font-medium text-sr-ink">{hold.reason}</p>

                  <p class="text-sr-muted">
                    {@time_basis_short}
                    <.user_time
                      id={"timeline-hold-start-#{hold.id}"}
                      value={us_to_datetime(hold.start_us)}
                      timezone={@timezone}
                    /> &rarr;
                    <.user_time
                      id={"timeline-hold-end-#{hold.id}"}
                      value={us_to_datetime(hold.end_us)}
                      timezone={@timezone}
                    />
                  </p>

                  <div
                    :if={hold.archive_missing?}
                    id={"timeline-hold-archive-missing-#{hold.id}"}
                    class="rounded border border-amber-500/40 bg-amber-500/10 px-2 py-1 text-amber-700 dark:text-amber-300"
                  >
                    Archive copy missing — local copy is pinned when present.
                  </div>

                  <div
                    :if={hold.unavailable_blocks != []}
                    id={"timeline-hold-unavailable-#{hold.id}"}
                    class="rounded border border-rose-500/40 bg-rose-500/10 px-2 py-1 text-rose-700 dark:text-rose-300"
                  >
                    {length(hold.unavailable_blocks)} block(s) unavailable (deletion in progress when hold was placed).
                  </div>

                  <p :if={hold.state == :released && hold.release_reason} class="text-sr-muted">
                    Released: {hold.release_reason}
                  </p>

                  <form
                    :if={@can_manage_holds && hold.state == :accepted}
                    id={"release-timeline-hold-form-#{hold.id}"}
                    phx-submit="release_timeline_hold"
                    class="flex items-center gap-2 pt-1"
                  >
                    <input type="hidden" name="hold_id" value={hold.id} />
                    <input
                      type="text"
                      name="release_reason"
                      placeholder="Optional release note"
                      class="h-8 flex-1 rounded-md border border-sr-line bg-sr-control px-2 text-xs text-sr-ink"
                    />
                    <.ui_button
                      id={"release-timeline-hold-#{hold.id}"}
                      type="submit"
                      variant="outline"
                      size="xs"
                    >
                      Release
                    </.ui_button>
                  </form>
                </li>
              </ul>
            </section>

            <%!-- Clock Re-anchor Markers --%>
            <div
              :if={@reanchors != []}
              id="camera-timeline-reanchors"
              class="space-y-1.5 rounded-lg border border-sr-line bg-sr-canvas p-3 text-xs"
            >
              <p class="font-semibold text-sr-ink">Clock re-anchor markers</p>
              <ul class="space-y-1 text-sr-muted">
                <li
                  :for={{marker, idx} <- Enum.with_index(@reanchors)}
                  id={"camera-timeline-reanchor-#{idx}"}
                  class="flex flex-wrap items-center gap-1.5"
                >
                  <.ui_badge variant="outline" size="xs">Clock re-anchored</.ui_badge>
                  <span>
                    {@time_basis_short}
                    <.user_time
                      id={"camera-timeline-reanchor-time-#{idx}"}
                      value={us_to_datetime(reanchor_at_us(marker))}
                      timezone={@timezone}
                    />
                  </span>
                </li>
              </ul>
            </div>

            <%!-- Catalog Blocks in Span --%>
            <div :if={@blocks != []} id="camera-timeline-blocks" class="space-y-2">
              <h3 class="text-xs font-semibold uppercase tracking-wide text-sr-muted">
                Catalog blocks in span ({length(@blocks)})
              </h3>
              <ul class="max-h-72 space-y-1.5 overflow-y-auto pr-1 text-xs">
                <li
                  :for={block <- @blocks}
                  id={"camera-timeline-block-#{coverage_field(block, :id)}"}
                  data-copy-state={block_copy_state_name(block)}
                  class="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-sr-line px-2.5 py-1.5"
                >
                  <div class="flex flex-wrap items-center gap-1">
                    <.ui_badge
                      variant={copy_state_badge_variant(block_copy_state_name(block))}
                      size="xs"
                    >
                      {copy_state_label(block_copy_state_name(block))}
                    </.ui_badge>
                    <.ui_badge
                      :if={block_provisional?(block)}
                      data-role="block-provisional-badge"
                      variant="warning"
                      size="xs"
                    >
                      provisional
                    </.ui_badge>
                    <.ui_badge :if={block_reanchored?(block)} variant="outline" size="xs">
                      Clock re-anchored
                    </.ui_badge>
                  </div>
                  <span class="text-sr-muted">
                    {@time_basis_short}
                    <.user_time
                      id={"camera-timeline-block-start-#{coverage_field(block, :id)}"}
                      value={us_to_datetime(coverage_field(block, :timeline_start_us))}
                      timezone={@timezone}
                    />
                  </span>
                </li>
              </ul>
            </div>
          </div>
        </aside>
      </div>

      <%!-- Slide-Over Drawer: Non-PTZ Interactive Camera Scene Detection Zones (ROI Focus/Ignore Grid) --%>
      <div
        id="camera-timeline-roi-drawer"
        aria-hidden={to_string(not @roi_drawer_open?)}
        class={[
          "fixed inset-0 z-[80] flex justify-end",
          if(@roi_drawer_open?, do: "", else: "hidden")
        ]}
      >
        <div
          id="camera-timeline-roi-drawer-backdrop"
          phx-click="close_roi_drawer"
          class="fixed inset-0 bg-black/50 backdrop-blur-xs"
        >
        </div>

        <aside
          aria-label="Detection zones"
          class="relative z-10 flex h-full w-full max-w-xl flex-col overflow-y-auto border-l border-sr-line bg-sr-surface p-4 shadow-xl"
        >
          <div class="flex items-center justify-between gap-2 border-b border-sr-line pb-3">
            <div>
              <h2 class="text-sm font-semibold text-sr-ink">Detection Zones</h2>
              <p class="text-xs text-sr-muted">
                Mark scene cells to prioritize (Focus) or suppress (Ignore) smart detections.
              </p>
            </div>
            <.ui_button
              id="camera-timeline-roi-drawer-close"
              type="button"
              phx-click="close_roi_drawer"
              variant="ghost"
              size="xs"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </.ui_button>
          </div>

          <div class="mt-4 space-y-4">
            <%= if @is_ptz? do %>
              <div
                id="camera-roi-ptz-notice"
                role="status"
                class="rounded-xl border border-amber-500/40 bg-amber-500/10 p-4 text-xs text-sr-ink"
              >
                <div class="flex items-center gap-2 font-semibold">
                  <.icon name="hero-exclamation-triangle" class="size-4 text-amber-500" />
                  <span>Not applicable for PTZ cameras</span>
                </div>
                <p class="mt-1 text-sr-muted">
                  Fixed scene Focus/Ignore detection grids require a stationary camera view.
                  Pan-tilt-zoom cameras move their field of view, so static cell masks are disabled.
                </p>
              </div>
            <% else %>
              <%!-- Paint Mode Selector + Counts --%>
              <div class="flex flex-wrap items-center justify-between gap-2">
                <div
                  id="camera-roi-paint-modes"
                  role="group"
                  aria-label="Zone paint mode"
                  class="inline-flex items-center gap-1 rounded-lg border border-sr-line bg-sr-canvas p-0.5"
                >
                  <button
                    :for={
                      {mode_val, mode_label, active_cls} <- [
                        {"focus", "Focus", "bg-emerald-600 text-white"},
                        {"ignore", "Ignore", "bg-rose-600 text-white"},
                        {"erase", "Erase", "bg-sr-ink text-sr-surface"}
                      ]
                    }
                    id={"camera-roi-mode-#{mode_val}"}
                    type="button"
                    phx-click="roi_set_paint_mode"
                    phx-value-mode={mode_val}
                    aria-pressed={to_string(@roi_paint_mode == mode_val)}
                    class={[
                      "rounded-md px-2.5 py-1 text-xs font-medium transition-colors",
                      if(@roi_paint_mode == mode_val,
                        do: active_cls,
                        else: "text-sr-muted hover:text-sr-ink"
                      )
                    ]}
                  >
                    {mode_label}
                  </button>
                </div>

                <div class="flex items-center gap-2 text-[11px]">
                  <span
                    id="camera-roi-focus-count"
                    class="inline-flex items-center gap-1 rounded border border-emerald-500/40 bg-emerald-500/10 px-1.5 py-0.5 font-mono text-emerald-700 dark:text-emerald-300"
                  >
                    Focus: {MapSet.size(@roi_focus_set)}
                  </span>
                  <span
                    id="camera-roi-ignore-count"
                    class="inline-flex items-center gap-1 rounded border border-rose-500/40 bg-rose-500/10 px-1.5 py-0.5 font-mono text-rose-700 dark:text-rose-300"
                  >
                    Ignore: {MapSet.size(@roi_ignore_set)}
                  </span>
                </div>
              </div>

              <%!-- Interactive 12x8 Scene ROI Grid Overlaid on Latest Camera Frame --%>
              <div class="relative aspect-video w-full overflow-hidden rounded-xl border border-sr-line bg-zinc-950">
                <%= if is_binary(@roi_preview_thumbnail) and @roi_preview_thumbnail != "" do %>
                  <img
                    id="camera-roi-preview-image"
                    src={@roi_preview_thumbnail}
                    alt="Camera scene preview for detection zones"
                    class="h-full w-full object-cover opacity-80"
                  />
                <% else %>
                  <div class="flex h-full w-full items-center justify-center bg-gradient-to-br from-zinc-900 via-zinc-950 to-zinc-900 text-xs text-zinc-500">
                    <span>Camera scene preview ({@roi_grid_cols} &times; {@roi_grid_rows} grid)</span>
                  </div>
                <% end %>

                <div
                  id="camera-roi-grid"
                  role="grid"
                  aria-label="Camera scene detection zone grid"
                  style={"grid-template-columns: repeat(#{@roi_grid_cols}, minmax(0, 1fr)); grid-template-rows: repeat(#{@roi_grid_rows}, minmax(0, 1fr));"}
                  class="absolute inset-0 grid"
                >
                  <button
                    :for={idx <- 0..(@roi_total_cells - 1)}
                    id={"camera-roi-cell-#{idx}"}
                    type="button"
                    phx-click="roi_toggle_cell"
                    phx-value-cell={idx}
                    data-roi-state={roi_cell_state(idx, @roi_focus_set, @roi_ignore_set)}
                    aria-label={"Zone cell #{idx + 1}: #{roi_cell_state(idx, @roi_focus_set, @roi_ignore_set)}"}
                    class={[
                      "border border-white/15 transition-colors hover:border-white/50 focus-visible:z-10 focus-visible:outline-2 focus-visible:outline-white",
                      roi_cell_color_class(roi_cell_state(idx, @roi_focus_set, @roi_ignore_set))
                    ]}
                  ></button>
                </div>
              </div>

              <p class="text-[11px] text-sr-muted">
                Click cells to toggle
                <strong class="text-emerald-600 dark:text-emerald-400">Focus</strong>
                or <strong class="text-rose-600 dark:text-rose-400">Ignore</strong>
                regions.
                Saved under camera source metadata (<code class="font-mono">detection_roi_grid</code>).
              </p>

              <div
                :if={@roi_feedback}
                id="camera-roi-feedback"
                role="status"
                class="rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-xs text-sr-ink"
              >
                {@roi_feedback}
              </div>

              <%!-- Actions Footer --%>
              <div class="flex flex-wrap items-center justify-between gap-2 border-t border-sr-line pt-3">
                <div class="flex items-center gap-1.5">
                  <.ui_button
                    id="camera-roi-clear"
                    type="button"
                    phx-click="roi_clear_grid"
                    variant="outline"
                    size="xs"
                  >
                    Clear
                  </.ui_button>
                  <.ui_button
                    id="camera-roi-reset"
                    type="button"
                    phx-click="roi_reset_grid"
                    disabled={not @roi_dirty?}
                    variant="ghost"
                    size="xs"
                  >
                    Reset
                  </.ui_button>
                </div>

                <.ui_button
                  id="camera-roi-save"
                  type="button"
                  phx-click="roi_save_grid"
                  disabled={not @can_edit_detection_zones}
                  variant="primary"
                  size="xs"
                >
                  Save Zones
                </.ui_button>
              </div>
            <% end %>
          </div>
        </aside>
      </div>

      <.clip_playback_modal
        :if={@clip_modal}
        modal={@clip_modal}
        timezone={@timezone}
        timeline_event_markers={@timeline_event_markers}
        timeline_event_clips={@timeline_event_clips}
        blocks={@blocks}
        active_source_id={@active_source_id}
      />
    </div>
    """
  end

  attr :modal, :map, required: true
  attr :timezone, :string, required: true
  attr :timeline_event_markers, :list, default: []
  attr :timeline_event_clips, :list, default: []
  attr :blocks, :list, default: []
  attr :active_source_id, :string, default: nil

  defp clip_playback_modal(assigns) do
    modal = assigns.modal
    modal_origin_us = Map.get(modal, :playlist_origin_us) || Map.get(modal, :play_from_us)
    modal_to_us = Map.get(modal, :play_to_us)

    modal_scrubber_events =
      build_window_scrubber_events(
        assigns.timeline_event_markers || [],
        assigns.timeline_event_clips || [],
        modal_origin_us,
        modal_to_us
      )

    modal_scrubber_thumbnails =
      build_window_scrubber_thumbnails(
        assigns.blocks || [],
        assigns.timeline_event_markers || [],
        assigns.timeline_event_clips || [],
        assigns.active_source_id,
        modal_origin_us,
        modal_to_us
      )

    assigns =
      assigns
      |> assign(:modal_scrubber_events, modal_scrubber_events)
      |> assign(:modal_scrubber_thumbnails, modal_scrubber_thumbnails)

    ~H"""
    <dialog
      id="camera-clip-playback-modal"
      class="sr-ui-modal sr-ui-modal-open"
      phx-hook="DialogTopLayer"
      data-cancel="close_clip_modal"
      aria-labelledby="camera-clip-modal-title"
    >
      <div class="sr-ui-modal-box sr-ui-modal-box-xl relative border border-sr-line bg-sr-surface p-0 text-sr-ink shadow-sr-raised">
        <%!-- Modal Header --%>
        <div class="flex flex-wrap items-center justify-between gap-2 border-b border-sr-line px-4 py-3">
          <div class="flex min-w-0 flex-wrap items-center gap-2">
            <h1
              id="camera-clip-modal-title"
              class="truncate text-sm font-semibold text-sr-ink sm:text-base"
            >
              {@modal.camera_name || "Camera"}
            </h1>
            <span
              id="camera-clip-modal-class-badge"
              class={[
                "inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[11px] font-medium leading-none text-white",
                clip_badge_bg_class(@modal.category)
              ]}
            >
              <.icon name={clip_category_icon(@modal.category)} class="size-3 shrink-0" />
              <span>{@modal.label}</span>
              <span
                :if={is_number(Map.get(@modal, :confidence))}
                id="camera-clip-modal-confidence"
                class="font-mono text-[10px] opacity-90"
              >
                {format_confidence_pct(@modal.confidence)}
              </span>
            </span>
            <span
              :if={Map.get(@modal, :started_at)}
              class="text-xs text-sr-muted"
            >
              <.user_time
                id="camera-clip-modal-time"
                value={@modal.started_at}
                timezone={@timezone}
              />
            </span>
          </div>

          <div class="flex shrink-0 items-center gap-1.5">
            <.ui_button
              id="camera-clip-modal-open-timeline"
              type="button"
              phx-click="open_clip_in_timeline"
              variant="outline"
              size="xs"
            >
              <.icon name="hero-clock" class="size-3.5" />
              <span>View in Timeline</span>
            </.ui_button>
            <.ui_icon_button
              id="camera-clip-modal-close"
              type="button"
              phx-click="close_clip_modal"
              variant="ghost"
              size="sm"
              aria-label="Close clip player"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </.ui_icon_button>
          </div>
        </div>

        <%!-- Modal Body: 16:9 HLS Clip Player --%>
        <div class="p-4">
          <div
            :if={@modal.playlist_path in [nil, ""]}
            id="camera-clip-modal-empty"
            role="status"
            class="flex aspect-video w-full flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-sr-line bg-sr-canvas p-6 text-center text-sm text-sr-muted"
          >
            <.icon name="hero-video-camera-slash" class="size-6 text-sr-muted" />
            <span>No playable footage in this clip window.</span>
          </div>

          <div
            id="camera-clip-modal-player"
            phx-hook="CameraTimelinePlayer"
            phx-update="ignore"
            data-playlist-path={@modal.playlist_path || ""}
            data-has-adjacent-window="false"
            data-window-start-us={@modal.playlist_origin_us || @modal.play_from_us}
            data-window-end-us={@modal.play_to_us}
            data-seek-offset-seconds={format_seek_offset_attr(@modal.seek_offset_seconds)}
            data-highlight-frame-id={@modal.highlight_frame_id || ""}
            data-overlay-detections={Jason.encode!(@modal.overlay_detections || [])}
            data-window-events={Jason.encode!(@modal_scrubber_events)}
            data-window-thumbnails={Jason.encode!(@modal_scrubber_thumbnails)}
            class={[@modal.playlist_path in [nil, ""] && "hidden"]}
          >
            <div
              data-role="timeline-video-container"
              class="relative overflow-hidden rounded-lg bg-black"
            >
              <video
                data-role="timeline-video"
                controls
                playsinline
                class="aspect-video w-full bg-black"
                aria-label="Clip playback"
              ></video>
              <svg
                data-role="semantic-bbox-overlay"
                aria-hidden="true"
                class="pointer-events-none absolute inset-0 h-full w-full overflow-hidden"
              ></svg>
            </div>

            <%!-- Event-Highlighted Interactive Horizontal Playback Scrubber --%>
            <div
              id="camera-clip-modal-scrubber"
              data-role="playback-scrubber"
              role="slider"
              aria-label="Clip playback scrubber"
              aria-valuemin="0"
              aria-valuenow="0"
              aria-valuemax="0"
              tabindex="0"
              class="mt-2 select-none rounded-lg border border-sr-line bg-zinc-950/90 px-2.5 pt-2 pb-1.5"
            >
              <div
                data-role="scrubber-track"
                class="relative h-8 w-full cursor-pointer rounded-md bg-zinc-800/80"
              >
                <div
                  data-role="scrubber-filmstrip"
                  aria-hidden="true"
                  class="pointer-events-none absolute inset-0 z-[1] flex items-center overflow-hidden rounded-md opacity-45"
                >
                </div>
                <div
                  data-role="scrubber-contrast-scrim"
                  aria-hidden="true"
                  class="pointer-events-none absolute inset-0 z-[2] rounded-md bg-gradient-to-t from-black/65 via-black/15 to-transparent"
                >
                </div>
                <div
                  data-role="scrubber-buffered"
                  style="width: 0%"
                  class="pointer-events-none absolute inset-y-0 left-0 z-[2] rounded-md bg-zinc-700/35"
                >
                </div>
                <div
                  data-role="scrubber-progress"
                  style="width: 0%"
                  class="pointer-events-none absolute inset-y-0 left-0 z-[3] rounded-l-md bg-sky-500/30"
                >
                </div>
                <div
                  data-role="scrubber-events"
                  class="absolute inset-0 z-[4]"
                >
                </div>
                <div
                  data-role="scrubber-hover-line"
                  hidden
                  aria-hidden="true"
                  class="pointer-events-none absolute inset-y-0 z-[8] w-px bg-white/80"
                >
                </div>
                <div
                  data-role="scrubber-hover-tooltip"
                  hidden
                  aria-hidden="true"
                  class="pointer-events-none absolute bottom-full mb-2 z-[12] -translate-x-1/2 rounded-md bg-zinc-900/95 p-1 font-mono text-[10px] font-medium text-white shadow-lg ring-1 ring-white/20"
                >
                </div>
                <div
                  data-role="scrubber-playhead"
                  style="left: 0%"
                  aria-hidden="true"
                  class="pointer-events-none absolute -top-0.5 -bottom-0.5 z-[10] w-0.5 -translate-x-1/2 rounded-full bg-sky-400 shadow-[0_0_8px_rgba(56,189,248,0.95)]"
                >
                  <span class="absolute -top-1 left-1/2 size-2 -translate-x-1/2 rounded-full bg-sky-400 ring-1 ring-white"></span>
                </div>
              </div>

              <div
                data-role="scrubber-ticks"
                class="mt-1 flex items-center justify-between font-mono text-[9px] text-zinc-400"
              >
              </div>
            </div>

            <%!-- Compact Player Transport Bar --%>
            <div class="mt-2 flex flex-wrap items-center justify-between gap-2 rounded-lg border border-sr-line bg-sr-canvas px-2.5 py-1.5 text-xs">
              <div class="flex flex-wrap items-center gap-1.5">
                <button
                  id="camera-clip-modal-back-10"
                  type="button"
                  data-role="transport-back-10"
                  class="rounded border border-sr-line bg-sr-surface px-2 py-0.5 font-mono text-[11px] font-medium text-sr-ink hover:border-sr-brand"
                >
                  -10s
                </button>
                <button
                  id="camera-clip-modal-play-pause"
                  type="button"
                  data-role="transport-play-pause"
                  aria-pressed="false"
                  autofocus
                  class="rounded border border-sr-line bg-sr-ink px-2.5 py-0.5 text-[11px] font-medium text-sr-surface hover:opacity-90"
                >
                  Play
                </button>
                <button
                  id="camera-clip-modal-fwd-10"
                  type="button"
                  data-role="transport-fwd-10"
                  class="rounded border border-sr-line bg-sr-surface px-2 py-0.5 font-mono text-[11px] font-medium text-sr-ink hover:border-sr-brand"
                >
                  +10s
                </button>
                <span
                  data-role="transport-current-time"
                  class="ml-1 font-mono text-[11px] text-sr-muted"
                >
                  00:00
                </span>
                <span data-role="timeline-status" role="status" class="text-[11px] text-sr-muted">
                  Preparing clip...
                </span>
              </div>

              <div class="flex flex-wrap items-center gap-1.5">
                <span
                  id="camera-clip-modal-served-copy-badge"
                  data-role="served-copy-badge"
                  data-served-copy=""
                  class="inline-flex items-center rounded border border-sr-line bg-sr-surface px-1.5 py-0.5 font-mono text-[10px] text-sr-ink"
                >
                  Serving: —
                </span>
                <button
                  id="camera-clip-modal-mute"
                  type="button"
                  data-role="transport-mute"
                  aria-pressed="false"
                  class="rounded border border-sr-line bg-sr-surface px-2 py-0.5 text-[11px] text-sr-ink hover:border-sr-brand"
                >
                  Mute
                </button>
                <button
                  id="camera-clip-modal-fullscreen"
                  type="button"
                  data-role="transport-fullscreen"
                  class="rounded border border-sr-line bg-sr-surface px-2 py-0.5 text-[11px] text-sr-ink hover:border-sr-brand"
                >
                  Fullscreen
                </button>
                <button
                  id="camera-clip-modal-toggle-bbox-overlay"
                  type="button"
                  data-role="toggle-bbox-overlay"
                  aria-pressed="true"
                  class="rounded border border-sr-line bg-sr-surface px-2 py-0.5 text-[11px] font-medium text-sr-ink hover:border-sr-brand"
                >
                  AI boxes: On
                </button>
                <button
                  type="button"
                  data-role="timeline-retry"
                  class="sr-ops-button text-xs"
                  hidden
                >
                  Retry playback
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </dialog>
    """
  end

  defp latest_clip_thumbnail_url(clips) when is_list(clips) do
    Enum.find_value(clips, fn clip ->
      url = Map.get(clip, :thumbnail_url)
      if is_binary(url) and url != "", do: url
    end)
  end

  defp latest_clip_thumbnail_url(_), do: nil

  defp roi_cell_state(idx, focus_set, ignore_set) do
    cond do
      MapSet.member?(focus_set, idx) -> "focus"
      MapSet.member?(ignore_set, idx) -> "ignore"
      true -> "neutral"
    end
  end

  defp roi_cell_color_class("focus"), do: "bg-emerald-500/35 border-emerald-400/70"
  defp roi_cell_color_class("ignore"), do: "bg-rose-500/35 border-rose-400/70"
  defp roi_cell_color_class(_), do: "bg-transparent hover:bg-white/10"

  defp format_confidence_pct(conf) when is_number(conf) do
    pct = if conf <= 1.0, do: round(conf * 100), else: round(conf)
    "#{pct}%"
  end

  defp format_confidence_pct(_), do: ""

  defp camera_subtitle(cam) when is_map(cam) do
    site =
      case Map.get(cam, :metadata) do
        %{} = meta -> meta["site"] || meta[:site]
        _ -> nil
      end

    vendor = Map.get(cam, :vendor)
    status = Map.get(cam, :availability_status)

    [site, vendor, status]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
    |> case do
      "" -> "Camera"
      text -> text
    end
  end

  defp camera_subtitle(_), do: "Camera"

  defp camera_status_dot_class(cam) do
    status = cam |> Map.get(:availability_status) |> to_string() |> String.downcase()

    if status in ["online", "available", "active"] do
      "bg-emerald-500"
    else
      "bg-zinc-400"
    end
  end

  defp camera_status_title(cam) do
    status = cam |> Map.get(:availability_status) |> to_string() |> String.downcase()

    if status in ["online", "available", "active"] do
      "Online"
    else
      "Offline"
    end
  end

  defp build_vertical_time_ticks(from_us, to_us) when is_integer(from_us) and is_integer(to_us) and to_us > from_us do
    span = to_us - from_us

    [
      round(to_us - span * 0.25),
      round(to_us - span * 0.5),
      round(to_us - span * 0.75)
    ]
  end

  defp build_vertical_time_ticks(_, _), do: []

  defp build_play_window_band(play_from_us, play_to_us, cov_from_us, cov_to_us)
       when is_integer(play_from_us) and is_integer(play_to_us) and is_integer(cov_from_us) and is_integer(cov_to_us) do
    clamped_from = max(play_from_us, cov_from_us)
    clamped_to = min(play_to_us, cov_to_us)

    if cov_to_us > cov_from_us and play_to_us > play_from_us and clamped_to > clamped_from do
      span = cov_to_us - cov_from_us
      # Newest (to_us) is at top (0%), oldest (from_us) is at bottom (100%)
      top_pct = Float.round(min(max((cov_to_us - clamped_to) / span * 100.0, 0.0), 98.0), 2)
      bottom_pct = Float.round(min(max((cov_to_us - clamped_from) / span * 100.0, 2.0), 100.0), 2)
      height_pct = Float.round(max(bottom_pct - top_pct, 2.0), 2)
      %{top_pct: top_pct, height_pct: height_pct}
    end
  end

  defp build_play_window_band(_, _, _, _), do: nil

  defp default_empty_coverage do
    %{
      time_basis: "received",
      time_uncertainty: "unmeasured",
      buckets: [],
      blocks: [],
      gaps: [],
      reanchors: []
    }
  end

  defp format_time_basis(basis, uncertainty) do
    basis_str = to_string(basis || "received")

    uncertainty_str =
      cond do
        is_nil(uncertainty) or uncertainty == :unmeasured or uncertainty == "unmeasured" ->
          "unmeasured"

        is_integer(uncertainty) ->
          "#{uncertainty} us"

        true ->
          to_string(uncertainty)
      end

    "Time basis: #{basis_str} (uncertainty: #{uncertainty_str})"
  end

  defp legend_entries do
    [
      {"local_and_archived", "Local + archived"},
      {"archive_only", "Archive only"},
      {"pending_archive", "Pending archive"},
      {"local_only", "Local-only footage"},
      {"local_only_after_archive", "Local only (archive expired/reaped)"},
      {"gap", "Gap"},
      {"not_scheduled", "Not scheduled"},
      {"deleted_by_retention", "Deleted by retention"}
    ]
  end

  defp bucket_color_class("local_and_archived"), do: "bg-emerald-600/90 dark:bg-emerald-500/85"
  defp bucket_color_class("archive_only"), do: "bg-sky-600/90 dark:bg-sky-500/85"
  defp bucket_color_class("pending_archive"), do: "bg-cyan-500/80 dark:bg-cyan-400/80"
  defp bucket_color_class("local_only"), do: "bg-blue-600/90 dark:bg-blue-500/85"
  defp bucket_color_class("local_only_after_archive"), do: "bg-amber-500/85"
  defp bucket_color_class("gap"), do: "bg-rose-500/85"
  defp bucket_color_class("deleted_by_retention"), do: "bg-slate-400/60 dark:bg-slate-700/70"
  defp bucket_color_class(_), do: "bg-slate-300/60 dark:bg-slate-800/70"

  defp copy_state_label("local_and_archived"), do: "Local + archived"
  defp copy_state_label("archive_only"), do: "Archive only"
  defp copy_state_label("pending_archive"), do: "Pending archive"
  defp copy_state_label("local_only"), do: "Local-only footage"
  defp copy_state_label("local_only_after_archive"), do: "Local only (archive expired/reaped)"
  defp copy_state_label("deleted_by_retention"), do: "Deleted by retention"
  defp copy_state_label("gap"), do: "Gap"
  defp copy_state_label("not_scheduled"), do: "Not scheduled"
  defp copy_state_label(other), do: other

  defp copy_state_badge_variant("local_and_archived"), do: "success"
  defp copy_state_badge_variant("archive_only"), do: "info"
  defp copy_state_badge_variant("pending_archive"), do: "primary"
  defp copy_state_badge_variant("local_only"), do: "outline"
  defp copy_state_badge_variant("local_only_after_archive"), do: "warning"
  defp copy_state_badge_variant("deleted_by_retention"), do: "ghost"
  defp copy_state_badge_variant("gap"), do: "error"
  defp copy_state_badge_variant(_), do: "ghost"

  defp bucket_state_name(bucket) do
    state =
      coverage_field(bucket, :state) ||
        coverage_field(bucket, :copy_state) ||
        coverage_field(bucket, :status) ||
        :not_scheduled

    to_string(state)
  end

  defp block_copy_state_name(block) do
    state = coverage_field(block, :copy_state) || coverage_field(block, :state) || :local_only
    to_string(state)
  end

  defp bucket_provisional?(bucket) do
    coverage_field(bucket, :provisional?) == true or coverage_field(bucket, :provisional) == true
  end

  defp block_provisional?(block) do
    coverage_field(block, :provisional?) == true or coverage_field(block, :provisional) == true
  end

  defp block_reanchored?(block) do
    coverage_field(block, :reanchored?) == true or coverage_field(block, :reanchored) == true
  end

  defp bucket_title(bucket) do
    label = copy_state_label(bucket_state_name(bucket))
    reason = coverage_field(bucket, :gap_reason) || coverage_field(bucket, :reason)

    cond do
      bucket_provisional?(bucket) -> "#{label} (provisional)"
      not is_nil(reason) -> "#{label}: #{reason}"
      true -> label
    end
  end

  defp any_provisional?(buckets, blocks) do
    Enum.any?(buckets, &bucket_provisional?/1) or Enum.any?(blocks, &block_provisional?/1)
  end

  defp any_local_only_after_archive?(buckets, blocks) do
    Enum.any?(buckets, &(bucket_state_name(&1) == "local_only_after_archive")) or
      Enum.any?(blocks, &(block_copy_state_name(&1) == "local_only_after_archive"))
  end

  defp archive_only_unplayable?(_blocks, _source, true), do: false

  defp archive_only_unplayable?(blocks, source, false) do
    has_verified_archive? = Enum.any?(blocks, &block_archive_verified?/1)

    case source do
      "archive" -> has_verified_archive?
      "local" -> false
      _auto -> has_verified_archive? and not Enum.any?(blocks, &block_local_present?/1)
    end
  end

  defp block_local_present?(block), do: coverage_field(block, :local_state) in [:present, "present"]
  defp block_archive_verified?(block), do: coverage_field(block, :archive_state) in [:verified, "verified"]

  defp extract_reanchors(coverage, blocks) do
    case coverage_list(coverage, :reanchors) do
      [_ | _] = explicit ->
        explicit

      [] ->
        blocks
        |> Enum.filter(&block_reanchored?/1)
        |> Enum.map(fn block ->
          %{
            at_us: coverage_field(block, :timeline_start_us),
            entry_id: coverage_field(block, :id)
          }
        end)
    end
  end

  defp reanchor_at_us(marker) when is_integer(marker), do: marker

  defp reanchor_at_us(marker) when is_map(marker) do
    coverage_field(marker, :at_us) ||
      coverage_field(marker, :timeline_start_us) ||
      coverage_field(marker, :start_us)
  end

  defp reanchor_at_us(_), do: nil

  defp us_to_datetime(us) when is_integer(us), do: DateTime.from_unix!(us, :microsecond)
  defp us_to_datetime(%DateTime{} = dt), do: dt
  defp us_to_datetime(_), do: nil

  defp coverage_list(map, key) when is_map(map) do
    case coverage_field(map, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp coverage_list(_, _), do: []

  defp coverage_field(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp coverage_field(_, _), do: nil

  defp build_hit_markers(results, from_us, to_us)
       when is_list(results) and is_integer(from_us) and is_integer(to_us) and to_us > from_us do
    span_us = to_us - from_us

    results
    |> Enum.with_index()
    |> Enum.filter(fn {hit, _idx} ->
      ts = coverage_field(hit, :best_timeline_ts_us)
      is_integer(ts) and ts >= from_us and ts <= to_us
    end)
    |> Enum.map(fn {hit, idx} ->
      seek_us = coverage_field(hit, :best_timeline_ts_us)
      start_us = coverage_field(hit, :clip_start_us) || seek_us
      end_us = coverage_field(hit, :clip_end_us) || seek_us
      frame_id = to_string(coverage_field(hit, :visual_frame_id) || "")
      score = coverage_field(hit, :score)
      class_label = coverage_field(hit, :object_class) || coverage_field(hit, :region_kind) || "match"
      # Vertical timeline: top (0%) = to_us (newest), bottom (100%) = from_us (oldest)
      top_pct = Float.round(min(max((to_us - seek_us) / span_us * 100.0, 0.5), 99.5), 2)

      %{
        idx: idx,
        seek_us: seek_us,
        start_us: start_us,
        end_us: end_us,
        frame_id: frame_id,
        top_pct: top_pct,
        title: "Semantic match: #{class_label} (#{format_hit_score(score)})"
      }
    end)
  end

  defp build_hit_markers(_results, _from_us, _to_us), do: []

  defp format_hit_score(score) when is_number(score), do: "#{round(score * 100)}%"
  defp format_hit_score(_), do: "0%"

  defp format_hit_object_class(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: String.capitalize(trimmed)
  end

  defp format_hit_object_class(value) when is_atom(value) and not is_nil(value) do
    value |> Atom.to_string() |> format_hit_object_class()
  end

  defp format_hit_object_class(_), do: nil

  defp hit_category_atom(value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "person" -> :person
      "vehicle" -> :vehicle
      "animal" -> :animal
      "package" -> :package
      "motion" -> :motion
      _ -> :other
    end
  end

  defp hit_thumbnail_url(%{thumbnail_url: url}, _active_source_id) when is_binary(url) and url != "" do
    url
  end

  defp hit_thumbnail_url(%{thumbnail_url: nil}, _active_source_id), do: nil

  defp hit_thumbnail_url(hit, active_source_id) when is_map(hit) do
    source_id = Map.get(hit, :camera_source_id) || active_source_id

    ServiceRadarWebNGWeb.CameraSemanticSearch.build_thumbnail_url(
      source_id,
      Map.get(hit, :visual_frame_id),
      Map.get(hit, :catalog_entry_id),
      Map.get(hit, :has_frame_thumbnail),
      Map.get(hit, :has_block_thumbnail)
    )
  end

  defp hit_thumbnail_url(_, _), do: nil

  defp format_seek_offset_attr(offset) when is_number(offset) and offset > 0 do
    :erlang.float_to_binary(offset * 1.0, [:compact, decimals: 3])
  end

  defp format_seek_offset_attr(_), do: "0.0"

  defp clip_category_filter_specs do
    [
      {"all", "All", "hero-squares-2x2", :all},
      {"person", "Person", "hero-user", :person},
      {"vehicle", "Vehicle", "hero-truck", :vehicle},
      {"animal", "Animal", "hero-sparkles", :animal},
      {"package", "Package", "hero-cube", :package},
      {"motion", "Motion", "hero-bolt", :motion}
    ]
  end

  defp clip_category_icon(:person), do: "hero-user"
  defp clip_category_icon(:vehicle), do: "hero-truck"
  defp clip_category_icon(:animal), do: "hero-sparkles"
  defp clip_category_icon(:package), do: "hero-cube"
  defp clip_category_icon(:motion), do: "hero-bolt"
  defp clip_category_icon(:recording), do: "hero-video-camera"
  defp clip_category_icon(_), do: "hero-film"

  defp clip_badge_bg_class(:person), do: "bg-sky-600/85"
  defp clip_badge_bg_class(:vehicle), do: "bg-emerald-600/85"
  defp clip_badge_bg_class(:animal), do: "bg-amber-600/85"
  defp clip_badge_bg_class(:package), do: "bg-violet-600/85"
  defp clip_badge_bg_class(:motion), do: "bg-zinc-700/85"
  defp clip_badge_bg_class(_), do: "bg-black/75"

  defp event_marker_color_class(:person), do: "bg-sky-400"
  defp event_marker_color_class(:vehicle), do: "bg-cyan-400"
  defp event_marker_color_class(:animal), do: "bg-amber-400"
  defp event_marker_color_class(:package), do: "bg-violet-400"
  defp event_marker_color_class(_), do: "bg-slate-200"

  defp event_thumb_border_class(:person), do: "border-sky-400/80"
  defp event_thumb_border_class(:vehicle), do: "border-cyan-400/80"
  defp event_thumb_border_class(:animal), do: "border-amber-400/80"
  defp event_thumb_border_class(:package), do: "border-violet-400/80"
  defp event_thumb_border_class(_), do: "border-sr-line"

  defp span_zoom_index("7d"), do: 0
  defp span_zoom_index("24h"), do: 1
  defp span_zoom_index("6h"), do: 2
  defp span_zoom_index("1h"), do: 3
  defp span_zoom_index("15m"), do: 4
  defp span_zoom_index(_), do: 3

  @smart_marker_categories [:person, :animal, :vehicle, :package]
  @scrubber_event_categories [:person, :animal, :vehicle, :package, :object, :motion]

  defp object_detection_marker?(clip) when is_map(clip) do
    Map.get(clip, :category) in @smart_marker_categories
  end

  defp object_detection_marker?(_), do: false

  defp scrubber_event_marker?(clip) when is_map(clip) do
    Map.get(clip, :category) in @scrubber_event_categories
  end

  defp scrubber_event_marker?(_), do: false

  defp build_event_markers(clips, from_us, to_us, now_us)
       when is_list(clips) and is_integer(from_us) and is_integer(to_us) and to_us > from_us do
    span_us = to_us - from_us
    max_markers = 24
    min_gap = 2.2

    clips
    |> Enum.filter(fn clip ->
      ts = clip[:peak_ts_us] || clip[:start_us]

      object_detection_marker?(clip) and is_integer(ts) and ts >= from_us and ts <= to_us
    end)
    |> Enum.map(fn clip ->
      ts = clip[:peak_ts_us] || clip[:start_us]
      # Vertical timeline: top (0%) = to_us (newest), bottom (100%) = from_us (oldest)
      top_pct = Float.round(min(max((to_us - ts) / span_us * 100.0, 0.5), 99.5), 2)

      conf_suffix =
        if is_number(clip[:confidence]), do: " (#{format_hit_score(clip[:confidence])})", else: ""

      age_label = format_relative_age(ts, now_us)

      %{
        clip_id: clip.id,
        category: clip.category,
        ts_us: ts,
        top_pct: top_pct,
        title: "#{clip.label}#{conf_suffix} — #{age_label}"
      }
    end)
    |> Enum.sort_by(& &1.top_pct)
    |> Enum.reduce([], fn candidate, kept ->
      cond do
        length(kept) >= max_markers ->
          kept

        Enum.any?(kept, fn existing -> abs(existing.top_pct - candidate.top_pct) < min_gap end) ->
          kept

        true ->
          [candidate | kept]
      end
    end)
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.map(fn {marker, idx} -> Map.put(marker, :idx, idx) end)
  end

  defp build_event_markers(_clips, _from_us, _to_us, _now_us), do: []

  defp build_vertical_thumbnail_markers(markers, page_clips, from_us, to_us, now_us)
       when is_list(markers) and is_integer(from_us) and is_integer(to_us) and to_us > from_us do
    span_us = to_us - from_us
    min_gap_pct = 11.5
    max_thumbs = 8
    clip_thumbs_by_id = index_clip_thumbnail_urls(page_clips)

    markers
    |> Enum.filter(&object_detection_marker?/1)
    |> Enum.reduce([], fn clip, acc ->
      ts = Map.get(clip, :peak_ts_us) || Map.get(clip, :start_us)
      thumb_url = resolve_marker_thumbnail_url(clip, clip_thumbs_by_id)

      if is_integer(ts) and ts >= from_us and ts <= to_us and is_binary(thumb_url) and thumb_url != "" do
        top_pct = Float.round(min(max((to_us - ts) / span_us * 100.0, 6.0), 94.0), 2)

        conf_suffix =
          if is_number(Map.get(clip, :confidence)),
            do: " (#{format_hit_score(Map.get(clip, :confidence))})",
            else: ""

        age_label = format_relative_age(ts, now_us)

        [
          %{
            clip_id: clip.id,
            category: clip.category,
            ts_us: ts,
            top_pct: top_pct,
            thumbnail_url: thumb_url,
            title: "#{clip.label}#{conf_suffix} — #{age_label}"
          }
          | acc
        ]
      else
        acc
      end
    end)
    |> Enum.sort_by(& &1.top_pct)
    |> Enum.reduce([], fn candidate, kept ->
      cond do
        length(kept) >= max_thumbs ->
          kept

        Enum.any?(kept, fn existing -> abs(existing.top_pct - candidate.top_pct) < min_gap_pct end) ->
          kept

        true ->
          [candidate | kept]
      end
    end)
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.map(fn {thumb, idx} -> Map.put(thumb, :idx, idx) end)
  end

  defp build_vertical_thumbnail_markers(_, _, _, _, _), do: []

  defp resolve_marker_thumbnail_url(clip, clip_thumbs_by_id) do
    direct = Map.get(clip, :thumbnail_url)
    from_page = Map.get(clip_thumbs_by_id, to_string(Map.get(clip, :id)))

    cond do
      is_binary(direct) and direct != "" ->
        direct

      is_binary(from_page) and from_page != "" ->
        from_page

      true ->
        nil
    end
  end

  @max_scrubber_thumbnails 24

  defp index_clip_thumbnail_urls(page_clips) do
    page_clips
    |> List.wrap()
    |> Enum.reduce(%{}, fn clip, acc ->
      url = Map.get(clip, :thumbnail_url)
      id = Map.get(clip, :id)

      if is_binary(url) and url != "" and not is_nil(id) do
        Map.put(acc, to_string(id), url)
      else
        acc
      end
    end)
  end

  defp build_window_scrubber_events(markers, page_clips, play_from_us, play_to_us)
       when is_list(markers) and is_integer(play_from_us) and is_integer(play_to_us) and play_to_us > play_from_us do
    clip_thumbs_by_id = index_clip_thumbnail_urls(page_clips)

    markers
    |> Enum.filter(&scrubber_event_marker?/1)
    |> Enum.reduce([], fn clip, acc ->
      clip_start = Map.get(clip, :start_us) || Map.get(clip, :peak_ts_us)
      clip_end = Map.get(clip, :end_us) || clip_start

      if is_integer(clip_start) and is_integer(clip_end) and
           clip_end >= play_from_us and clip_start <= play_to_us do
        start_offset = max((clip_start - play_from_us) / 1_000_000, 0.0)
        end_offset = max((min(clip_end, play_to_us) - play_from_us) / 1_000_000, start_offset)
        thumb_url = resolve_marker_thumbnail_url(clip, clip_thumbs_by_id)

        entry = %{
          category: to_string(clip.category),
          label: clip.label || to_string(clip.category),
          start_offset_seconds: Float.round(start_offset, 3),
          end_offset_seconds: Float.round(end_offset, 3),
          confidence: Map.get(clip, :confidence)
        }

        entry =
          if is_binary(thumb_url) and thumb_url != "" do
            Map.put(entry, :thumbnail_url, thumb_url)
          else
            entry
          end

        [entry | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp build_window_scrubber_events(_, _, _, _), do: []

  defp build_window_scrubber_thumbnails(blocks, markers, page_clips, active_source_id, play_from_us, play_to_us)
       when is_integer(play_from_us) and is_integer(play_to_us) and play_to_us > play_from_us do
    duration_sec = (play_to_us - play_from_us) / 1_000_000
    clip_thumbs_by_id = index_clip_thumbnail_urls(page_clips)

    marker_candidates =
      markers
      |> List.wrap()
      |> Enum.reduce([], fn clip, acc ->
        ts = Map.get(clip, :peak_ts_us) || Map.get(clip, :start_us)
        thumb_url = resolve_marker_thumbnail_url(clip, clip_thumbs_by_id)

        if is_integer(ts) and ts >= play_from_us and ts <= play_to_us and is_binary(thumb_url) and thumb_url != "" do
          offset = min(max((ts - play_from_us) / 1_000_000, 0.0), duration_sec)
          smart? = object_detection_marker?(clip)

          [
            %{
              offset_seconds: offset,
              thumbnail_url: thumb_url,
              label: if(smart?, do: clip.label || to_string(clip.category)),
              priority: if(smart?, do: 2, else: 1)
            }
            | acc
          ]
        else
          acc
        end
      end)

    block_candidates =
      if is_binary(active_source_id) and active_source_id != "" do
        blocks
        |> List.wrap()
        |> Enum.reduce([], fn block, acc ->
          has_thumb = coverage_field(block, :has_thumbnail) == true
          block_id = coverage_field(block, :id)
          b_start = coverage_field(block, :timeline_start_us)
          b_end = coverage_field(block, :timeline_end_us) || b_start

          if has_thumb and is_binary(block_id) and block_id != "" and
               is_integer(b_start) and is_integer(b_end) and
               b_end >= play_from_us and b_start <= play_to_us do
            clamped_start = max(b_start, play_from_us)
            clamped_end = min(b_end, play_to_us)
            mid_us = div(clamped_start + clamped_end, 2)
            offset = min(max((mid_us - play_from_us) / 1_000_000, 0.0), duration_sec)

            [
              %{
                offset_seconds: offset,
                thumbnail_url: Thumbnail.block_url(active_source_id, block_id),
                label: nil,
                priority: 0
              }
              | acc
            ]
          else
            acc
          end
        end)
      else
        []
      end

    (marker_candidates ++ block_candidates)
    |> sample_scrubber_thumbnails(duration_sec, @max_scrubber_thumbnails)
    |> Enum.map(fn item ->
      %{
        offset_seconds: Float.round(item.offset_seconds, 3),
        thumbnail_url: item.thumbnail_url,
        label: item.label
      }
    end)
  end

  defp build_window_scrubber_thumbnails(_, _, _, _, _, _), do: []

  defp sample_scrubber_thumbnails([], _duration_sec, _limit), do: []

  defp sample_scrubber_thumbnails(candidates, duration_sec, limit) when length(candidates) <= limit do
    candidates
    |> Enum.sort_by(fn item -> {item.offset_seconds, -item.priority} end)
    |> dedupe_adjacent_thumbnails(duration_sec)
  end

  defp sample_scrubber_thumbnails(candidates, duration_sec, limit) do
    bucket_width = max(duration_sec / limit, 0.001)

    candidates
    |> Enum.group_by(fn item ->
      min(max(trunc(item.offset_seconds / bucket_width), 0), limit - 1)
    end)
    |> Enum.map(fn {bucket_idx, items} ->
      bucket_center = (bucket_idx + 0.5) * bucket_width

      Enum.min_by(items, fn item ->
        {-item.priority, abs(item.offset_seconds - bucket_center)}
      end)
    end)
    |> Enum.sort_by(& &1.offset_seconds)
  end

  defp dedupe_adjacent_thumbnails(items, _duration_sec) do
    items
    |> Enum.reduce([], fn item, acc ->
      case acc do
        [prev | _]
        when prev.thumbnail_url == item.thumbnail_url and abs(item.offset_seconds - prev.offset_seconds) < 1.0 ->
          acc

        _ ->
          [item | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp clip_selected?(clip, selected_clip_id, play_from_us, play_to_us) do
    cond do
      is_binary(selected_clip_id) and selected_clip_id != "" ->
        to_string(clip.id) == selected_clip_id

      is_integer(play_from_us) and is_integer(play_to_us) and is_integer(clip[:start_us]) and
          is_integer(clip[:end_us]) ->
        play_from_us <= clip.start_us and play_to_us >= clip.end_us and
          play_to_us - play_from_us <= clip.end_us - clip.start_us + 20_000_000

      true ->
        false
    end
  end

  defp format_relative_age(start_us, now_us) when is_integer(start_us) and is_integer(now_us) do
    diff_sec = max(div(now_us - start_us, 1_000_000), 0)

    cond do
      diff_sec < 60 -> "Just now"
      diff_sec < 3_600 -> "#{div(diff_sec, 60)}m ago"
      diff_sec < 86_400 -> "#{div(diff_sec, 3_600)}h ago"
      true -> "#{div(diff_sec, 86_400)}d ago"
    end
  end

  defp format_relative_age(_, _), do: "Recent"

  defp format_clip_duration(seconds) when is_integer(seconds) and seconds >= 3_600 do
    hours = div(seconds, 3_600)
    mins = div(rem(seconds, 3_600), 60)
    "#{hours}h #{mins}m"
  end

  defp format_clip_duration(seconds) when is_integer(seconds) and seconds >= 60 do
    mins = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp format_clip_duration(seconds) when is_integer(seconds) and seconds > 0, do: "#{seconds}s"
  defp format_clip_duration(_), do: "1s"

  defp clip_storage_badge(%{archive_state: :verified, local_state: :present}), do: "local+archive"
  defp clip_storage_badge(%{archive_state: :verified}), do: "archive"
  defp clip_storage_badge(%{local_state: :present}), do: "local"
  defp clip_storage_badge(_), do: "recorded"

  defp sort_gaps_newest_first(gaps) when is_list(gaps) do
    Enum.sort_by(
      gaps,
      fn gap ->
        start_us = coverage_field(gap, :start_us) || 0
        end_us = coverage_field(gap, :end_us) || start_us
        id = to_string(coverage_field(gap, :id) || "")
        {start_us, end_us, id}
      end,
      :desc
    )
  end

  defp summarize_gaps_by_reason(gaps) when is_list(gaps) do
    gaps
    |> Enum.reduce(%{}, fn gap, acc ->
      reason = to_string(coverage_field(gap, :reason) || "unknown")
      detail = coverage_field(gap, :detail_class)
      key = {reason, detail}
      Map.update(acc, key, 1, &(&1 + 1))
    end)
    |> Enum.map(fn {{reason, detail}, count} ->
      label =
        if is_binary(detail) and detail != "" do
          "#{reason} (#{detail})"
        else
          reason
        end

      %{reason: reason, detail_class: detail, label: label, count: count}
    end)
    |> Enum.sort_by(fn entry -> {-entry.count, entry.label} end)
  end

  defp camera_switcher_empty_message(search, switcher_cameras, total_count) do
    trimmed_search = String.trim(to_string(search || ""))

    cond do
      trimmed_search != "" and switcher_cameras == [] ->
        "No matching cameras."

      trimmed_search != "" ->
        "No other matching cameras."

      (total_count || 0) <= 1 ->
        "No other cameras configured."

      true ->
        "No matching cameras."
    end
  end
end
