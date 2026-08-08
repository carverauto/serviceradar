defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.ChartData
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.Config
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.Events
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowContext
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowList
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.Params
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.QueryState
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View
  alias ServiceRadarWebNGWeb.NetflowVisualize.State, as: NFState
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:active_tab, "netflows")
      |> assign(:netflow_viz_state, NFState.default())
      |> assign(:netflow_viz_state_error, nil)
      |> assign(:netflow_chart_keys_json, "[]")
      |> assign(:netflow_chart_points_json, "[]")
      |> assign(:netflow_chart_colors_json, "{}")
      |> assign(:netflow_chart_overlays_json, "[]")
      |> assign(:netflow_chart_empty_state, nil)
      |> assign(:netflow_sankey_edges_json, "[]")
      |> assign(:nf_dims_ordered, Config.nf_dims_ordered())
      |> assign(:sankey_src_dims, Config.sankey_src_dims())
      |> assign(:sankey_mid_dims, Config.sankey_mid_dims())
      |> assign(:sankey_dst_dims, Config.sankey_dst_dims())
      |> assign(:limit, Config.default_limit())
      |> assign(:selected_flow, nil)
      |> assign(:selected_flow_context, %{})
      |> assign(:arin_lookup, %{})
      |> assign(:flows, [])
      |> assign(:flows_pagination, %{})
      |> assign(:rdns_map, %{})
      |> assign(:geo_iso2_map, %{})
      |> assign(:flows_window_label, nil)
      |> SRQLPage.init("flows", default_limit: Config.default_limit())

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    state_param = Map.get(params, "nf")

    {state, state_error} =
      case NFState.decode_param(state_param) do
        {:ok, st} -> {st, nil}
        {:error, reason} -> {NFState.default(), reason}
      end

    state = QueryState.normalize_state_for_graph(state)
    q_param = params |> Map.get("q") |> Params.normalize_optional_string()

    socket =
      socket
      |> assign(:netflow_viz_state, state)
      |> assign(:netflow_viz_state_error, state_error)

    if is_nil(q_param) do
      chart_query = QueryState.chart_query_from_state("in:flows", state)

      {:noreply,
       push_patch(socket,
         to:
           Params.build_patch_url(socket, %{
             "q" => chart_query,
             "nf" => Params.nf_param(state)
           })
       )}
    else
      socket =
        socket
        |> FlowList.load_srql_assigns(q_param, uri, Params.parse_limit_param(Map.get(params, "limit")))
        |> ChartData.load_visualize_chart(q_param, state)
        |> FlowList.load_flows_list(params, state)
        |> FlowContext.maybe_open_flow_from_params(params)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event(event, params, socket), do: Events.handle_event(event, params, socket)

  @impl true
  def render(assigns), do: View.render(assigns)
end
