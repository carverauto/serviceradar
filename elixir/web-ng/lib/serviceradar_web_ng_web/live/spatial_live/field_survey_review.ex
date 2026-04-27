defmodule ServiceRadarWebNGWeb.SpatialLive.FieldSurveyReview do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.FieldSurveyReview

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "FieldSurvey Review")
     |> assign(:current_path, "/spatial/field-surveys")
     |> assign(:sessions, [])
     |> assign(:review, nil)
     |> assign(:selected_session_id, nil)
     |> assign(:overlay, "wifi")
     |> assign(:error, nil)}
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
        nil -> %{}
        session_id -> %{"session_id" => session_id}
      end

    {:noreply, load_review(socket, params)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={%{page_path: @current_path}}>
      <div class="mx-auto max-w-7xl p-6 space-y-5">
        <div class="flex flex-col gap-3 lg:flex-row lg:items-end lg:justify-between">
          <.header>
            FieldSurvey Review
            <:subtitle>
              Wi-Fi RSSI coverage, AP observations, walking path, and SDR interference from persisted survey rows.
            </:subtitle>
          </.header>

          <div class="flex flex-wrap items-center gap-2">
            <button class="btn btn-sm btn-outline" phx-click="refresh">
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </button>
            <.link navigate={~p"/spatial"} class="btn btn-sm btn-ghost">
              <.icon name="hero-cube-transparent" class="size-4" /> 3D View
            </.link>
          </div>
        </div>

        <div :if={@error} class="alert alert-error">
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span>{@error}</span>
        </div>

        <div class="grid grid-cols-1 gap-4 lg:grid-cols-[18rem_1fr]">
          <.ui_panel body_class="p-0">
            <:header>
              <div>
                <div class="text-sm font-semibold">Survey Sessions</div>
                <div class="text-xs text-base-content/60">{length(@sessions)} recent sessions</div>
              </div>
            </:header>

            <div class="divide-y divide-base-200">
              <.link
                :for={session <- @sessions}
                navigate={~p"/spatial/field-surveys/#{session.id}"}
                class={[
                  "block px-4 py-3 transition hover:bg-base-200/60",
                  session.id == @selected_session_id && "bg-primary/10"
                ]}
              >
                <div class="truncate text-sm font-semibold">{session.id}</div>
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

            <.ui_panel :if={@review} body_class="p-0">
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

              <div class="grid grid-cols-1 gap-0 xl:grid-cols-[1fr_20rem]">
                <div class="relative min-h-[34rem] overflow-hidden bg-base-200/40">
                  <div class="absolute inset-5 rounded border border-base-300 bg-base-100 shadow-inner">
                    <div class="absolute inset-0 opacity-40 [background-image:linear-gradient(to_right,hsl(var(--bc)/0.12)_1px,transparent_1px),linear-gradient(to_bottom,hsl(var(--bc)/0.12)_1px,transparent_1px)] [background-size:2rem_2rem]">
                    </div>

                    <span
                      :for={cell <- coverage_cells(@review, @overlay)}
                      class="absolute rounded-full pointer-events-none"
                      style={coverage_cell_style(cell)}
                    >
                    </span>

                    <svg
                      :if={@review.floorplan_segments != []}
                      class="absolute inset-0 h-full w-full pointer-events-none"
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
                      class="absolute size-1 rounded-full bg-base-content/30"
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
                  </div>
                </div>

                <div class="border-t border-base-200 p-4 xl:border-l xl:border-t-0">
                  <.map_legend overlay={@overlay} />
                  <div class="divider my-4"></div>
                  <.channel_scores scores={@review.channel_scores} />
                </div>
              </div>
            </.ui_panel>

            <div :if={@review} class="grid grid-cols-1 gap-4 xl:grid-cols-3">
              <.ui_panel>
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

              <.ui_panel>
                <:header>
                  <div class="text-sm font-semibold">Observed APs</div>
                </:header>
                <div class="space-y-2">
                  <div
                    :for={ap <- Enum.take(@review.ap_summaries, 12)}
                    class="flex items-center justify-between gap-3 rounded border border-base-200 px-3 py-2"
                  >
                    <div class="min-w-0">
                      <div class="truncate text-sm font-semibold">{ap.ssid}</div>
                      <div class="truncate text-xs text-base-content/60">{ap.bssid}</div>
                    </div>
                    <div class="text-right text-xs">
                      <div class="font-semibold">{ap.strongest_rssi} dBm</div>
                      <div class="text-base-content/60">ch {ap.channel || "?"}</div>
                    </div>
                  </div>
                </div>
              </.ui_panel>

              <.ui_panel>
                <:header>
                  <div class="text-sm font-semibold">Spectrum Summary</div>
                </:header>
                <div class="grid grid-cols-2 gap-3 text-sm">
                  <.summary_cell label="Heat Points" value={@review.metrics.interference_point_count} />
                  <.summary_cell label="Channels" value={@review.metrics.channel_count} />
                  <.summary_cell label="Spectrum Rows" value={@review.metrics.spectrum_count} />
                  <.summary_cell label="Pose Rows" value={@review.metrics.pose_count} />
                </div>
              </.ui_panel>
            </div>

            <.ui_panel :if={!@review && @sessions != []}>
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

  attr :metrics, :map, required: true

  defp metric_strip(assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-3 lg:grid-cols-7">
      <.summary_cell label="RF Rows" value={@metrics.rf_count} />
      <.summary_cell label="Pose Rows" value={@metrics.pose_count} />
      <.summary_cell label="APs" value={@metrics.ap_count} />
      <.summary_cell
        label="Wi-Fi Heat"
        value={"#{@metrics.wifi_raster_cell_count}/#{@metrics.wifi_point_count}"}
      />
      <.summary_cell label="RF Heat" value={@metrics.interference_point_count} />
      <.summary_cell label="Spectrum" value={@metrics.spectrum_count} />
      <.summary_cell label="Artifacts" value={@metrics.room_artifact_count} />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp summary_cell(assigns) do
    ~H"""
    <div class="rounded border border-base-200 bg-base-100 px-3 py-2">
      <div class="text-xs uppercase text-base-content/50">{@label}</div>
      <div class="mt-1 text-xl font-semibold">{@value}</div>
    </div>
    """
  end

  attr :overlay, :string, required: true

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

  attr :scores, :list, required: true

  defp channel_scores(assigns) do
    assigns = assign(assigns, :scores, Enum.take(assigns.scores, 28))

    ~H"""
    <div>
      <div class="text-sm font-semibold">Channel Energy</div>
      <div class="mt-3 space-y-2">
        <div
          :for={score <- @scores}
          class="grid grid-cols-[3.5rem_1fr_3rem] items-center gap-2 text-xs"
        >
          <div>{score.band} {score.channel}</div>
          <div class="h-2 overflow-hidden rounded bg-base-200">
            <div class="h-full rounded" style={bar_style(score.score)}></div>
          </div>
          <div class="text-right text-base-content/60">{round(score.score)}%</div>
        </div>
        <div :if={@scores == []} class="text-xs text-base-content/60">
          No spectrum channel summaries yet.
        </div>
      </div>
    </div>
    """
  end

  defp load_review(socket, params) do
    scope = socket.assigns.current_scope
    requested_id = params["session_id"]

    case FieldSurveyReview.list_sessions(scope, limit: 300) do
      {:ok, sessions} ->
        selected_id = requested_id || List.first(sessions, %{})[:id]

        case selected_id do
          nil ->
            assign(socket, sessions: sessions, selected_session_id: nil, review: nil, error: nil)

          session_id ->
            case FieldSurveyReview.get_review(scope, session_id) do
              {:ok, review} ->
                assign(socket,
                  sessions: sessions,
                  selected_session_id: session_id,
                  review: review,
                  error: nil
                )

              {:error, error} ->
                assign(socket,
                  sessions: sessions,
                  selected_session_id: session_id,
                  review: nil,
                  error: "Could not load FieldSurvey review: #{inspect(error)}"
                )
            end
        end

      {:error, error} ->
        assign(socket,
          sessions: [],
          selected_session_id: nil,
          review: nil,
          error: "Could not load sessions: #{inspect(error)}"
        )
    end
  end

  defp map_points(review, "interference"), do: review.interference_points
  defp map_points(review, _overlay), do: review.wifi_points

  defp coverage_cells(review, "wifi"), do: Map.get(review, :wifi_raster, [])
  defp coverage_cells(_review, _overlay), do: []

  defp coverage_cell_style(cell) do
    diameter = max((cell.radius_pct || 1.0) * 2.4, 2.4)
    color = rssi_color(cell.rssi || -95)
    opacity = 0.14 + min(max(cell.confidence || 0.0, 0.0), 1.0) * 0.42

    "left: calc(#{cell.x_pct}% - #{diameter / 2}%); top: calc(#{cell.z_pct}% - #{diameter / 2}%); width: #{diameter}%; height: #{diameter}%; background: radial-gradient(circle, #{color} 0%, #{color} 52%, transparent 78%); opacity: #{Float.round(opacity, 3)}; filter: blur(3px);"
  end

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

  defp path_style(point) do
    "left: #{point.x_pct}%; top: #{point.z_pct}%;"
  end

  defp bar_style(score) do
    "width: #{min(max(score || 0, 0), 100)}%; background: #{interference_color(score || 0)};"
  end

  defp floorplan_line_style(%{kind: "door"}) do
    "stroke: rgba(255,255,255,0.78); stroke-width: 0.32; stroke-dasharray: 1.4 0.9; stroke-linecap: round; vector-effect: non-scaling-stroke;"
  end

  defp floorplan_line_style(%{kind: "window"}) do
    "stroke: rgba(125,211,252,0.88); stroke-width: 0.26; stroke-dasharray: 0.9 0.7; stroke-linecap: round; vector-effect: non-scaling-stroke;"
  end

  defp floorplan_line_style(_segment) do
    "stroke: rgba(103,232,249,0.72); stroke-width: 0.36; stroke-linecap: round; vector-effect: non-scaling-stroke;"
  end

  defp point_title(point, "interference") do
    "#{round(point.score || 0)}% RF energy, peak #{format_number(point.peak_power_dbm)} dBm @ #{format_number(point.peak_frequency_mhz)} MHz"
  end

  defp point_title(point, _overlay) do
    "#{point.ssid} #{format_number(point.rssi)} dBm, #{point.count} samples"
  end

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

  defp format_time(nil), do: "unknown"

  defp format_time(%DateTime{} = value) do
    Calendar.strftime(value, "%b %-d %H:%M")
  end

  defp format_time(_value), do: "unknown"

  defp format_number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp format_number(value) when is_integer(value), do: Integer.to_string(value)
  defp format_number(_value), do: "?"

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
end
