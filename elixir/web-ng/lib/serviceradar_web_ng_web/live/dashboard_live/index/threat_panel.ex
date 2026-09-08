defmodule ServiceRadarWebNGWeb.DashboardLive.Index.ThreatPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DashboardLive.Index.Common

  alias ServiceRadarWebNGWeb.DashboardLive.Index.Common
  alias ServiceRadarWebNGWeb.Observability.ThreatIntelLinks

  @visible_match_limit 3

  attr(:dashboard, :map, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

  def render(%{dashboard: dashboard} = assigns) do
    summary = dashboard[:threat_intel_summary] || dashboard["threat_intel_summary"]
    {visible_matches, hidden_match_count} = visible_matches(summary)

    assigns =
      assigns
      |> Map.merge(dashboard)
      |> Map.put(:recent_matches, visible_matches)
      |> Map.put(:hidden_match_count, hidden_match_count)

    ~H"""
    <Common.panel title="Threat Intel">
      <:actions>
        <.link href={ThreatIntelLinks.settings_path()} class="sr-ops-button">
          Manage
        </.link>
      </:actions>
      <div class="sr-ops-threat-intel" data-testid="threat-intel-summary">
        <div class="sr-ops-threat-toolbar">
          <.link
            href={ThreatIntelLinks.investigation_path()}
            class="sr-ops-threat-sync sr-ops-threat-sync-link"
            aria-label="Open Threat Intel investigation"
          >
            <span class={[
              "sr-ops-threat-status",
              threat_status_class(@threat_intel_summary.latest_status)
            ]}>
              {threat_status_label(@threat_intel_summary.latest_status)}
            </span>
            <div class="sr-ops-threat-sync-copy">
              <strong>{threat_source_label(@threat_intel_summary)}</strong>
              <%= if sync = threat_sync(@threat_intel_summary) do %>
                <small>
                  {sync.label}
                  <.user_time
                    id={"dashboard-threat-#{sync.kind}-at"}
                    value={sync.value}
                    timezone={@timezone}
                    style={:compact}
                  />
                </small>
              <% else %>
                <small>Waiting for OTX sync</small>
              <% end %>
            </div>
          </.link>

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
              label="Indicator matches"
              value={format_compact_count(@threat_intel_summary.indicator_matches)}
            />
            <Common.small_stat
              label="Max sev"
              value={format_compact_count(@threat_intel_summary.max_severity)}
            />
          </div>
        </div>

        <div
          id="threat-intel-matches"
          class="sr-ops-threat-matches"
          data-testid="threat-intel-matches"
        >
          <div :if={@recent_matches == []} class="sr-ops-threat-matches-empty">
            <span>No current NetFlow IOC matches.</span>
            <span class="sr-ops-threat-message">{threat_message(@threat_intel_summary)}</span>
          </div>
          <div :for={match <- @recent_matches} class="sr-ops-threat-match">
            <span class="sr-ops-threat-match-ip">{match.ip}</span>
            <span class="sr-ops-threat-match-meta">
              <span :if={match_meta_label(match) != ""}>{match_meta_label(match)} · </span>
              <.user_time
                :if={match_seen_at(match)}
                id={"dashboard-threat-match-#{time_id_part(match.ip)}-looked-up-at"}
                value={match_seen_at(match)}
                timezone={@timezone}
                style={:compact}
              />
            </span>
            <div class="sr-ops-threat-match-links">
              <.link
                href={ThreatIntelLinks.device_path(match.ip, match.device_uid)}
                class="link link-hover"
                aria-label={"Open inventory for #{match.ip}"}
              >
                {if match.device_uid, do: "Device", else: "Inventory"}
              </.link>
              <.link
                href={ThreatIntelLinks.netflow_path(match.ip)}
                class="link link-hover"
                aria-label={"Open NetFlow for #{match.ip}"}
              >
                Flows
              </.link>
            </div>
          </div>
          <div :if={@hidden_match_count > 0} class="sr-ops-threat-matches-more">
            +{@hidden_match_count} more matched IPs
          </div>
        </div>
      </div>
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

  defp threat_sync(%{latest_success_at: value}) when not is_nil(value),
    do: %{kind: "last-success", label: "Last success", value: value}

  defp threat_sync(%{latest_attempt_at: value}) when not is_nil(value),
    do: %{kind: "last-attempt", label: "Last attempt", value: value}

  defp threat_sync(_), do: nil

  defp threat_message(%{latest_message: message}) when is_binary(message) and message != "", do: message

  defp threat_message(%{imported_indicators: count}) when count > 0, do: "Indicators are ready for NetFlow matching."

  defp threat_message(_), do: "Assign the OTX plugin and sync to populate threat context."

  defp present_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_text?(_), do: false

  defp visible_matches(summary) do
    matches = recent_matches(summary)
    {Enum.take(matches, @visible_match_limit), max(length(matches) - @visible_match_limit, 0)}
  end

  defp recent_matches(%{recent_matches: matches}) when is_list(matches), do: matches
  defp recent_matches(_summary), do: []

  defp match_meta_label(match) when is_map(match) do
    [
      match_host_label(match),
      match_hits_label(match)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
  end

  defp match_meta_label(_match), do: ""

  defp match_host_label(%{hostname: hostname}) when is_binary(hostname) and hostname != "", do: hostname
  defp match_host_label(_match), do: ""

  defp match_hits_label(%{match_count: count}) when is_integer(count) and count > 0, do: "#{count} hits"
  defp match_hits_label(_match), do: ""

  defp match_seen_at(%{looked_up_at: value}) when not is_nil(value), do: value
  defp match_seen_at(_match), do: nil

  defp time_id_part(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    |> String.trim("-")
  end
end
