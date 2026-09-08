defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.View.ChartPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.NetflowLive.Visualize.QueryState,
    only: [dim_human_label: 1, dims_from_state: 1, sanitize_sankey_dims: 1]

  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View.EmptyState

  attr(:visualize, :map, required: true)

  def render(%{visualize: visualize} = assigns) do
    assigns = Map.merge(assigns, visualize)

    ~H"""
    <div class="sr-ui-card bg-sr-surface border border-sr-line">
      <div class="sr-ui-card-body gap-3">
        <% chart_empty_state = EmptyState.effective(@srql, @netflow_chart_empty_state) %>

        <div class="flex items-center justify-between gap-3">
          <div class="text-sm font-semibold">Chart</div>
          <div class="text-[11px] text-sr-muted font-mono">
            {Map.get(@netflow_viz_state, "graph")}
          </div>
        </div>

        <EmptyState.render
          :if={is_map(chart_empty_state)}
          state={chart_empty_state}
        />

        <div :if={is_nil(chart_empty_state)} class="h-72 w-full">
          <%= case Map.get(@netflow_viz_state, "graph") do %>
            <% "sankey" -> %>
              <% sankey_dims =
                @netflow_viz_state |> dims_from_state() |> sanitize_sankey_dims() %>
              <% sankey_src_label = dim_human_label(Enum.at(sankey_dims, 0)) %>
              <% sankey_mid_label = dim_human_label(Enum.at(sankey_dims, 1)) %>
              <% sankey_dst_label = dim_human_label(Enum.at(sankey_dims, 2)) %>
              <div class="mb-2 flex items-center gap-3 text-xs text-sr-muted">
                <div class="flex items-center gap-1">
                  <span class="inline-block size-2 rounded" style="background:#60a5fa"></span>
                  <span>{sankey_src_label}</span>
                </div>
                <div class="flex items-center gap-1">
                  <span class="inline-block size-2 rounded" style="background:#a78bfa"></span>
                  <span>{sankey_mid_label}</span>
                </div>
                <div class="flex items-center gap-1">
                  <span class="inline-block size-2 rounded" style="background:#34d399"></span>
                  <span>{sankey_dst_label}</span>
                </div>
              </div>
              <div
                id="netflow-sankey"
                class="w-full h-full"
                phx-hook="NetflowSankeyChart"
                data-edges={@netflow_sankey_edges_json || "[]"}
                data-src-label={sankey_src_label}
                data-mid-label={sankey_mid_label}
                data-dst-label={sankey_dst_label}
              >
                <svg class="w-full h-full"></svg>
              </div>
            <% "stacked100" -> %>
              <div
                id="netflow-stacked100"
                class="w-full h-full"
                phx-hook="NetflowStacked100Chart"
                data-units={Map.get(@netflow_viz_state, "units", "Bps")}
                data-keys={@netflow_chart_keys_json}
                data-points={@netflow_chart_points_json}
                data-colors={@netflow_chart_colors_json}
                data-overlays={@netflow_chart_overlays_json || "[]"}
                data-timezone={@timezone}
              >
                <svg class="w-full h-full"></svg>
              </div>
            <% "lines" -> %>
              <div
                id="netflow-lines"
                class="w-full h-full"
                phx-hook="NetflowLineSeriesChart"
                data-units={Map.get(@netflow_viz_state, "units", "Bps")}
                data-keys={@netflow_chart_keys_json}
                data-points={@netflow_chart_points_json}
                data-colors={@netflow_chart_colors_json}
                data-timezone={@timezone}
              >
                <svg class="w-full h-full"></svg>
              </div>
            <% "grid" -> %>
              <div
                id="netflow-grid"
                class="w-full h-full"
                phx-hook="NetflowGridChart"
                data-units={Map.get(@netflow_viz_state, "units", "Bps")}
                data-keys={@netflow_chart_keys_json}
                data-points={@netflow_chart_points_json}
                data-colors={@netflow_chart_colors_json}
                data-timezone={@timezone}
              >
                <svg class="w-full h-full"></svg>
              </div>
            <% _ -> %>
              <div
                id="netflow-stacked"
                class="w-full h-full"
                phx-hook="NetflowStackedAreaChart"
                data-units={Map.get(@netflow_viz_state, "units", "Bps")}
                data-keys={@netflow_chart_keys_json}
                data-points={@netflow_chart_points_json}
                data-colors={@netflow_chart_colors_json}
                data-overlays={@netflow_chart_overlays_json || "[]"}
                data-timezone={@timezone}
              >
                <svg class="w-full h-full"></svg>
              </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
