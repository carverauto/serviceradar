defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.View.FlowsPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.NetflowLive.Visualize.Params, only: [nf_param: 1]

  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View.FlowsTable

  attr(:visualize, :map, required: true)

  def render(%{visualize: visualize} = assigns) do
    assigns =
      assigns
      |> Map.merge(visualize)
      |> assign_window_parts()

    ~H"""
    <div class="sr-ui-card bg-sr-surface border border-sr-line">
      <div class="sr-ui-card-body gap-3">
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-baseline gap-2 min-w-0">
            <div class="text-sm font-semibold">Flows</div>
            <div
              :if={not is_nil(@window_start) and not is_nil(@window_end)}
              class="text-[11px] text-sr-muted font-mono truncate"
            >
              <.user_time
                id="netflow-window-start"
                value={@window_start}
                timezone={@timezone}
                style={:compact}
              />
              <span aria-hidden="true"> – </span>
              <.user_time
                id="netflow-window-end"
                value={@window_end}
                timezone={@timezone}
                style={:compact}
              />
            </div>
            <div
              :if={is_binary(@window_label) and String.trim(@window_label) != ""}
              class="text-[11px] text-sr-muted font-mono truncate"
              title={@window_label}
            >
              {@window_label}
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
          timezone={@timezone}
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

  defp assign_window_parts(assigns) do
    case Map.get(assigns, :flows_window) do
      %{type: :absolute, start: start_dt, end: end_dt} ->
        Map.merge(assigns, %{window_start: start_dt, window_end: end_dt, window_label: nil})

      %{type: :relative, label: label} ->
        Map.merge(assigns, %{window_start: nil, window_end: nil, window_label: label})

      _ ->
        Map.merge(assigns, %{window_start: nil, window_end: nil, window_label: nil})
    end
  end
end
