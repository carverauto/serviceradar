defmodule ServiceRadarWebNGWeb.DashboardLive.Index.AlertsPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.DashboardLive.Index.Common

  attr(:dashboard, :map, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

  def render(%{dashboard: dashboard} = assigns) do
    assigns = Map.merge(assigns, dashboard)

    ~H"""
    <Common.panel title="Alerts Feed">
      <:actions>
        <.link href={~p"/observability/alerts"} class="sr-ops-button">
          View All Alerts
        </.link>
      </:actions>
      <.link
        :if={@alert_feed == []}
        href={~p"/observability/alerts"}
        class="sr-ops-feed-empty is-alert-feed"
        data-testid="alerts-feed-empty"
        aria-label="Open alerts"
      >
        <div class="sr-ops-empty-feed-shell" aria-hidden="true">
          <div class="sr-ops-empty-feed-header">
            <span>Time</span>
            <span>Alert</span>
            <span>Status</span>
          </div>
          <span :for={_ <- 1..5} class="sr-ops-empty-feed-row"></span>
        </div>
        <div class="sr-ops-empty-feed-message">
          <.icon name="hero-bell-alert" class="size-7 text-rose-400" />
          <p>No alerts in the last 24 hours</p>
          <span>Older retained alerts are still available in the alert stream.</span>
        </div>
      </.link>
      <div :if={@alert_feed != []} class="sr-ops-alert-feed" data-testid="alerts-feed">
        <.link
          :for={alert <- @alert_feed}
          href={~p"/alerts/#{alert.id}"}
          class="sr-ops-alert-row"
        >
          <span class={["sr-ops-alert-severity", alert_severity_class(alert.severity)]}>
            {alert_severity_label(alert.severity)}
          </span>
          <span class="sr-ops-alert-main">
            <strong>{alert.title}</strong>
            <small>{alert_subtitle(alert)}</small>
          </span>
          <span class="sr-ops-alert-meta">
            <em>{alert_status_label(alert.status)}</em>
            <.user_time
              id={"dashboard-alert-#{alert.id}-observed-at"}
              value={alert.observed_at}
              timezone={@timezone}
              style={:time}
            />
          </span>
        </.link>
      </div>
    </Common.panel>
    """
  end

  defp alert_severity_class(value) do
    case value |> to_string() |> String.downcase() do
      severity when severity in ["critical", "emergency"] -> "is-critical"
      "warning" -> "is-warning"
      "info" -> "is-info"
      _ -> "is-neutral"
    end
  end

  defp alert_severity_label(value) do
    case value |> to_string() |> String.trim() do
      "" -> "Alert"
      label -> String.capitalize(label)
    end
  end

  defp alert_status_label(value) do
    case value |> to_string() |> String.trim() do
      "" -> "Open"
      label -> label |> String.replace("_", " ") |> String.capitalize()
    end
  end

  defp alert_subtitle(alert) do
    [alert.source_type, alert.device_uid]
    |> Enum.reject(&(is_nil(&1) or to_string(&1) == ""))
    |> Enum.join(" / ")
    |> case do
      "" -> "ServiceRadar alert"
      value -> value
    end
  end
end
