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
    <Common.panel title="Top Vulnerable Assets" class="lg:col-span-4">
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
          Scores come from endpoint inventory on a native agent host. Kubernetes
          agents skip ScaLibr; a failed systemd unit on a VM host also leaves this empty.
        </span>
      </div>

      <div :if={@vulnerable_assets != []} class="overflow-x-auto" data-testid="vulnerable-assets">
        <table class="table table-xs">
          <thead>
            <tr>
              <th>Asset</th>
              <th>Type</th>
              <th>Risk Score</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={asset <- @vulnerable_assets}>
              <td class="max-w-36">
                <.link
                  href={asset.href}
                  class="link link-hover font-medium truncate block"
                  aria-label={"Open #{asset.name}"}
                >
                  {asset.name}
                </.link>
              </td>
              <td class="text-base-content/70">{asset.type}</td>
              <td class="font-mono tabular-nums">{asset.risk_score}</td>
              <td class="min-w-28">
                <div class="flex items-center gap-2">
                  <progress
                    class={["progress w-16", progress_class(asset.risk_level)]}
                    value={asset.risk_score}
                    max="100"
                    aria-label={"#{asset.risk_level} risk"}
                  ></progress>
                  <span class={["badge badge-sm badge-soft", badge_class(asset.risk_level)]}>
                    {asset.risk_level}
                  </span>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Common.panel>
    """
  end

  defp progress_class(level), do: tone_class(level, "progress")
  defp badge_class(level), do: tone_class(level, "badge")

  defp tone_class(level, prefix) do
    case level |> to_string() |> String.downcase() do
      "critical" -> "#{prefix}-error"
      "high" -> "#{prefix}-warning"
      "medium" -> "#{prefix}-info"
      "low" -> "#{prefix}-success"
      _ -> "#{prefix}-neutral"
    end
  end
end
