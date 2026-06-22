defmodule ServiceRadarWebNGWeb.DashboardLive.Index.ThreatPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DashboardLive.Index.Common

  alias ServiceRadarWebNGWeb.DashboardLive.Index.Common

  attr(:dashboard, :map, required: true)

  def render(%{dashboard: dashboard} = assigns) do
    assigns = Map.merge(assigns, dashboard)

    ~H"""
    <Common.panel title="Threat Intel" class="lg:col-span-4">
      <:actions>
        <.link href={~p"/settings/networks/threat-intel"} class="sr-ops-button">
          Manage
        </.link>
      </:actions>
      <.link
        href={~p"/settings/networks/threat-intel"}
        class="sr-ops-threat-intel sr-ops-threat-intel-link"
        data-testid="threat-intel-summary"
        aria-label="Open Threat Intel settings and match details"
      >
        <div class="sr-ops-threat-sync">
          <span class={[
            "sr-ops-threat-status",
            threat_status_class(@threat_intel_summary.latest_status)
          ]}>
            {threat_status_label(@threat_intel_summary.latest_status)}
          </span>
          <div>
            <strong>{threat_source_label(@threat_intel_summary)}</strong>
            <small>{threat_sync_label(@threat_intel_summary)}</small>
          </div>
        </div>

        <div class="sr-ops-threat-stat-grid">
          <Common.small_stat
            label="IOCs"
            value={format_compact_count(@threat_intel_summary.imported_indicators)}
          />
          <Common.small_stat
            label="Objects"
            value={format_compact_count(@threat_intel_summary.source_objects)}
          />
          <Common.small_stat
            label="Matched IPs"
            value={format_compact_count(@threat_intel_summary.matched_ips)}
          />
          <Common.small_stat
            label="IOC Hits"
            value={format_compact_count(@threat_intel_summary.indicator_matches)}
          />
        </div>

        <div class="sr-ops-threat-detail">
          <span>Max severity</span>
          <strong>{@threat_intel_summary.max_severity}</strong>
        </div>
        <div class="sr-ops-threat-message">
          {threat_message(@threat_intel_summary)}
        </div>
      </.link>
    </Common.panel>
    """
  end

  defp threat_status_label(nil), do: "idle"
  defp threat_status_label(""), do: "idle"
  defp threat_status_label("ok"), do: "ok"
  defp threat_status_label(status) when is_binary(status), do: String.downcase(status)
  defp threat_status_label(_), do: "idle"

  defp threat_status_class("ok"), do: "is-ok"
  defp threat_status_class("error"), do: "is-error"
  defp threat_status_class("failed"), do: "is-error"
  defp threat_status_class("timeout"), do: "is-warning"
  defp threat_status_class(_), do: "is-idle"

  defp threat_source_label(%{latest_provider: provider, latest_source: source}) do
    [provider, source]
    |> Enum.filter(&present_text?/1)
    |> Enum.join(" / ")
    |> case do
      "" -> "No feed sync yet"
      label -> label
    end
  end

  defp threat_source_label(_), do: "No feed sync yet"

  defp threat_sync_label(%{latest_success_label: label}) when is_binary(label) and label != "",
    do: "Last success #{label} UTC"

  defp threat_sync_label(%{latest_attempt_label: label}) when is_binary(label) and label != "",
    do: "Last attempt #{label} UTC"

  defp threat_sync_label(_), do: "Waiting for OTX sync"

  defp threat_message(%{latest_message: message}) when is_binary(message) and message != "", do: message

  defp threat_message(%{imported_indicators: count}) when count > 0, do: "Indicators are ready for NetFlow matching."

  defp threat_message(_), do: "Assign the OTX plugin and sync to populate threat context."

  defp present_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_text?(_), do: false
end
