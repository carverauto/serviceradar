defmodule ServiceRadarWebNGWeb.DashboardLive.Index.VulnerableAssetsPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.DashboardLive.Index.Common

  attr(:dashboard, :map, required: true)

  def render(%{dashboard: dashboard} = assigns) do
    assigns =
      assigns
      |> Map.merge(dashboard)
      |> Map.put(:vulnerable_assets, dashboard[:vulnerable_assets] || [])

    ~H"""
    <Common.panel title="Top Vulnerable Assets">
      <:actions>
        <.link href="/devices" class="sr-ops-button">
          View All Assets
        </.link>
      </:actions>

      <div
        :if={@vulnerable_assets == []}
        class="sr-ops-feed-empty"
        data-testid="vulnerable-assets-empty"
      >
        <.icon name="hero-shield-exclamation" class="size-7 text-warning" />
        <p>No scored assets yet</p>
        <span>
          Risk scores appear after endpoint inventory matching or a risk assessment run.
        </span>
      </div>

      <div :if={@vulnerable_assets != []} class="sr-ops-vuln-assets" data-testid="vulnerable-assets">
        <table class={ui_table_class(size: "xs", fixed: true, class: "w-full")}>
          <colgroup>
            <col class="sr-ops-vuln-col-asset" />
            <col class="sr-ops-vuln-col-type" />
            <col class="sr-ops-vuln-col-score" />
            <col class="sr-ops-vuln-col-status" />
          </colgroup>
          <thead>
            <tr>
              <th>Asset</th>
              <th>Type</th>
              <th>Risk</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={asset <- @vulnerable_assets}>
              <td>
                <.link
                  href={asset.href}
                  class="sr-ops-vuln-asset-link"
                  title={asset.name}
                  aria-label={"Open software inventory for #{asset.name}"}
                >
                  {asset.name}
                </.link>
              </td>
              <td class="sr-ops-vuln-type">{asset.type}</td>
              <td>
                <div class="sr-ops-vuln-score">
                  <span class="sr-ops-vuln-score-value">{asset.risk_score}</span>
                  <span
                    class={["sr-ops-vuln-bar", tone_class(asset.risk_level)]}
                    style={"--sr-ops-vuln: #{asset.risk_score}%"}
                    aria-hidden="true"
                  >
                    <i></i>
                  </span>
                </div>
              </td>
              <td>
                <.ui_badge variant={badge_variant_for(asset.risk_level)} size="xs">
                  {asset.risk_level}
                </.ui_badge>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Common.panel>
    """
  end

  defp tone_class(level) do
    case level |> to_string() |> String.downcase() do
      "critical" -> "is-critical"
      "high" -> "is-high"
      "medium" -> "is-medium"
      "low" -> "is-low"
      _ -> "is-neutral"
    end
  end
end
