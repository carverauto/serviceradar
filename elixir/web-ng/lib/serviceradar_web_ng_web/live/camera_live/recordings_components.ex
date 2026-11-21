defmodule ServiceRadarWebNGWeb.CameraLive.RecordingsComponents do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

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
  attr :stream_profiles, :list, default: []
  attr :timeline_profile_id, :string, default: ""
  attr :timeline_span, :string, default: "1h"
  attr :timeline_source, :string, default: "auto"
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
  attr :hold_form, :any, default: nil

  def recordings(assigns) do
    ~H"""
    <div id="camera-recordings" class="mx-auto max-w-7xl space-y-6 p-4 sm:p-6">
      <header class="flex flex-wrap items-start justify-between gap-4">
        <div class="min-w-0">
          <p class="text-sm text-sr-muted">
            {if(@mode == :timeline, do: "Camera timeline", else: "Camera archive")}
          </p>
          <h1 class="mt-1 text-2xl font-semibold text-sr-ink">
            {if(@source, do: @source.display_name || "Camera recordings", else: "Camera recordings")}
          </h1>
          <p :if={@mode == :published} class="mt-2 text-sm text-sr-muted">
            Browse published recordings. Publication time is not capture time.
          </p>
          <p
            :if={@mode == :published}
            id="camera-recordings-source-label"
            class="mt-1 text-xs text-sr-muted"
          >
            Source: <code class="font-mono">ArchiveUploads</code>
            published catalog, distinct from NVR archive receipts tracked in Recording &amp; Storage settings.
          </p>
          <p :if={@mode == :timeline} class="mt-2 text-sm text-sr-muted">
            Unified recorded playback across local NVR storage and verified object archive copies.
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <div class="inline-flex flex-wrap items-center gap-1 rounded-lg border border-sr-line bg-sr-surface p-1">
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
            class="sr-ops-button"
          >
            Recording &amp; storage
          </.link>
          <.link :if={@source} navigate={~p"/devices/#{@source.device_uid}"} class="sr-ops-button">
            Back to device
          </.link>
        </div>
      </header>

      <div
        :if={@error}
        id="camera-recordings-error"
        role="alert"
        class="rounded-xl border border-sr-line p-4"
      >
        {@error}
      </div>
      <div :if={@loading} id="camera-recordings-loading" role="status" class="text-sr-muted">
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
        stream_profiles={@stream_profiles}
        timeline_profile_id={@timeline_profile_id}
        timeline_span={@timeline_span}
        timeline_source={@timeline_source}
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
  attr :stream_profiles, :list, required: true
  attr :timeline_profile_id, :string, required: true
  attr :timeline_span, :string, required: true
  attr :timeline_source, :string, required: true
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
  attr :hold_form, :any, default: nil

  defp timeline_view(assigns) do
    coverage = assigns.timeline_coverage || default_empty_coverage()
    buckets = coverage_list(coverage, :buckets)
    blocks = coverage_list(coverage, :blocks)
    gaps = coverage_list(coverage, :gaps)
    reanchors = extract_reanchors(coverage, blocks)
    time_basis = coverage_field(coverage, :time_basis) || "received"
    time_uncertainty = coverage_field(coverage, :time_uncertainty) || "unmeasured"
    cov_from_us = coverage_field(coverage, :from_us)
    cov_to_us = coverage_field(coverage, :to_us)
    hit_markers = build_hit_markers(assigns.timeline_search_results, cov_from_us, cov_to_us)

    assigns =
      assigns
      |> assign(:coverage, coverage)
      |> assign(:buckets, buckets)
      |> assign(:blocks, blocks)
      |> assign(:gaps, gaps)
      |> assign(:reanchors, reanchors)
      |> assign(:hit_markers, hit_markers)
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
    <div id="camera-timeline-view" class="space-y-6">
      <%!-- Time Basis & Clock Integrity Banner --%>
      <section
        id="camera-timeline-basis-banner"
        aria-label="Timeline time basis"
        class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-sr-line bg-sr-surface px-4 py-3"
      >
        <div class="flex flex-wrap items-center gap-2">
          <.ui_badge id="camera-timeline-time-basis" variant="info" size="sm">
            {@time_basis_label}
          </.ui_badge>
          <.ui_badge
            :if={@has_provisional?}
            id="camera-timeline-provisional-badge"
            data-role="provisional-copy-badge"
            variant="warning"
            size="sm"
          >
            provisional
          </.ui_badge>
          <.ui_badge
            :if={@reanchors != []}
            id="camera-timeline-reanchor-badge"
            variant="outline"
            size="sm"
          >
            Clock re-anchored ({length(@reanchors)})
          </.ui_badge>
          <%!-- A continuous policy says recording is wanted; only a live recorder records. --%>
          <.ui_badge
            :if={@scheduled_continuous?}
            id="camera-timeline-recorder-state"
            variant={if(@recorder_running?, do: "success", else: "warning")}
            size="sm"
          >
            {if @recorder_running?, do: "Recording", else: "Continuous policy set: not recording yet"}
          </.ui_badge>
        </div>
        <p class="text-xs text-sr-muted">
          Wall-clock labels reflect <code class="font-mono">{@time_basis_short}</code>
          timestamps, never unverified camera capture clocks.
        </p>
      </section>

      <%!-- Controls Toolbar --%>
      <section
        id="camera-timeline-controls"
        aria-label="Timeline controls"
        class="flex flex-wrap items-center justify-between gap-4 rounded-xl border border-sr-line bg-sr-surface p-4"
      >
        <div class="flex flex-wrap items-center gap-3">
          <form id="camera-timeline-profile-form" phx-change="select_timeline_profile">
            <label for="camera-timeline-profile-select" class="sr-only">Stream profile</label>
            <select
              id="camera-timeline-profile-select"
              name="stream_profile_id"
              class="h-9 rounded-lg border border-sr-line bg-sr-control px-3 text-sm text-sr-ink"
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
            id="camera-timeline-span-selector"
            role="group"
            aria-label="Coverage span"
            class="inline-flex items-center gap-1 rounded-lg border border-sr-line p-1"
          >
            <button
              :for={span <- ["1h", "6h", "24h", "7d"]}
              id={"camera-timeline-span-#{span}"}
              type="button"
              phx-click="select_timeline_span"
              phx-value-span={span}
              aria-pressed={@timeline_span == span}
              class={[
                "rounded-md px-2.5 py-1 text-xs font-medium transition-colors",
                if(@timeline_span == span,
                  do: "bg-sr-ink text-sr-surface",
                  else: "text-sr-muted hover:text-sr-ink"
                )
              ]}
            >
              {span}
            </button>
          </div>

          <div id="camera-timeline-window-nav" class="inline-flex flex-wrap items-center gap-1.5">
            <.ui_button
              id="camera-timeline-prev-window"
              type="button"
              phx-click="navigate_timeline_window"
              phx-value-direction="previous"
              variant="outline"
              size="xs"
            >
              Previous
            </.ui_button>
            <.ui_button
              id="camera-timeline-next-window"
              type="button"
              phx-click="navigate_timeline_window"
              phx-value-direction="next"
              variant="outline"
              size="xs"
            >
              Next
            </.ui_button>
            <.ui_button
              id="camera-timeline-latest-window"
              type="button"
              phx-click="navigate_timeline_window"
              phx-value-direction="latest"
              variant="outline"
              size="xs"
            >
              Latest
            </.ui_button>
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

          <form
            id="camera-timeline-jump-form"
            phx-submit="jump_timeline_to"
            class="inline-flex flex-wrap items-center gap-1.5"
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
              class="h-8 rounded-lg border border-sr-line bg-sr-control px-2 text-xs text-sr-ink"
            />
            <.ui_button
              id="camera-timeline-jump-submit"
              type="submit"
              variant="outline"
              size="xs"
            >
              Go
            </.ui_button>
          </form>
        </div>

        <div
          id="camera-timeline-source-selector"
          role="group"
          aria-label="Playback source"
          class="inline-flex flex-wrap items-center gap-1 rounded-lg border border-sr-line p-1"
        >
          <button
            :for={
              {val, label} <- [
                {"auto", "Auto"},
                {"local", "Force local"},
                {"archive", "Force archive"}
              ]
            }
            id={"camera-timeline-source-#{val}"}
            type="button"
            phx-click="select_timeline_source"
            phx-value-source={val}
            aria-pressed={@timeline_source == val}
            class={[
              "rounded-md px-2.5 py-1 text-xs font-medium transition-colors",
              if(@timeline_source == val,
                do: "bg-sr-ink text-sr-surface",
                else: "text-sr-muted hover:text-sr-ink"
              )
            ]}
          >
            {label}
          </button>
        </div>
      </section>

      <%!-- Inline Timeline Semantic Search --%>
      <section
        id="camera-timeline-search-section"
        aria-label="Timeline semantic clip search"
        class="space-y-3 rounded-xl border border-sr-line bg-sr-surface p-4"
      >
        <form
          id="camera-timeline-search-form"
          phx-submit="timeline_semantic_search"
          class="flex flex-wrap items-center gap-2"
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
            placeholder="Search clips in timeline (e.g. person in red dress, white van near gate)"
            class="input input-sm input-bordered min-w-60 flex-1 bg-sr-control text-sr-ink"
          />

          <label for="camera-timeline-search-object-class" class="sr-only">Object class</label>
          <select
            id="camera-timeline-search-object-class"
            name="search[object_class]"
            class="select select-sm select-bordered bg-sr-control text-sr-ink"
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

          <button id="camera-timeline-search-submit" type="submit" class="btn btn-primary btn-sm">
            <.icon name="hero-magnifying-glass" class="size-4" /> Search timeline
          </button>
          <button
            :if={@timeline_search_executed? or @timeline_search_query != ""}
            id="camera-timeline-search-clear"
            type="button"
            phx-click="clear_timeline_semantic_search"
            class="btn btn-ghost btn-sm"
          >
            Clear
          </button>
        </form>

        <div
          :if={@timeline_embedder_unavailable?}
          id="camera-timeline-search-unavailable"
          role="alert"
          class="alert alert-warning sm:alert-horizontal text-xs"
        >
          <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
          <div>
            <p class="font-semibold">Visual search workers unavailable</p>
            <p>
              No compatible media worker responded within the interactive deadline. Timeline video playback remains unaffected.
            </p>
          </div>
        </div>

        <div
          :if={@timeline_search_error}
          id="camera-timeline-search-error"
          role="alert"
          class="alert alert-error sm:alert-horizontal text-xs"
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
          class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3"
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
                "w-full rounded-lg border p-2.5 text-left text-xs transition-colors hover:bg-sr-canvas",
                if(
                  not is_nil(@timeline_highlight_frame_id) and
                    @timeline_highlight_frame_id == hit.visual_frame_id,
                  do: "border-sr-brand bg-sr-brand/5",
                  else: "border-sr-line"
                )
              ]}
            >
              <div class="flex flex-wrap items-center justify-between gap-1.5">
                <div class="flex flex-wrap items-center gap-1">
                  <span class="badge badge-primary badge-xs font-mono">
                    {format_hit_score(hit.score)}
                  </span>
                  <span :if={hit.object_class} class="badge badge-outline badge-xs">
                    {hit.object_class}
                  </span>
                  <span
                    :for={color <- Enum.take(hit.dominant_colors || [], 2)}
                    class="badge badge-ghost badge-xs"
                  >
                    {color}
                  </span>
                </div>
                <span class="font-mono text-[11px] text-sr-muted">{hit.time_basis}</span>
              </div>
              <div class="mt-1.5 text-sr-ink">
                <.user_time
                  id={"timeline-hit-time-#{idx}"}
                  value={us_to_datetime(hit.best_timeline_ts_us)}
                  timezone={@timezone}
                />
              </div>
            </button>
          </li>
        </ul>
      </section>

      <%!-- Coverage Bar & Legend --%>
      <section
        id="camera-timeline-coverage-section"
        aria-label="Timeline coverage"
        class="space-y-4 rounded-xl border border-sr-line bg-sr-surface p-4"
      >
        <div class="flex flex-wrap items-center justify-between gap-2 text-xs text-sr-muted">
          <span :if={coverage_field(@coverage, :from_us)}>
            {@time_basis_short}
            <.user_time
              id="camera-timeline-span-start"
              value={us_to_datetime(coverage_field(@coverage, :from_us))}
              timezone={@timezone}
            />
          </span>
          <span class="font-medium text-sr-ink">Coverage ({@timeline_span})</span>
          <span :if={coverage_field(@coverage, :to_us)}>
            {@time_basis_short}
            <.user_time
              id="camera-timeline-span-end"
              value={us_to_datetime(coverage_field(@coverage, :to_us))}
              timezone={@timezone}
            />
          </span>
        </div>

        <div
          id="camera-timeline-coverage-bar"
          class="relative flex h-8 w-full overflow-hidden rounded-lg border border-sr-line bg-sr-canvas p-0.5"
        >
          <%= if @buckets == [] do %>
            <div
              data-bucket-state="not_scheduled"
              class="flex h-full w-full items-center justify-center text-xs text-sr-muted"
            >
              Not scheduled
            </div>
          <% else %>
            <button
              :for={{bucket, idx} <- Enum.with_index(@buckets)}
              id={"camera-timeline-bucket-#{idx}"}
              type="button"
              phx-click="select_timeline_bucket"
              phx-value-start_us={bucket_start_us(bucket)}
              phx-value-end_us={bucket_end_us(bucket)}
              data-bucket-state={bucket_state_name(bucket)}
              data-provisional={to_string(bucket_provisional?(bucket))}
              title={bucket_title(bucket)}
              class={[
                "h-full flex-1 border-r border-sr-surface/30 transition-opacity last:border-r-0 hover:opacity-80",
                bucket_color_class(bucket_state_name(bucket))
              ]}
            >
              <span class="sr-only">{bucket_title(bucket)}</span>
            </button>
          <% end %>

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
            style={"left: #{marker.left_pct}%"}
            class="absolute inset-y-0 z-10 w-1.5 -translate-x-1/2 rounded-full bg-amber-400 ring-1 ring-black/60 hover:scale-x-150"
          >
            <span class="sr-only">{marker.title}</span>
          </button>
        </div>

        <div
          id="camera-timeline-legend"
          class="flex flex-wrap items-center gap-x-4 gap-y-2 text-xs text-sr-muted"
        >
          <span
            :for={{state, label} <- legend_entries()}
            data-legend-state={state}
            class="inline-flex items-center gap-1.5"
          >
            <span class={["inline-block size-2.5 rounded-sm", bucket_color_class(state)]}></span>
            <span>{label}</span>
          </span>
        </div>

        <div
          :if={@has_local_only_after_archive?}
          id="camera-timeline-local-only-after-archive-note"
          class="rounded-lg border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-xs text-sr-ink"
        >
          <strong>Local only (archive expired/reaped):</strong>
          footage exists only on local NVR storage after object archive expiry or capacity reaping.
          These local bytes remain evictable under local retention and are never counted as unarchived.
        </div>

        <%!-- Clock Re-anchor Markers --%>
        <div
          :if={@reanchors != []}
          id="camera-timeline-reanchors"
          class="space-y-1 rounded-lg border border-sr-line bg-sr-canvas p-3 text-xs"
        >
          <p class="font-semibold text-sr-ink">Clock re-anchor markers</p>
          <ul class="space-y-1 text-sr-muted">
            <li
              :for={{marker, idx} <- Enum.with_index(@reanchors)}
              id={"camera-timeline-reanchor-#{idx}"}
              class="flex flex-wrap items-center gap-2"
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
              <span class="text-sr-muted">
                Receipt drift re-anchored the clock without a media gap.
              </span>
            </li>
          </ul>
        </div>

        <%!-- Recorded Gaps --%>
        <div
          :if={@gaps != []}
          id="camera-timeline-gaps"
          class="space-y-1.5 rounded-lg border border-rose-500/30 bg-rose-500/5 p-3 text-xs"
        >
          <p class="font-semibold text-sr-ink">Recorded gaps in window ({length(@gaps)})</p>
          <ul class="space-y-1">
            <li
              :for={{gap, idx} <- Enum.with_index(@gaps)}
              id={"camera-timeline-gap-#{coverage_field(gap, :id) || idx}"}
              data-gap-reason={to_string(coverage_field(gap, :reason))}
              class="flex flex-wrap items-center justify-between gap-2 text-sr-muted"
            >
              <div class="flex flex-wrap items-center gap-2">
                <.ui_badge variant="error" size="xs">
                  {to_string(coverage_field(gap, :reason))}
                </.ui_badge>
                <span :if={coverage_field(gap, :detail_class)} class="font-mono">
                  ({coverage_field(gap, :detail_class)})
                </span>
              </div>
              <span>
                {@time_basis_short}
                <.user_time
                  id={"camera-timeline-gap-start-#{idx}"}
                  value={us_to_datetime(coverage_field(gap, :start_us))}
                  timezone={@timezone}
                />
                <%= if coverage_field(gap, :end_us) do %>
                  &rarr;
                  <.user_time
                    id={"camera-timeline-gap-end-#{idx}"}
                    value={us_to_datetime(coverage_field(gap, :end_us))}
                    timezone={@timezone}
                  />
                <% else %>
                  (open)
                <% end %>
              </span>
            </li>
          </ul>
        </div>
      </section>

      <%!-- Main Grid: Player + Blocks & Holds --%>
      <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_24rem]">
        <section
          id="camera-timeline-player-section"
          aria-label="Timeline player"
          class="min-w-0 space-y-4 rounded-xl border border-sr-line bg-sr-surface p-4"
        >
          <div class="flex flex-wrap items-center justify-between gap-2">
            <div>
              <h2 class="font-semibold text-sr-ink">Playback window</h2>
              <p :if={@timeline_play_from_us && @timeline_play_to_us} class="text-xs text-sr-muted">
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
            </div>
            <.ui_badge variant="ghost" size="xs">
              Source mode: {@timeline_source}
            </.ui_badge>
          </div>

          <div id="camera-timeline-player-card">
            <div
              :if={@timeline_playlist_path in [nil, ""]}
              id="camera-timeline-empty-state"
              role="status"
              class="rounded-xl border border-dashed border-sr-line bg-sr-canvas p-6 text-sm space-y-2"
            >
              <%= cond do %>
                <% @archive_only_unplayable? -> %>
                  <div class="flex items-center gap-2 font-semibold text-sr-ink">
                    <.icon name="hero-archive-box" class="size-4 text-sr-muted" />
                    <span>Archive playback not available yet</span>
                  </div>
                  <p id="camera-timeline-archive-only" class="text-xs text-sr-muted">
                    Archive copies cannot be played yet, so footage stored only in the archive
                    shows on the timeline but does not play. Local copies play as they are recorded.
                  </p>
                <% @scheduled_continuous? -> %>
                  <div class="flex items-center gap-2 font-semibold text-sr-ink">
                    <.icon name="hero-clock" class="size-4 text-sr-muted" />
                    <span>No playable footage in selected window</span>
                  </div>
                  <p
                    :if={not @recorder_running?}
                    id="camera-timeline-not-recording"
                    class="text-xs text-sr-muted"
                  >
                    A <code class="font-mono">continuous</code>
                    recording policy is configured for this camera, but no recorder is running for it,
                    so no new footage is being captured. Footage appears here once recording runs.
                  </p>
                  <p :if={@recorder_running?} class="text-xs text-sr-muted">
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
                    <.icon name="hero-video-camera-slash" class="size-4 text-sr-muted" />
                    <span>No continuous recording policy active</span>
                  </div>
                  <p class="text-xs text-sr-muted">
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
              class={[@timeline_playlist_path in [nil, ""] && "hidden"]}
            >
              <div class="relative overflow-hidden rounded-lg bg-black">
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
              <div class="mt-3 flex flex-wrap items-center justify-between gap-3">
                <div class="flex flex-wrap items-center gap-2">
                  <p data-role="timeline-status" role="status" class="text-sm text-sr-muted">
                    Preparing timeline...
                  </p>
                  <span
                    id="camera-timeline-served-copy-badge"
                    data-role="served-copy-badge"
                    data-served-copy=""
                    class="inline-flex items-center rounded-md border border-sr-line px-2 py-0.5 font-mono text-xs text-sr-ink"
                  >
                    Serving: —
                  </span>
                </div>
                <div class="flex flex-wrap items-center gap-2">
                  <button
                    id="camera-timeline-toggle-bbox-overlay"
                    type="button"
                    data-role="toggle-bbox-overlay"
                    aria-pressed="true"
                    class="btn btn-outline btn-xs"
                  >
                    Detection overlay
                  </button>
                  <button type="button" data-role="timeline-retry" class="sr-ops-button" hidden>
                    Retry playback
                  </button>
                </div>
              </div>
            </div>
          </div>

          <%!-- Catalog Blocks in Window --%>
          <div :if={@blocks != []} id="camera-timeline-blocks" class="space-y-2 pt-2">
            <h3 class="text-xs font-semibold uppercase tracking-wide text-sr-muted">
              Catalog blocks in span ({length(@blocks)})
            </h3>
            <ul class="max-h-56 space-y-1.5 overflow-y-auto pr-1 text-xs">
              <li
                :for={block <- @blocks}
                id={"camera-timeline-block-#{coverage_field(block, :id)}"}
                data-copy-state={block_copy_state_name(block)}
                class="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-sr-line px-3 py-2"
              >
                <div class="flex flex-wrap items-center gap-1.5">
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
        </section>

        <%!-- Holds Placement & Release --%>
        <section
          id="camera-timeline-holds-section"
          aria-label="Recording holds"
          class="space-y-4 rounded-xl border border-sr-line bg-sr-surface p-4"
        >
          <div class="flex items-center justify-between gap-2">
            <h2 class="font-semibold text-sr-ink">Recording holds</h2>
            <.ui_badge variant="ghost" size="xs">{length(@timeline_holds)}</.ui_badge>
          </div>

          <%= if @can_manage_holds && @hold_form do %>
            <.form
              for={@hold_form}
              id="place-timeline-hold-form"
              phx-change="change_hold_form"
              phx-submit="place_timeline_hold"
              class="space-y-3 rounded-lg border border-sr-line bg-sr-canvas p-3"
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
            class="text-sm text-sr-muted"
          >
            No holds recorded for this camera.
          </p>

          <ul :if={@timeline_holds != []} id="camera-timeline-holds-list" class="space-y-3">
            <li
              :for={hold <- @timeline_holds}
              id={"timeline-hold-#{hold.id}"}
              data-hold-state={to_string(hold.state)}
              class="space-y-2 rounded-lg border border-sr-line p-3 text-xs"
            >
              <div class="flex flex-wrap items-center justify-between gap-2">
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
      </div>
    </div>
    """
  end

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

  defp bucket_color_class("local_and_archived"), do: "bg-emerald-500"
  defp bucket_color_class("archive_only"), do: "bg-sky-500"
  defp bucket_color_class("pending_archive"), do: "bg-cyan-400"
  defp bucket_color_class("local_only"), do: "bg-indigo-500"
  defp bucket_color_class("local_only_after_archive"), do: "bg-amber-500"
  defp bucket_color_class("gap"), do: "bg-rose-500"
  defp bucket_color_class("deleted_by_retention"), do: "bg-zinc-400 dark:bg-zinc-600"
  defp bucket_color_class(_), do: "bg-zinc-200 dark:bg-zinc-800"

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

  defp bucket_start_us(bucket) do
    coverage_field(bucket, :start_us) || coverage_field(bucket, :from_us)
  end

  defp bucket_end_us(bucket) do
    coverage_field(bucket, :end_us) || coverage_field(bucket, :to_us)
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
      left_pct = Float.round(min(max((seek_us - from_us) / span_us * 100.0, 0.5), 99.5), 2)

      %{
        idx: idx,
        seek_us: seek_us,
        start_us: start_us,
        end_us: end_us,
        frame_id: frame_id,
        left_pct: left_pct,
        title: "Semantic match: #{class_label} (#{format_hit_score(score)})"
      }
    end)
  end

  defp build_hit_markers(_results, _from_us, _to_us), do: []

  defp format_hit_score(score) when is_number(score), do: "#{round(score * 100)}%"
  defp format_hit_score(_), do: "0%"

  defp format_seek_offset_attr(offset) when is_number(offset) and offset > 0 do
    :erlang.float_to_binary(offset * 1.0, [:compact, decimals: 3])
  end

  defp format_seek_offset_attr(_), do: "0.0"
end
