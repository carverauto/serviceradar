defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.View.FlowsPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.NetflowLive.Visualize.Params, only: [nf_param: 1]

  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View.FlowsTable

  attr(:visualize, :map, required: true)

  def render(%{visualize: visualize} = assigns) do
    assigns = Map.merge(assigns, visualize)

    ~H"""
    <div class="sr-ui-card bg-sr-surface border border-sr-line">
      <div class="sr-ui-card-body gap-3">
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-baseline gap-2 min-w-0">
            <div class="text-sm font-semibold">Flows</div>
            <div
              :if={is_binary(@flows_window_label) and String.trim(@flows_window_label) != ""}
              class="text-[11px] text-sr-muted font-mono truncate"
              title={@flows_window_label}
            >
              {@flows_window_label}
            </div>
          </div>
          <div class="text-[11px] text-sr-muted font-mono">
            limit:{@limit}
          </div>
        </div>

        <FlowsTable.render
          flows={@flows}
          rdns_map={@rdns_map}
          geo_iso2_map={@geo_iso2_map}
          base_path="/observability/flows"
          query={Map.get(@srql, :query) || ""}
          limit={@limit}
          nf_param={nf_param(@netflow_viz_state)}
          unit_mode={Map.get(@netflow_viz_state, "units", "Bps")}
        />

        <div class="pt-3 border-t border-sr-line">
          <.ui_pagination
            prev_cursor={Map.get(@flows_pagination, "prev_cursor")}
            next_cursor={Map.get(@flows_pagination, "next_cursor")}
            limit={@limit}
            current_page={Map.get(assigns, :pagination_page, 1)}
            result_count={length(@flows || [])}
          />
        </div>
      </div>
    </div>
    """
  end
end
