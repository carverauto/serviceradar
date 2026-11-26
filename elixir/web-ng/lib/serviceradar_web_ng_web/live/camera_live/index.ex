defmodule ServiceRadarWebNGWeb.CameraLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.CameraMultiview
  alias ServiceRadarWebNGWeb.CameraRelayComponents
  alias ServiceRadarWebNGWeb.CameraSemanticSearch

  require Logger

  @layout_options [2, 4, 8, 16, 32]
  @default_layout_count 4
  @quality_options [
    {"auto", "Auto"},
    {"low", "Low"},
    {"medium", "Medium"},
    {"high", "High"}
  ]
  @default_stream_quality "auto"

  @range_durations_us %{
    "1h" => 3_600_000_000,
    "6h" => 6 * 3_600_000_000,
    "24h" => 24 * 3_600_000_000,
    "7d" => 7 * 24 * 3_600_000_000,
    "30d" => 30 * 24 * 3_600_000_000
  }

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:current_scope]

    socket =
      socket
      |> assign(:page_title, "Vantage")
      |> assign(:current_path, "/cameras")
      |> assign(:srql, %{enabled: false, page_path: "/cameras"})
      |> assign(:layout_options, @layout_options)
      |> assign(:layout_count, @default_layout_count)
      |> assign(:quality_options, @quality_options)
      |> assign(:stream_quality, @default_stream_quality)
      |> assign(:camera_tiles, [])
      |> assign(:camera_relay_subscriptions, MapSet.new())
      |> assign(:camera_layout_open_in_flight?, false)
      |> assign(:camera_layout_opening_key, nil)
      |> assign(:pending_layout_request, nil)
      |> assign(:initial_layout_opened?, false)
      |> assign(:relay_notice, nil)
      |> assign(:can_view_recordings?, can_view_recordings?(scope))
      |> assign(:can_semantic_search?, CameraSemanticSearch.can_search?(scope))
      |> assign(:semantic_search_form, to_form(default_search_params(), as: :search))
      |> assign(:semantic_search_executed?, false)
      |> assign(:semantic_search_count, 0)
      |> assign(:semantic_search_error, nil)
      |> assign(:semantic_embedder_unavailable?, false)
      |> stream(:semantic_search_results, [], reset: true)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    count =
      if Map.has_key?(params, "layout"),
        do: normalize_layout_count(params["layout"]),
        else: socket.assigns.layout_count

    quality =
      if Map.has_key?(params, "quality"),
        do: CameraMultiview.normalize_quality(params["quality"]),
        else: socket.assigns.stream_quality

    quality_changed? = quality != socket.assigns.stream_quality
    layout_changed? = count != socket.assigns.layout_count

    socket =
      socket
      |> assign(:layout_count, count)
      |> assign(:stream_quality, quality)

    socket =
      if connected?(socket) and (not socket.assigns.initial_layout_opened? or quality_changed? or layout_changed?) do
        socket
        |> assign(:initial_layout_opened?, true)
        |> open_camera_layout(count, quality, reset_existing?: quality_changed?)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :timezone, user_timezone(assigns.current_scope))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <div class="sr-camera-page space-y-4">
        <header class="sr-camera-toolbar">
          <div class="flex items-center gap-3">
            <.vantage_logo id="vantage-multiview-logo" class="size-8 shrink-0" />
            <div>
              <h2>ServiceRadar Vantage</h2>
              <p>IP Camera VMS &amp; Visual Intelligence</p>
            </div>
          </div>
          <div class="flex flex-wrap items-center gap-3">
            <div class="flex items-center gap-1.5">
              <span class="text-[11px] font-medium text-sr-muted">Quality</span>
              <div
                id="camera-multiview-quality-controls"
                class="sr-camera-layout-controls"
                role="group"
                aria-label="Stream quality"
              >
                <button
                  :for={{val, label} <- @quality_options}
                  id={"camera-multiview-quality-#{val}"}
                  type="button"
                  phx-click="set_quality"
                  phx-value-quality={val}
                  aria-pressed={to_string(@stream_quality == val)}
                  class={[
                    "sr-camera-layout-button px-2.5",
                    @stream_quality == val && "is-active"
                  ]}
                >
                  {label}
                </button>
              </div>
            </div>
            <div class="flex items-center gap-1.5">
              <span class="text-[11px] font-medium text-sr-muted">Grid</span>
              <div class="sr-camera-layout-controls" role="group" aria-label="Camera layout">
                <button
                  :for={count <- @layout_options}
                  id={"camera-multiview-layout-#{count}"}
                  type="button"
                  phx-click="set_layout"
                  phx-value-count={count}
                  aria-pressed={to_string(@layout_count == count)}
                  class={["sr-camera-layout-button", @layout_count == count && "is-active"]}
                >
                  {count}
                </button>
              </div>
            </div>
          </div>
        </header>

        <section
          :if={@can_semantic_search?}
          id="camera-fleet-semantic-search"
          aria-label="Semantic Clip Search"
          class="space-y-3 rounded-xl border border-sr-line bg-sr-surface p-4"
        >
          <div class="flex flex-wrap items-center justify-between gap-2">
            <div>
              <h3 class="text-sm font-semibold text-sr-ink">Semantic Clip Search</h3>
              <p class="mt-0.5 text-xs text-sr-muted">
                Search recorded camera clips across authorized cameras by visual description.
              </p>
            </div>
            <.ui_badge
              :if={@semantic_search_executed?}
              id="camera-fleet-semantic-count"
              variant="outline"
              size="xs"
            >
              {@semantic_search_count} {if(@semantic_search_count == 1, do: "clip", else: "clips")}
            </.ui_badge>
          </div>

          <.form
            for={@semantic_search_form}
            id="camera-fleet-semantic-search-form"
            phx-submit="semantic_search"
            class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_9.5rem_7.5rem_auto] sm:items-center"
          >
            <div>
              <label for="camera-fleet-semantic-query" class="sr-only">
                Visual clip search query
              </label>
              <input
                id="camera-fleet-semantic-query"
                type="text"
                name="search[q]"
                value={@semantic_search_form[:q].value}
                maxlength="256"
                placeholder="e.g. person in red dress, white van near gate"
                class="h-9 w-full rounded-lg border border-sr-line bg-sr-control px-3 text-xs text-sr-ink placeholder:text-sr-muted focus:border-sr-brand focus:outline-none"
              />
            </div>

            <div>
              <label for="camera-fleet-semantic-object-class" class="sr-only">Object class</label>
              <select
                id="camera-fleet-semantic-object-class"
                name="search[object_class]"
                class="h-9 w-full rounded-lg border border-sr-line bg-sr-control px-2.5 text-xs text-sr-ink focus:border-sr-brand focus:outline-none"
              >
                <option
                  value=""
                  selected={@semantic_search_form[:object_class].value in [nil, ""]}
                >
                  All classes
                </option>
                <option
                  :for={cls <- CameraSemanticSearch.allowed_object_classes()}
                  value={cls}
                  selected={@semantic_search_form[:object_class].value == cls}
                >
                  {String.capitalize(cls)}
                </option>
              </select>
            </div>

            <div>
              <label for="camera-fleet-semantic-range" class="sr-only">Time range</label>
              <select
                id="camera-fleet-semantic-range"
                name="search[range]"
                class="h-9 w-full rounded-lg border border-sr-line bg-sr-control px-2.5 text-xs text-sr-ink focus:border-sr-brand focus:outline-none"
              >
                <option
                  :for={
                    {val, label} <- [
                      {"1h", "Last 1h"},
                      {"6h", "Last 6h"},
                      {"24h", "Last 24h"},
                      {"7d", "Last 7d"},
                      {"30d", "Last 30d"}
                    ]
                  }
                  value={val}
                  selected={(@semantic_search_form[:range].value || "24h") == val}
                >
                  {label}
                </option>
              </select>
            </div>

            <div class="flex items-center gap-2">
              <.ui_button
                id="camera-fleet-semantic-submit"
                type="submit"
                variant="primary"
                size="sm"
              >
                <.icon name="hero-magnifying-glass" class="size-4" /> Search
              </.ui_button>
              <.ui_button
                :if={
                  @semantic_search_executed? or
                    (@semantic_search_form[:q].value || "") != ""
                }
                id="camera-fleet-semantic-clear"
                type="button"
                phx-click="clear_semantic_search"
                variant="outline"
                size="sm"
              >
                Clear
              </.ui_button>
            </div>
          </.form>

          <div
            :if={@semantic_embedder_unavailable?}
            id="camera-fleet-semantic-unavailable"
            role="alert"
            class="flex items-start gap-2.5 rounded-lg border border-amber-500/40 bg-amber-500/10 px-3 py-2.5 text-xs text-sr-ink"
          >
            <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0 text-amber-400" />
            <div>
              <p class="font-semibold">Visual search workers unavailable</p>
              <p class="mt-0.5 text-sr-muted">
                No compatible media worker responded within the interactive deadline. Live camera views and continuous recording remain unaffected.
              </p>
            </div>
          </div>

          <div
            :if={@semantic_search_error}
            id="camera-fleet-semantic-error"
            role="alert"
            class="rounded-lg border border-rose-500/40 bg-rose-500/10 px-3 py-2.5 text-xs text-sr-ink"
          >
            <span>{@semantic_search_error}</span>
          </div>

          <p
            :if={
              @semantic_search_executed? and @semantic_search_count == 0 and
                not @semantic_embedder_unavailable? and is_nil(@semantic_search_error)
            }
            id="camera-fleet-semantic-empty"
            class="rounded-lg border border-dashed border-sr-line bg-sr-canvas px-4 py-4 text-center text-xs text-sr-muted"
          >
            No matching recorded clips found across authorized cameras in the selected window.
          </p>

          <div
            id="camera-fleet-semantic-results"
            phx-update="stream"
            class={[
              "grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3",
              @semantic_search_count == 0 && "hidden"
            ]}
          >
            <article
              :for={{dom_id, hit} <- @streams.semantic_search_results}
              id={dom_id}
              data-role="semantic-search-result-card"
              class="group flex flex-col overflow-hidden rounded-xl border border-sr-line bg-sr-canvas transition-colors hover:border-sr-brand/60 hover:bg-sr-surface"
            >
              <% thumb_url = hit_thumbnail_url(hit) %>
              <% object_label = format_hit_object_class(hit.object_class) %>
              <div class="relative aspect-video w-full overflow-hidden bg-zinc-950">
                <div
                  data-role="semantic-hit-thumbnail-fallback"
                  class="flex h-full w-full items-center justify-center bg-gradient-to-br from-zinc-900 via-zinc-950 to-zinc-900 text-zinc-500"
                >
                  <.icon
                    name={hit_category_icon(hit.object_class)}
                    class="size-8 text-zinc-600 transition-transform duration-200 group-hover:scale-110 group-hover:text-zinc-400"
                  />
                </div>
                <img
                  :if={thumb_url}
                  src={thumb_url}
                  alt={"#{hit.camera_display_name} — #{object_label || "Clip"} match"}
                  loading="lazy"
                  data-role="semantic-hit-thumbnail"
                  onerror="this.style.display='none'"
                  class="absolute inset-0 h-full w-full object-cover transition-transform duration-200 group-hover:scale-105"
                />
                <div class="pointer-events-none absolute inset-x-0 top-0 h-12 bg-gradient-to-b from-black/70 via-black/30 to-transparent">
                </div>
                <span
                  data-role="semantic-hit-score-pill"
                  class="absolute top-2 left-2 inline-flex items-center gap-1.5 rounded-md border border-white/10 bg-black/75 px-2 py-0.5 text-[11px] font-medium text-white backdrop-blur-xs"
                >
                  <.icon
                    name={hit_category_icon(hit.object_class)}
                    class="size-3 shrink-0 text-emerald-400"
                  />
                  <span :if={object_label}>{object_label}</span>
                  <span :if={object_label} class="text-white/40">&middot;</span>
                  <span class="font-mono font-semibold text-emerald-300">
                    {format_score_pct(hit.score)}
                  </span>
                </span>
                <span
                  data-role="semantic-hit-camera-badge"
                  title={hit.camera_display_name}
                  class="absolute top-2 right-2 max-w-[55%] truncate rounded-md border border-white/10 bg-black/75 px-2 py-0.5 text-[11px] font-medium text-zinc-100 backdrop-blur-xs"
                >
                  {hit.camera_display_name}
                </span>
              </div>

              <div class="flex flex-1 flex-col gap-2.5 p-3">
                <div class="flex items-center justify-between gap-2 text-[11px] text-sr-muted">
                  <span class="truncate font-medium text-sr-ink">
                    <.user_time
                      id={"#{dom_id}-time"}
                      value={DateTime.from_unix!(hit.best_timeline_ts_us, :microsecond)}
                      timezone={@timezone}
                      style={:compact}
                    />
                  </span>
                  <span class="shrink-0 rounded bg-sr-surface px-1.5 py-0.5 font-mono text-[10px] text-sr-muted">
                    {hit.time_basis}
                  </span>
                </div>

                <p
                  :if={present_caption?(hit)}
                  data-role="semantic-hit-caption"
                  class="line-clamp-2 text-xs leading-relaxed text-sr-ink"
                >
                  {hit.caption_text}
                </p>

                <div
                  :if={hit.dominant_colors != [] or Map.get(hit, :action_tags, []) != []}
                  data-role="semantic-hit-metadata"
                  class="flex flex-wrap items-center gap-1"
                >
                  <span
                    :for={tag <- Enum.take(Map.get(hit, :action_tags, []), 3)}
                    class="rounded-md border border-sr-line bg-sr-surface px-1.5 py-0.5 text-[10px] font-medium text-sr-ink"
                  >
                    {String.capitalize(tag)}
                  </span>
                  <span
                    :for={color <- Enum.take(hit.dominant_colors, 3)}
                    class="rounded-md border border-sr-line/70 bg-sr-surface/60 px-1.5 py-0.5 text-[10px] text-sr-muted"
                  >
                    {String.capitalize(color)}
                  </span>
                </div>

                <div class="mt-auto flex items-center justify-end border-t border-sr-line/60 pt-2">
                  <.link
                    id={"#{dom_id}-open-timeline"}
                    data-role="open-in-timeline-link"
                    navigate={hit.timeline_path}
                    class="inline-flex items-center gap-1 text-xs font-medium text-emerald-400 transition-colors hover:text-emerald-300"
                  >
                    <span>Open in Timeline</span>
                    <.icon
                      name="hero-arrow-right"
                      class="size-3.5 transition-transform group-hover:translate-x-0.5"
                    />
                  </.link>
                </div>
              </div>
            </article>
          </div>
        </section>

        <div :if={@relay_notice} class="sr-camera-notice">
          {@relay_notice}
        </div>

        <section
          class={[
            "sr-camera-multiview",
            "sr-camera-multiview-#{@layout_count}"
          ]}
          data-testid="camera-multiview"
        >
          <article
            :for={tile <- visible_camera_tiles(@camera_tiles, @layout_count)}
            class="sr-camera-cell"
          >
            <header>
              <div class="flex min-w-0 items-center gap-2">
                <%= if is_binary(Map.get(tile, :camera_source_id)) do %>
                  <.link
                    id={"camera-multiview-tile-link-#{tile.camera_source_id}"}
                    navigate={camera_workspace_path(tile.camera_source_id, @can_view_recordings?)}
                    class="truncate text-xs font-bold text-slate-50 transition-colors hover:text-emerald-300"
                  >
                    {tile.label}
                  </.link>
                <% else %>
                  <span>{tile.label}</span>
                <% end %>
              </div>
              <div class="flex shrink-0 items-center gap-2">
                <small>{tile.detail || tile.source_status || "Camera stream"}</small>
                <.link
                  :if={is_binary(Map.get(tile, :camera_source_id))}
                  id={"camera-multiview-open-workspace-#{tile.camera_source_id}"}
                  data-role="multiview-open-workspace"
                  navigate={camera_workspace_path(tile.camera_source_id, @can_view_recordings?)}
                  title="Open Live & Timeline workspace"
                  class="inline-flex items-center gap-1 rounded border border-emerald-500/40 bg-emerald-500/15 px-1.5 py-0.5 text-[10px] font-semibold text-emerald-200 transition-colors hover:border-emerald-400 hover:bg-emerald-500/25 hover:text-white"
                >
                  <.icon name="hero-arrow-top-right-on-square" class="size-3" />
                  <span>{if(@can_view_recordings?, do: "Workspace", else: "Live")}</span>
                </.link>
              </div>
            </header>
            <CameraRelayComponents.relay_player
              :if={tile.session}
              session={tile.session}
              id_prefix="camera-multiview-relay"
            />
            <div :if={!tile.session} class="sr-camera-cell-empty">
              <.icon name="hero-video-camera-slash" class="size-8" />
              <span>{tile.error || "No live relay available"}</span>
            </div>
          </article>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("set_layout", %{"count" => count}, socket) do
    count = normalize_layout_count(count)
    quality = socket.assigns.stream_quality

    {:noreply,
     socket
     |> open_camera_layout(count, quality, reset_existing?: false)
     |> push_patch(to: ~p"/cameras?#{%{layout: count, quality: quality}}")}
  end

  def handle_event("set_quality", %{"quality" => quality}, socket) do
    quality = CameraMultiview.normalize_quality(quality)
    count = socket.assigns.layout_count

    if quality == socket.assigns.stream_quality do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> open_camera_layout(count, quality, reset_existing?: true)
       |> push_patch(to: ~p"/cameras?#{%{layout: count, quality: quality}}")}
    end
  end

  def handle_event("semantic_search", params, socket) do
    raw = Map.get(params, "search", params)
    q = raw |> Map.get("q", "") |> to_string()
    object_class = raw |> Map.get("object_class", "") |> to_string()
    range = normalize_range(raw["range"])

    form_params = %{
      "q" => q,
      "object_class" => object_class,
      "range" => range
    }

    now_us = System.system_time(:microsecond)
    duration_us = Map.fetch!(@range_durations_us, range)
    from_us = max(now_us - duration_us, 0)

    search_input = %{
      "q" => q,
      "object_class" => object_class,
      "from" => from_us,
      "to" => now_us,
      "limit" => 20
    }

    opts = search_opts(socket)

    socket =
      socket
      |> assign(:semantic_search_form, to_form(form_params, as: :search))
      |> execute_fleet_semantic_search(search_input, opts)

    {:noreply, socket}
  end

  def handle_event("clear_semantic_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:semantic_search_form, to_form(default_search_params(), as: :search))
     |> assign(:semantic_search_executed?, false)
     |> assign(:semantic_search_count, 0)
     |> assign(:semantic_search_error, nil)
     |> assign(:semantic_embedder_unavailable?, false)
     |> stream(:semantic_search_results, [], reset: true)}
  end

  @impl true
  def handle_async(:camera_layout_open, {:ok, {count, quality, tiles}}, socket) do
    Enum.each(tiles, &schedule_camera_refresh/1)

    socket =
      socket
      |> subscribe_camera_tiles(tiles)
      |> assign(:camera_tiles, pad_camera_tiles(tiles, count))
      |> assign(:relay_notice, camera_layout_notice(tiles, count))

    {:noreply, finish_camera_layout_open(socket, {count, quality})}
  end

  def handle_async(:camera_layout_open, {:exit, reason}, socket) do
    Logger.warning("Camera multiview relay open failed: #{inspect(reason, limit: 20, printable_limit: 200)}")
    count = socket.assigns.layout_count

    kept =
      socket.assigns.camera_tiles
      |> Enum.filter(& &1.session)
      |> Enum.take(count)

    socket =
      socket
      |> assign(:camera_tiles, pad_camera_tiles(kept, count))
      |> assign(:relay_notice, "Camera relay sessions could not be opened.")

    {:noreply, finish_camera_layout_open(socket, socket.assigns.camera_layout_opening_key)}
  end

  @impl true
  # Fallback timer for one tile: re-read it and re-arm.
  def handle_info({:refresh_camera_multiview_relay_session, relay_session_id}, socket) do
    {:noreply, refresh_camera_tile(socket, relay_session_id, rearm: true)}
  end

  # The relay published a state change for a tile's session.
  def handle_info({:camera_relay_state, %{relay_session_id: relay_session_id}}, socket)
      when is_binary(relay_session_id) do
    {:noreply, refresh_camera_tile(socket, relay_session_id, rearm: false)}
  end

  def handle_info({:camera_relay_state, _payload}, socket), do: {:noreply, socket}

  # Player channels consume these events from the shared relay topic.
  def handle_info({:camera_relay_webrtc_closed, _payload}, socket), do: {:noreply, socket}
  def handle_info({:camera_relay_chunk, _payload}, socket), do: {:noreply, socket}
  def handle_info({:camera_relay_viewer_chunk, _payload}, socket), do: {:noreply, socket}

  def handle_info(message, socket) do
    Logger.debug("Ignoring unexpected camera multiview message: #{inspect(message, limit: 20, printable_limit: 200)}")
    {:noreply, socket}
  end

  defp execute_fleet_semantic_search(socket, search_input, opts) do
    case CameraSemanticSearch.execute(socket.assigns.current_scope, search_input, opts) do
      {:ok, %{results: results}} ->
        stream_items =
          Enum.with_index(results, fn hit, idx ->
            Map.put(
              hit,
              :id,
              "fleet-semantic-hit-#{idx}-#{hit.visual_frame_id || hit.catalog_entry_id || hit.camera_source_id}"
            )
          end)

        socket
        |> assign(:semantic_search_executed?, true)
        |> assign(:semantic_search_count, length(stream_items))
        |> assign(:semantic_search_error, nil)
        |> assign(:semantic_embedder_unavailable?, false)
        |> stream(:semantic_search_results, stream_items, reset: true)

      {:error, :search_embedder_unavailable} ->
        socket
        |> assign(:semantic_search_executed?, true)
        |> assign(:semantic_search_count, 0)
        |> assign(:semantic_search_error, nil)
        |> assign(:semantic_embedder_unavailable?, true)
        |> stream(:semantic_search_results, [], reset: true)

      {:error, reason} when reason in [:unauthorized, :forbidden] ->
        socket
        |> assign(:can_semantic_search?, false)
        |> assign(:semantic_search_executed?, false)
        |> assign(:semantic_search_count, 0)
        |> assign(:semantic_search_error, "You do not have permission to search camera recordings.")
        |> assign(:semantic_embedder_unavailable?, false)
        |> stream(:semantic_search_results, [], reset: true)

      {:error, :invalid_query} ->
        socket
        |> assign(:semantic_search_executed?, false)
        |> assign(:semantic_search_count, 0)
        |> assign(:semantic_search_error, "Enter a search query between 1 and 256 characters.")
        |> assign(:semantic_embedder_unavailable?, false)
        |> stream(:semantic_search_results, [], reset: true)

      {:error, _reason} ->
        socket
        |> assign(:semantic_search_executed?, true)
        |> assign(:semantic_search_count, 0)
        |> assign(:semantic_search_error, "Semantic clip search is temporarily unavailable.")
        |> assign(:semantic_embedder_unavailable?, false)
        |> stream(:semantic_search_results, [], reset: true)
    end
  end

  defp search_opts(socket) do
    Map.get_lazy(socket.assigns, :camera_semantic_search_opts, fn ->
      Application.get_env(:serviceradar_web_ng, :camera_semantic_search_opts, [])
    end)
  end

  defp default_search_params do
    %{"q" => "", "object_class" => "", "range" => "24h"}
  end

  defp normalize_range(val) when is_binary(val) do
    if Map.has_key?(@range_durations_us, val), do: val, else: "24h"
  end

  defp normalize_range(_), do: "24h"

  defp format_score_pct(score) when is_number(score), do: "#{round(score * 100)}%"
  defp format_score_pct(_), do: "0%"

  defp hit_thumbnail_url(%{thumbnail_url: url}) when is_binary(url) and url != "", do: url
  defp hit_thumbnail_url(%{thumbnail_url: nil}), do: nil

  defp hit_thumbnail_url(hit) when is_map(hit) do
    CameraSemanticSearch.build_thumbnail_url(
      Map.get(hit, :camera_source_id),
      Map.get(hit, :catalog_entry_id),
      Map.get(hit, :has_block_thumbnail)
    )
  end

  defp hit_thumbnail_url(_), do: nil

  defp present_caption?(hit) when is_map(hit) do
    case Map.get(hit, :caption_text) do
      text when is_binary(text) -> String.trim(text) != ""
      _ -> false
    end
  end

  defp present_caption?(_), do: false

  defp format_hit_object_class(cls) when is_binary(cls) do
    trimmed = String.trim(cls)
    if trimmed == "", do: nil, else: String.capitalize(trimmed)
  end

  defp format_hit_object_class(_), do: nil

  defp hit_category_icon(cls) when is_binary(cls) do
    case String.downcase(String.trim(cls)) do
      "person" -> "hero-user"
      "vehicle" -> "hero-truck"
      "animal" -> "hero-sparkles"
      "package" -> "hero-cube"
      "bicycle" -> "hero-bolt"
      _ -> "hero-video-camera"
    end
  end

  defp hit_category_icon(_), do: "hero-video-camera"

  defp user_timezone(%{user: %{timezone: tz}}) when is_binary(tz) and tz != "", do: tz
  defp user_timezone(_scope), do: "Etc/UTC"

  defp refresh_camera_tile(socket, relay_session_id, rearm: rearm?) do
    tiles =
      Enum.map(socket.assigns.camera_tiles, fn tile ->
        if CameraMultiview.session_id(tile) == relay_session_id do
          refreshed = CameraMultiview.refresh_tile_session(socket.assigns.current_scope, tile)
          if rearm? or CameraMultiview.session_id(refreshed) != relay_session_id, do: schedule_camera_refresh(refreshed)
          refreshed
        else
          tile
        end
      end)

    socket
    |> assign(:camera_tiles, tiles)
    |> subscribe_camera_tiles(tiles)
  end

  defp subscribe_camera_tiles(socket, tiles) do
    subscribed =
      Enum.reduce(tiles, socket.assigns.camera_relay_subscriptions, &CameraMultiview.subscribe_relay_state(&2, &1))

    assign(socket, :camera_relay_subscriptions, subscribed)
  end

  # Opening a relay session reads the source, resolves its gateway and
  # dispatches an agent command, once per viewport. That runs in a task so the
  # page renders its viewports at once and fills them in as sessions open.
  defp open_camera_layout(socket, count, quality, opts) do
    reset_existing? = Keyword.get(opts, :reset_existing?, false)
    request_key = {count, quality}

    if RBAC.can?(socket.assigns.current_scope, "devices.cameras.view") do
      existing = if reset_existing?, do: [], else: socket.assigns.camera_tiles

      socket =
        socket
        |> assign(:layout_count, count)
        |> assign(:stream_quality, quality)
        |> assign(:camera_tiles, opening_camera_tiles(existing, count))
        |> assign(:relay_notice, nil)

      if socket.assigns.camera_layout_open_in_flight? do
        assign(socket, :pending_layout_request, {count, quality, reset_existing?})
      else
        scope = socket.assigns.current_scope

        socket
        |> assign(:camera_layout_open_in_flight?, true)
        |> assign(:camera_layout_opening_key, request_key)
        |> assign(:pending_layout_request, nil)
        |> start_async(:camera_layout_open, fn ->
          {count, quality, CameraMultiview.open_preview_tiles(scope, count, quality: quality)}
        end)
      end
    else
      socket
      |> assign(:layout_count, count)
      |> assign(:stream_quality, quality)
      |> assign(:camera_tiles, pad_camera_tiles([], count))
      |> assign(:relay_notice, "You are not authorized to view camera streams.")
    end
  end

  defp finish_camera_layout_open(socket, opened_key) do
    pending = socket.assigns.pending_layout_request

    socket =
      socket
      |> assign(:camera_layout_open_in_flight?, false)
      |> assign(:pending_layout_request, nil)

    case pending do
      {next_count, next_quality, reset?} when {next_count, next_quality} != opened_key ->
        open_camera_layout(socket, next_count, next_quality, reset_existing?: reset?)

      _ ->
        socket
    end
  end

  defp can_view_recordings?(scope) do
    RBAC.can?(scope, "devices.view") and RBAC.can?(scope, "devices.cameras.recordings.view")
  end

  defp camera_workspace_path(camera_source_id, true), do: ~p"/cameras/#{camera_source_id}/recordings?mode=timeline"
  defp camera_workspace_path(camera_source_id, false), do: ~p"/cameras/#{camera_source_id}"

  # Viewports that already show a session keep it while the new layout opens.
  defp opening_camera_tiles(tiles, count) do
    open = tiles |> Enum.filter(& &1.session) |> Enum.take(count)

    open ++
      for idx <- (length(open) + 1)..count//1 do
        %{label: "Camera #{idx}", detail: "Opening relay session", session: nil, error: "Opening camera relay"}
      end
  end

  defp visible_camera_tiles(tiles, count), do: Enum.take(tiles, count)

  defp pad_camera_tiles(tiles, count) do
    tiles ++
      for idx <- (length(tiles) + 1)..count//1 do
        %{label: "Camera #{idx}", detail: "Unassigned viewport", session: nil, error: "No relay-capable camera selected"}
      end
  end

  defp camera_layout_notice(tiles, count) do
    opened = Enum.count(tiles, & &1.session)

    cond do
      opened == count ->
        nil

      opened > 0 ->
        "#{opened} of #{count} viewports are backed by active relay sessions."

      tiles != [] ->
        relay_failure_notice(tiles)

      true ->
        "No relay-capable cameras were available from the current camera inventory."
    end
  end

  defp relay_failure_notice(tiles) do
    errors =
      tiles
      |> Enum.map(&Map.get(&1, :error))
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.uniq()

    case errors do
      [] ->
        "Relay-capable cameras are available, but no relay sessions opened."

      [error] ->
        "Relay-capable cameras are available, but no relay sessions opened: #{error}."

      errors ->
        "Relay-capable cameras are available, but no relay sessions opened: #{Enum.join(errors, "; ")}."
    end
  end

  defp normalize_layout_count(value) when is_binary(value) do
    value
    |> Integer.parse()
    |> case do
      {count, ""} -> normalize_layout_count(count)
      _ -> @default_layout_count
    end
  end

  defp normalize_layout_count(value) when value in @layout_options, do: value
  defp normalize_layout_count(_value), do: @default_layout_count

  defp schedule_camera_refresh(tile) do
    case CameraMultiview.session_id(tile) do
      session_id when is_binary(session_id) ->
        Process.send_after(
          self(),
          {:refresh_camera_multiview_relay_session, session_id},
          CameraMultiview.fallback_refresh_ms()
        )

      _ ->
        :ok
    end
  end
end
