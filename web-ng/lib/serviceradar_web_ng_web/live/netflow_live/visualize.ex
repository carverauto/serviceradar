defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize do
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNGWeb.NetflowVisualize.State, as: NFState
  alias ServiceRadarWebNGWeb.NetflowVisualize.Query, as: NFQuery
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage
  alias ServiceRadarWebNGWeb.SRQL.Builder, as: SRQLBuilder
  alias ServiceRadar.Observability.IpRdnsCache

  require Ash.Query

  @default_limit 100
  @max_limit 200
  @default_time "last_1h"
  @default_bucket "5m"
  @chart_limit 4000

  @nf_dims_ordered [
    {"Protocol (group)", "protocol_group"},
    {"Application", "app"},
    {"Dest port", "dst_port"},
    {"Source IP", "src_ip"},
    {"Dest IP", "dst_ip"},
    {"Protocol (name)", "protocol_name"},
    {"Sampler address", "sampler_address"},
    {"Exporter name", "exporter_name"},
    {"In interface", "in_if_name"},
    {"Out interface", "out_if_name"},
    {"Source CIDR (Sankey/stats)", "src_cidr"},
    {"Dest CIDR (Sankey/stats)", "dst_cidr"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:active_tab, "netflow")
      |> assign(:netflow_viz_state, NFState.default())
      |> assign(:netflow_viz_state_error, nil)
      |> assign(:netflow_chart_keys_json, "[]")
      |> assign(:netflow_chart_points_json, "[]")
      |> assign(:netflow_chart_colors_json, "{}")
      |> assign(:netflow_chart_overlays_json, "[]")
      |> assign(:netflow_sankey_edges_json, "[]")
      |> assign(:nf_dims_ordered, @nf_dims_ordered)
      |> assign(:limit, @default_limit)
      |> assign(:selected_flow, nil)
      |> assign(:flows, [])
      |> assign(:flows_pagination, %{})
      |> assign(:rdns_map, %{})
      |> SRQLPage.init("flows", default_limit: @default_limit)

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

    q_param = Map.get(params, "q") |> normalize_optional_string()

    socket =
      socket
      |> assign(:netflow_viz_state, state)
      |> assign(:netflow_viz_state_error, state_error)

    # The Visualize controls emit SRQL. If no `q` is present, patch to the derived chart query.
    if is_nil(q_param) do
      chart_query = chart_query_from_state("in:flows", state)

      {:noreply,
       push_patch(socket,
         to:
           build_patch_url(socket, %{
             "q" => chart_query,
             "nf" => nf_param(state),
             "cursor" => nil,
             "limit" => parse_limit_param(Map.get(params, "limit"))
           })
       )}
    else
      socket =
        socket
        |> load_srql_assigns(q_param, uri, parse_limit_param(Map.get(params, "limit")))
        |> load_visualize_chart(q_param, state)
        |> load_flows_list(params, state)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_submit", params,
       fallback_path: "/netflow",
       extra_params: srql_submit_extra_params(socket)
     )}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_toggle", %{},
       entity: "flows",
       fallback_path: "/netflow"
     )}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_run", %{},
       entity: "flows",
       fallback_path: "/netflow",
       extra_params: srql_submit_extra_params(socket)
     )}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "flows")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "flows")}
  end

  def handle_event("nf_reset", _params, socket) do
    next = NFState.default()
    chart_query = chart_query_from_state("in:flows", next)

    socket = assign(socket, :netflow_viz_state, next)

    {:noreply,
     push_patch(socket,
       to: build_patch_url(socket, %{"nf" => nf_param(next), "q" => chart_query, "cursor" => nil})
     )}
  end

  @impl true
  def handle_event("netflow_open", %{"idx" => idx_raw}, socket) do
    idx =
      case Integer.parse(to_string(idx_raw || "")) do
        {n, ""} when n >= 0 -> n
        _ -> nil
      end

    selected =
      if is_integer(idx) and is_list(socket.assigns.flows) do
        Enum.at(socket.assigns.flows, idx)
      else
        nil
      end

    {:noreply, assign(socket, :selected_flow, selected)}
  end

  def handle_event("netflow_close", _params, socket) do
    {:noreply, assign(socket, :selected_flow, nil)}
  end

  def handle_event("netflow_sankey_edge", %{} = params, socket) do
    src = Map.get(params, "src") |> normalize_optional_string()
    dst = Map.get(params, "dst") |> normalize_optional_string()

    port = parse_optional_port(Map.get(params, "port"))
    mid_field = Map.get(params, "mid_field") |> normalize_optional_string()
    mid_value = Map.get(params, "mid_value") |> normalize_optional_string()

    query = Map.get(socket.assigns.srql, :query) || ""

    new_query =
      query
      |> apply_endpoint_filter(:src, src)
      |> apply_endpoint_filter(:dst, dst)
      |> apply_mid_filter(mid_field, mid_value, port)

    {:noreply, push_patch(socket, to: build_patch_url(socket, %{"q" => new_query}))}
  end

  defp parse_optional_port(nil), do: nil
  defp parse_optional_port(""), do: nil

  defp parse_optional_port(port_raw) do
    case Integer.parse(to_string(port_raw)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp apply_endpoint_filter(query, _side, nil), do: query

  defp apply_endpoint_filter(query, :src, value) when is_binary(value) do
    if String.contains?(value, "/") do
      upsert_query_filter(query, "src_cidr", value)
    else
      upsert_query_filter(query, "src_ip", value)
    end
  end

  defp apply_endpoint_filter(query, :dst, value) when is_binary(value) do
    if String.contains?(value, "/") do
      upsert_query_filter(query, "dst_cidr", value)
    else
      upsert_query_filter(query, "dst_ip", value)
    end
  end

  defp apply_endpoint_filter(query, _side, _value), do: query

  defp apply_mid_filter(query, nil, _mid_value, _port), do: query

  defp apply_mid_filter(query, mid_field, mid_value, port) when is_binary(mid_field) do
    case mid_field do
      f when f in ["dst_port", "dst_endpoint_port"] ->
        cond do
          is_integer(port) -> upsert_query_filter(query, "dst_port", to_string(port))
          is_binary(mid_value) and mid_value != "" -> upsert_query_filter(query, "dst_port", mid_value)
          true -> query
        end

      "app" when is_binary(mid_value) and mid_value != "" ->
        upsert_query_filter(query, "app", mid_value)

      "protocol_group" when is_binary(mid_value) and mid_value != "" ->
        upsert_query_filter(query, "protocol_group", mid_value)

      _ ->
        query
    end
  end

  defp apply_mid_filter(query, _mid_field, _mid_value, _port), do: query

  def handle_event("netflow_stack_series", %{"field" => field, "value" => value}, socket) do
    field = to_string(field || "") |> String.trim()
    value = to_string(value || "") |> String.trim()

    if field in ["app", "protocol_group"] and value != "" do
      query = Map.get(socket.assigns.srql, :query) || ""
      new_query = upsert_query_filter(query, field, value)
      {:noreply, push_patch(socket, to: build_patch_url(socket, %{"q" => new_query}))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("nf_state_change", %{"state" => %{} = incoming}, socket) do
    current = Map.get(socket.assigns, :netflow_viz_state, NFState.default())

    next =
      merge_nf_state(current, incoming)

    next =
      case NFState.encode_param(next) do
        {:ok, encoded} ->
          case NFState.decode_param(encoded) do
            {:ok, normalized} -> normalized
            _ -> current
          end

        _ ->
          current
      end

    socket = assign(socket, :netflow_viz_state, next)

    base = NFQuery.flows_sanitize_for_stats(Map.get(socket.assigns.srql, :query) || "")
    chart_query = chart_query_from_state(base, next)

    {:noreply,
     push_patch(socket,
       to: build_patch_url(socket, %{"nf" => nf_param(next), "q" => chart_query, "cursor" => nil})
     )}
  end

  def handle_event("nf_dim_move", %{"dim" => dim, "dir" => dir}, socket)
      when is_binary(dim) and dir in ["up", "down"] do
    current = Map.get(socket.assigns, :netflow_viz_state, NFState.default())
    dims = current |> Map.get("dims", []) |> List.wrap() |> Enum.map(&to_string/1)
    next_dims = move_dim(dims, dim, dir)
    next = Map.put(current, "dims", next_dims)

    socket = assign(socket, :netflow_viz_state, next)
    base = NFQuery.flows_sanitize_for_stats(Map.get(socket.assigns.srql, :query) || "")
    chart_query = chart_query_from_state(base, next)

    {:noreply,
     push_patch(socket,
       to: build_patch_url(socket, %{"nf" => nf_param(next), "q" => chart_query, "cursor" => nil})
     )}
  end

  def handle_event("nf_dim_remove", %{"dim" => dim}, socket) when is_binary(dim) do
    current = Map.get(socket.assigns, :netflow_viz_state, NFState.default())
    dims = current |> Map.get("dims", []) |> List.wrap() |> Enum.map(&to_string/1)
    next_dims = Enum.reject(dims, &(&1 == dim))
    next = Map.put(current, "dims", next_dims)

    socket = assign(socket, :netflow_viz_state, next)
    base = NFQuery.flows_sanitize_for_stats(Map.get(socket.assigns.srql, :query) || "")
    chart_query = chart_query_from_state(base, next)

    {:noreply,
     push_patch(socket,
       to: build_patch_url(socket, %{"nf" => nf_param(next), "q" => chart_query, "cursor" => nil})
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="px-4 py-4">
        <div class="flex flex-col lg:flex-row gap-4 items-start">
          <aside class="w-full lg:w-80 shrink-0">
            <div class="card bg-base-100 border border-base-200 shadow-sm">
              <div class="card-body gap-3">
                <div class="min-w-0">
                  <div class="text-base font-semibold">NetFlow Visualize</div>
                  <div class="text-xs text-base-content/60">
                    SRQL-driven analytics (preview). Charts and dimensions will expand in follow-up changes.
                  </div>
                </div>

                <div :if={@netflow_viz_state_error} class="alert alert-warning">
                  <div class="text-xs">
                    Invalid `nf` state in URL: <span class="font-mono">{inspect(@netflow_viz_state_error)}</span>.
                    Using defaults.
                  </div>
                </div>

                <div class="grid grid-cols-2 gap-2">
                  <div class="col-span-2">
                    <div class="text-xs font-semibold text-base-content/70 mb-1">Graph</div>
                    <form phx-change="nf_state_change">
                      <select
                        name="state[graph]"
                        class="select select-bordered select-sm w-full font-mono text-xs"
                      >
                        <%= for {label, value} <- [{"Stacked", "stacked"}, {"100% Stacked", "stacked100"}, {"Lines", "lines"}, {"Grid", "grid"}, {"Sankey", "sankey"}] do %>
                          <option
                            value={value}
                            selected={Map.get(@netflow_viz_state, "graph") == value}
                          >
                            {label}
                          </option>
                        <% end %>
                      </select>
                    </form>
                  </div>

                  <div class="col-span-2">
                    <div class="text-xs font-semibold text-base-content/70 mb-1">Dimensions</div>
                    <form phx-change="nf_state_change" class="space-y-2">
                      <select
                        name="state[dims][]"
                        class="select select-bordered select-sm w-full font-mono text-xs h-28"
                        multiple
                      >
                        <%= for {label, value} <- @nf_dims_ordered do %>
                          <option
                            value={value}
                            selected={Enum.member?(Map.get(@netflow_viz_state, "dims", []), value)}
                          >
                            {label}
                          </option>
                        <% end %>
                      </select>

                      <div class="text-[11px] text-base-content/60">
                        Time-series charts use the first selected dimension; Sankey uses up to the first 3.
                        Exporter/interface dimensions may appear as
                        <span class="font-mono">Unknown</span>
                        until the NetFlow cache refresh job populates metadata.
                      </div>
                    </form>

                    <div
                      :if={length(Map.get(@netflow_viz_state, "dims", [])) > 0}
                      class="mt-2 space-y-1"
                    >
                      <div class="text-[11px] text-base-content/60">Order</div>
                      <div class="space-y-1">
                        <%= for dim <- Map.get(@netflow_viz_state, "dims", []) do %>
                          <div class="flex items-center gap-2">
                            <div class="badge badge-ghost font-mono text-[11px]">{dim}</div>
                            <button
                              type="button"
                              class="btn btn-xs btn-ghost"
                              phx-click="nf_dim_move"
                              phx-value-dim={dim}
                              phx-value-dir="up"
                            >
                              Up
                            </button>
                            <button
                              type="button"
                              class="btn btn-xs btn-ghost"
                              phx-click="nf_dim_move"
                              phx-value-dim={dim}
                              phx-value-dir="down"
                            >
                              Down
                            </button>
                            <button
                              type="button"
                              class="btn btn-xs btn-ghost text-error"
                              phx-click="nf_dim_remove"
                              phx-value-dim={dim}
                            >
                              Remove
                            </button>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  </div>

                  <div class="col-span-2">
                    <div class="text-xs font-semibold text-base-content/70 mb-1">Units</div>
                    <form phx-change="nf_state_change">
                      <select
                        name="state[units]"
                        class="select select-bordered select-sm w-full font-mono text-xs"
                      >
                        <%= for {label, value} <- [{"Bytes/sec (Bps)", "Bps"}, {"Bits/sec (bps)", "bps"}, {"Packets/sec (pps)", "pps"}] do %>
                          <option
                            value={value}
                            selected={Map.get(@netflow_viz_state, "units") == value}
                          >
                            {label}
                          </option>
                        <% end %>
                      </select>
                    </form>
                  </div>

                  <div class="col-span-2">
                    <div class="text-xs font-semibold text-base-content/70 mb-1">Top-N</div>
                    <form phx-change="nf_state_change" class="grid grid-cols-2 gap-2">
                      <input
                        type="number"
                        min="1"
                        max="50"
                        name="state[limit]"
                        value={Map.get(@netflow_viz_state, "limit")}
                        class="input input-bordered input-sm w-full font-mono text-xs"
                      />

                      <select
                        name="state[limit_type]"
                        class="select select-bordered select-sm w-full font-mono text-xs"
                      >
                        <%= for {label, value} <- [{"avg", "avg"}, {"max", "max"}, {"last", "last"}] do %>
                          <option
                            value={value}
                            selected={Map.get(@netflow_viz_state, "limit_type") == value}
                          >
                            {label}
                          </option>
                        <% end %>
                      </select>
                    </form>
                  </div>

                  <div class="col-span-2">
                    <div class="text-xs font-semibold text-base-content/70 mb-1">Truncate</div>
                    <form phx-change="nf_state_change" class="grid grid-cols-2 gap-2">
                      <div class="space-y-1">
                        <div class="text-[11px] text-base-content/60">IPv4 prefix bits</div>
                        <input
                          type="number"
                          min="0"
                          max="32"
                          name="state[truncate_v4]"
                          value={Map.get(@netflow_viz_state, "truncate_v4")}
                          class="input input-bordered input-sm w-full font-mono text-xs"
                        />
                      </div>

                      <div class="space-y-1">
                        <div class="text-[11px] text-base-content/60">IPv6 prefix bits</div>
                        <input
                          type="number"
                          min="0"
                          max="128"
                          name="state[truncate_v6]"
                          value={Map.get(@netflow_viz_state, "truncate_v6")}
                          class="input input-bordered input-sm w-full font-mono text-xs"
                        />
                      </div>
                    </form>
                  </div>

                  <div class="col-span-2">
                    <div class="text-xs font-semibold text-base-content/70 mb-1">Time</div>
                    <form phx-change="nf_state_change">
                      <select
                        name="state[time]"
                        class="select select-bordered select-sm w-full font-mono text-xs"
                      >
                        <%= for value <- ["last_1h", "last_6h", "last_12h", "last_24h", "last_7d", "last_30d"] do %>
                          <option
                            value={value}
                            selected={Map.get(@netflow_viz_state, "time") == value}
                          >
                            {value}
                          </option>
                        <% end %>
                      </select>
                    </form>
                  </div>

                  <div class="col-span-2">
                    <div class="text-xs font-semibold text-base-content/70 mb-1">Overlays</div>
                    <form phx-change="nf_state_change" class="space-y-2">
                      <input type="hidden" name="state[bidirectional]" value="false" />
                      <label class="flex items-center gap-2 cursor-pointer">
                        <input
                          type="checkbox"
                          class="checkbox checkbox-sm"
                          name="state[bidirectional]"
                          value="true"
                          checked={Map.get(@netflow_viz_state, "bidirectional") == true}
                        />
                        <span class="text-xs">Bidirectional (reverse)</span>
                      </label>

                      <input type="hidden" name="state[previous_period]" value="false" />
                      <label class="flex items-center gap-2 cursor-pointer">
                        <input
                          type="checkbox"
                          class="checkbox checkbox-sm"
                          name="state[previous_period]"
                          value="true"
                          checked={Map.get(@netflow_viz_state, "previous_period") == true}
                        />
                        <span class="text-xs">Previous period</span>
                      </label>

                      <div class="text-[11px] text-base-content/60">
                        Overlays are currently supported on <span class="font-mono">lines</span>
                        and <span class="font-mono">stacked</span>
                        and <span class="font-mono">stacked100</span>.
                      </div>
                    </form>
                  </div>
                </div>

                <div class="flex items-center justify-between">
                  <button type="button" class="btn btn-sm btn-ghost" phx-click="nf_reset">
                    Reset view state
                  </button>

                  <div class="text-[11px] text-base-content/50">
                    URL param: <span class="font-mono">nf</span>
                  </div>
                </div>
              </div>
            </div>
          </aside>

          <section class="w-full min-w-0 flex-1 flex flex-col gap-4">
            <div class="card bg-base-100 border border-base-200 shadow-sm">
              <div class="card-body gap-3">
                <div class="flex items-center justify-between gap-3">
                  <div class="text-sm font-semibold">Chart</div>
                  <div class="text-[11px] text-base-content/50 font-mono">
                    {Map.get(@netflow_viz_state, "graph")}
                  </div>
                </div>

                <div class="h-72 w-full">
                  <%= case Map.get(@netflow_viz_state, "graph") do %>
                    <% "sankey" -> %>
                      <div
                        id="netflow-sankey"
                        class="w-full h-full"
                        phx-hook="NetflowSankeyChart"
                        data-edges={@netflow_sankey_edges_json || "[]"}
                      >
                        <svg class="w-full h-full"></svg>
                      </div>
                    <% "stacked100" -> %>
                      <div
                        id="netflow-stacked100"
                        class="w-full h-full"
                        phx-hook="NetflowStacked100Chart"
                        data-keys={@netflow_chart_keys_json}
                        data-points={@netflow_chart_points_json}
                        data-colors={@netflow_chart_colors_json}
                        data-overlays={@netflow_chart_overlays_json || "[]"}
                      >
                        <svg class="w-full h-full"></svg>
                      </div>
                    <% "lines" -> %>
                      <div
                        id="netflow-lines"
                        class="w-full h-full"
                        phx-hook="NetflowLineSeriesChart"
                        data-keys={@netflow_chart_keys_json}
                        data-points={@netflow_chart_points_json}
                        data-colors={@netflow_chart_colors_json}
                      >
                        <svg class="w-full h-full"></svg>
                      </div>
                    <% "grid" -> %>
                      <div
                        id="netflow-grid"
                        class="w-full h-full"
                        phx-hook="NetflowGridChart"
                        data-keys={@netflow_chart_keys_json}
                        data-points={@netflow_chart_points_json}
                        data-colors={@netflow_chart_colors_json}
                      >
                        <svg class="w-full h-full"></svg>
                      </div>
                    <% _ -> %>
                      <div
                        id="netflow-stacked"
                        class="w-full h-full"
                        phx-hook="NetflowStackedAreaChart"
                        data-keys={@netflow_chart_keys_json}
                        data-points={@netflow_chart_points_json}
                        data-colors={@netflow_chart_colors_json}
                        data-overlays={@netflow_chart_overlays_json || "[]"}
                      >
                        <svg class="w-full h-full"></svg>
                      </div>
                  <% end %>
                </div>
              </div>
            </div>

            <div class="card bg-base-100 border border-base-200 shadow-sm">
              <div class="card-body gap-3">
                <div class="flex items-center justify-between gap-3">
                  <div class="text-sm font-semibold">Flows</div>
                  <div class="text-[11px] text-base-content/50 font-mono">
                    limit:{@limit}
                  </div>
                </div>

                <.flows_table
                  flows={@flows}
                  rdns_map={@rdns_map}
                  base_path="/netflow"
                  query={Map.get(@srql, :query) || ""}
                  limit={@limit}
                  nf_param={nf_param(@netflow_viz_state)}
                />

                <div class="pt-3 border-t border-base-200">
                  <.ui_pagination
                    prev_cursor={Map.get(@flows_pagination, "prev_cursor")}
                    next_cursor={Map.get(@flows_pagination, "next_cursor")}
                    base_path="/netflow"
                    query={Map.get(@srql, :query) || ""}
                    limit={@limit}
                    result_count={length(@flows || [])}
                    extra_params={
                      %{"nf" => nf_param(@netflow_viz_state)}
                      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
                      |> Map.new()
                    }
                  />
                </div>
              </div>
            </div>

            <.flow_details_modal :if={is_map(@selected_flow)} flow={@selected_flow} rdns_map={@rdns_map} />
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr(:flows, :list, default: [])
  attr(:rdns_map, :map, default: %{})
  attr(:base_path, :string, required: true)
  attr(:query, :string, required: true)
  attr(:limit, :integer, required: true)
  attr(:nf_param, :string, default: nil)

  defp flows_table(assigns) do
    ~H"""
    <div class="w-full">
      <table class="table table-zebra table-sm w-full table-fixed">
        <thead>
          <tr>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-40">
              Time
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60">
              Source
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60">
              Destination
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-24">
              Protocol
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-32 text-right">
              Packets/Bytes
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-10 text-right">
            </th>
          </tr>
        </thead>
        <tbody>
          <%= for {flow, idx} <- Enum.with_index(@flows) do %>
            <% src_ip = flow_get(flow, ["src_endpoint_ip", "src_ip"]) %>
            <% dst_ip = flow_get(flow, ["dst_endpoint_ip", "dst_ip"]) %>
            <% src_port = flow_get(flow, ["src_endpoint_port"]) %>
            <% dst_port = flow_get(flow, ["dst_endpoint_port", "dst_port"]) %>
            <% src_cc = flow_get(flow, ["src_country_iso2"]) %>
            <% dst_cc = flow_get(flow, ["dst_country_iso2"]) %>

            <tr class="hover:bg-base-200/40">
              <td class="whitespace-nowrap text-xs font-mono">
                {flow_get(flow, ["time", "timestamp"]) || "—"}
              </td>
              <td class="text-xs font-mono min-w-0 truncate">
                <span
                  :if={is_binary(src_cc) and String.length(src_cc) == 2}
                  class="mr-1 inline-block align-middle text-sm leading-none"
                  title={src_cc}
                >
                  {iso2_flag_emoji(src_cc)}
                </span>
                <.link
                  :if={is_binary(src_ip) and String.trim(src_ip) != ""}
                  patch={flows_filter_patch(@base_path, @query, @limit, @nf_param, "src_ip", src_ip)}
                  class="hover:underline truncate"
                >
                  {src_ip}
                </.link>
                <span :if={not (is_binary(src_ip) and String.trim(src_ip) != "")}>
                  {src_ip || "—"}
                </span>
                <span class="text-base-content/60">{if src_port, do: ":#{src_port}", else: ""}</span>
                <div
                  :if={hostname = Map.get(@rdns_map, src_ip)}
                  class="mt-0.5 text-[11px] text-base-content/60 max-w-72 truncate font-mono"
                  title={hostname}
                >
                  {hostname}
                </div>
              </td>
              <td class="text-xs font-mono min-w-0 truncate">
                <span
                  :if={is_binary(dst_cc) and String.length(dst_cc) == 2}
                  class="mr-1 inline-block align-middle text-sm leading-none"
                  title={dst_cc}
                >
                  {iso2_flag_emoji(dst_cc)}
                </span>
                <.link
                  :if={is_binary(dst_ip) and String.trim(dst_ip) != ""}
                  patch={flows_filter_patch(@base_path, @query, @limit, @nf_param, "dst_ip", dst_ip)}
                  class="hover:underline truncate"
                >
                  {dst_ip}
                </.link>
                <span :if={not (is_binary(dst_ip) and String.trim(dst_ip) != "")}>
                  {dst_ip || "—"}
                </span>
                <span class="text-base-content/60">{if dst_port, do: ":#{dst_port}", else: ""}</span>
                <div
                  :if={hostname = Map.get(@rdns_map, dst_ip)}
                  class="mt-0.5 text-[11px] text-base-content/60 max-w-72 truncate font-mono"
                  title={hostname}
                >
                  {hostname}
                </div>
              </td>
              <td class="whitespace-nowrap text-xs">
                <.ui_badge variant="ghost" size="xs" class="font-mono">
                  {flow_get(flow, ["protocol_group", "protocol_name", "proto"]) || "—"}
                </.ui_badge>
              </td>
              <td class="whitespace-nowrap text-xs text-right font-mono">
                <div>{flow_get(flow, ["packets_total", "packets"]) || "—"}</div>
                <div class="text-[10px] text-base-content/60">
                  {flow_get(flow, ["bytes_total", "bytes"]) || "—"}
                </div>
              </td>
              <td class="whitespace-nowrap text-xs text-right">
                <.ui_dropdown align="end">
                  <:trigger>
                    <.ui_icon_button variant="ghost" size="xs" aria-label="Flow actions">
                      <.icon name="hero-ellipsis-vertical" class="size-4" />
                    </.ui_icon_button>
                  </:trigger>
                  <:item>
                    <.link phx-click="netflow_open" phx-value-idx={idx} class="text-xs">
                      Open details
                    </.link>
                  </:item>
                  <:item :if={is_binary(src_ip) and String.trim(src_ip) != ""}>
                    <.link
                      patch={
                        flows_filter_patch(@base_path, @query, @limit, @nf_param, "src_ip", src_ip)
                      }
                      class="text-xs"
                    >
                      Filter source
                    </.link>
                  </:item>
                  <:item :if={is_binary(dst_ip) and String.trim(dst_ip) != ""}>
                    <.link
                      patch={
                        flows_filter_patch(@base_path, @query, @limit, @nf_param, "dst_ip", dst_ip)
                      }
                      class="text-xs"
                    >
                      Filter destination
                    </.link>
                  </:item>
                  <:item :if={dst_port && to_string(dst_port) != ""}>
                    <.link
                      patch={
                        flows_filter_patch(
                          @base_path,
                          @query,
                          @limit,
                          @nf_param,
                          "dst_port",
                          to_string(dst_port)
                        )
                      }
                      class="text-xs"
                    >
                      Filter port
                    </.link>
                  </:item>
                </.ui_dropdown>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>

      <div :if={@flows == []} class="py-10 text-center text-base-content/60">
        No flows in this window.
      </div>
    </div>
    """
  end

  defp flow_get(nil, _keys), do: nil

  defp flow_get(flow, keys) when is_map(flow) and is_list(keys) do
    Enum.find_value(keys, fn k ->
      Map.get(flow, k) ||
        try do
          Map.get(flow, String.to_existing_atom(k))
        rescue
          _ -> nil
        end
    end)
    |> case do
      v when is_binary(v) -> String.trim(v)
      v -> v
    end
  end

  defp iso2_flag_emoji(nil), do: nil

  defp iso2_flag_emoji(iso2) when is_binary(iso2) do
    iso2 = iso2 |> String.trim() |> String.upcase()

    if String.length(iso2) == 2 do
      <<a::utf8, b::utf8>> = iso2

      if a in ?A..?Z and b in ?A..?Z do
        # Regional indicator symbols: U+1F1E6 = 'A'
        <<(0x1F1E6 + (a - ?A))::utf8, (0x1F1E6 + (b - ?A))::utf8>>
      else
        nil
      end
    else
      nil
    end
  end

  defp iso2_flag_emoji(_), do: nil

  defp flow_asn(flow, :src) when is_map(flow) do
    flow_get(flow, ["src_as_number", "src_asn", "src_as"])
  end

  defp flow_asn(flow, :dst) when is_map(flow) do
    flow_get(flow, ["dst_as_number", "dst_asn", "dst_as"])
  end

  defp flow_asn(_flow, _side), do: nil

  defp flow_geo(flow, :src) when is_map(flow) do
    geo_parts =
      [
        flow_get(flow, ["src_city"]),
        flow_get(flow, ["src_region"]),
        flow_get(flow, ["src_country_name"]),
        flow_get(flow, ["src_country_iso2"])
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case geo_parts do
      [] -> nil
      parts -> Enum.join(parts, ", ")
    end
  end

  defp flow_geo(flow, :dst) when is_map(flow) do
    geo_parts =
      [
        flow_get(flow, ["dst_city"]),
        flow_get(flow, ["dst_region"]),
        flow_get(flow, ["dst_country_name"]),
        flow_get(flow, ["dst_country_iso2"])
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case geo_parts do
      [] -> nil
      parts -> Enum.join(parts, ", ")
    end
  end

  defp flow_geo(_flow, _side), do: nil

  defp flows_filter_patch(base_path, query, limit, nf, field, value) do
    value = to_string(value || "") |> String.trim()

    q = upsert_query_filter(query || "", field, value)

    params =
      %{"q" => q, "limit" => limit, "nf" => nf}
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    base_path <> "?" <> URI.encode_query(params)
  end

  defp upsert_query_filter(query, field, value) when is_binary(query) and is_binary(field) do
    pattern = ~r/(?:^|\s)#{Regex.escape(field)}:(?:"([^"]+)"|(\S+))/

    query =
      query
      |> String.replace(pattern, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if String.trim(to_string(value || "")) == "" do
      query
    else
      (query <> " " <> "#{field}:#{value}")
      |> String.trim()
    end
  end

  defp nf_param(%{} = state) do
    case NFState.encode_param(state) do
      {:ok, nf} -> nf
      _ -> nil
    end
  end

  defp nf_param(_), do: nil

  defp srql_submit_extra_params(socket) do
    %{"nf" => nf_param(socket.assigns.netflow_viz_state)}
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_string(_), do: nil

  defp parse_limit_param(nil), do: @default_limit

  defp parse_limit_param(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n > 0 -> min(n, @max_limit)
      _ -> @default_limit
    end
  end

  defp parse_limit_param(v) when is_integer(v) and v > 0, do: min(v, @max_limit)
  defp parse_limit_param(_), do: @default_limit

  defp load_srql_assigns(socket, query, uri, limit) when is_binary(query) do
    srql = Map.get(socket.assigns, :srql, %{})
    page_path = uri |> to_string() |> URI.parse() |> Map.get(:path)

    {builder_supported, builder_sync, builder_state} =
      case SRQLBuilder.parse(query) do
        {:ok, parsed} -> {true, true, parsed}
        {:error, _} -> {false, false, SRQLBuilder.default_state("flows", limit)}
      end

    srql =
      srql
      |> Map.merge(%{
        enabled: true,
        entity: "flows",
        page_path: page_path,
        query: query,
        draft: query,
        error: nil,
        loading: false,
        builder_available: true,
        builder_supported: builder_supported,
        builder_sync: builder_sync,
        builder: builder_state
      })

    socket
    |> assign(:srql, srql)
    |> assign(:limit, limit)
  end

  defp load_srql_assigns(socket, other, uri, limit),
    do: load_srql_assigns(socket, to_string(other || ""), uri, limit)

  defp load_flows_list(socket, params, %{} = state) do
    srql_module = Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
    scope = socket.assigns.current_scope

    chart_query = Map.get(socket.assigns.srql, :query) || ""
    fallback_time = Map.get(state, "time", @default_time)

    list_query =
      chart_query
      |> NFQuery.flows_base_query(fallback_time)
      |> NFQuery.flows_sanitize_for_stats()
      |> ensure_sort_time_desc()

    cursor = Map.get(params, "cursor") |> normalize_optional_string()
    limit = Map.get(socket.assigns, :limit, @default_limit)

    {flows, pagination} =
      case srql_module.query(list_query, %{cursor: cursor, limit: limit, scope: scope}) do
        {:ok, %{"results" => results, "pagination" => pag}} when is_list(results) ->
          {results, pag || %{}}

        {:ok, %{"results" => results}} when is_list(results) ->
          {results, %{}}

        _ ->
          {[], %{}}
      end

    socket
    |> assign(:flows, flows)
    |> assign(:flows_pagination, pagination)
    |> assign(:rdns_map, rdns_map_for_flows(flows, scope))
  rescue
    _ ->
      socket
      |> assign(:flows, [])
      |> assign(:flows_pagination, %{})
      |> assign(:rdns_map, %{})
  end

  defp ensure_sort_time_desc(query) when is_binary(query) do
    q = String.trim(query)

    if Regex.match?(~r/(?:^|\s)sort:/, q) do
      q
    else
      String.trim(q <> " sort:time:desc")
    end
  end

  defp ensure_sort_time_desc(other), do: to_string(other || "")

  defp rdns_map_for_flows(flows, scope) when is_list(flows) do
    ips =
      flows
      |> Enum.flat_map(fn row ->
        [
          flow_get(row, ["src_endpoint_ip", "src_ip"]),
          flow_get(row, ["dst_endpoint_ip", "dst_ip"])
        ]
      end)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    query =
      IpRdnsCache
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(ip in ^ips)

    case Ash.read(query, scope: scope) do
      {:ok, rows} when is_list(rows) ->
        rows
        |> Enum.filter(fn row ->
          row.status == "ok" and is_binary(row.hostname) and String.trim(row.hostname) != ""
        end)
        |> Map.new(fn row -> {row.ip, row.hostname} end)

      _ ->
        %{}
    end
  end

  defp rdns_map_for_flows(_flows, _scope), do: %{}

  defp chart_query_from_state(base_query, %{} = state) do
    time = Map.get(state, "time", @default_time)
    base = chart_base_query(base_query, time)

    case Map.get(state, "graph", "stacked") do
      "sankey" -> chart_query_sankey(base, state)
      _ -> chart_query_timeseries(base, state)
    end
  end

  defp chart_base_query(base_query, time_token) when is_binary(time_token) do
    base_query
    |> to_string()
    |> NFQuery.flows_base_query(time_token)
    |> NFQuery.flows_sanitize_for_stats()
    |> String.trim()
  end

  defp chart_query_sankey(base, %{} = state) when is_binary(base) do
    prefix = sankey_prefix_from_state(state)
    cidr_prefix = if prefix == 32, do: 24, else: prefix
    dims = dims_from_state(state)

    src_dim = Enum.at(dims, 0)
    mid_dim = Enum.at(dims, 1)
    dst_dim = Enum.at(dims, 2)

    src = sankey_src_group_by(src_dim, cidr_prefix)
    mid = sankey_mid_group_by(mid_dim)
    dst = sankey_dst_group_by(dst_dim, cidr_prefix)

    ~s|#{base} stats:"sum(bytes_total) as total_bytes by #{src}, #{mid}, #{dst}" sort:total_bytes:desc limit:200|
  end

  defp chart_query_timeseries(base, %{} = state) when is_binary(base) do
    units = Map.get(state, "units", "Bps")
    dims = dims_from_state(state)
    series_limit = Map.get(state, "limit", 12)

    value_field = if units == "pps", do: "packets_total", else: "bytes_total"
    series_field = NFQuery.downsample_series_field_from_dims(dims)
    limit = max(@chart_limit, series_limit * 200)

    ~s|#{base} bucket:#{@default_bucket} agg:sum value_field:#{value_field} series:#{series_field} limit:#{limit}|
  end

  defp dims_from_state(%{} = state) do
    state
    |> Map.get("dims", [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp sankey_src_group_by("src_ip", _cidr_prefix), do: "src_endpoint_ip"
  defp sankey_src_group_by("src_cidr", cidr_prefix), do: "src_cidr:#{cidr_prefix}"
  defp sankey_src_group_by(_, cidr_prefix), do: "src_cidr:#{cidr_prefix}"

  defp sankey_dst_group_by("dst_ip", _cidr_prefix), do: "dst_endpoint_ip"
  defp sankey_dst_group_by("dst_cidr", cidr_prefix), do: "dst_cidr:#{cidr_prefix}"
  defp sankey_dst_group_by(_, cidr_prefix), do: "dst_cidr:#{cidr_prefix}"

  defp sankey_mid_group_by("dst_port"), do: "dst_endpoint_port"
  defp sankey_mid_group_by("app"), do: "app"
  defp sankey_mid_group_by("protocol_group"), do: "protocol_group"
  defp sankey_mid_group_by(_), do: "dst_endpoint_port"

  attr(:flow, :map, required: true)
  attr(:rdns_map, :map, default: %{})

  defp flow_details_modal(assigns) do
    ~H"""
    <dialog class="modal modal-open" phx-window-keydown="netflow_close" phx-key="escape">
      <div class="modal-box max-w-3xl">
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <div class="text-sm font-semibold">Flow details</div>
            <div class="mt-1 text-[11px] text-base-content/60 font-mono truncate">
              {flow_get(@flow, ["time", "timestamp"]) || "—"}
            </div>
          </div>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="netflow_close">Close</button>
        </div>

        <% src_ip = flow_get(@flow, ["src_endpoint_ip", "src_ip"]) %>
        <% dst_ip = flow_get(@flow, ["dst_endpoint_ip", "dst_ip"]) %>
        <% src_cc = flow_get(@flow, ["src_country_iso2"]) %>
        <% dst_cc = flow_get(@flow, ["dst_country_iso2"]) %>
        <% ocsf = flow_get(@flow, ["ocsf_payload"]) || %{} %>
        <% src_if_uid = get_in(ocsf, ["src_endpoint", "interface_uid"]) %>
        <% dst_if_uid = get_in(ocsf, ["dst_endpoint", "interface_uid"]) %>
        <% src_mac = get_in(ocsf, ["unmapped", "src_mac"]) %>
        <% dst_mac = get_in(ocsf, ["unmapped", "dst_mac"]) %>
        <% sampler = flow_get(@flow, ["sampler_address"]) || get_in(ocsf, ["observables", Access.at(0), "value"]) %>

        <div class="mt-4 grid grid-cols-1 gap-3 md:grid-cols-2">
          <div class="p-3 rounded-lg border border-base-200 bg-base-200/30">
            <div class="text-xs uppercase tracking-wider text-base-content/50">Source</div>
            <div class="mt-1 font-mono text-sm flex items-baseline gap-1 min-w-0">
              <span :if={is_binary(src_cc) and String.length(src_cc) == 2} class="text-sm leading-none">
                {iso2_flag_emoji(src_cc)}
              </span>
              <span class="min-w-0 truncate">{src_ip || "—"}</span>
              <span class="shrink-0 text-base-content/60">
                {if p = flow_get(@flow, ["src_endpoint_port", "src_port"]), do: ":#{p}", else: ""}
              </span>
            </div>
            <div :if={hostname = Map.get(@rdns_map, src_ip)} class="mt-0.5 text-[11px] text-base-content/60 font-mono truncate" title={hostname}>
              {hostname}
            </div>
            <div class="mt-1 text-[11px] text-base-content/60 space-y-0.5">
              <div :if={is_binary(src_if_uid) and src_if_uid != ""}>if_uid: <span class="font-mono">{src_if_uid}</span></div>
              <div :if={is_binary(src_mac) and src_mac != ""}>mac: <span class="font-mono">{src_mac}</span></div>
              <div :if={asn = flow_asn(@flow, :src)}>asn: <span class="font-mono">{asn}</span></div>
              <div :if={geo = flow_geo(@flow, :src)}>{geo}</div>
            </div>
          </div>

          <div class="p-3 rounded-lg border border-base-200 bg-base-200/30">
            <div class="text-xs uppercase tracking-wider text-base-content/50">Destination</div>
            <div class="mt-1 font-mono text-sm flex items-baseline gap-1 min-w-0">
              <span :if={is_binary(dst_cc) and String.length(dst_cc) == 2} class="text-sm leading-none">
                {iso2_flag_emoji(dst_cc)}
              </span>
              <span class="min-w-0 truncate">{dst_ip || "—"}</span>
              <span class="shrink-0 text-base-content/60">
                {if p = flow_get(@flow, ["dst_endpoint_port", "dst_port"]), do: ":#{p}", else: ""}
              </span>
            </div>
            <div :if={hostname = Map.get(@rdns_map, dst_ip)} class="mt-0.5 text-[11px] text-base-content/60 font-mono truncate" title={hostname}>
              {hostname}
            </div>
            <div class="mt-1 text-[11px] text-base-content/60 space-y-0.5">
              <div :if={is_binary(dst_if_uid) and dst_if_uid != ""}>if_uid: <span class="font-mono">{dst_if_uid}</span></div>
              <div :if={is_binary(dst_mac) and dst_mac != ""}>mac: <span class="font-mono">{dst_mac}</span></div>
              <div :if={asn = flow_asn(@flow, :dst)}>asn: <span class="font-mono">{asn}</span></div>
              <div :if={geo = flow_geo(@flow, :dst)}>{geo}</div>
            </div>
          </div>

          <div class="p-3 rounded-lg border border-base-200 bg-base-200/30">
            <div class="text-xs uppercase tracking-wider text-base-content/50">Protocol</div>
            <div class="mt-1 font-mono text-sm">
              {flow_get(@flow, ["protocol_name", "protocol_group", "proto"]) || get_in(ocsf, ["connection_info", "protocol_name"]) || "—"}
            </div>
            <div class="mt-1 text-[11px] text-base-content/60 space-y-0.5">
              <div :if={n = flow_get(@flow, ["protocol_num"])}>proto_num: <span class="font-mono">{n}</span></div>
              <div :if={flags = flow_get(@flow, ["tcp_flags"])}>tcp_flags: <span class="font-mono">{flags}</span></div>
              <div :if={dir = get_in(ocsf, ["connection_info", "direction_id"])}>direction_id: <span class="font-mono">{dir}</span></div>
              <div :if={bid = get_in(ocsf, ["connection_info", "boundary_id"])}>boundary_id: <span class="font-mono">{bid}</span></div>
            </div>
          </div>

          <div class="p-3 rounded-lg border border-base-200 bg-base-200/30">
            <div class="text-xs uppercase tracking-wider text-base-content/50">Volume</div>
            <div class="mt-1 font-mono text-sm">
              packets:{flow_get(@flow, ["packets_total", "packets"]) || "—"} bytes:{flow_get(@flow, [
                "bytes_total",
                "bytes"
              ]) || "—"}
            </div>
            <div class="mt-1 text-[11px] text-base-content/60 space-y-0.5">
              <div :if={bytes_in = flow_get(@flow, ["bytes_in"])}>bytes_in: <span class="font-mono">{bytes_in}</span></div>
              <div :if={bytes_out = flow_get(@flow, ["bytes_out"])}>bytes_out: <span class="font-mono">{bytes_out}</span></div>
              <div :if={s = sampler}>sampler: <span class="font-mono">{s}</span></div>
              <div :if={ft = get_in(ocsf, ["unmapped", "flow_type"])}>flow_type: <span class="font-mono">{ft}</span></div>
            </div>
          </div>
        </div>

        <details class="mt-4">
          <summary class="cursor-pointer text-xs text-base-content/60">Raw fields</summary>
          <pre class="mt-2 text-[11px] leading-snug whitespace-pre-wrap bg-base-200/30 border border-base-200 rounded-lg p-3 font-mono"><%= inspect(@flow, pretty: true, limit: :infinity) %></pre>
        </details>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="netflow_close">close</button>
      </form>
    </dialog>
    """
  end

  defp build_patch_url(socket, extra_params) do
    base = %{
      "q" => Map.get(socket.assigns.srql, :query),
      "limit" => Map.get(socket.assigns, :limit),
      "nf" => nf_param(Map.get(socket.assigns, :netflow_viz_state))
    }

    params =
      base
      |> Map.merge(extra_params)
      |> Map.reject(fn {_k, v} -> is_nil(v) or v == "" end)

    "/netflow?" <> URI.encode_query(params)
  end

  defp patch_nf_state(socket, %{} = state) do
    case NFState.encode_param(state) do
      {:ok, nf} -> push_patch(socket, to: build_patch_url(socket, %{"nf" => nf}))
      _ -> socket
    end
  end

  defp merge_nf_state(%{} = current, %{} = incoming) do
    allowed =
      Map.take(incoming, [
        "graph",
        "units",
        "time",
        "limit",
        "limit_type",
        "truncate_v4",
        "truncate_v6",
        "bidirectional",
        "previous_period",
        "dims"
      ])

    next = Map.merge(current, Map.delete(allowed, "dims"))

    if Map.has_key?(allowed, "dims") do
      Map.put(next, "dims", merge_dim_selection(Map.get(current, "dims", []), allowed["dims"]))
    else
      next
    end
  end

  defp merge_dim_selection(current_dims, incoming_dims) do
    current =
      current_dims
      |> List.wrap()
      |> Enum.map(&to_string/1)

    incoming =
      incoming_dims
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    preserved = Enum.filter(current, &Enum.member?(incoming, &1))
    added = Enum.reject(incoming, &Enum.member?(preserved, &1))

    (preserved ++ added)
    |> Enum.uniq()
  end

  defp move_dim(dims, dim, "up"), do: move_dim(dims, dim, -1)
  defp move_dim(dims, dim, "down"), do: move_dim(dims, dim, 1)

  defp move_dim(dims, dim, delta) when is_list(dims) and is_integer(delta) do
    idx = Enum.find_index(dims, &(&1 == dim))

    if is_integer(idx) do
      new_idx = idx + delta

      if new_idx >= 0 and new_idx < length(dims) do
        dims
        |> List.delete_at(idx)
        |> List.insert_at(new_idx, dim)
      else
        dims
      end
    else
      dims
    end
  end

  defp sankey_prefix_from_state(%{} = state) do
    case Map.get(state, "truncate_v4", 24) do
      16 -> 16
      24 -> 24
      32 -> 32
      _ -> 24
    end
  end

  defp units_to_value_field_and_scale("pps", bucket),
    do: {"packets_total", rate_scale_fun(bucket, 1.0)}

  defp units_to_value_field_and_scale("bps", bucket),
    do: {"bytes_total", rate_scale_fun(bucket, 8.0)}

  defp units_to_value_field_and_scale("Bps", bucket),
    do: {"bytes_total", rate_scale_fun(bucket, 1.0)}

  defp units_to_value_field_and_scale(_, bucket),
    do: {"bytes_total", rate_scale_fun(bucket, 1.0)}

  defp rate_scale_fun(bucket, multiplier) when is_binary(bucket) and is_number(multiplier) do
    secs = bucket_to_seconds(bucket)
    fn v -> to_float(v) * multiplier / secs end
  end

  defp bucket_to_seconds("1m"), do: 60
  defp bucket_to_seconds("5m"), do: 300
  defp bucket_to_seconds("15m"), do: 900
  defp bucket_to_seconds("1h"), do: 3600
  defp bucket_to_seconds(_), do: 300

  defp to_float(v) when is_integer(v), do: v * 1.0
  defp to_float(v) when is_float(v), do: v

  defp to_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, ""} -> f
      _ -> 0.0
    end
  end

  defp to_float(_), do: 0.0

  defp load_visualize_chart(socket, chart_query, %{} = state) when is_binary(chart_query) do
    srql_module = Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
    scope = socket.assigns.current_scope

    graph = Map.get(state, "graph", "stacked")
    fallback_time = Map.get(state, "time", @default_time)
    units = Map.get(state, "units", "Bps")
    dims = Map.get(state, "dims", [])
    series_limit = Map.get(state, "limit", 12)
    limit_type = Map.get(state, "limit_type", "avg")
    bidirectional = Map.get(state, "bidirectional", false) == true
    previous_period = Map.get(state, "previous_period", false) == true

    base =
      chart_query
      |> NFQuery.flows_base_query(fallback_time)
      |> String.trim()

    case graph do
      "sankey" ->
        edges =
          case srql_module.query(chart_query, %{scope: scope}) do
            {:ok, %{"results" => results}} when is_list(results) ->
              results
              |> extract_srql_rows()
              |> Enum.map(&srql_sankey_edge_from_row/1)
              |> Enum.reject(&is_nil/1)

            _ ->
              prefix = sankey_prefix_from_state(state)

              sankey =
                NFQuery.load_sankey(srql_module, base, scope,
                  prefix: prefix,
                  dims: dims,
                  max_edges: 300
                )

              Map.get(sankey, :edges, [])
          end

        edges_json = Jason.encode!(edges)

        socket
        |> assign(:netflow_sankey_edges_json, edges_json)
        |> assign(:netflow_chart_overlays_json, "[]")

      _ ->
        # Charts are SRQL-driven: the SRQL query in the top bar is the chart query.
        {keys, points} =
          case srql_module.query(chart_query, %{scope: scope}) do
            {:ok, %{"results" => results}} when is_list(results) ->
              downsample_from_results(results)

            _ ->
              # Fallback to derived SRQL (still SRQL-only), in case the user typed a non-downsample query.
              series_field = NFQuery.downsample_series_field_from_dims(dims)
              bucket = @default_bucket
              {value_field, _scale_fun} = units_to_value_field_and_scale(units, bucket)

              NFQuery.load_downsample_series(srql_module, base, scope,
                bucket: bucket,
                series_field: series_field,
                value_field: value_field,
                agg: "sum",
                limit: max(@chart_limit, series_limit * 200)
              )
          end

        # Apply Top-N bucketing and unit scaling (if chart_query is already scaled, this is a no-op).
        bucket = @default_bucket
        {value_field, scale_fun} = units_to_value_field_and_scale(units, bucket)
        points = NFQuery.scale_points(points, scale_fun)
        {keys, points} = NFQuery.top_n(keys, points, series_limit, limit_type)

        overlays =
          load_overlays(srql_module, base, scope,
            graph: graph,
            keys: keys,
            series_field: NFQuery.downsample_series_field_from_dims(dims),
            bucket: bucket,
            value_field: value_field,
            scale_fun: scale_fun,
            bidirectional: bidirectional,
            previous_period: previous_period
          )

        socket
        |> assign(:netflow_chart_keys_json, Jason.encode!(keys))
        |> assign(:netflow_chart_points_json, Jason.encode!(points))
        |> assign(:netflow_chart_colors_json, Jason.encode!(%{}))
        |> assign(:netflow_chart_overlays_json, Jason.encode!(overlays))
    end
  rescue
    _ ->
      socket
      |> assign(:netflow_chart_keys_json, "[]")
      |> assign(:netflow_chart_points_json, "[]")
      |> assign(:netflow_chart_colors_json, "{}")
      |> assign(:netflow_chart_overlays_json, "[]")
      |> assign(:netflow_sankey_edges_json, "[]")
  end

  defp load_visualize_chart(socket, other, %{} = state),
    do: load_visualize_chart(socket, to_string(other || ""), state)

  defp extract_srql_rows(results) when is_list(results) do
    Enum.map(results, fn
      %{"payload" => %{} = payload} -> payload
      %{} = row -> row
      _ -> %{}
    end)
  end

  defp downsample_from_results(results) when is_list(results) do
    {keys, buckets} =
      Enum.reduce(results, {MapSet.new(), %{}}, fn
        %{"timestamp" => ts, "series" => series, "value" => value}, {keys, acc} ->
          with {:ok, dt} <- parse_srql_datetime(ts),
               true <- is_binary(series),
               v when is_number(v) <- to_number(value) do
            label = if series == "", do: "total", else: series
            keys = MapSet.put(keys, label)

            acc =
              Map.update(acc, dt, %{label => v}, fn m ->
                Map.update(m, label, v, &(&1 + v))
              end)

            {keys, acc}
          else
            _ -> {keys, acc}
          end

        _row, acc ->
          acc
      end)

    keys = keys |> MapSet.to_list() |> Enum.sort()

    points =
      buckets
      |> Enum.sort_by(fn {dt, _} -> DateTime.to_unix(dt, :second) end)
      |> Enum.map(fn {dt, values} ->
        base = %{"t" => DateTime.to_iso8601(dt)}

        Enum.reduce(keys, base, fn k, acc ->
          Map.put(acc, k, Map.get(values, k, 0))
        end)
      end)

    {keys, points}
  end

  defp downsample_from_results(_), do: {[], []}

  defp parse_srql_datetime(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} ->
        {:ok, dt}

      _ ->
        case NaiveDateTime.from_iso8601(ts) do
          {:ok, ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
          _ -> {:error, :invalid_timestamp}
        end
    end
  end

  defp parse_srql_datetime(_), do: {:error, :invalid_timestamp}

  defp to_number(value) when is_number(value), do: value

  defp to_number(value) when is_binary(value) do
    case Float.parse(value) do
      {f, ""} -> f
      _ -> 0
    end
  end

  defp to_number(_), do: 0

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {i, ""} -> i
      _ -> 0
    end
  end

  defp to_int(_), do: 0

  defp srql_sankey_edge_from_row(%{} = row) do
    {src_field, src} = sankey_endpoint(row, :src)
    {dst_field, dst} = sankey_endpoint(row, :dst)
    {mid_field, mid_value, port} = sankey_mid(row)

    bytes = to_int(Map.get(row, "total_bytes"))
    mid = sankey_mid_label(mid_field, mid_value, port)

    src = if is_binary(src), do: String.trim(src), else: src
    dst = if is_binary(dst), do: String.trim(dst), else: dst

    if is_binary(src) and src != "" and is_binary(dst) and dst != "" and bytes > 0 do
      %{
        src: src,
        mid: mid,
        port: port,
        dst: dst,
        bytes: bytes,
        src_field: src_field,
        dst_field: dst_field,
        mid_field: mid_field,
        mid_value: mid_value
      }
    else
      nil
    end
  end

  defp sankey_endpoint(%{} = row, :src) do
    cond do
      is_binary(Map.get(row, "src_cidr")) -> {"src_cidr", Map.get(row, "src_cidr")}
      is_binary(Map.get(row, "src_endpoint_ip")) -> {"src_ip", Map.get(row, "src_endpoint_ip")}
      is_binary(Map.get(row, "src_ip")) -> {"src_ip", Map.get(row, "src_ip")}
      true -> {nil, nil}
    end
  end

  defp sankey_endpoint(%{} = row, :dst) do
    cond do
      is_binary(Map.get(row, "dst_cidr")) -> {"dst_cidr", Map.get(row, "dst_cidr")}
      is_binary(Map.get(row, "dst_endpoint_ip")) -> {"dst_ip", Map.get(row, "dst_endpoint_ip")}
      is_binary(Map.get(row, "dst_ip")) -> {"dst_ip", Map.get(row, "dst_ip")}
      true -> {nil, nil}
    end
  end

  defp sankey_endpoint(_row, _side), do: {nil, nil}

  defp sankey_mid(%{} = row) do
    cond do
      not is_nil(Map.get(row, "dst_endpoint_port")) ->
        p = to_int(Map.get(row, "dst_endpoint_port"))
        {"dst_port", p, p}

      is_binary(Map.get(row, "app")) ->
        {"app", Map.get(row, "app"), 0}

      is_binary(Map.get(row, "protocol_group")) ->
        {"protocol_group", Map.get(row, "protocol_group"), 0}

      true ->
        {nil, nil, 0}
    end
  end

  defp sankey_mid(_), do: {nil, nil, 0}

  defp sankey_mid_label("dst_port", _mid_value, port) when is_integer(port) and port > 0,
    do: "PORT:#{port}"

  defp sankey_mid_label(_mid_field, mid_value, _port) when is_binary(mid_value) do
    v = String.trim(mid_value)
    if v == "", do: "PORT:?", else: v
  end

  defp sankey_mid_label(_mid_field, _mid_value, _port), do: "PORT:?"

  defp srql_sankey_edge_from_row(_), do: nil

  defp load_primary_series(srql_module, base, scope, opts) do
    graph = Keyword.get(opts, :graph, "stacked")
    series_field = Keyword.get(opts, :series_field, "protocol_group")
    bucket = Keyword.get(opts, :bucket, "5m")
    value_field = Keyword.get(opts, :value_field, "bytes_total")
    scale_fun = Keyword.get(opts, :scale_fun, fn v -> v end)
    series_limit = Keyword.get(opts, :series_limit, 12)
    limit_type = Keyword.get(opts, :limit_type, "avg")
    bidirectional = Keyword.get(opts, :bidirectional, false) == true
    previous_period = Keyword.get(opts, :previous_period, false) == true

    {keys, points} =
      if graph == "lines" and (bidirectional or previous_period) do
        load_lines_with_overlays(srql_module, base, scope,
          series_field: series_field,
          bucket: bucket,
          value_field: value_field,
          agg: "sum",
          limit: 2000,
          series_limit: series_limit,
          limit_type: limit_type,
          bidirectional: bidirectional,
          previous_period: previous_period
        )
      else
        {keys, points} =
          NFQuery.load_downsample_series(srql_module, base, scope,
            series_field: series_field,
            bucket: bucket,
            value_field: value_field,
            agg: "sum",
            limit: 2000
          )

        NFQuery.top_n(keys, points, series_limit, limit_type)
      end

    points = NFQuery.scale_points(points, scale_fun)
    {keys, points}
  end

  defp load_overlays(srql_module, base, scope, opts) do
    graph = Keyword.get(opts, :graph, "stacked")
    keys = Keyword.get(opts, :keys, []) |> List.wrap()
    series_field = Keyword.get(opts, :series_field, "protocol_group")
    bucket = Keyword.get(opts, :bucket, "5m")
    value_field = Keyword.get(opts, :value_field, "bytes_total")
    scale_fun = Keyword.get(opts, :scale_fun, fn v -> v end)
    bidirectional = Keyword.get(opts, :bidirectional, false) == true
    previous_period = Keyword.get(opts, :previous_period, false) == true

    if bidirectional or previous_period do
      cond do
        graph == "stacked" ->
          load_stacked_total_overlays(srql_module, base, scope,
            bucket: bucket,
            value_field: value_field,
            scale_fun: scale_fun,
            agg: "sum",
            limit: 2000,
            bidirectional: bidirectional,
            previous_period: previous_period
          )

        graph == "stacked100" ->
          load_stacked100_composition_overlays(srql_module, base, scope,
            keys: keys,
            series_field: series_field,
            bucket: bucket,
            value_field: value_field,
            scale_fun: scale_fun,
            agg: "sum",
            limit: 2000,
            bidirectional: bidirectional,
            previous_period: previous_period
          )

        true ->
          []
      end
    else
      []
    end
  end

  defp load_stacked_total_overlays(srql_module, base_query, scope, opts) do
    bucket = Keyword.get(opts, :bucket, "5m")
    value_field = Keyword.get(opts, :value_field, "bytes_total")
    agg = Keyword.get(opts, :agg, "sum")
    limit = Keyword.get(opts, :limit, 2000)
    scale_fun = Keyword.get(opts, :scale_fun, fn v -> v end)
    bidirectional = Keyword.get(opts, :bidirectional, false) == true
    previous_period = Keyword.get(opts, :previous_period, false) == true

    rev_overlay =
      if bidirectional do
        rev_query = NFQuery.flows_reverse_direction_query(base_query)

        points =
          load_total_overlay_points(srql_module, rev_query, scope,
            bucket: bucket,
            value_field: value_field,
            agg: agg,
            limit: limit,
            scale_fun: scale_fun
          )

        [%{"key" => "rev:total", "points" => points}]
      else
        []
      end

    prev_overlay =
      if previous_period do
        with {:ok, {start_dt, end_dt}} <- parse_time_window_from_query(base_query),
             diff when is_integer(diff) and diff > 0 <- DateTime.diff(end_dt, start_dt, :second) do
          prev_start = DateTime.add(start_dt, -diff, :second)
          prev_end = DateTime.add(end_dt, -diff, :second)
          prev_time = "[#{DateTime.to_iso8601(prev_start)},#{DateTime.to_iso8601(prev_end)}]"
          prev_query = NFQuery.flows_replace_time(base_query, prev_time)

          points =
            load_total_overlay_points(srql_module, prev_query, scope,
              bucket: bucket,
              value_field: value_field,
              agg: agg,
              limit: limit,
              scale_fun: scale_fun
            )
            |> shift_overlay_points(diff)

          [%{"key" => "prev:total", "points" => points}]
        else
          _ -> []
        end
      else
        []
      end

    rev_overlay ++ prev_overlay
  end

  defp load_total_overlay_points(srql_module, query, scope, opts) do
    bucket = Keyword.get(opts, :bucket, "5m")
    value_field = Keyword.get(opts, :value_field, "bytes_total")
    agg = Keyword.get(opts, :agg, "sum")
    limit = Keyword.get(opts, :limit, 2000)
    scale_fun = Keyword.get(opts, :scale_fun, fn v -> v end)

    {_keys, points} =
      NFQuery.load_downsample_series(srql_module, query, scope,
        series_field: nil,
        bucket: bucket,
        value_field: value_field,
        agg: agg,
        limit: limit
      )

    points = NFQuery.scale_points(points, scale_fun)

    Enum.flat_map(points, fn
      %{"t" => t} = p when is_binary(t) ->
        [%{"t" => t, "v" => to_float(Map.get(p, "total", 0))}]

      _ ->
        []
    end)
  end

  defp shift_overlay_points(points, seconds) when is_list(points) and is_integer(seconds) do
    Enum.map(points, fn
      %{"t" => t} = p when is_binary(t) ->
        case DateTime.from_iso8601(t) do
          {:ok, dt, _} ->
            Map.put(p, "t", dt |> DateTime.add(seconds, :second) |> DateTime.to_iso8601())

          _ ->
            p
        end

      other ->
        other
    end)
  end

  defp shift_overlay_points(other, _seconds), do: other

  defp load_stacked100_composition_overlays(srql_module, base_query, scope, opts) do
    keys = Keyword.get(opts, :keys, []) |> List.wrap()
    series_field = Keyword.get(opts, :series_field, "protocol_group")
    bucket = Keyword.get(opts, :bucket, "5m")
    value_field = Keyword.get(opts, :value_field, "bytes_total")
    agg = Keyword.get(opts, :agg, "sum")
    limit = Keyword.get(opts, :limit, 2000)
    scale_fun = Keyword.get(opts, :scale_fun, fn v -> v end)
    bidirectional = Keyword.get(opts, :bidirectional, false) == true
    previous_period = Keyword.get(opts, :previous_period, false) == true

    if keys == [] do
      []
    else
      rev_overlay =
        if bidirectional do
          rev_query = NFQuery.flows_reverse_direction_query(base_query)
          rev_series = NFQuery.reverse_series_field(series_field)

          {_rev_keys, rev_points} =
            NFQuery.load_downsample_series(srql_module, rev_query, scope,
              series_field: rev_series,
              bucket: bucket,
              value_field: value_field,
              agg: agg,
              limit: limit
            )

          points =
            rev_points
            |> restrict_points_to_keys(keys)
            |> NFQuery.scale_points(scale_fun)

          [%{"type" => "rev", "points" => points}]
        else
          []
        end

      prev_overlay =
        if previous_period do
          with {:ok, {start_dt, end_dt}} <- parse_time_window_from_query(base_query),
               diff when is_integer(diff) and diff > 0 <- DateTime.diff(end_dt, start_dt, :second) do
            prev_start = DateTime.add(start_dt, -diff, :second)
            prev_end = DateTime.add(end_dt, -diff, :second)
            prev_time = "[#{DateTime.to_iso8601(prev_start)},#{DateTime.to_iso8601(prev_end)}]"
            prev_query = NFQuery.flows_replace_time(base_query, prev_time)

            {_prev_keys, prev_points} =
              NFQuery.load_downsample_series(srql_module, prev_query, scope,
                series_field: series_field,
                bucket: bucket,
                value_field: value_field,
                agg: agg,
                limit: limit
              )

            points =
              prev_points
              |> restrict_points_to_keys(keys)
              |> NFQuery.scale_points(scale_fun)
              |> shift_points(diff)
              |> elem(1)

            [%{"type" => "prev", "points" => points}]
          else
            _ ->
              []
          end
        else
          []
        end

      rev_overlay ++ prev_overlay
    end
  end

  defp restrict_points_to_keys(points, keys) when is_list(points) and is_list(keys) do
    Enum.map(points, fn
      %{"t" => t} = point ->
        out = %{"t" => t}

        Enum.reduce(keys, out, fn k, acc ->
          Map.put(acc, k, Map.get(point, k, 0))
        end)

      other ->
        other
    end)
  end

  defp restrict_points_to_keys(other, _keys), do: other

  defp load_lines_with_overlays(srql_module, base_query, scope, opts) do
    series_field = Keyword.get(opts, :series_field, "protocol_group")
    bucket = Keyword.get(opts, :bucket, "5m")
    value_field = Keyword.get(opts, :value_field, "bytes_total")
    agg = Keyword.get(opts, :agg, "sum")
    limit = Keyword.get(opts, :limit, 2000)
    series_limit = Keyword.get(opts, :series_limit, 12)
    limit_type = Keyword.get(opts, :limit_type, "avg")
    bidirectional = Keyword.get(opts, :bidirectional, false) == true
    previous_period = Keyword.get(opts, :previous_period, false) == true

    {direct_keys, direct_points} =
      NFQuery.load_downsample_series(srql_module, base_query, scope,
        series_field: series_field,
        bucket: bucket,
        value_field: value_field,
        agg: agg,
        limit: limit
      )
      |> then(fn {k, p} -> NFQuery.top_n(k, p, series_limit, limit_type) end)

    {rev_keys, rev_points} =
      if bidirectional do
        rev_query = NFQuery.flows_reverse_direction_query(base_query)
        rev_series = NFQuery.reverse_series_field(series_field)

        NFQuery.load_downsample_series(srql_module, rev_query, scope,
          series_field: rev_series,
          bucket: bucket,
          value_field: value_field,
          agg: agg,
          limit: limit
        )
        |> then(fn {k, p} -> NFQuery.top_n(k, p, series_limit, limit_type) end)
        |> prefix_series("rev:")
      else
        {[], []}
      end

    {prev_keys, prev_points} =
      if previous_period do
        with {:ok, {start_dt, end_dt}} <- parse_time_window_from_query(base_query),
             diff when is_integer(diff) and diff > 0 <- DateTime.diff(end_dt, start_dt, :second) do
          prev_start = DateTime.add(start_dt, -diff, :second)
          prev_end = DateTime.add(end_dt, -diff, :second)
          prev_time = "[#{DateTime.to_iso8601(prev_start)},#{DateTime.to_iso8601(prev_end)}]"
          prev_query = NFQuery.flows_replace_time(base_query, prev_time)

          NFQuery.load_downsample_series(srql_module, prev_query, scope,
            series_field: nil,
            bucket: bucket,
            value_field: value_field,
            agg: agg,
            limit: limit
          )
          |> shift_points(diff)
          |> rename_total_series("prev:")
        else
          _ -> {[], []}
        end
      else
        {[], []}
      end

    keys = Enum.uniq(direct_keys ++ rev_keys ++ prev_keys)
    points = merge_points_by_t([direct_points, rev_points, prev_points], keys)
    {keys, points}
  end

  defp prefix_series({keys, points}, prefix)
       when is_list(keys) and is_list(points) and is_binary(prefix) do
    keys = Enum.map(keys, &"#{prefix}#{&1}")

    points =
      Enum.map(points, fn
        %{"t" => t} = point ->
          out = %{"t" => t}

          Enum.reduce(keys, out, fn prefixed_key, acc ->
            k = String.replace_prefix(prefixed_key, prefix, "")
            Map.put(acc, prefixed_key, Map.get(point, k, 0))
          end)

        other ->
          other
      end)

    {keys, points}
  end

  defp prefix_series(other, _prefix), do: other

  defp rename_total_series({keys, points}, prefix) when is_list(keys) and is_list(points) do
    # load_downsample_series uses "total" for series-less queries.
    if keys == ["total"] do
      keys = [prefix <> "total"]

      points =
        Enum.map(points, fn
          %{"t" => t} = point -> %{"t" => t, (prefix <> "total") => Map.get(point, "total", 0)}
          other -> other
        end)

      {keys, points}
    else
      prefix_series({keys, points}, prefix)
    end
  end

  defp rename_total_series(other, _prefix), do: other

  defp shift_points({keys, points}, seconds)
       when is_list(keys) and is_list(points) and is_integer(seconds) do
    points =
      Enum.map(points, fn
        %{"t" => t} = point when is_binary(t) ->
          case DateTime.from_iso8601(t) do
            {:ok, dt, _} ->
              Map.put(point, "t", dt |> DateTime.add(seconds, :second) |> DateTime.to_iso8601())

            _ ->
              point
          end

        other ->
          other
      end)

    {keys, points}
  end

  defp shift_points(other, _seconds), do: other

  defp merge_points_by_t(point_lists, keys) when is_list(point_lists) and is_list(keys) do
    merged =
      point_lists
      |> Enum.flat_map(&List.wrap/1)
      |> Enum.reduce(%{}, &merge_point_by_t/2)

    merged
    |> Enum.map(fn {t, point} -> Map.put(point, "t", t) end)
    |> Enum.sort_by(fn %{"t" => t} -> t end)
    |> Enum.map(fn %{"t" => _t} = point ->
      Enum.reduce(keys, point, fn k, acc -> Map.put_new(acc, k, 0) end)
    end)
  end

  defp merge_point_by_t(%{"t" => t} = point, acc) when is_binary(t) do
    Map.update(acc, t, point, fn existing ->
      Map.merge(existing, Map.drop(point, ["t"]))
    end)
  end

  defp merge_point_by_t(_point, acc), do: acc

  defp parse_time_window_from_query(query) when is_binary(query) do
    case Regex.run(~r/(?:^|\s)time:(?:"([^"]+)"|(\[[^\]]+\])|(\S+))/, query) do
      [_, quoted, _, _] when is_binary(quoted) and quoted != "" -> parse_time_token(quoted)
      [_, _, bracket, _] when is_binary(bracket) and bracket != "" -> parse_time_token(bracket)
      [_, _, _, token] when is_binary(token) and token != "" -> parse_time_token(token)
      _ -> {:error, :no_time}
    end
  end

  defp parse_time_window_from_query(_), do: {:error, :invalid_query}

  defp parse_time_token("last_1h"), do: relative_window(3600)
  defp parse_time_token("last_6h"), do: relative_window(6 * 3600)
  defp parse_time_token("last_12h"), do: relative_window(12 * 3600)
  defp parse_time_token("last_24h"), do: relative_window(24 * 3600)
  defp parse_time_token("last_7d"), do: relative_window(7 * 24 * 3600)
  defp parse_time_token("last_30d"), do: relative_window(30 * 24 * 3600)

  defp parse_time_token(token) when is_binary(token) do
    token = String.trim(token)

    if bracket_range?(token) do
      parse_bracket_range(token)
    else
      case parse_last_duration_seconds(token) do
        {:ok, seconds} -> relative_window(seconds)
        {:error, _} -> {:error, :unsupported_time}
      end
    end
  end

  defp parse_time_token(_), do: {:error, :invalid_time}

  defp relative_window(seconds) when is_integer(seconds) and seconds > 0 do
    end_dt = DateTime.utc_now() |> DateTime.truncate(:second)
    start_dt = DateTime.add(end_dt, -seconds, :second)
    {:ok, {start_dt, end_dt}}
  end

  defp parse_dt(value) when is_binary(value) do
    v = value |> String.trim() |> String.trim(~s|"|)

    case DateTime.from_iso8601(v) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, :invalid_dt}
    end
  end

  defp parse_dt(_), do: {:error, :invalid_dt}

  defp bracket_range?(token) when is_binary(token) do
    String.starts_with?(token, "[") and String.ends_with?(token, "]")
  end

  defp bracket_range?(_), do: false

  defp parse_bracket_range(token) when is_binary(token) do
    token
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(",", parts: 2)
    |> case do
      [s, e] ->
        with {:ok, sdt} <- parse_dt(s),
             {:ok, edt} <- parse_dt(e) do
          {:ok, {sdt, edt}}
        end

      _ ->
        {:error, :invalid_range}
    end
  end

  defp parse_bracket_range(_), do: {:error, :invalid_range}

  defp parse_last_duration_seconds(token) when is_binary(token) do
    case Regex.run(~r/^last_(\d+)([mhd])$/, token) do
      [_, n, unit] ->
        {n, ""} = Integer.parse(n)

        seconds =
          case unit do
            "m" -> n * 60
            "h" -> n * 3600
            "d" -> n * 24 * 3600
          end

        {:ok, seconds}

      _ ->
        {:error, :invalid_last}
    end
  end

  defp parse_last_duration_seconds(_), do: {:error, :invalid_last}
end
