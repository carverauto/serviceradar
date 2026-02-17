defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize do
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNGWeb.NetflowVisualize.State, as: NFState
  alias ServiceRadarWebNGWeb.NetflowVisualize.Query, as: NFQuery
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage
  alias ServiceRadarWebNGWeb.SRQL.Builder, as: SRQLBuilder

  alias ServiceRadar.Observability.{
    IpGeoEnrichmentCache,
    IpIpinfoCache,
    IpRdnsCache,
    IpThreatIntelCache,
    NetflowPortAnomalyFlag,
    NetflowPortScanFlag
  }

  alias ServiceRadar.Integrations.MapboxSettings

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

  # Sankey is positional: Source -> Middle -> Destination. Restrict the UI choices accordingly.
  @sankey_src_dims [{"Source IP", "src_ip"}, {"Source CIDR", "src_cidr"}]
  @sankey_mid_dims [
    {"Dest port", "dst_port"},
    {"Application", "app"},
    {"Protocol (group)", "protocol_group"}
  ]
  @sankey_dst_dims [{"Dest IP", "dst_ip"}, {"Dest CIDR", "dst_cidr"}]

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
      |> assign(:sankey_src_dims, @sankey_src_dims)
      |> assign(:sankey_mid_dims, @sankey_mid_dims)
      |> assign(:sankey_dst_dims, @sankey_dst_dims)
      |> assign(:limit, @default_limit)
      |> assign(:selected_flow, nil)
      |> assign(:selected_flow_context, %{})
      |> assign(:flows, [])
      |> assign(:flows_pagination, %{})
      |> assign(:rdns_map, %{})
      |> assign(:geo_iso2_map, %{})
      |> assign(:flows_window_label, nil)
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

    state = normalize_state_for_graph(state)

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
       fallback_path: "/flows",
       extra_params: srql_submit_extra_params(socket)
     )}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_toggle", %{},
       entity: "flows",
       fallback_path: "/flows"
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
       fallback_path: "/flows",
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

    context = load_flow_context(selected, socket.assigns.current_scope)

    {:noreply,
     socket
     |> assign(:selected_flow, selected)
     |> assign(:selected_flow_context, context)}
  end

  def handle_event("netflow_close", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_flow, nil)
     |> assign(:selected_flow_context, %{})}
  end

  def handle_event("netflow_sankey_edge", %{} = params, socket) do
    src = Map.get(params, "src") |> normalize_optional_string()
    dst = Map.get(params, "dst") |> normalize_optional_string()

    port = parse_optional_port(Map.get(params, "port"))
    mid_field = Map.get(params, "mid_field") |> normalize_optional_string()
    mid_value = Map.get(params, "mid_value") |> normalize_optional_string()

    # Edges involving "Other" are bucketed aggregates (not a concrete endpoint). SRQL doesn't
    # have a clean way to express "everything except top-N", so clicking these should not
    # navigate to an empty chart.
    src_bucketed =
      is_binary(src) and (src in ["Other", "Unknown"] or String.starts_with?(src, "Other"))

    dst_bucketed =
      is_binary(dst) and (dst in ["Other", "Unknown"] or String.starts_with?(dst, "Other"))

    if src_bucketed or dst_bucketed do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "This edge is bucketed as Other. Increase detail (or switch dims) to drill in."
       )}
    else
      # IMPORTANT: The current SRQL query is a chart query (e.g. includes `stats:"..."`).
      # Upserting filters into that string can accidentally match group-by expressions inside
      # the quoted stats expression (e.g. `dst_cidr:24`) and corrupt the query.
      #
      # Instead:
      # 1) derive a base flows query without chart tokens
      # 2) apply filters to the base query
      # 3) re-emit a chart query from the current visualize state
      state = Map.get(socket.assigns, :netflow_viz_state, %{})
      time = Map.get(state, "time", @default_time)

      base =
        socket.assigns.srql
        |> Map.get(:query, "")
        |> chart_base_query(time)

      filtered_base =
        base
        |> apply_endpoint_filter(:src, src)
        |> apply_endpoint_filter(:dst, dst)
        |> apply_mid_filter(mid_field, mid_value, port)

      chart_query = chart_query_from_state(filtered_base, state)

      {:noreply,
       push_patch(socket,
         to:
           build_patch_url(socket, %{"q" => chart_query, "cursor" => nil, "nf" => nf_param(state)})
       )}
    end
  end

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

    next = normalize_state_for_graph(next)

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

    # Sankey dims are positional (src -> mid -> dst). Avoid confusing reorder operations.
    if Map.get(current, "graph") == "sankey" do
      {:noreply, socket}
    else
      dims = current |> Map.get("dims", []) |> List.wrap() |> Enum.map(&to_string/1)
      next_dims = move_dim(dims, dim, dir)
      next = Map.put(current, "dims", next_dims)

      socket = assign(socket, :netflow_viz_state, next)
      base = NFQuery.flows_sanitize_for_stats(Map.get(socket.assigns.srql, :query) || "")
      chart_query = chart_query_from_state(base, next)

      {:noreply,
       push_patch(socket,
         to:
           build_patch_url(socket, %{"nf" => nf_param(next), "q" => chart_query, "cursor" => nil})
       )}
    end
  end

  def handle_event("nf_dim_remove", %{"dim" => dim}, socket) when is_binary(dim) do
    current = Map.get(socket.assigns, :netflow_viz_state, NFState.default())

    if Map.get(current, "graph") == "sankey" do
      {:noreply, socket}
    else
      dims = current |> Map.get("dims", []) |> List.wrap() |> Enum.map(&to_string/1)
      next_dims = Enum.reject(dims, &(&1 == dim))
      next = Map.put(current, "dims", next_dims)

      socket = assign(socket, :netflow_viz_state, next)
      base = NFQuery.flows_sanitize_for_stats(Map.get(socket.assigns.srql, :query) || "")
      chart_query = chart_query_from_state(base, next)

      {:noreply,
       push_patch(socket,
         to:
           build_patch_url(socket, %{"nf" => nf_param(next), "q" => chart_query, "cursor" => nil})
       )}
    end
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
          is_integer(port) ->
            upsert_query_filter(query, "dst_port", to_string(port))

          is_binary(mid_value) and mid_value != "" ->
            upsert_query_filter(query, "dst_port", mid_value)

          true ->
            query
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
                  <div class="text-base font-semibold">Network Flows</div>
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
                      <% graph = Map.get(@netflow_viz_state, "graph", "stacked") %>
                      <%= if graph == "sankey" do %>
                        <% dims = @netflow_viz_state |> dims_from_state() |> sanitize_sankey_dims() %>
                        <div class="grid grid-cols-3 gap-2">
                          <div class="space-y-1">
                            <div class="text-[11px] text-base-content/60">Source</div>
                            <select
                              name="state[dims][]"
                              class="select select-bordered select-sm w-full font-mono text-xs"
                            >
                              <%= for {label, value} <- @sankey_src_dims do %>
                                <option value={value} selected={Enum.at(dims, 0) == value}>
                                  {label}
                                </option>
                              <% end %>
                            </select>
                          </div>
                          <div class="space-y-1">
                            <div class="text-[11px] text-base-content/60">Middle</div>
                            <select
                              name="state[dims][]"
                              class="select select-bordered select-sm w-full font-mono text-xs"
                            >
                              <%= for {label, value} <- @sankey_mid_dims do %>
                                <option value={value} selected={Enum.at(dims, 1) == value}>
                                  {label}
                                </option>
                              <% end %>
                            </select>
                          </div>
                          <div class="space-y-1">
                            <div class="text-[11px] text-base-content/60">Destination</div>
                            <select
                              name="state[dims][]"
                              class="select select-bordered select-sm w-full font-mono text-xs"
                            >
                              <%= for {label, value} <- @sankey_dst_dims do %>
                                <option value={value} selected={Enum.at(dims, 2) == value}>
                                  {label}
                                </option>
                              <% end %>
                            </select>
                          </div>
                        </div>
                      <% else %>
                        <% primary =
                          Map.get(@netflow_viz_state, "dims", []) |> List.wrap() |> List.first() %>
                        <select
                          name="state[dims][]"
                          class="select select-bordered select-sm w-full font-mono text-xs"
                        >
                          <%= for {label, value} <- @nf_dims_ordered do %>
                            <option value={value} selected={primary == value}>
                              {label}
                            </option>
                          <% end %>
                        </select>
                      <% end %>

                      <div class="text-[11px] text-base-content/60">
                        Time-series charts group by the selected dimension; Sankey uses source -> middle -> destination.
                        Exporter/interface dimensions may appear as
                        <span class="font-mono">Unknown</span>
                        until the NetFlow cache refresh job populates metadata.
                      </div>
                    </form>

                    <div
                      :if={graph != "sankey" and length(Map.get(@netflow_viz_state, "dims", [])) > 1}
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
                      <% sankey_dims =
                        @netflow_viz_state |> dims_from_state() |> sanitize_sankey_dims() %>
                      <% sankey_src_label = dim_human_label(Enum.at(sankey_dims, 0)) %>
                      <% sankey_mid_label = dim_human_label(Enum.at(sankey_dims, 1)) %>
                      <% sankey_dst_label = dim_human_label(Enum.at(sankey_dims, 2)) %>
                      <div class="mb-2 flex items-center gap-3 text-xs text-base-content/60">
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
                  <div class="flex items-baseline gap-2 min-w-0">
                    <div class="text-sm font-semibold">Flows</div>
                    <div
                      :if={is_binary(@flows_window_label) and String.trim(@flows_window_label) != ""}
                      class="text-[11px] text-base-content/50 font-mono truncate"
                      title={@flows_window_label}
                    >
                      {@flows_window_label}
                    </div>
                  </div>
                  <div class="text-[11px] text-base-content/50 font-mono">
                    limit:{@limit}
                  </div>
                </div>

                <.flows_table
                  flows={@flows}
                  rdns_map={@rdns_map}
                  geo_iso2_map={@geo_iso2_map}
                  base_path="/flows"
                  query={Map.get(@srql, :query) || ""}
                  limit={@limit}
                  nf_param={nf_param(@netflow_viz_state)}
                />

                <div class="pt-3 border-t border-base-200">
                  <.ui_pagination
                    prev_cursor={Map.get(@flows_pagination, "prev_cursor")}
                    next_cursor={Map.get(@flows_pagination, "next_cursor")}
                    base_path="/flows"
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

            <.flow_details_modal
              :if={is_map(@selected_flow)}
              flow={@selected_flow}
              rdns_map={@rdns_map}
              context={@selected_flow_context}
            />
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr(:flows, :list, default: [])
  attr(:rdns_map, :map, default: %{})
  attr(:geo_iso2_map, :map, default: %{})
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
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-32">
              Time
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60">
              Source
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60">
              Destination
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-20 text-right">
              Proto
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-28 text-right">
              Packets / Bytes
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
            <% src_cc = flow_get(flow, ["src_country_iso2"]) || Map.get(@geo_iso2_map, src_ip) %>
            <% dst_cc = flow_get(flow, ["dst_country_iso2"]) || Map.get(@geo_iso2_map, dst_ip) %>

            <tr class="hover:bg-base-200/40">
              <% t_raw = flow_get(flow, ["time", "timestamp"]) %>
              <td class="whitespace-nowrap text-xs font-mono truncate overflow-hidden" title={t_raw}>
                <span id={"nf-time-#{idx}"} phx-hook="LocalTime" data-iso={t_raw}>
                  {format_flow_time_short(t_raw) || "—"}
                </span>
              </td>
              <td class="text-xs font-mono min-w-0">
                <div class="min-w-0">
                  <div class="flex items-baseline gap-1 min-w-0">
                    <span
                      :if={is_binary(src_cc) and String.length(src_cc) == 2}
                      class="inline-block align-middle text-sm leading-none shrink-0"
                      title={src_cc}
                    >
                      {iso2_flag_emoji(src_cc)}
                    </span>
                    <.link
                      :if={is_binary(src_ip) and String.trim(src_ip) != ""}
                      patch={
                        flows_filter_patch(@base_path, @query, @limit, @nf_param, "src_ip", src_ip)
                      }
                      class="hover:underline min-w-0 truncate"
                      title={src_ip}
                    >
                      {src_ip}
                    </.link>
                    <span
                      :if={not (is_binary(src_ip) and String.trim(src_ip) != "")}
                      class="min-w-0 truncate"
                    >
                      {src_ip || "—"}
                    </span>
                    <span class="shrink-0 text-base-content/60">
                      {if src_port, do: ":#{src_port}", else: ""}
                    </span>
                  </div>
                  <div
                    :if={hostname = Map.get(@rdns_map, src_ip)}
                    class="mt-0.5 text-[11px] text-base-content/60 truncate font-mono"
                    title={hostname}
                  >
                    {hostname}
                  </div>
                </div>
              </td>
              <td class="text-xs font-mono min-w-0">
                <div class="min-w-0">
                  <div class="flex items-baseline gap-1 min-w-0">
                    <span
                      :if={is_binary(dst_cc) and String.length(dst_cc) == 2}
                      class="inline-block align-middle text-sm leading-none shrink-0"
                      title={dst_cc}
                    >
                      {iso2_flag_emoji(dst_cc)}
                    </span>
                    <.link
                      :if={is_binary(dst_ip) and String.trim(dst_ip) != ""}
                      patch={
                        flows_filter_patch(@base_path, @query, @limit, @nf_param, "dst_ip", dst_ip)
                      }
                      class="hover:underline min-w-0 truncate"
                      title={dst_ip}
                    >
                      {dst_ip}
                    </.link>
                    <span
                      :if={not (is_binary(dst_ip) and String.trim(dst_ip) != "")}
                      class="min-w-0 truncate"
                    >
                      {dst_ip || "—"}
                    </span>
                    <span class="shrink-0 text-base-content/60">
                      {if dst_port, do: ":#{dst_port}", else: ""}
                    </span>
                  </div>
                  <div
                    :if={hostname = Map.get(@rdns_map, dst_ip)}
                    class="mt-0.5 text-[11px] text-base-content/60 truncate font-mono"
                    title={hostname}
                  >
                    {hostname}
                  </div>
                </div>
              </td>
              <td class="whitespace-nowrap text-xs text-right font-mono align-top">
                <% proto = flow_get(flow, ["protocol_group", "protocol_name", "proto"]) || "—" %>
                <% app = flow_app_label(flow) %>
                <div class="flex flex-col items-end gap-0.5 leading-tight">
                  <.ui_badge variant="ghost" size="xs" class="font-mono">
                    {proto}
                  </.ui_badge>
                  <div
                    :if={is_binary(app) and String.trim(app) != "" and app != "unknown"}
                    class="text-[10px] text-base-content/60 font-mono"
                  >
                    {app}
                  </div>
                </div>
              </td>
              <td class="whitespace-nowrap text-xs text-right font-mono align-top">
                <% packets = flow_get(flow, ["packets_total", "packets"]) %>
                <% {bytes_val, bytes_unit} =
                  format_bytes_parts(flow_get(flow, ["bytes_total", "bytes"])) %>
                <div class="flex flex-col items-end leading-tight">
                  <div>{packets || "—"}</div>
                  <div class="flex items-baseline gap-1 text-[10px] text-base-content/60">
                    <span>{bytes_val}</span>
                    <span :if={bytes_unit != ""} class="uppercase">{bytes_unit}</span>
                  </div>
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

  # SRQL results are typically JSON maps with string keys, but some code paths can hand us
  # atom-keyed maps (e.g. if decoded/normalized elsewhere). Avoid `String.to_atom/1` here
  # (atom leak); instead, use a fixed allowlist of atoms that exist at compile time.
  @flow_key_atoms [
    :time,
    :timestamp,
    :src_endpoint_ip,
    :dst_endpoint_ip,
    :src_ip,
    :dst_ip,
    :src_endpoint_port,
    :dst_endpoint_port,
    :src_port,
    :dst_port,
    :protocol_name,
    :protocol_group,
    :proto,
    :protocol_num,
    :tcp_flags,
    :packets_total,
    :packets,
    :bytes_total,
    :bytes,
    :bytes_in,
    :bytes_out,
    :sampler_address,
    :src_country_iso2,
    :dst_country_iso2,
    :ocsf_payload,
    :ocsf
  ]

  @flow_key_atom_map Map.new(@flow_key_atoms, fn a -> {Atom.to_string(a), a} end)

  defp flow_get(flow, keys) when is_map(flow) and is_list(keys) do
    Enum.find_value(keys, fn k ->
      Map.get(flow, k) ||
        case Map.get(@flow_key_atom_map, k) do
          a when is_atom(a) -> Map.get(flow, a)
          _ -> nil
        end
    end)
    |> case do
      v when is_binary(v) -> String.trim(v)
      v -> v
    end
  end

  defp flow_get_in(map, path) when is_map(map) and is_list(path) do
    Enum.reduce_while(path, map, fn key, acc ->
      case flow_map_get(acc, key) do
        nil -> {:halt, nil}
        v -> {:cont, v}
      end
    end)
  end

  defp flow_get_in(_map, _path), do: nil

  defp flow_map_get(%{} = acc, key) when is_atom(key) do
    Map.get(acc, key) || Map.get(acc, Atom.to_string(key))
  end

  defp flow_map_get(%{} = acc, key) when is_binary(key) do
    Map.get(acc, key) ||
      case Map.get(@flow_key_atom_map, key) do
        a when is_atom(a) -> Map.get(acc, a)
        _ -> nil
      end
  end

  defp flow_map_get(%{} = acc, key), do: Map.get(acc, key)
  defp flow_map_get(_acc, _key), do: nil

  defp flow_app_label(flow) when is_map(flow) do
    # Prefer any computed/app-labeled field if present, otherwise use a small pragmatic mapping
    # for common ports so the flows table shows useful L7 hints.
    flow_get(flow, ["app", "app_label"]) ||
      case to_int(flow_get(flow, ["dst_endpoint_port", "dst_port"])) do
        53 -> "dns"
        80 -> "http"
        443 -> "https"
        22 -> "ssh"
        123 -> "ntp"
        _ -> "unknown"
      end
  rescue
    _ -> "unknown"
  end

  defp flow_app_label(_), do: "unknown"

  defp iso2_flag_emoji(nil), do: nil

  defp iso2_flag_emoji(iso2) when is_binary(iso2) do
    iso2 = iso2 |> String.trim() |> String.upcase()

    if String.length(iso2) == 2 do
      <<a::utf8, b::utf8>> = iso2

      if a in ?A..?Z and b in ?A..?Z do
        # Regional indicator symbols: U+1F1E6 = 'A'
        <<0x1F1E6 + (a - ?A)::utf8, 0x1F1E6 + (b - ?A)::utf8>>
      else
        nil
      end
    else
      nil
    end
  end

  defp iso2_flag_emoji(_), do: nil

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
      chart_base_query(chart_query, fallback_time)
      |> ensure_sort_time_desc()

    window_label = flows_window_label_from_query(list_query, fallback_time)

    cursor = Map.get(params, "cursor") |> normalize_optional_string()
    limit = Map.get(socket.assigns, :limit, @default_limit)

    {flows, pagination} =
      case srql_module.query(list_query, %{cursor: cursor, limit: limit, scope: scope}) do
        {:ok, %{"results" => results, "pagination" => pag}} when is_list(results) ->
          {extract_srql_rows(results), pag || %{}}

        {:ok, %{"results" => results}} when is_list(results) ->
          {extract_srql_rows(results), %{}}

        _ ->
          {[], %{}}
      end

    socket
    |> assign(:flows, flows)
    |> assign(:flows_pagination, pagination)
    |> assign(:rdns_map, rdns_map_for_flows(flows, scope))
    |> assign(:geo_iso2_map, geo_iso2_map_for_flows(flows, scope))
    |> assign(:flows_window_label, window_label)
  rescue
    _ ->
      socket
      |> assign(:flows, [])
      |> assign(:flows_pagination, %{})
      |> assign(:rdns_map, %{})
      |> assign(:geo_iso2_map, %{})
      |> assign(:flows_window_label, nil)
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

  defp geo_iso2_map_for_flows(flows, scope) when is_list(flows) do
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
      IpGeoEnrichmentCache
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(ip in ^ips)

    with [_ | _] <- ips,
         {:ok, rows} when is_list(rows) <- Ash.read(query, scope: scope) do
      rows
      |> Enum.filter(fn row ->
        is_binary(row.country_iso2) and String.length(String.trim(row.country_iso2)) == 2
      end)
      |> Map.new(fn row -> {row.ip, String.upcase(String.trim(row.country_iso2))} end)
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp geo_iso2_map_for_flows(_flows, _scope), do: %{}

  defp flows_window_label_from_query(query, fallback_time)
       when is_binary(query) and is_binary(fallback_time) do
    # Prefer explicit bracket range, otherwise show the state time token.
    case parse_time_window_from_query(query) do
      {:ok, {start_dt, end_dt}} ->
        # Keep this short in the UI; full query is already visible in the SRQL bar.
        "#{DateTime.to_iso8601(start_dt)} - #{DateTime.to_iso8601(end_dt)}"

      _ ->
        human_time_token(fallback_time)
    end
  rescue
    _ -> human_time_token(fallback_time)
  end

  defp flows_window_label_from_query(_query, fallback_time), do: human_time_token(fallback_time)

  defp human_time_token(nil), do: nil
  defp human_time_token(""), do: nil

  defp human_time_token(token) when is_binary(token) do
    t = String.trim(token)

    cond do
      String.starts_with?(t, "last_") ->
        String.replace_prefix(t, "last_", "Last ")

      bracket_range?(t) ->
        "Custom range"

      true ->
        t
    end
  end

  defp human_time_token(other), do: to_string(other || "")

  defp chart_query_from_state(base_query, %{} = state) do
    time = Map.get(state, "time", @default_time)
    base = chart_base_query(base_query, time)
    graph = Map.get(state, "graph", "stacked")
    dims = dims_from_state(state)
    dims = if graph == "sankey", do: sanitize_sankey_dims(dims), else: dims

    state = Map.put(state, "dims", dims)

    case graph do
      "sankey" -> chart_query_sankey(base, state)
      _ -> chart_query_timeseries(base, state)
    end
  end

  defp chart_base_query(base_query, time_token) when is_binary(time_token) do
    # Visualize state is the SRQL emitter. When the user changes the time dropdown,
    # we must override any existing `time:` token in the working base query.
    base_query
    |> to_string()
    |> NFQuery.flows_base_query(time_token)
    |> NFQuery.flows_replace_time(time_token)
    |> NFQuery.flows_sanitize_for_stats()
    |> String.trim()
  end

  defp chart_query_sankey(base, %{} = state) when is_binary(base) do
    prefix = sankey_prefix_from_state(state)
    cidr_prefix = if prefix == 32, do: 24, else: prefix
    dims = state |> dims_from_state() |> sanitize_sankey_dims()

    src_dim = Enum.at(dims, 0)
    mid_dim = Enum.at(dims, 1)
    dst_dim = Enum.at(dims, 2)

    src = sankey_src_group_by(src_dim, cidr_prefix)
    mid = sankey_mid_group_by(mid_dim)
    dst = sankey_dst_group_by(dst_dim, cidr_prefix)

    limit = sankey_max_edges_from_state(state)

    ~s|#{base} stats:"sum(bytes_total) as total_bytes by #{src}, #{mid}, #{dst}" sort:total_bytes:desc limit:#{limit}|
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

  defp normalize_state_for_graph(%{} = state) do
    if Map.get(state, "graph") == "sankey" do
      dims = state |> dims_from_state() |> sanitize_sankey_dims()
      Map.put(state, "dims", dims)
    else
      state
    end
  end

  defp sanitize_sankey_dims(dims) when is_list(dims) do
    src_allowed = Enum.map(@sankey_src_dims, fn {_l, v} -> v end)
    mid_allowed = Enum.map(@sankey_mid_dims, fn {_l, v} -> v end)
    dst_allowed = Enum.map(@sankey_dst_dims, fn {_l, v} -> v end)

    src = Enum.find(dims, &(&1 in src_allowed)) || "src_cidr"
    mid = Enum.find(dims, &(&1 in mid_allowed)) || "dst_port"
    dst = Enum.find(dims, &(&1 in dst_allowed)) || "dst_cidr"
    [src, mid, dst]
  end

  defp sanitize_sankey_dims(_), do: ["src_cidr", "dst_port", "dst_cidr"]

  defp dim_human_label(nil), do: ""
  defp dim_human_label(""), do: ""

  defp dim_human_label(dim) when is_binary(dim) do
    case String.trim(dim) do
      "src_ip" -> "Source IP"
      "src_cidr" -> "Source CIDR"
      "dst_ip" -> "Destination IP"
      "dst_cidr" -> "Destination CIDR"
      "dst_port" -> "Destination Port"
      "app" -> "Application"
      "protocol_group" -> "Protocol"
      "protocol_name" -> "Protocol"
      other -> other
    end
  end

  defp dim_human_label(other), do: to_string(other || "")

  defp sankey_max_edges_from_state(%{} = state) do
    # Each edge is rendered as 2 links (src->mid, mid->dst). Keep the sankey readable.
    n =
      case Map.get(state, "limit") do
        i when is_integer(i) ->
          i

        s when is_binary(s) ->
          case Integer.parse(String.trim(s)) do
            {i, ""} -> i
            _ -> 12
          end

        _ ->
          12
      end

    n = max(n, 1)
    max(min(n * 2, 60), 20)
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
  attr(:context, :map, default: %{})

  defp flow_details_modal(assigns) do
    ~H"""
    <dialog class="modal modal-open" phx-window-keydown="netflow_close" phx-key="escape">
      <div class="modal-box max-w-5xl">
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
        <% src_geo = Map.get(@context, :src_geo) %>
        <% dst_geo = Map.get(@context, :dst_geo) %>
        <% src_device_uid = Map.get(@context, :src_device_uid) %>
        <% dst_device_uid = Map.get(@context, :dst_device_uid) %>
        <% src_cc =
          flow_get(@flow, ["src_country_iso2"]) ||
            (is_map(src_geo) && Map.get(src_geo, :country_iso2)) %>
        <% dst_cc =
          flow_get(@flow, ["dst_country_iso2"]) ||
            (is_map(dst_geo) && Map.get(dst_geo, :country_iso2)) %>
        <% ocsf = flow_get(@flow, ["ocsf_payload"]) || %{} %>
        <% src_if_uid = flow_get_in(ocsf, ["src_endpoint", "interface_uid"]) %>
        <% dst_if_uid = flow_get_in(ocsf, ["dst_endpoint", "interface_uid"]) %>
        <% src_mac = flow_get_in(ocsf, ["unmapped", "src_mac"]) %>
        <% dst_mac = flow_get_in(ocsf, ["unmapped", "dst_mac"]) %>
        <% sampler =
          flow_get(@flow, ["sampler_address"]) ||
            flow_get_in(ocsf, ["observables"])
            |> case do
              [%{} = first | _] -> flow_get(first, ["value"]) || flow_get(first, ["name"])
              _ -> nil
            end %>
        <% mapbox = Map.get(@context, :mapbox) %>
        <% map_markers = netflow_map_markers(@context, @flow) %>

        <div class="mt-4 grid grid-cols-1 gap-3 lg:grid-cols-3">
          <div class="space-y-3 lg:col-span-2">
            <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
              <div class="p-3 rounded-lg border border-base-200 bg-base-200/30">
                <div class="text-xs uppercase tracking-wider text-base-content/50">Source</div>
                <div class="mt-1 font-mono text-sm flex items-baseline gap-1 min-w-0">
                  <span
                    :if={is_binary(src_cc) and String.length(src_cc) == 2}
                    class="text-sm leading-none"
                  >
                    {iso2_flag_emoji(src_cc)}
                  </span>
                  <.link
                    :if={is_binary(src_device_uid) and src_device_uid != ""}
                    navigate={~p"/devices/#{src_device_uid}"}
                    class="min-w-0 truncate hover:underline"
                    title={src_ip}
                  >
                    {src_ip || "—"}
                  </.link>
                  <span
                    :if={not (is_binary(src_device_uid) and src_device_uid != "")}
                    class="min-w-0 truncate"
                  >
                    {src_ip || "—"}
                  </span>
                  <span class="shrink-0 text-base-content/60">
                    {if p = flow_get(@flow, ["src_endpoint_port", "src_port"]), do: ":#{p}", else: ""}
                  </span>
                </div>
                <div
                  :if={hostname = Map.get(@rdns_map, src_ip)}
                  class="mt-0.5 text-[11px] text-base-content/60 font-mono truncate"
                  title={hostname}
                >
                  {hostname}
                </div>
                <div class="mt-1 text-[11px] text-base-content/60 space-y-0.5">
                  <div :if={is_binary(src_if_uid) and src_if_uid != ""}>
                    if_uid: <span class="font-mono">{src_if_uid}</span>
                  </div>
                  <div>
                    mac:
                    <%= if is_binary(src_mac) and src_mac != "" do %>
                      <.link
                        :if={is_binary(src_device_uid) and src_device_uid != ""}
                        navigate={~p"/devices/#{src_device_uid}"}
                        class="font-mono hover:underline"
                        title="Open device"
                      >
                        {src_mac}
                      </.link>
                      <span
                        :if={not (is_binary(src_device_uid) and src_device_uid != "")}
                        class="font-mono"
                      >
                        {src_mac}
                      </span>
                    <% else %>
                      <span class="font-mono text-base-content/50">n/a</span>
                    <% end %>
                  </div>
                </div>
              </div>

              <div class="p-3 rounded-lg border border-base-200 bg-base-200/30">
                <div class="text-xs uppercase tracking-wider text-base-content/50">Destination</div>
                <div class="mt-1 font-mono text-sm flex items-baseline gap-1 min-w-0">
                  <span
                    :if={is_binary(dst_cc) and String.length(dst_cc) == 2}
                    class="text-sm leading-none"
                  >
                    {iso2_flag_emoji(dst_cc)}
                  </span>
                  <.link
                    :if={is_binary(dst_device_uid) and dst_device_uid != ""}
                    navigate={~p"/devices/#{dst_device_uid}"}
                    class="min-w-0 truncate hover:underline"
                    title={dst_ip}
                  >
                    {dst_ip || "—"}
                  </.link>
                  <span
                    :if={not (is_binary(dst_device_uid) and dst_device_uid != "")}
                    class="min-w-0 truncate"
                  >
                    {dst_ip || "—"}
                  </span>
                  <span class="shrink-0 text-base-content/60">
                    {if p = flow_get(@flow, ["dst_endpoint_port", "dst_port"]), do: ":#{p}", else: ""}
                  </span>
                </div>
                <div
                  :if={hostname = Map.get(@rdns_map, dst_ip)}
                  class="mt-0.5 text-[11px] text-base-content/60 font-mono truncate"
                  title={hostname}
                >
                  {hostname}
                </div>
                <div class="mt-1 text-[11px] text-base-content/60 space-y-0.5">
                  <div :if={is_binary(dst_if_uid) and dst_if_uid != ""}>
                    if_uid: <span class="font-mono">{dst_if_uid}</span>
                  </div>
                  <div>
                    mac:
                    <%= if is_binary(dst_mac) and dst_mac != "" do %>
                      <.link
                        :if={is_binary(dst_device_uid) and dst_device_uid != ""}
                        navigate={~p"/devices/#{dst_device_uid}"}
                        class="font-mono hover:underline"
                        title="Open device"
                      >
                        {dst_mac}
                      </.link>
                      <span
                        :if={not (is_binary(dst_device_uid) and dst_device_uid != "")}
                        class="font-mono"
                      >
                        {dst_mac}
                      </span>
                    <% else %>
                      <span class="font-mono text-base-content/50">n/a</span>
                    <% end %>
                  </div>
                </div>
              </div>

              <div class="p-3 rounded-lg border border-base-200 bg-base-200/30">
                <div class="text-xs uppercase tracking-wider text-base-content/50">Protocol</div>
                <div class="mt-1 font-mono text-sm">
                  {flow_get(@flow, ["protocol_name", "protocol_group", "proto"]) ||
                    get_in(ocsf, ["connection_info", "protocol_name"]) || "—"}
                </div>
                <div class="mt-1 text-[11px] text-base-content/60 space-y-0.5">
                  <div :if={n = flow_get(@flow, ["protocol_num"])}>
                    proto_num: <span class="font-mono">{n}</span>
                  </div>
                  <div :if={flags = flow_get(@flow, ["tcp_flags"])}>
                    tcp_flags: <span class="font-mono">{flags}</span>
                  </div>
                  <div :if={dir = get_in(ocsf, ["connection_info", "direction_id"])}>
                    direction_id: <span class="font-mono">{dir}</span>
                  </div>
                  <div :if={bid = get_in(ocsf, ["connection_info", "boundary_id"])}>
                    boundary_id: <span class="font-mono">{bid}</span>
                  </div>
                </div>
              </div>

              <div class="p-3 rounded-lg border border-base-200 bg-base-200/30">
                <div class="text-xs uppercase tracking-wider text-base-content/50">Volume</div>
                <div class="mt-1 font-mono text-sm">
                  packets:{flow_get(@flow, ["packets_total", "packets"]) || "—"} bytes:{flow_get(
                    @flow,
                    [
                      "bytes_total",
                      "bytes"
                    ]
                  ) || "—"}
                </div>
                <div class="mt-1 text-[11px] text-base-content/60 space-y-0.5">
                  <div :if={bytes_in = flow_get(@flow, ["bytes_in"])}>
                    bytes_in: <span class="font-mono">{bytes_in}</span>
                  </div>
                  <div :if={bytes_out = flow_get(@flow, ["bytes_out"])}>
                    bytes_out: <span class="font-mono">{bytes_out}</span>
                  </div>
                  <div :if={s = sampler}>sampler: <span class="font-mono">{s}</span></div>
                  <div :if={ft = get_in(ocsf, ["unmapped", "flow_type"])}>
                    flow_type: <span class="font-mono">{ft}</span>
                  </div>
                </div>
              </div>

              <div class="p-3 rounded-lg border border-base-200 bg-base-200/30 md:col-span-2">
                <div class="text-xs uppercase tracking-wider text-base-content/50">Map</div>

                <%= if mapbox && mapbox.enabled &&
                      is_binary(Map.get(mapbox, :access_token)) &&
                      String.trim(Map.get(mapbox, :access_token)) != "" do %>
                  <div class="mt-2 rounded-lg overflow-hidden border border-base-200 bg-base-200/30">
                    <div
                      id="netflow-flow-map"
                      class="relative h-72 w-full"
                      style="min-height:18rem"
                      phx-hook="MapboxFlowMap"
                      data-enabled="true"
                      data-access-token={Map.get(mapbox, :access_token) || ""}
                      data-style-light={
                        Map.get(mapbox, :style_light) || "mapbox://styles/mapbox/light-v11"
                      }
                      data-style-dark={
                        Map.get(mapbox, :style_dark) || "mapbox://styles/mapbox/dark-v11"
                      }
                      data-markers={Jason.encode!(map_markers)}
                    >
                    </div>
                  </div>
                  <div class="mt-1 text-xs text-base-content/60">
                    <%= if map_markers != [] do %>
                      Tip: click markers for details.
                    <% else %>
                      No GeoIP coordinates available for this flow yet (showing default map).
                    <% end %>
                  </div>
                <% else %>
                  <div class="mt-2 text-sm text-base-content/60">
                    Mapbox is disabled or no GeoIP coordinates are available for this flow.
                  </div>
                <% end %>
              </div>
            </div>

            <details class="mt-1">
              <summary class="cursor-pointer text-xs text-base-content/60">Raw fields</summary>
              <pre class="mt-2 text-[11px] leading-snug whitespace-pre-wrap bg-base-200/30 border border-base-200 rounded-lg p-3 font-mono"><%= inspect(@flow, pretty: true, limit: :infinity) %></pre>
            </details>
          </div>

          <div class="p-3 rounded-lg border border-base-200 bg-base-200/30">
            <div class="text-xs uppercase tracking-wider text-base-content/50">
              Security and Enrichment
            </div>

            <div class="mt-3 space-y-3 text-xs">
              <div>
                <div class="font-semibold">GeoIP / ASN</div>
                <.netflow_geoip_asn_line side="Source" geo={Map.get(@context, :src_geo)} />
                <.netflow_geoip_asn_line side="Dest" geo={Map.get(@context, :dst_geo)} />
              </div>

              <div>
                <div class="font-semibold">Threat intel</div>
                <div class="mt-1 text-base-content/70">
                  Source:
                  <%= if match = Map.get(@context, :src_threat) do %>
                    <span class="ml-2 badge badge-xs badge-warning">match</span>
                    <span class="ml-2 font-mono">{match.match_count} indicators</span>
                  <% else %>
                    <span class="ml-2 badge badge-xs badge-ghost">none</span>
                  <% end %>
                </div>
                <div class="mt-1 text-base-content/70">
                  Dest:
                  <%= if match = Map.get(@context, :dst_threat) do %>
                    <span class="ml-2 badge badge-xs badge-warning">match</span>
                    <span class="ml-2 font-mono">{match.match_count} indicators</span>
                  <% else %>
                    <span class="ml-2 badge badge-xs badge-ghost">none</span>
                  <% end %>
                </div>
              </div>

              <div>
                <div class="font-semibold">Port scan</div>
                <%= if scan = Map.get(@context, :src_port_scan) do %>
                  <div class="mt-1 text-base-content/70">
                    <span class="badge badge-xs badge-error">flagged</span>
                    <span class="ml-2 font-mono">{scan.unique_ports} unique ports</span>
                  </div>
                <% else %>
                  <div class="mt-1 text-base-content/70">
                    <span class="badge badge-xs badge-ghost">not flagged</span>
                  </div>
                <% end %>
              </div>

              <div :if={anomaly = Map.get(@context, :dst_port_anomaly)}>
                <div class="font-semibold">Port anomaly</div>
                <div class="mt-1 text-base-content/70">
                  <span class="badge badge-xs badge-error">anomalous</span>
                  <span class="ml-2 font-mono">
                    {anomaly.current_bytes} vs baseline {anomaly.baseline_bytes}
                  </span>
                </div>
              </div>

              <div>
                <div class="font-semibold">ipinfo.io/lite</div>
                <%= if info = Map.get(@context, :src_ipinfo) do %>
                  <div class="mt-1 text-base-content/70">
                    Source:
                    <span class="font-mono">
                      {Enum.join(
                        Enum.filter([info.city, info.region, info.country_code], &(&1 && &1 != "")),
                        ", "
                      )}
                      <%= if is_integer(info.as_number) and info.as_number > 0 do %>
                        <span class="ml-2">AS{info.as_number}</span>
                      <% end %>
                      <%= if is_binary(info.as_name) and info.as_name != "" do %>
                        <span class="ml-2 text-base-content/60">{info.as_name}</span>
                      <% end %>
                    </span>
                  </div>
                <% else %>
                  <div class="mt-1 text-base-content/70">
                    Source: <span class="text-base-content/50">n/a</span>
                  </div>
                <% end %>

                <%= if info = Map.get(@context, :dst_ipinfo) do %>
                  <div class="mt-1 text-base-content/70">
                    Dest:
                    <span class="font-mono">
                      {Enum.join(
                        Enum.filter([info.city, info.region, info.country_code], &(&1 && &1 != "")),
                        ", "
                      )}
                      <%= if is_integer(info.as_number) and info.as_number > 0 do %>
                        <span class="ml-2">AS{info.as_number}</span>
                      <% end %>
                      <%= if is_binary(info.as_name) and info.as_name != "" do %>
                        <span class="ml-2 text-base-content/60">{info.as_name}</span>
                      <% end %>
                    </span>
                  </div>
                <% else %>
                  <div class="mt-1 text-base-content/70">
                    Dest: <span class="text-base-content/50">n/a</span>
                  </div>
                <% end %>
              </div>

              <div>
                <div class="font-semibold">rDNS</div>
                <%= if rdns = Map.get(@context, :src_rdns) do %>
                  <div class="mt-1 text-base-content/70">
                    Source:
                    <span class="font-mono">
                      <%= if rdns.status == "ok" and is_binary(rdns.hostname) and rdns.hostname != "" do %>
                        {rdns.hostname}
                      <% else %>
                        <span class="text-base-content/50">n/a</span>
                      <% end %>
                    </span>
                  </div>
                <% else %>
                  <div class="mt-1 text-base-content/70">
                    Source: <span class="text-base-content/50">n/a</span>
                  </div>
                <% end %>

                <%= if rdns = Map.get(@context, :dst_rdns) do %>
                  <div class="mt-1 text-base-content/70">
                    Dest:
                    <span class="font-mono">
                      <%= if rdns.status == "ok" and is_binary(rdns.hostname) and rdns.hostname != "" do %>
                        {rdns.hostname}
                      <% else %>
                        <span class="text-base-content/50">n/a</span>
                      <% end %>
                    </span>
                  </div>
                <% else %>
                  <div class="mt-1 text-base-content/70">
                    Dest: <span class="text-base-content/50">n/a</span>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="netflow_close">close</button>
      </form>
    </dialog>
    """
  end

  attr(:side, :string, required: true)
  attr(:geo, :any, default: nil)

  defp netflow_geoip_asn_line(assigns) do
    geo = assigns.geo

    parts =
      if is_map(geo) do
        [
          Map.get(geo, :country_code),
          Map.get(geo, :country_name),
          Map.get(geo, :as_number) && "AS#{Map.get(geo, :as_number)}",
          Map.get(geo, :as_name)
        ]
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
      else
        []
      end

    assigns = assign(assigns, :label, if(parts == [], do: "n/a", else: Enum.join(parts, " ")))

    ~H"""
    <div class="mt-1 text-base-content/70">
      {@side}: <span class="font-mono">{@label}</span>
    </div>
    """
  end

  defp netflow_map_markers(context, flow) when is_map(context) and is_map(flow) do
    src_ip = flow_get(flow, ["src_endpoint_ip", "src_ip"])
    dst_ip = flow_get(flow, ["dst_endpoint_ip", "dst_ip"])

    []
    |> maybe_add_geo_marker("Source", src_ip, Map.get(context, :src_geo))
    |> maybe_add_geo_marker("Dest", dst_ip, Map.get(context, :dst_geo))
    |> Enum.take(2)
  end

  defp netflow_map_markers(_context, _flow), do: []

  defp maybe_add_geo_marker(markers, side, ip, geo) when is_list(markers) do
    cond do
      not is_map(geo) ->
        markers

      not is_number(Map.get(geo, :latitude)) or not is_number(Map.get(geo, :longitude)) ->
        markers

      true ->
        label =
          [side, ip, Map.get(geo, :city), Map.get(geo, :region), Map.get(geo, :country_name)]
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join(" - ")

        markers ++
          [
            %{
              lng: Map.get(geo, :longitude),
              lat: Map.get(geo, :latitude),
              label: label
            }
          ]
    end
  end

  defp maybe_add_geo_marker(markers, _side, _ip, _geo), do: markers

  defp load_flow_context(flow, scope) when is_map(flow) do
    srql_module = Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
    user = scope && scope.user
    src_ip = flow_get(flow, ["src_endpoint_ip", "src_ip"]) |> normalize_ip()
    dst_ip = flow_get(flow, ["dst_endpoint_ip", "dst_ip"]) |> normalize_ip()
    dst_port = flow_get(flow, ["dst_endpoint_port", "dst_port"]) |> to_int()

    src_mac =
      get_in(flow_get(flow, ["ocsf_payload"]) || %{}, ["unmapped", "src_mac"]) |> normalize_mac()

    dst_mac =
      get_in(flow_get(flow, ["ocsf_payload"]) || %{}, ["unmapped", "dst_mac"]) |> normalize_mac()

    src_device_uid =
      lookup_device_uid_by_ip_or_mac(srql_module, scope, src_ip, src_mac)

    dst_device_uid =
      lookup_device_uid_by_ip_or_mac(srql_module, scope, dst_ip, dst_mac)

    %{
      mapbox: read_mapbox(user),
      src_rdns: read_rdns(user, src_ip),
      dst_rdns: read_rdns(user, dst_ip),
      src_geo: read_geo(user, src_ip),
      dst_geo: read_geo(user, dst_ip),
      src_ipinfo: read_ipinfo(user, src_ip),
      dst_ipinfo: read_ipinfo(user, dst_ip),
      src_threat: read_threat(user, src_ip),
      dst_threat: read_threat(user, dst_ip),
      src_port_scan: read_port_scan(user, src_ip),
      dst_port_anomaly: read_port_anomaly(user, dst_port),
      src_device_uid: src_device_uid,
      dst_device_uid: dst_device_uid
    }
  rescue
    _ -> %{}
  end

  defp load_flow_context(_flow, _scope), do: %{}

  defp normalize_ip(nil), do: nil
  defp normalize_ip(""), do: nil

  defp normalize_ip(ip) when is_binary(ip) do
    ip = String.trim(ip)
    if ip in ["", "—", "-"], do: nil, else: ip
  end

  defp normalize_ip(_), do: nil

  defp normalize_mac(nil), do: nil
  defp normalize_mac(""), do: nil

  defp normalize_mac(mac) when is_binary(mac) do
    mac
    |> String.trim()
    |> String.downcase()
    |> String.replace(":", "")
    |> String.replace("-", "")
    |> String.upcase()
    |> case do
      "" -> nil
      v -> v
    end
  end

  defp normalize_mac(_), do: nil

  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", " ")
    |> String.replace("\r", " ")
    |> String.trim()
  end

  defp escape_value(other), do: escape_value(to_string(other || ""))

  defp lookup_device_uid_by_ip_or_mac(_srql_module, _scope, nil, nil), do: nil

  defp lookup_device_uid_by_ip_or_mac(srql_module, scope, ip, mac) do
    lookup_device_uid_by_ip(srql_module, scope, ip) ||
      lookup_device_uid_by_mac(srql_module, scope, mac)
  end

  defp lookup_device_uid_by_ip(_srql_module, _scope, nil), do: nil

  defp lookup_device_uid_by_ip(srql_module, scope, ip) when is_binary(ip) do
    q = "in:devices ip:#{escape_value(ip)} limit:1"

    case srql_module.query(q, %{scope: scope}) do
      {:ok, %{"results" => [%{} = row | _]}} ->
        Map.get(row, "uid") || Map.get(row, "id")

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp lookup_device_uid_by_mac(_srql_module, _scope, nil), do: nil

  defp lookup_device_uid_by_mac(srql_module, scope, mac) when is_binary(mac) do
    q = "in:devices mac:#{escape_value(mac)} limit:1"

    case srql_module.query(q, %{scope: scope}) do
      {:ok, %{"results" => [%{} = row | _]}} ->
        Map.get(row, "uid") || Map.get(row, "id")

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp read_rdns(nil, _ip), do: nil
  defp read_rdns(_user, nil), do: nil

  defp read_rdns(user, ip) when is_binary(ip) do
    query = IpRdnsCache |> Ash.Query.for_read(:by_ip, %{ip: ip})

    case Ash.read_one(query, actor: user) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  defp read_mapbox(nil), do: nil

  defp read_mapbox(user) do
    case MapboxSettings.get_settings(actor: user) do
      {:ok, %MapboxSettings{} = settings} -> settings
      _ -> nil
    end
  end

  defp read_geo(nil, _ip), do: nil
  defp read_geo(_user, nil), do: nil

  defp read_geo(user, ip) when is_binary(ip) do
    query = IpGeoEnrichmentCache |> Ash.Query.for_read(:by_ip, %{ip: ip})

    case Ash.read_one(query, actor: user) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  defp read_ipinfo(nil, _ip), do: nil
  defp read_ipinfo(_user, nil), do: nil

  defp read_ipinfo(user, ip) when is_binary(ip) do
    query = IpIpinfoCache |> Ash.Query.for_read(:by_ip, %{ip: ip})

    case Ash.read_one(query, actor: user) do
      {:ok, %IpIpinfoCache{} = record} -> record
      _ -> nil
    end
  end

  defp read_threat(nil, _ip), do: nil
  defp read_threat(_user, nil), do: nil

  defp read_threat(user, ip) when is_binary(ip) do
    query = IpThreatIntelCache |> Ash.Query.for_read(:by_ip, %{ip: ip})

    case Ash.read_one(query, actor: user) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  defp read_port_scan(nil, _ip), do: nil
  defp read_port_scan(_user, nil), do: nil

  defp read_port_scan(user, ip) when is_binary(ip) do
    query = NetflowPortScanFlag |> Ash.Query.for_read(:by_src_ip, %{src_ip: ip})

    case Ash.read_one(query, actor: user) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  defp read_port_anomaly(nil, _port), do: nil
  defp read_port_anomaly(_user, nil), do: nil

  defp read_port_anomaly(user, port) when is_integer(port) and port > 0 do
    query = NetflowPortAnomalyFlag |> Ash.Query.for_read(:by_port, %{dst_port: port})

    case Ash.read_one(query, actor: user) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  defp read_port_anomaly(_user, _port), do: nil

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
      if Map.get(next, "graph") == "sankey" do
        # Sankey dims are positional and should not require multi-select keyboard interaction.
        dims =
          allowed["dims"]
          |> List.wrap()
          |> Enum.map(&to_string/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.take(3)

        Map.put(next, "dims", dims)
      else
        Map.put(next, "dims", merge_dim_selection(Map.get(current, "dims", []), allowed["dims"]))
      end
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

    # Prefer "latest selection wins": newly selected dimensions become the primary series.
    # This makes the chart respond immediately when users click additional dimensions.
    (added ++ preserved)
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

    # IMPORTANT: `chart_query` may already be a downsample/stats query; for fallbacks we need a
    # "base flows" query without chart tokens.
    base = chart_base_query(chart_query, fallback_time)

    case graph do
      "sankey" ->
        max_edges = sankey_max_edges_from_state(state)

        edges = load_sankey_edges(srql_module, chart_query, base, state, scope, max_edges)

        dims = state |> dims_from_state() |> sanitize_sankey_dims()
        edges = reduce_sankey_clutter(edges, dims, max_edges)

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

  defp load_sankey_edges(srql_module, chart_query, base, state, scope, max_edges)
       when is_integer(max_edges) and max_edges > 0 do
    prefix = sankey_prefix_from_state(state)
    dims = state |> dims_from_state() |> sanitize_sankey_dims()

    case srql_module.query(chart_query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        edges =
          results
          |> extract_srql_rows()
          |> Enum.map(&srql_sankey_edge_from_row/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(&(-Map.get(&1, :bytes, 0)))
          |> Enum.take(max_edges)

        if edges == [] do
          sankey =
            NFQuery.load_sankey(srql_module, base, scope,
              prefix: prefix,
              dims: dims,
              max_edges: max_edges
            )

          Map.get(sankey, :edges, [])
        else
          edges
        end

      _ ->
        sankey =
          NFQuery.load_sankey(srql_module, base, scope,
            prefix: prefix,
            dims: dims,
            max_edges: max_edges
          )

        Map.get(sankey, :edges, [])
    end
  rescue
    _ -> []
  end

  defp reduce_sankey_clutter(edges, dims, max_edges)
       when is_list(edges) and is_list(dims) and is_integer(max_edges) do
    # IP-mode Sankey gets unreadable quickly (too many unique endpoints). We bucket low-volume
    # endpoints into "Other" and then re-aggregate the edge weights.
    src_dim = Enum.at(dims, 0) || "src_cidr"
    dst_dim = Enum.at(dims, 2) || "dst_cidr"

    # Prefer more aggressive bucketing when showing per-IP.
    top_src = if src_dim == "src_ip", do: 8, else: 12
    top_dst = if dst_dim == "dst_ip", do: 8, else: 12

    {top_src_set, top_dst_set} = sankey_top_endpoint_sets(edges, top_src, top_dst)

    edges =
      edges
      |> Enum.map(fn
        %{src: src, dst: dst} = e ->
          # Use per-column "Other" labels to avoid Sankey cycles when labels collide across columns.
          src = if src in top_src_set, do: src, else: "Other (src)"
          dst = if dst in top_dst_set, do: dst, else: "Other (dst)"
          %{e | src: src, dst: dst}

        other ->
          other
      end)
      |> sankey_aggregate_edges()
      |> Enum.sort_by(&(-Map.get(&1, :bytes, 0)))
      |> Enum.take(max_edges)

    edges
  rescue
    _ -> edges
  end

  defp reduce_sankey_clutter(edges, _dims, _max_edges), do: edges

  defp sankey_top_endpoint_sets(edges, top_src, top_dst)
       when is_list(edges) and is_integer(top_src) and is_integer(top_dst) do
    {src_bytes, dst_bytes} =
      Enum.reduce(edges, {%{}, %{}}, fn
        %{src: src, dst: dst, bytes: bytes}, {sa, da}
        when is_binary(src) and is_binary(dst) and is_integer(bytes) ->
          sa = Map.update(sa, src, bytes, &(&1 + bytes))
          da = Map.update(da, dst, bytes, &(&1 + bytes))
          {sa, da}

        _e, acc ->
          acc
      end)

    src_top =
      src_bytes
      |> Enum.sort_by(fn {_k, v} -> -v end)
      |> Enum.take(max(top_src, 1))
      |> Enum.map(fn {k, _} -> k end)
      |> MapSet.new()

    dst_top =
      dst_bytes
      |> Enum.sort_by(fn {_k, v} -> -v end)
      |> Enum.take(max(top_dst, 1))
      |> Enum.map(fn {k, _} -> k end)
      |> MapSet.new()

    {src_top, dst_top}
  end

  defp sankey_top_endpoint_sets(_edges, _top_src, _top_dst), do: {MapSet.new(), MapSet.new()}

  defp sankey_aggregate_edges(edges) when is_list(edges) do
    edges
    |> Enum.reduce(%{}, fn
      %{src: src, mid: mid, dst: dst, bytes: bytes} = e, acc
      when is_binary(src) and is_binary(mid) and is_binary(dst) and is_integer(bytes) ->
        key = {src, mid, dst}

        Map.update(acc, key, e, fn prev ->
          Map.update(prev, :bytes, bytes, &(&1 + bytes))
        end)

      _e, acc ->
        acc
    end)
    |> Map.values()
  end

  defp sankey_aggregate_edges(other), do: other

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
      {i, ""} ->
        i

      _ ->
        # SRQL may serialize aggregates as float strings (e.g. "123.0" or "1.23e4").
        case Float.parse(value) do
          {f, ""} -> trunc(f)
          _ -> 0
        end
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

  defp srql_sankey_edge_from_row(_), do: nil

  defp sankey_endpoint(%{} = row, :src) do
    # SRQL group-by expressions can surface as different column names (e.g. "src_cidr",
    # "src_cidr:24", or aliased variants). Be tolerant so sankey charts don't go empty
    # just because a column name changed.
    find_key = fn prefix ->
      row
      |> Map.keys()
      |> Enum.find(fn
        k when is_binary(k) -> String.starts_with?(k, prefix)
        _ -> false
      end)
    end

    cidr_key = find_key.("src_cidr")
    ip_key = find_key.("src_endpoint_ip") || find_key.("src_ip")

    cond do
      is_binary(cidr_key) and is_binary(Map.get(row, cidr_key)) ->
        {"src_cidr", Map.get(row, cidr_key)}

      is_binary(ip_key) and is_binary(Map.get(row, ip_key)) ->
        {"src_ip", Map.get(row, ip_key)}

      true ->
        {nil, nil}
    end
  end

  defp sankey_endpoint(%{} = row, :dst) do
    find_key = fn prefix ->
      row
      |> Map.keys()
      |> Enum.find(fn
        k when is_binary(k) -> String.starts_with?(k, prefix)
        _ -> false
      end)
    end

    cidr_key = find_key.("dst_cidr")
    ip_key = find_key.("dst_endpoint_ip") || find_key.("dst_ip")

    cond do
      is_binary(cidr_key) and is_binary(Map.get(row, cidr_key)) ->
        {"dst_cidr", Map.get(row, cidr_key)}

      is_binary(ip_key) and is_binary(Map.get(row, ip_key)) ->
        {"dst_ip", Map.get(row, ip_key)}

      true ->
        {nil, nil}
    end
  end

  defp sankey_endpoint(_row, _side), do: {nil, nil}

  defp sankey_mid(%{} = row) do
    find_key = fn prefix ->
      row
      |> Map.keys()
      |> Enum.find(fn
        k when is_binary(k) -> String.starts_with?(k, prefix)
        _ -> false
      end)
    end

    port_key = find_key.("dst_endpoint_port") || find_key.("dst_port")

    cond do
      is_binary(port_key) and not is_nil(Map.get(row, port_key)) ->
        p = to_int(Map.get(row, port_key))
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
    do: to_string(port)

  defp sankey_mid_label(_mid_field, mid_value, _port) when is_binary(mid_value) do
    v = String.trim(mid_value)
    if v == "", do: "PORT:?", else: v
  end

  defp sankey_mid_label(_mid_field, _mid_value, _port), do: "?"

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

  defp format_flow_time_short(nil), do: nil
  defp format_flow_time_short(""), do: nil

  defp format_flow_time_short(value) when is_binary(value) do
    v = String.trim(value)

    case DateTime.from_iso8601(v) do
      {:ok, dt, _} ->
        Calendar.strftime(dt, "%H:%M:%S")

      _ ->
        case NaiveDateTime.from_iso8601(v) do
          {:ok, ndt} ->
            dt = DateTime.from_naive!(ndt, "Etc/UTC")
            Calendar.strftime(dt, "%H:%M:%S")

          _ ->
            v
        end
    end
  end

  defp format_flow_time_short(other), do: to_string(other || "")

  defp format_bytes_parts(nil), do: {"—", ""}
  defp format_bytes_parts(""), do: {"—", ""}

  defp format_bytes_parts(value) do
    bytes = to_int(value)
    abs_bytes = abs(bytes)

    cond do
      abs_bytes >= 1024 * 1024 * 1024 ->
        {format_float(bytes / (1024 * 1024 * 1024)), "GB"}

      abs_bytes >= 1024 * 1024 ->
        {format_float(bytes / (1024 * 1024)), "MB"}

      abs_bytes >= 1024 ->
        {format_float(bytes / 1024), "KB"}

      true ->
        {Integer.to_string(bytes), "B"}
    end
  rescue
    _ -> {"—", ""}
  end

  defp format_float(v) when is_float(v) do
    # Compact but readable for table cells.
    if abs(v) >= 10.0,
      do: :erlang.float_to_binary(v, decimals: 1),
      else: :erlang.float_to_binary(v, decimals: 2)
  end

  defp format_float(v) when is_integer(v), do: Integer.to_string(v)
  defp format_float(v) when is_binary(v), do: v
  defp format_float(_), do: "0"
end
