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

  def recordings(assigns) do
    ~H"""
    <div id="camera-recordings" class="mx-auto max-w-7xl space-y-6 p-4 sm:p-6">
      <header class="flex flex-wrap items-start justify-between gap-4">
        <div>
          <p class="text-sm text-sr-muted">Camera archive</p>
          <h1 class="mt-1 text-2xl font-semibold text-sr-ink">
            {if @source, do: @source.display_name || "Camera recordings", else: "Camera recordings"}
          </h1>
          <p class="mt-2 text-sm text-sr-muted">
            Browse published recordings. Publication time is not capture time.
          </p>
        </div>
        <.link :if={@source} navigate={~p"/devices/#{@source.device_uid}"} class="sr-ops-button">
          Back to device
        </.link>
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

      <div :if={!@loading} class="grid gap-6 lg:grid-cols-[20rem_minmax(0,1fr)]">
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
                  Fragments {@selected.window.first + 1}-{@selected.window.first +
                    @selected.window.count} &middot; {Float.round(
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
                >Previous window</.ui_button>
                <.ui_button
                  id="next-recording-window"
                  phx-click="recording_window"
                  phx-value-direction="next"
                  disabled={@selected.window.index + 1 == @selected.window.total}
                  variant="outline"
                  size="sm"
                >Next window</.ui_button>
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
                <button type="button" data-role="archive-retry" class="sr-ops-button" hidden>Retry playback</button>
              </div>
            </div>
            <p id="camera-recording-time-note" class="text-xs text-sr-muted">
              Player time follows this recording's media clock. Each window ends independently.
              No capture-time timeline is available.
            </p>
          </div>
        </section>
      </div>
    </div>
    """
  end
end
