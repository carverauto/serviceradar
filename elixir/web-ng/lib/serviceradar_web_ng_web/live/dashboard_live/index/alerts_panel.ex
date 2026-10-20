defmodule ServiceRadarWebNGWeb.DashboardLive.Index.AlertsPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.DashboardLive.Index.Common

  attr(:dashboard, :map, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

  def render(%{dashboard: dashboard} = assigns) do
    assigns =
      assigns
      |> Map.merge(dashboard)
      |> assign(:alert_evaluation_active?, dashboard.alert_evaluation_mode == :active)

    ~H"""
    <Common.panel title="Alerts Feed">
      <:actions>
        <.link href={~p"/observability/alerts"} class="sr-ops-button">
          View All Alerts
        </.link>
      </:actions>
      <.link
        :if={@alert_feed == [] and @alert_evaluation_active?}
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
      <.link
        :if={@alert_feed == [] and not @alert_evaluation_active?}
        href={~p"/settings/rules?#{%{tab: "alerts"}}"}
        class="sr-ops-feed-empty is-alert-feed"
        data-testid="alerts-feed-not-activated"
        aria-label="Alert evaluation not activated"
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
          <.icon name="hero-exclamation-triangle" class="size-7 text-amber-400" />
          <p>Alert evaluation is not activated ({@alert_evaluation_mode})</p>
          <span>
            Set <code>core.alertEvaluation.mode=active</code> to evaluate alert rules.
          </span>
        </div>
      </.link>
      <.link
        :if={@alert_feed != [] and not @alert_evaluation_active?}
        href={~p"/settings/rules?#{%{tab: "alerts"}}"}
        class="mb-2 flex items-center gap-2 rounded-sr-surface border border-amber-500/30 bg-amber-500/10 px-3 py-2 text-xs text-amber-800 dark:text-amber-200"
        data-testid="alerts-feed-not-activated-notice"
      >
        <.icon name="hero-exclamation-triangle" class="size-4 shrink-0 text-amber-500" />
        <span>
          Alert evaluation is not activated ({@alert_evaluation_mode}). Showing retained alerts only; set
          <code>core.alertEvaluation.mode=active</code>
          to evaluate alert rules.
        </span>
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
