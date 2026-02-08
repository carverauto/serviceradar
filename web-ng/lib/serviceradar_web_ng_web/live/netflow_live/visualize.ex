defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize do
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNGWeb.NetflowVisualize.State, as: NFState
  alias ServiceRadarWebNGWeb.NetflowVisualize.Query, as: NFQuery
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  import ServiceRadarWebNGWeb.SRQLComponents

  @default_limit 100
  @max_limit 200

  @nf_dims_ordered [
    {"Protocol (group)", "protocol_group"},
    {"Application", "app"},
    {"Dest port", "dst_port"},
    {"Source IP", "src_ip"},
    {"Dest IP", "dst_ip"},
    {"Protocol (name)", "protocol_name"},
    {"Sampler address", "sampler_address"},
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
      |> assign(:netflow_sankey_edges_json, "[]")
      |> assign(:nf_dims_ordered, @nf_dims_ordered)
      |> assign(:limit, @default_limit)
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

    socket =
      socket
      |> assign(:netflow_viz_state, state)
      |> assign(:netflow_viz_state_error, state_error)
      |> SRQLPage.load_list(params, uri, :netflows,
        default_limit: @default_limit,
        max_limit: @max_limit,
        limit_assign_key: :limit
      )

    socket =
      socket
      |> load_visualize_chart(params, state)

    {:noreply, socket}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/netflow")}
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
       fallback_path: "/netflow"
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
    socket = assign(socket, :netflow_viz_state, NFState.default())

    case NFState.encode_param(socket.assigns.netflow_viz_state) do
      {:ok, nf} ->
        {:noreply, push_patch(socket, to: build_patch_url(socket, %{"nf" => nf}))}

      _ ->
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

    {:noreply, patch_nf_state(socket, next)}
  end

  def handle_event("nf_dim_move", %{"dim" => dim, "dir" => dir}, socket)
      when is_binary(dim) and dir in ["up", "down"] do
    current = Map.get(socket.assigns, :netflow_viz_state, NFState.default())
    dims = current |> Map.get("dims", []) |> List.wrap() |> Enum.map(&to_string/1)
    next_dims = move_dim(dims, dim, dir)
    next = Map.put(current, "dims", next_dims)

    socket = assign(socket, :netflow_viz_state, next)
    {:noreply, patch_nf_state(socket, next)}
  end

  def handle_event("nf_dim_remove", %{"dim" => dim}, socket) when is_binary(dim) do
    current = Map.get(socket.assigns, :netflow_viz_state, NFState.default())
    dims = current |> Map.get("dims", []) |> List.wrap() |> Enum.map(&to_string/1)
    next_dims = Enum.reject(dims, &(&1 == dim))
    next = Map.put(current, "dims", next_dims)

    socket = assign(socket, :netflow_viz_state, next)
    {:noreply, patch_nf_state(socket, next)}
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
                <div class="flex flex-col gap-2">
                  <.srql_query_bar
                    query={Map.get(@srql, :query)}
                    draft={Map.get(@srql, :draft)}
                    loading={Map.get(@srql, :loading, false)}
                    builder_available={Map.get(@srql, :builder_available, true)}
                    builder_open={Map.get(@srql, :builder_open, false)}
                    builder_supported={Map.get(@srql, :builder_supported, true)}
                    builder_sync={Map.get(@srql, :builder_sync, true)}
                    builder={Map.get(@srql, :builder, %{})}
                  />

                  <div :if={!Map.get(@srql, :builder_supported, true)} class="text-xs text-warning">
                    This SRQL query can’t be fully represented by the builder yet. The builder won’t overwrite your
                    query unless you click “Replace query”.
                  </div>

                  <div :if={Map.get(@srql, :error)} class="text-xs text-error font-mono">
                    SRQL error: {Map.get(@srql, :error)}
                  </div>
                </div>
              </div>
            </div>

            <.srql_auto_viz viz={Map.get(@srql, :viz, :none)} />

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
                      >
                        <svg class="w-full h-full"></svg>
                      </div>
                  <% end %>
                </div>
              </div>
            </div>

            <.srql_results_table
              id="netflow-results"
              rows={@netflows}
              empty_message="No flows in this window."
            />
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp build_patch_url(socket, extra_params) do
    base = %{
      "q" => Map.get(socket.assigns.srql, :query),
      "limit" => Map.get(socket.assigns, :limit)
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

  defp load_visualize_chart(socket, params, %{} = state) do
    srql_module = Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
    scope = socket.assigns.current_scope

    graph = Map.get(state, "graph", "stacked")
    fallback_time = Map.get(state, "time", "last_1h")
    units = Map.get(state, "units", "Bps")
    dims = Map.get(state, "dims", [])
    series_limit = Map.get(state, "limit", 12)
    limit_type = Map.get(state, "limit_type", "avg")

    base =
      NFQuery.flows_base_query(
        Map.get(params, "q") || Map.get(socket.assigns.srql, :query) || "",
        fallback_time
      )

    if graph == "sankey" do
      prefix = sankey_prefix_from_state(state)

      sankey =
        NFQuery.load_sankey(srql_module, base, scope,
          prefix: prefix,
          dims: dims,
          max_edges: 300
        )

      edges_json = Jason.encode!(Map.get(sankey, :edges, []))

      socket
      |> assign(:netflow_sankey_edges_json, edges_json)
    else
      series_field = NFQuery.downsample_series_field_from_dims(dims)
      bucket = "5m"
      {value_field, scale_fun} = units_to_value_field_and_scale(units, bucket)

      {keys, points} =
        NFQuery.load_downsample_series(srql_module, base, scope,
          series_field: series_field,
          bucket: bucket,
          value_field: value_field,
          agg: "sum",
          limit: 2000
        )

      {keys, points} = NFQuery.top_n(keys, points, series_limit, limit_type)
      points = NFQuery.scale_points(points, scale_fun)

      socket
      |> assign(:netflow_chart_keys_json, Jason.encode!(keys))
      |> assign(:netflow_chart_points_json, Jason.encode!(points))
      |> assign(:netflow_chart_colors_json, Jason.encode!(%{}))
    end
  rescue
    _ ->
      socket
      |> assign(:netflow_chart_keys_json, "[]")
      |> assign(:netflow_chart_points_json, "[]")
      |> assign(:netflow_chart_colors_json, "{}")
      |> assign(:netflow_sankey_edges_json, "[]")
  end
end
