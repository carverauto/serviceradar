defmodule ServiceRadarWebNGWeb.DashboardLive.Index.MetricsPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.DashboardLive.Index.Common

  attr(:dashboard, :map, required: true)
  attr(:embedded, :boolean, default: false)

  def render(%{dashboard: dashboard} = assigns) do
    assigns =
      assigns
      |> Map.merge(dashboard)
      |> Map.put_new(:observability_metrics, [])

    ~H"""
    <Common.panel :if={!@embedded} title="Observability Metrics">
      <.metrics_grid observability_metrics={@observability_metrics} />
    </Common.panel>

    <.metrics_grid :if={@embedded} observability_metrics={@observability_metrics} />
    """
  end

  attr(:observability_metrics, :list, required: true)

  defp metrics_grid(assigns) do
    ~H"""
    <div class="sr-ops-metric-grid">
      <.link
        :for={metric <- @observability_metrics}
        href={metric.href}
        class={[
          "sr-ops-metric-card",
          "sr-ops-metric-card-link",
          "tone-#{metric.tone}",
          if(metric.available, do: nil, else: "is-empty")
        ]}
        aria-label={metric.aria_label}
      >
        <span>{metric.label}</span>
        <div class="sr-ops-metric-value-row">
          <strong>{metric.value}</strong>
          <small :if={metric.scale != ""}>{metric.scale}</small>
        </div>
        <div class="sr-ops-metric-sparkline-wrap">
          <span class="sr-ops-metric-axis sr-ops-metric-axis-top">{metric.axis_max}</span>
          <span class="sr-ops-metric-axis sr-ops-metric-axis-mid">{metric.axis_mid}</span>
          <span class="sr-ops-metric-axis sr-ops-metric-axis-bottom">{metric.axis_min}</span>
          <Common.sparkline
            values={metric.sparkline}
            tone={metric.tone}
            class="sr-ops-metric-sparkline"
          />
        </div>
      </.link>
    </div>
    """
  end
end
