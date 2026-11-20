defmodule ServiceRadarWebNGWeb.DashboardLive.Index.RumPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.DashboardLive.Index.Common

  attr(:dashboard, :map, required: true)

  def render(%{dashboard: dashboard} = assigns) do
    rum_summary = Map.get(dashboard, :rum_summary) || %{enabled_properties: 0}
    assigns = assign(assigns, :rum_summary, rum_summary)

    ~H"""
    <section
      :if={@rum_summary.enabled_properties > 0}
      class="sr-ops-grid-alerts"
      aria-label="Web RUM summary"
      data-testid="dashboard-rum-panel"
    >
      <Common.panel title="Web RUM (Last 24h)">
        <:actions>
          <.link navigate={~p"/websites"} class="sr-ops-button">
            Websites ({@rum_summary.enabled_properties})
          </.link>
          <.link navigate={~p"/dashboards/web-rum"} class="sr-ops-button">
            Open Web RUM
          </.link>
        </:actions>
        <div class="grid grid-cols-2 gap-3 p-4 sm:grid-cols-5">
          <div class="rounded-lg border border-sr-line/70 bg-sr-surface/50 px-3 py-2.5">
            <div class="text-[11px] font-medium uppercase tracking-wide text-sr-muted">
              Beacons (24h)
            </div>
            <div class="mt-1 font-mono text-lg font-semibold text-sr-ink">
              {@rum_summary.beacons}
            </div>
          </div>
          <div class="rounded-lg border border-sr-line/70 bg-sr-surface/50 px-3 py-2.5">
            <div class="text-[11px] font-medium uppercase tracking-wide text-sr-muted">
              LCP (p75)
            </div>
            <div class="mt-1 font-mono text-lg font-semibold text-sr-ink">
              {format_ms(@rum_summary.p75_lcp_ms)}
            </div>
          </div>
          <div class="rounded-lg border border-sr-line/70 bg-sr-surface/50 px-3 py-2.5">
            <div class="text-[11px] font-medium uppercase tracking-wide text-sr-muted">
              INP (p75)
            </div>
            <div class="mt-1 font-mono text-lg font-semibold text-sr-ink">
              {format_ms(@rum_summary.p75_inp_ms)}
            </div>
          </div>
          <div class="rounded-lg border border-sr-line/70 bg-sr-surface/50 px-3 py-2.5">
            <div class="text-[11px] font-medium uppercase tracking-wide text-sr-muted">
              CLS (p75)
            </div>
            <div class="mt-1 font-mono text-lg font-semibold text-sr-ink">
              {format_cls(@rum_summary.p75_cls)}
            </div>
          </div>
          <div class="rounded-lg border border-sr-line/70 bg-sr-surface/50 px-3 py-2.5">
            <div class="text-[11px] font-medium uppercase tracking-wide text-sr-muted">
              TTFB (p75)
            </div>
            <div class="mt-1 font-mono text-lg font-semibold text-sr-ink">
              {format_ms(@rum_summary.p75_ttfb_ms)}
            </div>
          </div>
        </div>
        <div
          :if={@rum_summary.properties != []}
          class="flex flex-wrap items-center gap-2 border-t border-sr-line/60 px-4 py-2.5 text-xs text-sr-muted"
        >
          <span class="font-medium text-sr-ink">Monitored sites:</span>
          <.link
            :for={prop <- @rum_summary.properties}
            navigate={~p"/websites/#{prop.id}"}
            class="inline-flex items-center gap-1.5 rounded-full border border-sr-line bg-sr-subtle/50 px-2.5 py-0.5 font-mono text-xs text-sr-ink hover:border-sr-brand"
          >
            <span>{prop.name}</span>
            <span class="text-sr-muted">{prop.canonical_origin}</span>
          </.link>
        </div>
      </Common.panel>
    </section>
    """
  end

  defp format_ms(val) when is_number(val), do: "#{round(val)} ms"
  defp format_ms(_), do: "—"

  defp format_cls(val) when is_number(val), do: :erlang.float_to_binary(val * 1.0, decimals: 2)
  defp format_cls(_), do: "—"
end
