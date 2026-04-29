defmodule ServiceRadarWebNGWeb.SpatialLive.FieldSurveyReview do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.FieldSurveyReview
  alias ServiceRadarWebNG.FieldSurveyReviewPreferences

  @default_selector_query "in:field_survey_rasters overlay_type:wifi_rssi has_floorplan:true sort:generated_at:desc limit:1"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "FieldSurvey Review")
     |> assign(:current_path, "/spatial/field-surveys")
     |> assign(:sessions, [])
     |> assign(:floor_options, [])
     |> assign(:selected_floor_key, "all")
     |> assign(:review, nil)
     |> assign(:selected_session_id, nil)
     |> assign(:overlay, "wifi")
     |> assign(:selector_params, %{"srql_query" => @default_selector_query})
     |> assign(:selector_preview, nil)
     |> assign(:error, nil)
     |> assign_selector_form()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_review(socket, params)}
  end

  @impl true
  def handle_event("overlay", %{"mode" => mode}, socket) when mode in ["wifi", "interference"] do
    {:noreply, assign(socket, :overlay, mode)}
  end

  def handle_event("refresh", _params, socket) do
    params =
      case socket.assigns.selected_session_id do
        nil -> %{"floor" => socket.assigns.selected_floor_key}
        session_id -> %{"session_id" => session_id, "floor" => socket.assigns.selected_floor_key}
      end

    {:noreply, load_review(socket, params)}
  end

  def handle_event("floor_filter", %{"floor" => floor_key}, socket) do
    params =
      case socket.assigns.selected_session_id do
        nil -> %{"floor" => floor_key}
        session_id -> %{"session_id" => session_id, "floor" => floor_key}
      end

    {:noreply, load_review(socket, params)}
  end

  def handle_event("select_session", %{"survey" => %{"session_id" => session_id}}, socket)
      when is_binary(session_id) and session_id != "" do
    {:noreply,
     push_patch(socket,
       to: field_survey_review_path(session_id, socket.assigns.selected_floor_key)
     )}
  end

  def handle_event("select_session", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_favorite", _params, socket) do
    with session_id when is_binary(session_id) <- socket.assigns.selected_session_id,
         {:ok, preference} <-
           FieldSurveyReviewPreferences.toggle_favorite(socket.assigns.current_scope, session_id) do
      message =
        if preference.favorite,
          do: "Favorited FieldSurvey session",
          else: "Removed FieldSurvey favorite"

      {:noreply,
       socket
       |> put_flash(:info, message)
       |> load_review(%{"session_id" => session_id, "floor" => socket.assigns.selected_floor_key})}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Could not update FieldSurvey favorite")}
    end
  end

  def handle_event("set_default", _params, socket) do
    with session_id when is_binary(session_id) <- socket.assigns.selected_session_id,
         {:ok, _preference} <-
           FieldSurveyReviewPreferences.set_default(socket.assigns.current_scope, session_id) do
      {:noreply,
       socket
       |> put_flash(:info, "Set FieldSurvey default view")
       |> load_review(%{"session_id" => session_id, "floor" => socket.assigns.selected_floor_key})}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Could not set FieldSurvey default view")}
    end
  end

  def handle_event("validate_selector", %{"selector" => params}, socket) do
    {:noreply,
     socket
     |> assign(:selector_params, selector_params(params))
     |> assign(:selector_preview, nil)
     |> assign_selector_form()}
  end

  def handle_event("preview_selector", %{"selector" => params}, socket) do
    params = selector_params(params)

    case preview_selector_query(socket.assigns.current_scope, params["srql_query"]) do
      {:ok, candidate} ->
        {:noreply,
         socket
         |> assign(:selector_params, params)
         |> assign(:selector_preview, {:ok, candidate})
         |> put_flash(:info, "SRQL resolved to FieldSurvey session #{candidate.session_id}")
         |> assign_selector_form()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:selector_params, params)
         |> assign(:selector_preview, {:error, reason})
         |> put_flash(:error, "SRQL preview failed: #{format_error(reason)}")
         |> assign_selector_form()}
    end
  end

  def handle_event("load_selector_candidate", %{"session-id" => session_id}, socket)
      when is_binary(session_id) and session_id != "" do
    {:noreply,
     push_patch(socket,
       to: field_survey_review_path(session_id, socket.assigns.selected_floor_key)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={%{page_path: @current_path}}>
      <div class="sr-fieldsurvey-review-page mx-auto max-w-7xl p-6 space-y-5">
        <div class="flex flex-col gap-3 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <h1 class="sr-spatial-title">FieldSurvey Review</h1>
            <p class="sr-spatial-subtitle">
              Wi-Fi RSSI coverage, AP observations, walking path, and SDR interference from persisted survey rows.
            </p>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <button class="btn btn-sm btn-outline" phx-click="refresh">
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </button>
            <.link
              :if={@selected_session_id}
              href={~p"/api/spatial/field-surveys/#{@selected_session_id}/export?format=svg"}
              class="btn btn-sm btn-outline"
            >
              <.icon name="hero-photo" class="size-4" /> Export SVG
            </.link>
            <.link
              :if={@selected_session_id}
              href={~p"/api/spatial/field-surveys/#{@selected_session_id}/export?format=json"}
              class="btn btn-sm btn-outline"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> Export JSON
            </.link>
            <.link navigate={~p"/spatial"} class="btn btn-sm btn-ghost">
              <.icon name="hero-cube-transparent" class="size-4" /> 3D View
            </.link>
          </div>
        </div>

        <div :if={@error} class="alert alert-error">
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span>{@error}</span>
        </div>

        <.ui_panel
          class="sr-spatial-panel"
          header_class="sr-spatial-panel-header"
          body_class="p-4"
        >
          <:header>
            <div>
              <div class="text-sm font-semibold">Survey Selection</div>
              <div class="text-xs text-base-content/60">
                Recent sessions, saved review defaults, and SRQL candidates.
              </div>
            </div>
          </:header>

          <div class="grid grid-cols-1 gap-4 xl:grid-cols-[minmax(18rem,0.8fr)_minmax(0,1.2fr)]">
            <div class="space-y-3">
              <form phx-change="select_session">
                <label class="form-control">
                  <span class="label">
                    <span class="label-text text-xs font-semibold uppercase text-base-content/60">
                      Recent survey
                    </span>
                  </span>
                  <select name="survey[session_id]" class="select select-bordered select-sm w-full">
                    <option :if={@sessions == []} value="">No surveys</option>
                    <option
                      :for={session <- @sessions}
                      value={session.id}
                      selected={session.id == @selected_session_id}
                    >
                      {session_option_label(session)}
                    </option>
                  </select>
                </label>
              </form>

              <div class="flex flex-wrap gap-2">
                <button
                  type="button"
                  class={[
                    "btn btn-sm",
                    selected_session_favorite?(@sessions, @selected_session_id) && "btn-primary"
                  ]}
                  phx-click="toggle_favorite"
                  disabled={is_nil(@selected_session_id)}
                >
                  <.icon name="hero-star" class="size-4" />
                  {if selected_session_favorite?(@sessions, @selected_session_id),
                    do: "Favorited",
                    else: "Favorite"}
                </button>
                <button
                  type="button"
                  class={[
                    "btn btn-sm",
                    selected_session_default?(@sessions, @selected_session_id) && "btn-primary"
                  ]}
                  phx-click="set_default"
                  disabled={is_nil(@selected_session_id)}
                >
                  <.icon name="hero-bookmark-square" class="size-4" />
                  {if selected_session_default?(@sessions, @selected_session_id),
                    do: "Default",
                    else: "Set Default"}
                </button>
              </div>
            </div>

            <div>
              <.form for={@selector_form} phx-change="validate_selector" phx-submit="preview_selector">
                <div class="grid grid-cols-1 gap-3 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-end">
                  <.input field={@selector_form[:srql_query]} type="text" label="SRQL selector" />
                  <button type="submit" class="btn btn-sm btn-outline">
                    <.icon name="hero-magnifying-glass" class="size-4" /> Preview
                  </button>
                </div>
              </.form>

              <div
                :if={match?({:ok, _}, @selector_preview)}
                class="mt-3 rounded border border-success/30 bg-success/10 px-3 py-2 text-sm"
              >
                <% {:ok, candidate} = @selector_preview %>
                <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                  <div>
                    <div class="font-semibold">{candidate.label}</div>
                    <div class="text-xs text-base-content/60">{candidate.session_id}</div>
                  </div>
                  <button
                    type="button"
                    class="btn btn-xs btn-primary"
                    phx-click="load_selector_candidate"
                    phx-value-session-id={candidate.session_id}
                  >
                    Load Survey
                  </button>
                </div>
              </div>

              <div
                :if={match?({:error, _}, @selector_preview)}
                class="mt-3 rounded border border-error/30 bg-error/10 px-3 py-2 text-sm text-error"
              >
                <% {:error, reason} = @selector_preview %>
                {format_error(reason)}
              </div>
            </div>
          </div>
        </.ui_panel>

        <div class="grid grid-cols-1 gap-4 lg:grid-cols-[18rem_1fr]">
          <.ui_panel class="sr-spatial-panel" header_class="sr-spatial-panel-header" body_class="p-0">
            <:header>
              <div>
                <div class="text-sm font-semibold">Survey Sessions</div>
                <div class="text-xs text-base-content/60">{length(@sessions)} recent sessions</div>
              </div>
            </:header>

            <div :if={length(@floor_options) > 1} class="border-b border-base-200 p-3">
              <div class="mb-2 text-xs font-semibold uppercase tracking-wide text-base-content/50">
                Floor
              </div>
              <div class="flex flex-wrap gap-1.5">
                <button
                  :for={floor <- @floor_options}
                  type="button"
                  phx-click="floor_filter"
                  phx-value-floor={floor.key}
                  class={[
                    "btn btn-xs",
                    floor.key == @selected_floor_key && "btn-primary",
                    floor.key != @selected_floor_key && "btn-outline"
                  ]}
                >
                  {floor.label}
                </button>
              </div>
            </div>

            <div class="divide-y divide-base-200">
              <.link
                :for={session <- @sessions}
                navigate={field_survey_review_path(session.id, @selected_floor_key)}
                class={[
                  "block px-4 py-3 transition hover:bg-base-200/60",
                  session.id == @selected_session_id && "bg-primary/10"
                ]}
              >
                <div class="truncate text-sm font-semibold">{session.id}</div>
                <div
                  :if={session[:metadata] && session.metadata[:label]}
                  class="mt-1 truncate text-xs text-primary/80"
                >
                  {session.metadata.label}
                </div>
                <div class="mt-1 flex items-center justify-between text-xs text-base-content/60">
                  <span>{format_time(session.last_seen)}</span>
                  <span>{session.rf_count} RF</span>
                </div>
                <div class="mt-1 text-xs text-base-content/50">
                  {session.ap_count} APs · {session.spectrum_count} spectrum
                </div>
              </.link>

              <div :if={@sessions == []} class="px-4 py-8 text-sm text-base-content/60">
                No FieldSurvey rows have been ingested yet.
              </div>
            </div>
          </.ui_panel>

          <div class="space-y-4">
            <.metric_strip :if={@review} metrics={@review.metrics} />

            <.ui_panel
              :if={@review}
              class="sr-spatial-panel"
              header_class="sr-spatial-panel-header"
              body_class="p-0"
            >
              <:header>
                <div>
                  <div class="text-sm font-semibold">Live Signal Map Review</div>
                  <div class="text-xs text-base-content/60">
                    2D top-down projection from fused pose and RF timestamps.
                  </div>
                </div>
                <div class="join">
                  <button
                    class={["btn btn-xs join-item", @overlay == "wifi" && "btn-primary"]}
                    phx-click="overlay"
                    phx-value-mode="wifi"
                  >
                    Wi-Fi RSSI
                  </button>
                  <button
                    class={["btn btn-xs join-item", @overlay == "interference" && "btn-primary"]}
                    phx-click="overlay"
                    phx-value-mode="interference"
                  >
                    RF Interference
                  </button>
                </div>
              </:header>

              <div class="sr-fieldsurvey-review-map-stack">
                <div class="sr-fieldsurvey-review-map-shell" style={review_map_shell_style(@review)}>
                  <div class="sr-fieldsurvey-review-map">
                    <div class="sr-fieldsurvey-review-grid"></div>

                    <div class={["sr-fieldsurvey-review-coverage", "overlay-#{@overlay}"]}>
                      <span
                        :for={cell <- coverage_cells(@review, @overlay)}
                        class="sr-fieldsurvey-review-coverage-cell"
                        style={coverage_cell_style(cell, @overlay)}
                      >
                      </span>
                    </div>

                    <svg
                      :if={@review.floorplan_segments != []}
                      class="sr-fieldsurvey-review-floorplan"
                      viewBox="0 0 100 100"
                      preserveAspectRatio="none"
                      aria-hidden="true"
                    >
                      <line
                        :for={segment <- @review.floorplan_segments}
                        x1={segment.start_x_pct}
                        y1={segment.start_z_pct}
                        x2={segment.end_x_pct}
                        y2={segment.end_z_pct}
                        style={floorplan_line_style(segment)}
                      />
                    </svg>

                    <span
                      :for={point <- @review.path_points}
                      class="sr-fieldsurvey-review-path-point"
                      style={path_style(point)}
                    >
                    </span>

                    <span
                      :for={point <- map_points(@review, @overlay)}
                      class="absolute rounded-full border border-white/70 shadow-lg"
                      title={point_title(point, @overlay)}
                      style={point_style(point, @overlay)}
                    >
                    </span>

                    <span
                      :for={ap <- ap_markers(@review)}
                      class="sr-fieldsurvey-review-ap-marker"
                      title={ap_marker_title(ap)}
                      style={ap_marker_style(ap)}
                    >
                      <.icon name="hero-wifi" class="size-3 text-sky-300" />
                      {confidence_percent(ap.confidence)}
                    </span>
                  </div>
                </div>

                <div class="sr-fieldsurvey-review-map-details">
                  <.map_legend overlay={@overlay} />
                  <.channel_scores scores={@review.channel_scores} />
                </div>
              </div>
            </.ui_panel>

            <div :if={@review} class="grid grid-cols-1 gap-4 xl:grid-cols-3">
              <.ui_panel class="sr-spatial-panel" header_class="sr-spatial-panel-header">
                <:header>
                  <div class="text-sm font-semibold">Room Artifacts</div>
                </:header>
                <div class="space-y-2">
                  <div
                    :for={artifact <- @review.room_artifacts}
                    class="flex items-center justify-between gap-3 rounded border border-base-200 px-3 py-2"
                  >
                    <div class="min-w-0">
                      <div class="truncate text-sm font-semibold">{artifact_label(artifact)}</div>
                      <div class="truncate text-xs text-base-content/60">
                        {format_bytes(artifact.byte_size)} · {format_time(artifact.uploaded_at)}
                      </div>
                    </div>
                    <.link href={artifact.download_url} class="btn btn-xs btn-outline">
                      Download
                    </.link>
                  </div>
                  <div :if={@review.room_artifacts == []} class="text-sm text-base-content/60">
                    No room artifacts uploaded for this session.
                  </div>
                  <div
                    :if={@review.room_artifacts != [] && @review.floorplan_segments == []}
                    class="rounded border border-warning/30 bg-warning/10 px-3 py-2 text-xs text-warning"
                  >
                    RoomPlan USDZ is stored, but no 2D floorplan GeoJSON artifact exists for this session yet.
                  </div>
                </div>
              </.ui_panel>

              <.ui_panel class="sr-spatial-panel" header_class="sr-spatial-panel-header">
                <:header>
                  <div class="text-sm font-semibold">Observed APs</div>
                </:header>
                <div class="space-y-2">
                  <div
                    :for={ap <- observed_ap_summaries(@review)}
                    class="rounded border border-base-200 px-3 py-2"
                  >
                    <div class="flex items-start justify-between gap-3">
                      <div class="min-w-0">
                        <div class="truncate text-sm font-semibold">{ap.ssid}</div>
                        <div class="truncate text-xs text-base-content/60">{ap.bssid}</div>
                      </div>
                      <div class="text-right text-xs">
                        <div class="font-semibold">{ap.strongest_rssi} dBm</div>
                        <div class="text-base-content/60">ch {ap.channel || "?"}</div>
                      </div>
                    </div>

                    <div class="mt-2 grid grid-cols-3 gap-2 text-[0.68rem] text-base-content/65">
                      <div>
                        <div class="uppercase text-base-content/40">Confidence</div>
                        <div class={["font-semibold", ap_confidence_class(ap.confidence)]}>
                          {confidence_percent(ap.confidence)}
                        </div>
                      </div>
                      <div>
                        <div class="uppercase text-base-content/40">Positioned</div>
                        <div class="font-semibold">
                          {ap.positioned_count}/{ap.count}
                        </div>
                      </div>
                      <div>
                        <div class="uppercase text-base-content/40">Spread</div>
                        <div class="font-semibold">{format_number(ap.path_spread_m)} m</div>
                      </div>
                    </div>
                  </div>
                  <div :if={@review.ap_summaries == []} class="text-sm text-base-content/60">
                    No AP observations for this session.
                  </div>
                </div>
              </.ui_panel>

              <.ui_panel class="sr-spatial-panel" header_class="sr-spatial-panel-header">
                <:header>
                  <div class="text-sm font-semibold">Spectrum Summary</div>
                </:header>
                <div class="grid grid-cols-2 gap-3 text-sm">
                  <.summary_cell label="Heat Points" value={@review.metrics.interference_point_count} />
                  <.summary_cell
                    label="Heat Cells"
                    value={@review.metrics.interference_raster_cell_count}
                  />
                  <.summary_cell label="Channels" value={@review.metrics.channel_count} />
                  <.summary_cell label="Spectrum Rows" value={@review.metrics.spectrum_count} />
                  <.summary_cell
                    label="Waterfall"
                    value={"#{@review.metrics.waterfall_row_count}x#{@review.metrics.waterfall_bin_count}"}
                  />
                  <.summary_cell label="Interferers" value={@review.metrics.interferer_count} />
                  <.summary_cell label="Pose Rows" value={@review.metrics.pose_count} />
                </div>
                <.interferer_classifications classifications={@review.interferer_classifications} />
              </.ui_panel>
            </div>

            <.spectrum_waterfall :if={@review} waterfall={@review.spectrum_waterfall} />

            <.ui_panel
              :if={!@review && @sessions != []}
              class="sr-spatial-panel"
              header_class="sr-spatial-panel-header"
            >
              <div class="py-10 text-center text-sm text-base-content/60">
                Select a survey session to review captured Wi-Fi and spectrum data.
              </div>
            </.ui_panel>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr(:metrics, :map, required: true)

  defp metric_strip(assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-3 lg:grid-cols-8">
      <.summary_cell label="RF Rows" value={@metrics.rf_count} />
      <.summary_cell label="Pose Rows" value={@metrics.pose_count} />
      <.summary_cell label="APs" value={@metrics.ap_count} />
      <.summary_cell
        label="Wi-Fi Heat"
        value={"#{@metrics.wifi_raster_cell_count}/#{@metrics.wifi_point_count}"}
      />
      <.summary_cell
        label="RF Heat"
        value={"#{@metrics.interference_raster_cell_count}/#{@metrics.interference_point_count}"}
      />
      <.summary_cell label="Spectrum" value={@metrics.spectrum_count} />
      <.summary_cell label="Waterfall" value={@metrics.waterfall_row_count} />
      <.summary_cell label="Artifacts" value={@metrics.room_artifact_count} />
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  defp summary_cell(assigns) do
    ~H"""
    <div class="sr-fieldsurvey-review-summary-cell rounded border px-3 py-2">
      <div class="text-xs uppercase text-base-content/50">{@label}</div>
      <div class="mt-1 text-xl font-semibold">{@value}</div>
    </div>
    """
  end

  attr(:overlay, :string, required: true)

  defp map_legend(assigns) do
    ~H"""
    <div>
      <div class="text-sm font-semibold">
        {if @overlay == "wifi", do: "Signal Strength", else: "RF Energy"}
      </div>
      <div class="mt-3 space-y-2 text-xs">
        <div :for={{label, color} <- legend(@overlay)} class="flex items-center gap-2">
          <span class="size-3 rounded" style={"background: #{color};"}></span>
          <span>{label}</span>
        </div>
      </div>
    </div>
    """
  end

  attr(:scores, :list, required: true)

  defp channel_scores(assigns) do
    assigns = assign(assigns, :scores, Enum.take(assigns.scores, 28))

    ~H"""
    <div>
      <div class="text-sm font-semibold">Channel Energy</div>
      <div class="mt-3 space-y-2">
        <div
          :for={score <- @scores}
          class="grid grid-cols-[3.5rem_1fr_3rem_1.5rem] items-center gap-2 text-xs"
        >
          <div>{score.band} {score.channel}</div>
          <div class="h-2 overflow-hidden rounded bg-base-200">
            <div class="h-full rounded" style={bar_style(score.score)}></div>
          </div>
          <div class="text-right text-base-content/60">{round(score.score)}%</div>
          <div class="text-right" title={channel_conflict_title(score)}>
            <.icon :if={score.conflict} name="hero-exclamation-triangle" class="size-3 text-warning" />
          </div>
        </div>
        <div :if={@scores == []} class="text-xs text-base-content/60">
          No spectrum channel summaries yet.
        </div>
      </div>
    </div>
    """
  end

  attr(:classifications, :list, required: true)

  defp interferer_classifications(assigns) do
    assigns = assign(assigns, :classifications, Enum.take(assigns.classifications, 4))

    ~H"""
    <div class="mt-4 border-t border-base-200 pt-3">
      <div class="text-sm font-semibold">Interferer Classification</div>
      <div class="mt-3 space-y-2">
        <div
          :for={classification <- @classifications}
          class="rounded border border-base-200 px-3 py-2 text-xs"
          title={classification.description}
        >
          <div class="flex items-center justify-between gap-3">
            <div class="font-semibold">{classification.label}</div>
            <div class={["font-mono", interferer_severity_class(classification.severity)]}>
              {classification.severity}%
            </div>
          </div>
          <div class="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-base-content/60">
            <span>{classification.event_count} events</span>
            <span>peak {format_number(classification.peak_power_dbm)} dBm</span>
            <span>@ {format_number(classification.peak_frequency_mhz)} MHz</span>
          </div>
        </div>
        <div :if={@classifications == []} class="text-xs text-base-content/60">
          No coarse interferers classified yet.
        </div>
      </div>
    </div>
    """
  end

  defp load_review(socket, params) do
    scope = socket.assigns.current_scope
    requested_id = params["session_id"]
    requested_floor_key = params["floor"] || "all"

    case FieldSurveyReview.list_sessions(scope, limit: 300) do
      {:ok, sessions} ->
        floor_options = floor_options_for_sessions(sessions)
        selected_floor_key = normalize_floor_key(requested_floor_key, floor_options)

        visible_sessions =
          sessions
          |> filter_sessions_by_floor(selected_floor_key)
          |> merge_preferences(scope)

        selected_id = select_session_id(visible_sessions, requested_id)

        case selected_id do
          nil ->
            assign(socket,
              sessions: visible_sessions,
              floor_options: floor_options,
              selected_floor_key: selected_floor_key,
              selected_session_id: nil,
              review: nil,
              error: nil
            )

          session_id ->
            case FieldSurveyReview.get_review(scope, session_id) do
              {:ok, review} ->
                assign(socket,
                  sessions: visible_sessions,
                  floor_options: floor_options,
                  selected_floor_key: selected_floor_key,
                  selected_session_id: session_id,
                  review: review,
                  error: nil
                )

              {:error, error} ->
                assign(socket,
                  sessions: visible_sessions,
                  floor_options: floor_options,
                  selected_floor_key: selected_floor_key,
                  selected_session_id: session_id,
                  review: nil,
                  error: "Could not load FieldSurvey review: #{inspect(error)}"
                )
            end
        end

      {:error, error} ->
        assign(socket,
          sessions: [],
          floor_options: [],
          selected_floor_key: "all",
          selected_session_id: nil,
          review: nil,
          error: "Could not load sessions: #{inspect(error)}"
        )
    end
  end

  defp map_points(review, "interference"), do: review.interference_points
  defp map_points(_review, _overlay), do: []

  defp coverage_cells(review, "wifi"), do: Map.get(review, :wifi_raster, [])
  defp coverage_cells(review, "interference"), do: Map.get(review, :interference_raster, [])
  defp coverage_cells(_review, _overlay), do: []

  defp assign_selector_form(socket) do
    assign(socket, :selector_form, to_form(socket.assigns.selector_params, as: :selector))
  end

  defp selector_params(params) when is_map(params) do
    query =
      params
      |> Map.get("srql_query", @default_selector_query)
      |> normalize_selector_query()

    %{"srql_query" => query}
  end

  defp selector_params(_params), do: %{"srql_query" => @default_selector_query}

  defp normalize_selector_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> case do
      "" -> @default_selector_query
      trimmed -> trimmed
    end
  end

  defp normalize_selector_query(_query), do: @default_selector_query

  defp preview_selector_query(scope, query) do
    query = normalize_selector_query(query)

    with :ok <- require_field_survey_query(query),
         {:ok, %{"results" => results}} <- srql_module().query(query, %{limit: 1, scope: scope}) do
      case Enum.find_value(results, &selector_candidate/1) do
        nil -> {:error, :no_field_survey_candidate}
        candidate -> {:ok, candidate}
      end
    end
  end

  defp require_field_survey_query(query) do
    if Regex.match?(
         ~r/(?:^|\s)in:(field_survey_rasters|fieldsurvey_rasters|survey_coverage_rasters|survey_rasters|field_survey_sessions|fieldsurvey_sessions|survey_sessions|field_survey_artifacts|fieldsurvey_artifacts|survey_room_artifacts)(?:\s|$)/i,
         query
       ) do
      :ok
    else
      {:error, :selector_query_must_target_field_survey}
    end
  end

  defp selector_candidate(%{"session_id" => session_id} = row) when is_binary(session_id) and session_id != "" do
    %{
      session_id: session_id,
      label: selector_candidate_label(row),
      row: row
    }
  end

  defp selector_candidate(_row), do: nil

  defp selector_candidate_label(row) do
    [
      Map.get(row, "site_name") || Map.get(row, "site_id"),
      Map.get(row, "building_name") || Map.get(row, "building_id"),
      Map.get(row, "floor_name") || floor_index_label(Map.get(row, "floor_index"))
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" / ")
    |> case do
      "" -> fallback_selector_label(row)
      label -> label
    end
  end

  defp fallback_selector_label(%{"entity" => entity}) when is_binary(entity), do: Phoenix.Naming.humanize(entity)

  defp fallback_selector_label(_row), do: "FieldSurvey session"

  defp selected_session_favorite?(sessions, session_id), do: selected_session_flag?(sessions, session_id, :favorite)

  defp selected_session_default?(sessions, session_id), do: selected_session_flag?(sessions, session_id, :default_view)

  defp selected_session_flag?(sessions, session_id, flag) when is_binary(session_id) do
    Enum.any?(sessions, &(&1.id == session_id and &1[flag]))
  end

  defp selected_session_flag?(_sessions, _session_id, _flag), do: false

  defp session_option_label(session) do
    prefix =
      [
        if(session[:default_view], do: "Default"),
        if(session[:favorite], do: "Favorite"),
        if(session[:renderable], do: "Ready")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" / ")
      |> case do
        "" -> ""
        labels -> "#{labels}: "
      end

    label =
      case session[:metadata] do
        %{label: label} when is_binary(label) and label != "" -> label
        _metadata -> session.id
      end

    "#{prefix}#{label} - #{session.rf_count} RF, #{session.ap_count} APs"
  end

  defp merge_preferences([], _scope), do: []

  defp merge_preferences(sessions, scope) do
    session_ids = Enum.map(sessions, & &1.id)

    case FieldSurveyReviewPreferences.for_sessions(scope, session_ids) do
      {:ok, preferences} ->
        Enum.map(sessions, fn session ->
          preference = Map.get(preferences, session.id, %{})

          session
          |> Map.put(:favorite, Map.get(preference, :favorite, false))
          |> Map.put(:default_view, Map.get(preference, :default_view, false))
        end)

      {:error, _reason} ->
        Enum.map(sessions, fn session ->
          session
          |> Map.put(:favorite, false)
          |> Map.put(:default_view, false)
        end)
    end
  end

  defp select_session_id(sessions, requested_id) do
    cond do
      is_binary(requested_id) and Enum.any?(sessions, &(&1.id == requested_id)) ->
        requested_id

      default = Enum.find(sessions, & &1[:default_view]) ->
        default.id

      favorite = best_session(Enum.filter(sessions, & &1[:favorite])) ->
        favorite.id

      renderable = best_session(Enum.filter(sessions, & &1[:renderable])) ->
        renderable.id

      complete = best_session(Enum.filter(sessions, &session_complete?/1)) ->
        complete.id

      first = List.first(sessions) ->
        first.id

      true ->
        nil
    end
  end

  defp best_session([]), do: nil

  defp best_session(sessions) do
    Enum.max_by(sessions, fn session ->
      {
        truthy_score(session[:renderable]),
        truthy_score(session[:has_floorplan]),
        session[:wifi_raster_count] || 0,
        session[:rf_count] || 0,
        session[:last_seen] || session[:first_seen] || DateTime.from_unix!(0)
      }
    end)
  end

  defp session_complete?(session), do: (session[:rf_count] || 0) > 0 and (session[:ap_count] || 0) > 0

  defp truthy_score(true), do: 1
  defp truthy_score(_), do: 0

  defp ap_markers(review) do
    review.ap_summaries
    |> Enum.filter(&valid_ap_marker?/1)
    |> Enum.sort_by(
      fn ap -> {ap.confidence || 0.0, ap.count || 0, ap.strongest_rssi || -120} end,
      :desc
    )
    |> clustered_ap_markers()
    |> Enum.take(6)
  end

  defp observed_ap_summaries(review) do
    review.ap_summaries
    |> Enum.reject(&invalid_bssid?(Map.get(&1, :bssid)))
    |> Enum.take(12)
  end

  defp floor_options_for_sessions(sessions) do
    floor_options =
      sessions
      |> Enum.map(&floor_option_for_session/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.key)
      |> Enum.sort_by(& &1.sort)

    if floor_options == [] do
      []
    else
      [%{key: "all", label: "All", sort: {-9_999, "All"}} | floor_options]
    end
  end

  defp floor_option_for_session(%{metadata: metadata}) when is_map(metadata) do
    floor_id = metadata[:floor_id] || metadata["floor_id"]
    floor_name = metadata[:floor_name] || metadata["floor_name"]
    floor_index = metadata[:floor_index] || metadata["floor_index"]

    cond do
      nonempty_string?(floor_id) ->
        %{
          key: "floor_id:#{floor_id}",
          label: floor_label(floor_name, floor_index),
          sort: floor_sort(floor_index, floor_name)
        }

      is_integer(floor_index) ->
        %{
          key: "floor_index:#{floor_index}",
          label: floor_label(floor_name, floor_index),
          sort: floor_sort(floor_index, floor_name)
        }

      nonempty_string?(floor_name) ->
        %{key: "floor_name:#{floor_name}", label: floor_name, sort: floor_sort(nil, floor_name)}

      true ->
        nil
    end
  end

  defp floor_option_for_session(_session), do: nil

  defp normalize_floor_key(floor_key, floor_options) when is_binary(floor_key) do
    if Enum.any?(floor_options, &(&1.key == floor_key)), do: floor_key, else: "all"
  end

  defp normalize_floor_key(_floor_key, _floor_options), do: "all"

  defp filter_sessions_by_floor(sessions, "all"), do: sessions

  defp filter_sessions_by_floor(sessions, floor_key) do
    Enum.filter(sessions, &(floor_option_for_session(&1)[:key] == floor_key))
  end

  defp field_survey_review_path(session_id, "all"), do: ~p"/spatial/field-surveys/#{session_id}"

  defp field_survey_review_path(session_id, floor_key) do
    query = URI.encode_query(%{"floor" => floor_key})
    "#{~p"/spatial/field-surveys/#{session_id}"}?#{query}"
  end

  defp floor_label(floor_name, _floor_index) when is_binary(floor_name) and floor_name != "", do: floor_name

  defp floor_label(_floor_name, floor_index) when is_integer(floor_index), do: "Floor #{floor_index}"

  defp floor_label(_floor_name, _floor_index), do: "Floor"

  defp floor_index_label(index) when is_integer(index), do: "Floor #{index}"
  defp floor_index_label(index) when is_binary(index) and index != "", do: "Floor #{index}"
  defp floor_index_label(_index), do: nil

  defp floor_sort(floor_index, floor_name) when is_integer(floor_index), do: {floor_index, floor_name || ""}

  defp floor_sort(_floor_index, floor_name), do: {9_999, floor_name || ""}

  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_ap_marker?(ap) do
    number?(Map.get(ap, :x_pct)) and
      number?(Map.get(ap, :z_pct)) and
      number?(Map.get(ap, :x)) and
      number?(Map.get(ap, :z)) and
      not invalid_bssid?(Map.get(ap, :bssid)) and
      (Map.get(ap, :confidence) || 0.0) >= 0.78 and
      (Map.get(ap, :positioned_count) || 0) >= 20
  end

  defp clustered_ap_markers(ap_summaries) do
    Enum.reduce(ap_summaries, [], fn ap, selected ->
      if Enum.any?(selected, &same_ap_candidate?(&1, ap)) do
        selected
      else
        selected ++ [ap]
      end
    end)
  end

  defp same_ap_candidate?(left, right) do
    distance =
      :math.sqrt(
        :math.pow((Map.get(left, :x) || 0.0) - (Map.get(right, :x) || 0.0), 2) +
          :math.pow((Map.get(left, :z) || 0.0) - (Map.get(right, :z) || 0.0), 2)
      )

    same_radio_family?(Map.get(left, :bssid), Map.get(right, :bssid)) or distance <= 1.8
  end

  defp same_radio_family?(left, right) when is_binary(left) and is_binary(right) do
    left_parts = left |> String.downcase() |> String.split(":")
    right_parts = right |> String.downcase() |> String.split(":")

    length(left_parts) == 6 and length(right_parts) == 6 and
      Enum.take(left_parts, 4) == Enum.take(right_parts, 4)
  end

  defp same_radio_family?(_left, _right), do: false

  defp invalid_bssid?(bssid) when is_binary(bssid) do
    normalized = String.downcase(String.trim(bssid))
    normalized in ["", "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff"]
  end

  defp invalid_bssid?(_bssid), do: true

  defp coverage_cell_style(cell, "interference") do
    diameter = max((cell.radius_pct || 1.0) * 2.75, 2.7)
    color = interference_color(cell.score || 0)
    opacity = 0.14 + min(max(cell.confidence || 0.0, 0.0), 1.0) * 0.42

    "left: calc(#{cell.x_pct}% - #{diameter / 2}%); top: calc(#{cell.z_pct}% - #{diameter / 2}%); width: #{diameter}%; height: #{diameter}%; background: radial-gradient(circle, #{color} 0%, #{color} 58%, transparent 86%); opacity: #{Float.round(opacity, 3)};"
  end

  defp coverage_cell_style(cell, _overlay) do
    diameter = max((cell.radius_pct || 1.0) * 3.0, 2.8)
    color = rssi_color(cell.rssi || -95)
    opacity = 0.16 + min(max(cell.confidence || 0.0, 0.0), 1.0) * 0.34

    "left: calc(#{cell.x_pct}% - #{diameter / 2}%); top: calc(#{cell.z_pct}% - #{diameter / 2}%); width: #{diameter}%; height: #{diameter}%; background: radial-gradient(circle, #{color} 0%, #{color} 62%, transparent 88%); opacity: #{Float.round(opacity, 3)};"
  end

  defp review_map_shell_style(%{bounds: %{aspect_ratio: ratio}}) when is_number(ratio) do
    ratio =
      ratio
      |> max(0.72)
      |> min(3.4)
      |> Float.round(3)

    "aspect-ratio: #{ratio} / 1;"
  end

  defp review_map_shell_style(_review), do: nil

  defp point_style(point, "interference") do
    size = 18 + (point.score || 0) * 0.22
    color = interference_color(point.score || 0)

    "left: calc(#{point.x_pct}% - #{size / 2}px); top: calc(#{point.z_pct}% - #{size / 2}px); width: #{size}px; height: #{size}px; background: #{color}; opacity: 0.72;"
  end

  defp point_style(point, _overlay) do
    size = 16 + min(max((point.count || 1) * 2, 0), 28)
    color = rssi_color(point.rssi || -95)

    "left: calc(#{point.x_pct}% - #{size / 2}px); top: calc(#{point.z_pct}% - #{size / 2}px); width: #{size}px; height: #{size}px; background: #{color}; opacity: 0.76;"
  end

  defp ap_marker_style(ap) do
    "left: #{ap.x_pct}%; top: #{ap.z_pct}%;"
  end

  defp path_style(point) do
    "left: #{point.x_pct}%; top: #{point.z_pct}%;"
  end

  defp bar_style(score) do
    "width: #{min(max(score || 0, 0), 100)}%; background: #{interference_color(score || 0)};"
  end

  defp channel_conflict_title(%{conflict: true} = score) do
    "#{score.ap_count} APs observed; strongest RSSI #{format_number(score.strongest_rssi)} dBm with high RF energy"
  end

  defp channel_conflict_title(_score), do: "No AP/noise conflict flagged"

  attr(:waterfall, :map, required: true)

  defp spectrum_waterfall(assigns) do
    ~H"""
    <.ui_panel class="sr-spatial-panel" header_class="sr-spatial-panel-header">
      <:header>
        <div>
          <div class="text-sm font-semibold">Spectrum Waterfall</div>
          <div class="text-xs text-base-content/60">
            HackRF sweep bins over time. Frequency runs left to right, newest rows are at the bottom.
          </div>
        </div>
      </:header>

      <div :if={@waterfall.rows != []} class="space-y-2">
        <div class="overflow-hidden rounded border border-base-200 bg-base-300/40 p-2">
          <div
            class="grid gap-px"
            style={"grid-template-columns: repeat(#{@waterfall.bin_count}, minmax(2px, 1fr));"}
          >
            <span
              :for={bin <- waterfall_bins(@waterfall)}
              class="block h-2 min-w-0"
              title={waterfall_bin_title(bin)}
              style={"background: #{waterfall_color(bin.intensity)};"}
            >
            </span>
          </div>
        </div>
        <div class="flex items-center justify-between text-xs text-base-content/60">
          <span>{format_frequency(waterfall_start(@waterfall))}</span>
          <span>
            {format_number(@waterfall.min_power_dbm)} to {format_number(@waterfall.max_power_dbm)} dBm
          </span>
          <span>{format_frequency(waterfall_stop(@waterfall))}</span>
        </div>
      </div>

      <div :if={@waterfall.rows == []} class="text-sm text-base-content/60">
        No spectrum waterfall rows yet.
      </div>
    </.ui_panel>
    """
  end

  defp floorplan_line_style(%{kind: "door"}) do
    "stroke: rgba(248,253,255,0.96); stroke-width: 0.46; stroke-dasharray: 1.4 0.9; stroke-linecap: round; vector-effect: non-scaling-stroke;"
  end

  defp floorplan_line_style(%{kind: "window"}) do
    "stroke: rgba(94,214,255,0.96); stroke-width: 0.42; stroke-dasharray: 0.9 0.7; stroke-linecap: round; vector-effect: non-scaling-stroke;"
  end

  defp floorplan_line_style(_segment) do
    "stroke: rgba(205,250,255,0.96); stroke-width: 0.52; stroke-linecap: round; vector-effect: non-scaling-stroke;"
  end

  defp point_title(point, "interference") do
    "#{round(point.score || 0)}% RF energy, peak #{format_number(point.peak_power_dbm)} dBm @ #{format_number(point.peak_frequency_mhz)} MHz"
  end

  defp point_title(point, _overlay) do
    "#{point.ssid} #{format_number(point.rssi)} dBm, #{point.count} samples"
  end

  defp ap_marker_title(ap) do
    "#{ap.ssid} #{ap.bssid}: #{confidence_percent(ap.confidence)} confidence, #{ap.positioned_count}/#{ap.count} positioned observations, strongest #{format_number(ap.strongest_rssi)} dBm"
  end

  defp ap_confidence_class(confidence) when is_number(confidence) and confidence >= 0.72, do: "text-success"

  defp ap_confidence_class(confidence) when is_number(confidence) and confidence >= 0.45, do: "text-warning"

  defp ap_confidence_class(_confidence), do: "text-error"

  defp legend("interference") do
    [{"Low", "#22c55e"}, {"Moderate", "#facc15"}, {"High", "#f97316"}, {"Severe", "#ef4444"}]
  end

  defp legend(_overlay) do
    [
      {"-30 Excellent", "#16a34a"},
      {"-50 Good", "#84cc16"},
      {"-60 Fair", "#facc15"},
      {"-70 Poor", "#f97316"},
      {"-80+ Very Poor", "#ef4444"}
    ]
  end

  defp rssi_color(rssi) when rssi >= -50, do: "#16a34a"
  defp rssi_color(rssi) when rssi >= -60, do: "#84cc16"
  defp rssi_color(rssi) when rssi >= -70, do: "#facc15"
  defp rssi_color(rssi) when rssi >= -80, do: "#f97316"
  defp rssi_color(_rssi), do: "#ef4444"

  defp interference_color(score) when score >= 75, do: "#ef4444"
  defp interference_color(score) when score >= 55, do: "#f97316"
  defp interference_color(score) when score >= 35, do: "#facc15"
  defp interference_color(_score), do: "#22c55e"

  defp interferer_severity_class(severity) when is_number(severity) and severity >= 75, do: "text-error"

  defp interferer_severity_class(severity) when is_number(severity) and severity >= 55, do: "text-warning"

  defp interferer_severity_class(_severity), do: "text-success"

  defp waterfall_bins(waterfall) do
    waterfall.rows
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, row_index} ->
      Enum.map(row.bins, &Map.put(&1, :row_index, row_index))
    end)
  end

  defp waterfall_bin_title(bin) do
    "#{format_frequency(bin.frequency_mhz)} #{format_number(bin.power_dbm)} dBm"
  end

  defp waterfall_start(%{rows: [row | _]}), do: row.start_frequency_mhz
  defp waterfall_start(_waterfall), do: nil

  defp waterfall_stop(%{rows: [row | _]}), do: row.stop_frequency_mhz
  defp waterfall_stop(_waterfall), do: nil

  defp waterfall_color(score) when score >= 82, do: "#ef4444"
  defp waterfall_color(score) when score >= 64, do: "#f97316"
  defp waterfall_color(score) when score >= 46, do: "#facc15"
  defp waterfall_color(score) when score >= 28, do: "#84cc16"
  defp waterfall_color(_score), do: "#0f766e"

  defp format_time(nil), do: "unknown"

  defp format_time(%DateTime{} = value) do
    Calendar.strftime(value, "%b %-d %H:%M")
  end

  defp format_time(_value), do: "unknown"

  defp format_number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp format_number(value) when is_integer(value), do: Integer.to_string(value)
  defp format_number(_value), do: "?"

  defp confidence_percent(value) when is_number(value), do: "#{round(value * 100)}%"
  defp confidence_percent(_value), do: "?%"

  defp format_frequency(value) when is_number(value), do: "#{format_number(value)} MHz"
  defp format_frequency(_value), do: "? MHz"

  defp artifact_label(%{artifact_type: "roomplan_usdz"}), do: "RoomPlan USDZ"
  defp artifact_label(%{artifact_type: "floorplan_geojson"}), do: "2D floorplan GeoJSON"
  defp artifact_label(%{artifact_type: "point_cloud_ply"}), do: "Point cloud PLY"
  defp artifact_label(%{artifact_type: type}), do: type

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  defp format_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp format_bytes(_bytes), do: "unknown size"

  defp format_error(:selector_query_must_target_field_survey),
    do: "query must target field_survey_rasters, field_survey_sessions, or field_survey_artifacts"

  defp format_error(:no_field_survey_candidate), do: "query returned no FieldSurvey candidate"
  defp format_error(%Jason.DecodeError{} = error), do: Exception.message(error)
  defp format_error(%ArgumentError{} = error), do: Exception.message(error)
  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  defp number?(value), do: is_integer(value) or is_float(value)
end
