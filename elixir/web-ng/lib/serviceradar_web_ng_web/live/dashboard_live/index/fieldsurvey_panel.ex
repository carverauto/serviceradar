defmodule ServiceRadarWebNGWeb.DashboardLive.Index.FieldSurveyPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DashboardLive.Index.Common

  alias ServiceRadarWebNGWeb.DashboardLive.Index.Common

  attr(:dashboard, :map, required: true)

  def render(%{dashboard: dashboard} = assigns) do
    assigns = Map.merge(assigns, dashboard)

    ~H"""
    <Common.panel :if={survey_panel_visible?(@survey_summary)} title="FieldSurvey Heatmap">
      <:actions>
        <.link href={~p"/spatial/field-surveys"} class="sr-ops-button">Open FieldSurvey</.link>
      </:actions>
      <div
        class={[
          "sr-ops-heatmap-placeholder",
          "sr-ops-field-survey-card-map",
          @survey_summary.raster_cell_count > 0 && "sr-ops-heatmap-real"
        ]}
        style={fieldsurvey_heatmap_style(@survey_summary)}
        data-testid="fieldsurvey-heatmap"
      >
        <.link
          href={~p"/spatial/field-surveys"}
          class="sr-ops-field-survey-open-overlay"
          aria-label="Open FieldSurvey heatmap details"
        >
          <span class="sr-only">Open FieldSurvey heatmap details</span>
        </.link>
        <svg
          :if={@survey_summary.floorplan_segment_count > 0}
          class="sr-ops-field-survey-floorplan"
          viewBox="0 0 100 100"
          preserveAspectRatio="none"
          aria-hidden="true"
        >
          <line
            :for={segment <- @survey_summary.floorplan_segments}
            x1={segment.start_x_pct}
            y1={segment.start_z_pct}
            x2={segment.end_x_pct}
            y2={segment.end_z_pct}
            class={"sr-ops-floorplan-line sr-ops-floorplan-line-#{segment.kind}"}
          />
        </svg>
        <div :if={@survey_summary.ap_marker_count > 0} class="sr-ops-field-survey-ap-layer">
          <.link
            :for={ap <- Enum.filter(@survey_summary.ap_markers, &Map.get(&1, :device_uid))}
            navigate={~p"/devices/#{ap.device_uid}"}
            class="sr-ops-field-survey-ap-marker is-linked"
            style={fieldsurvey_ap_marker_style(ap)}
            title={fieldsurvey_ap_marker_title(ap)}
            aria-label={fieldsurvey_ap_marker_title(ap)}
          >
            <.icon name="hero-wifi" class="size-3.5" />
            <.fieldsurvey_ap_tooltip ap={ap} />
          </.link>
          <span
            :for={ap <- Enum.reject(@survey_summary.ap_markers, &Map.get(&1, :device_uid))}
            class="sr-ops-field-survey-ap-marker"
            style={fieldsurvey_ap_marker_style(ap)}
            title={fieldsurvey_ap_marker_title(ap)}
            aria-label={fieldsurvey_ap_marker_title(ap)}
            tabindex="0"
            role="button"
          >
            <.icon name="hero-wifi" class="size-3.5" />
            <.fieldsurvey_ap_tooltip ap={ap} />
          </span>
        </div>
        <div
          :if={@survey_summary.raster_cell_count > 0}
          class="sr-ops-field-survey-raster-cells"
          aria-label="Latest FieldSurvey Wi-Fi RSSI raster"
        >
          <span
            :for={cell <- @survey_summary.raster_cells}
            class="sr-ops-field-survey-raster-cell"
            style={fieldsurvey_raster_cell_style(cell)}
          ></span>
        </div>
        <div
          :if={@survey_summary.raster_cell_count > 0}
          class="sr-ops-field-survey-legend"
          aria-label="FieldSurvey signal strength legend"
        >
          <span><i class="excellent"></i>-55+</span>
          <span><i class="good"></i>-65</span>
          <span><i class="fair"></i>-75</span>
          <span><i class="poor"></i>-82</span>
          <span><i class="weak"></i>weak</span>
        </div>
        <div
          :if={@survey_summary.raster_playlist_diagnostics != []}
          class="sr-ops-field-survey-diagnostics"
          aria-label="FieldSurvey playlist diagnostics"
        >
          <.icon name="hero-exclamation-triangle" class="size-3.5" />
          <span>{fieldsurvey_playlist_diagnostic(@survey_summary)}</span>
        </div>
        <div :if={@survey_summary.raster_cell_count == 0} class="sr-ops-floor-grid">
          <span :for={_ <- 1..18}></span>
        </div>
        <div
          :if={
            @module_states.fieldsurvey == :loading and @survey_summary.sample_count == 0 and
              @survey_summary.raster_cell_count == 0
          }
          class="sr-ops-heatmap-empty sr-ops-heatmap-summary"
        >
          <.icon name="hero-wifi" class="size-8" />
          <p>Loading FieldSurvey heatmap</p>
          <span>Checking persisted Wi-Fi rasters and floorplan artifacts.</span>
        </div>
        <div
          :if={
            @module_states.fieldsurvey != :loading and @survey_summary.sample_count == 0 and
              @survey_summary.raster_cell_count == 0
          }
          class="sr-ops-heatmap-empty"
        >
          <.icon name="hero-wifi" class="size-8" />
          <p>No FieldSurvey heatmap data</p>
          <span>Survey overlays will render here when floorplan samples exist.</span>
        </div>
        <div
          :if={@survey_summary.sample_count > 0 and @survey_summary.raster_cell_count == 0}
          class="sr-ops-heatmap-empty sr-ops-heatmap-summary"
          data-testid="fieldsurvey-summary"
        >
          <.icon name="hero-wifi" class="size-8" />
          <p>{@survey_summary.session_count} survey sessions</p>
          <span>
            {@survey_summary.sample_count} samples, {@survey_summary.avg_rssi} dBm average RSSI
          </span>
        </div>
      </div>
    </Common.panel>
    """
  end

  defp fieldsurvey_heatmap_style(%{raster_aspect_ratio: ratio}) when is_number(ratio) do
    ratio =
      ratio
      |> max(0.72)
      |> min(3.2)
      |> Float.round(3)

    "aspect-ratio: #{ratio} / 1;"
  end

  defp fieldsurvey_heatmap_style(_summary), do: nil

  defp fieldsurvey_playlist_diagnostic(%{raster_playlist_diagnostics: [diagnostic | _]}) do
    Map.get(diagnostic, :message) || "Using fallback FieldSurvey heatmap"
  end

  defp fieldsurvey_playlist_diagnostic(_summary), do: "Using fallback FieldSurvey heatmap"

  defp fieldsurvey_ap_marker_style(%{x_pct: x, z_pct: z}) when is_number(x) and is_number(z) do
    "left: #{Float.round(x, 3)}%; top: #{Float.round(z, 3)}%;"
  end

  defp fieldsurvey_ap_marker_style(_ap), do: nil

  attr(:ap, :map, required: true)

  defp fieldsurvey_ap_tooltip(assigns) do
    ~H"""
    <span class="sr-ops-field-survey-ap-tooltip">
      <strong>{Map.get(@ap, :ssid) || "Hidden SSID"}</strong>
      <span>{Map.get(@ap, :bssid) || "unknown BSSID"}</span>
      <span>
        {format_ap_rssi(Map.get(@ap, :strongest_rssi))} dBm - ch {format_ap_channel(@ap)} - {format_marker_count(
          Map.get(@ap, :sample_count, 0)
        )} samples
      </span>
      <span>
        {format_marker_percent((Map.get(@ap, :confidence) || 0.0) * 100)} placement confidence
      </span>
      <span :if={Map.get(@ap, :device_uid)} class="sr-ops-field-survey-ap-device">
        {fieldsurvey_ap_device_label(@ap)}
      </span>
    </span>
    """
  end

  defp fieldsurvey_raster_cell_style(%{x_pct: x, z_pct: z, radius_pct: radius, rssi: rssi, confidence: confidence})
       when is_number(x) and is_number(z) do
    diameter = max((radius || 1.0) * 3.0, 2.8)
    opacity = 0.16 + min(max((confidence || 0.0) * 1.0, 0.0), 1.0) * 0.34
    color = fieldsurvey_rssi_color(rssi || -95)

    "left: calc(#{Float.round(x, 3)}% - #{Float.round(diameter / 2, 3)}%); top: calc(#{Float.round(z, 3)}% - #{Float.round(diameter / 2, 3)}%); width: #{Float.round(diameter, 3)}%; height: #{Float.round(diameter, 3)}%; background: radial-gradient(circle, #{color} 0%, #{color} 62%, transparent 88%); opacity: #{Float.round(opacity, 3)};"
  end

  defp fieldsurvey_raster_cell_style(_cell), do: nil

  defp fieldsurvey_rssi_color(rssi) when is_number(rssi) and rssi >= -55, do: "#5fd38a"
  defp fieldsurvey_rssi_color(rssi) when is_number(rssi) and rssi >= -65, do: "#8bd94f"
  defp fieldsurvey_rssi_color(rssi) when is_number(rssi) and rssi >= -75, do: "#ffd25a"
  defp fieldsurvey_rssi_color(rssi) when is_number(rssi) and rssi >= -82, do: "#ff7d3f"
  defp fieldsurvey_rssi_color(_rssi), do: "#ef4444"

  defp fieldsurvey_ap_marker_title(ap) do
    ssid = Map.get(ap, :ssid) || "Hidden"
    bssid = Map.get(ap, :bssid) || "unknown BSSID"
    rssi = Map.get(ap, :strongest_rssi)
    samples = Map.get(ap, :sample_count, 0)

    "#{ssid} #{bssid}: strongest #{format_ap_rssi(rssi)} dBm, #{samples} samples"
  end

  defp format_ap_rssi(rssi) when is_number(rssi), do: rssi |> Kernel.*(1.0) |> Float.round(1) |> to_string()

  defp format_ap_rssi(_rssi), do: "unknown"

  defp format_marker_count(value) when is_integer(value), do: Integer.to_string(value)

  defp format_marker_count(value) when is_number(value), do: value |> round() |> Integer.to_string()

  defp format_marker_count(_value), do: "0"

  defp format_marker_percent(value) when is_number(value) do
    "#{(value * 1.0) |> Float.round(0) |> trunc()}%"
  end

  defp format_marker_percent(_value), do: "0%"

  defp format_ap_channel(%{channel: channel, frequency_mhz: frequency}) when is_number(channel) and is_number(frequency),
    do: "#{channel} / #{frequency} MHz"

  defp format_ap_channel(%{channel: channel}) when is_number(channel), do: to_string(channel)

  defp format_ap_channel(%{frequency_mhz: frequency}) when is_number(frequency), do: "#{frequency} MHz"

  defp format_ap_channel(_ap), do: "unknown"

  defp fieldsurvey_ap_device_label(ap) do
    [Map.get(ap, :device_name), Map.get(ap, :device_vendor), Map.get(ap, :device_model)]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> case do
      [] -> "Open matched device"
      parts -> "Open " <> Enum.join(parts, " ")
    end
  end
end
