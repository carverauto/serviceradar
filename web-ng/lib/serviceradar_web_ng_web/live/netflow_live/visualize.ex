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
    bidirectional = Map.get(state, "bidirectional", false) == true
    previous_period = Map.get(state, "previous_period", false) == true

    base =
      NFQuery.flows_base_query(
        Map.get(params, "q") || Map.get(socket.assigns.srql, :query) || "",
        fallback_time
      )

    case graph do
      "sankey" ->
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
        |> assign(:netflow_chart_overlays_json, "[]")

      _ ->
        series_field = NFQuery.downsample_series_field_from_dims(dims)
        bucket = "5m"
        {value_field, scale_fun} = units_to_value_field_and_scale(units, bucket)

        {keys, points} =
          load_primary_series(srql_module, base, scope,
            graph: graph,
            series_field: series_field,
            bucket: bucket,
            value_field: value_field,
            scale_fun: scale_fun,
            series_limit: series_limit,
            limit_type: limit_type,
            bidirectional: bidirectional,
            previous_period: previous_period
          )

        overlays =
          load_overlays(srql_module, base, scope,
            graph: graph,
            keys: keys,
            series_field: series_field,
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
