defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Integrations.MapboxSettings
  alias ServiceRadar.Observability.IpGeoEnrichmentCache
  alias ServiceRadar.Observability.IpIpinfoCache
  alias ServiceRadar.Observability.IpRdnsCache
  alias ServiceRadar.Observability.IpThreatIntelCache
  alias ServiceRadar.Observability.NetflowPortAnomalyFlag
  alias ServiceRadar.Observability.NetflowPortScanFlag
  alias ServiceRadarWebNGWeb.NetflowVisualize.Query, as: NFQuery
  alias ServiceRadarWebNGWeb.NetflowVisualize.State, as: NFState
  alias ServiceRadarWebNGWeb.SRQL.Builder, as: SRQLBuilder
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  require Ash.Query
  require Logger

  @default_limit 100
  @max_limit 200
  @default_time "last_1h"
  @default_bucket "5m"
  @chart_limit 4000
  @arin_cache_table :netflow_arin_asn_cache
  @arin_cache_ttl_ms 6 * 60 * 60 * 1000
  @arin_cache_negative_ttl_ms 60 * 1000

  @nf_dims_ordered [
    {"Protocol (group)", "protocol_group"},
    {"Application", "app"},
    {"Flow source", "flow_source"},
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
      |> assign(:active_tab, "netflows")
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
      |> assign(:arin_lookup, %{})
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

    q_param = params |> Map.get("q") |> normalize_optional_string()

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
        |> maybe_open_flow_from_params(params)

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
       fallback_path: "/observability/flows",
       extra_params: srql_submit_extra_params(socket)
     )}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_toggle", %{},
       entity: "flows",
       fallback_path: "/observability/flows"
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
       fallback_path: "/observability/flows",
       extra_params: srql_submit_extra_params(socket)
     )}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "flows")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "flows")}
  end

  def handle_event("bgp_add_as_filter", %{"as_number" => as_number}, socket) do
    case Integer.parse(as_number) do
      {as_int, ""} when as_int > 0 and as_int <= 4_294_967_295 ->
        params = %{"field" => "as_path", "value" => to_string(as_int)}
        {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "flows")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("bgp_add_community_filter", params, socket) do
    community_value =
      case Map.get(params, "community") do
        # From quick button click (already an integer string)
        val when is_binary(val) -> val
        # From form submission
        _ -> ""
      end

    # Try parsing the community value
    parsed_community =
      cond do
        # Direct integer value
        String.match?(community_value, ~r/^\d+$/) ->
          community_value

        # AS:value format (e.g., "65000:100")
        String.contains?(community_value, ":") ->
          case String.split(community_value, ":") do
            [as_str, value_str] ->
              with {as_num, ""} <- Integer.parse(as_str),
                   {value_num, ""} <- Integer.parse(value_str),
                   true <- as_num >= 0 and as_num <= 65_535,
                   true <- value_num >= 0 and value_num <= 65_535 do
                # Encode as 32-bit integer: (AS << 16) | value
                encoded = Bitwise.bor(Bitwise.bsl(as_num, 16), value_num)
                to_string(encoded)
              else
                _ -> nil
              end

            _ ->
              nil
          end

        true ->
          nil
      end

    if parsed_community do
      params = %{"field" => "bgp_communities", "value" => parsed_community}
      {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "flows")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("bgp_clear_filters", _params, socket) do
    socket =
      socket
      |> SRQLPage.handle_event("srql_builder_remove_filter", %{"field" => "as_path"}, entity: "flows")
      |> SRQLPage.handle_event("srql_builder_remove_filter", %{"field" => "bgp_communities"}, entity: "flows")

    {:noreply, socket}
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
      end

    context = load_flow_context(selected, socket.assigns.current_scope)

    {:noreply,
     socket
     |> assign(:selected_flow, selected)
     |> assign(:selected_flow_context, context)
     |> assign(:arin_lookup, %{})}
  end

  def handle_event("netflow_close", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_flow, nil)
     |> assign(:selected_flow_context, %{})
     |> assign(:arin_lookup, %{})}
  end

  def handle_event("netflow_lookup_asn", %{"asn" => asn_raw} = params, socket) do
    asn = to_int(asn_raw)
    rir_hint = normalize_rir_hint(Map.get(params, "rir_hint"))

    if is_integer(asn) and asn > 0 do
      lookup =
        case fetch_asn_registry_data(asn, rir_hint) do
          {:ok, data} ->
            %{asn: asn, loading: false, data: data, error: nil}

          {:error, reason} ->
            %{asn: asn, loading: false, data: nil, error: arin_error_text(reason)}
        end

      {:noreply, assign(socket, :arin_lookup, lookup)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("netflow_sankey_edge", %{} = params, socket) do
    src = params |> Map.get("src") |> normalize_optional_string()
    dst = params |> Map.get("dst") |> normalize_optional_string()

    port = parse_optional_port(Map.get(params, "port"))
    mid_field = params |> Map.get("mid_field") |> normalize_optional_string()
    mid_value = params |> Map.get("mid_value") |> normalize_optional_string()

    # Edges involving "Other" are bucketed aggregates (not a concrete endpoint). SRQL doesn't
    # have a clean way to express "everything except top-N", so clicking these should not
    # navigate to an empty chart.
    src_bucketed =
      is_binary(src) and (src in ["Other", "Unknown"] or String.starts_with?(src, "Other"))

    dst_bucketed =
      is_binary(dst) and (dst in ["Other", "Unknown"] or String.starts_with?(dst, "Other"))

    if src_bucketed or dst_bucketed do
      {:noreply,
       put_flash(socket, :info, "This edge is bucketed as Other. Increase detail (or switch dims) to drill in.")}
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
         to: build_patch_url(socket, %{"q" => chart_query, "cursor" => nil, "nf" => nf_param(state)})
       )}
    end
  end

  def handle_event("netflow_stack_series", %{"field" => field, "value" => value}, socket) do
    field = (field || "") |> to_string() |> String.trim()
    value = (value || "") |> to_string() |> String.trim()

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

  def handle_event("nf_dim_move", %{"dim" => dim, "dir" => dir}, socket) when is_binary(dim) and dir in ["up", "down"] do
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
         to: build_patch_url(socket, %{"nf" => nf_param(next), "q" => chart_query, "cursor" => nil})
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
         to: build_patch_url(socket, %{"nf" => nf_param(next), "q" => chart_query, "cursor" => nil})
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6 space-y-4">
        <.observability_chrome active_pane="netflows" />

        <div class="flex flex-col lg:flex-row gap-4 items-start">
          <aside class="w-full lg:w-80 shrink-0">
            <div class="card bg-base-100 border border-base-200">
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
                  
    <!-- BGP Filters Section -->
                  <div class="col-span-full mt-4 pt-4 border-t border-base-200">
                    <details class="collapse collapse-arrow bg-base-200/30 rounded-lg">
                      <summary class="collapse-title text-xs font-semibold text-base-content/70 min-h-0 py-2 px-3">
                        BGP Routing Filters
                      </summary>
                      <div class="collapse-content px-3 pb-3">
                        <.bgp_filter_inputs query={Map.get(@srql, :query) || ""} />
                      </div>
                    </details>
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
            <div class="card bg-base-100 border border-base-200">
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

            <div class="card bg-base-100 border border-base-200">
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
                  base_path="/observability/flows"
                  query={Map.get(@srql, :query) || ""}
                  limit={@limit}
                  nf_param={nf_param(@netflow_viz_state)}
                  unit_mode={Map.get(@netflow_viz_state, "units", "Bps")}
                />

                <div class="pt-3 border-t border-base-200">
                  <.ui_pagination
                    prev_cursor={Map.get(@flows_pagination, "prev_cursor")}
                    next_cursor={Map.get(@flows_pagination, "next_cursor")}
                    base_path="/observability/flows"
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
              arin_lookup={@arin_lookup}
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
  attr(:unit_mode, :string, default: "Bps")

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
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-16 text-right">
              Source
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-28 text-right">
              {flows_table_traffic_header(@unit_mode)}
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
                <% flow_src = flow_get_in(flow, ["ocsf_payload", "flow_source"]) %>
                <.ui_badge
                  :if={is_binary(flow_src) and flow_src != "Unknown"}
                  variant={
                    cond do
                      String.starts_with?(flow_src, "sFlow") -> "info"
                      String.starts_with?(flow_src, "IPFIX") -> "warning"
                      true -> "success"
                    end
                  }
                  size="xs"
                  class="font-mono"
                >
                  {flow_src}
                </.ui_badge>
                <span
                  :if={!is_binary(flow_src) or flow_src == "Unknown"}
                  class="text-base-content/40"
                >
                  —
                </span>
              </td>
              <td class="whitespace-nowrap text-xs text-right font-mono align-top">
                <% packets = flow_get(flow, ["packets_total", "packets"]) %>
                <% raw_bytes = flow_get(flow, ["bytes_total", "bytes"]) %>
                <%= case @unit_mode do %>
                  <% "pps" -> %>
                    <div class="flex flex-col items-end leading-tight">
                      <div>{packets || "—"}</div>
                    </div>
                  <% "bps" -> %>
                    <% {bits_val, bits_unit} = format_bits_parts(raw_bytes) %>
                    <div class="flex flex-col items-end leading-tight">
                      <div>{packets || "—"}</div>
                      <div class="flex items-baseline gap-1 text-[10px] text-base-content/60">
                        <span>{bits_val}</span>
                        <span :if={bits_unit != ""} class="uppercase">{bits_unit}</span>
                      </div>
                    </div>
                  <% _ -> %>
                    <% {bytes_val, bytes_unit} = format_bytes_parts(raw_bytes) %>
                    <div class="flex flex-col items-end leading-tight">
                      <div>{packets || "—"}</div>
                      <div class="flex items-baseline gap-1 text-[10px] text-base-content/60">
                        <span>{bytes_val}</span>
                        <span :if={bytes_unit != ""} class="uppercase">{bytes_unit}</span>
                      </div>
                    </div>
                <% end %>
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
    :protocol_source,
    :tcp_flags,
    :tcp_flags_labels,
    :tcp_flags_source,
    :dst_service_label,
    :dst_service_source,
    :packets_total,
    :packets,
    :bytes_total,
    :bytes,
    :bytes_in,
    :bytes_out,
    :direction_label,
    :direction_source,
    :src_hosting_provider,
    :src_hosting_provider_source,
    :dst_hosting_provider,
    :dst_hosting_provider_source,
    :src_mac,
    :dst_mac,
    :src_mac_vendor,
    :src_mac_vendor_source,
    :dst_mac_vendor,
    :dst_mac_vendor_source,
    :sampler_address,
    :src_country_iso2,
    :dst_country_iso2,
    :ocsf_payload,
    :ocsf
  ]

  @flow_key_atom_map Map.new(@flow_key_atoms, fn a -> {Atom.to_string(a), a} end)

  defp flow_get(flow, keys) when is_map(flow) and is_list(keys) do
    keys
    |> Enum.find_value(fn k ->
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
    # Prefer persisted enrichment labels first.
    flow_get(flow, ["dst_service_label", "app", "app_label"]) ||
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
      end
    end
  end

  defp iso2_flag_emoji(_), do: nil

  defp tcp_flag_tooltip(flag) when is_binary(flag) do
    case String.upcase(String.trim(flag)) do
      "SYN" -> "SYN: Starts a TCP connection."
      "ACK" -> "ACK: Acknowledges received data."
      "FIN" -> "FIN: Requests a graceful connection close."
      "RST" -> "RST: Abruptly resets the connection."
      "PSH" -> "PSH: Pushes buffered data to the application immediately."
      "URG" -> "URG: Marks urgent data in this segment."
      "ECE" -> "ECE: Signals Explicit Congestion Notification."
      "CWR" -> "CWR: Confirms congestion window was reduced."
      "NS" -> "NS: ECN nonce protection flag (rare)."
      _ -> "TCP flag."
    end
  end

  defp tcp_flag_tooltip(_), do: "TCP flag."

  defp flows_filter_patch(base_path, query, limit, nf, field, value) do
    value = (value || "") |> to_string() |> String.trim()

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
      String.trim(query <> " " <> "#{field}:#{value}")
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
      Map.merge(srql, %{
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

  defp load_srql_assigns(socket, other, uri, limit), do: load_srql_assigns(socket, to_string(other || ""), uri, limit)

  defp load_flows_list(socket, params, %{} = state) do
    srql_module = Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
    scope = socket.assigns.current_scope

    chart_query = Map.get(socket.assigns.srql, :query) || ""
    fallback_time = Map.get(state, "time", @default_time)

    list_query =
      chart_query
      |> flows_list_base_query(fallback_time)
      |> ensure_sort_time_desc()

    window_label = flows_window_label_from_query(list_query, fallback_time)

    cursor = params |> Map.get("cursor") |> normalize_optional_string()
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

  defp maybe_open_flow_from_params(socket, params) do
    if Map.get(params, "open") == "first" do
      selected = List.first(Map.get(socket.assigns, :flows, []))
      context = load_flow_context(selected, socket.assigns.current_scope)

      socket
      |> assign(:selected_flow, selected)
      |> assign(:selected_flow_context, context)
    else
      socket
    end
  end

  defp ensure_sort_time_desc(query) when is_binary(query) do
    q = String.trim(query)

    if Regex.match?(~r/(?:^|\s)sort:/, q) do
      q
    else
      String.trim(q <> " sort:time:desc")
    end
  end

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

  defp flows_window_label_from_query(query, fallback_time) when is_binary(query) and is_binary(fallback_time) do
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

  attr(:community, :integer, required: true)

  defp bgp_community_badge_small(assigns) do
    community_value = assigns.community

    display_text =
      case community_value do
        0xFFFFFF01 ->
          "NO_EXPORT"

        0xFFFFFF02 ->
          "NO_ADVERTISE"

        0xFFFFFF03 ->
          "NO_EXPORT_SUBCONFED"

        0xFFFFFF04 ->
          "NOPEER"

        _ ->
          as_number = Bitwise.bsr(community_value, 16)
          value = Bitwise.band(community_value, 0xFFFF)
          "#{as_number}:#{value}"
      end

    assigns = assign(assigns, :display_text, display_text)

    ~H"""
    <span class="badge badge-xs badge-info font-mono">{@display_text}</span>
    """
  end

  attr(:query, :string, required: true)

  defp bgp_filter_inputs(assigns) do
    # Parse current query to extract BGP filters
    as_filter = extract_filter_value(assigns.query, "as_path")
    community_filter = extract_filter_value(assigns.query, "bgp_communities")

    assigns =
      assigns
      |> assign(:as_filter, as_filter)
      |> assign(:community_filter, community_filter)
      |> assign(:has_filters, as_filter != "" || community_filter != "")

    ~H"""
    <div class="space-y-3">
      <div class="text-[11px] text-base-content/60 mb-2">
        Filter flows by BGP routing information. Filters are automatically added to your SRQL query.
      </div>
      
    <!-- Active BGP Filters Display -->
      <div
        :if={@has_filters}
        class="flex items-center gap-2 flex-wrap p-2 bg-primary/5 rounded-md border border-primary/20"
      >
        <span class="text-xs text-base-content/60">Active BGP filters:</span>
        <div :if={@as_filter != ""} class="badge badge-primary badge-sm gap-1">
          <span>AS Path: {@as_filter}</span>
          <button
            type="button"
            phx-click="srql_builder_remove_filter"
            phx-value-field="as_path"
            class="text-primary-content hover:text-error"
            title="Remove AS filter"
          >
            ✕
          </button>
        </div>
        <div :if={@community_filter != ""} class="badge badge-info badge-sm gap-1">
          <span>Community: {decode_community_display(@community_filter)}</span>
          <button
            type="button"
            phx-click="srql_builder_remove_filter"
            phx-value-field="bgp_communities"
            class="text-info-content hover:text-error"
            title="Remove community filter"
          >
            ✕
          </button>
        </div>
      </div>
      
    <!-- AS Number Filter Input -->
      <div>
        <label class="text-xs font-semibold text-base-content/70 mb-1 block">
          AS Number
        </label>
        <form phx-submit="bgp_add_as_filter" class="flex gap-2">
          <input
            type="number"
            name="as_number"
            placeholder="e.g., 64512"
            min="1"
            max="4294967295"
            class="input input-bordered input-sm flex-1 font-mono text-xs"
          />
          <button type="submit" class="btn btn-primary btn-sm">
            Add AS Filter
          </button>
        </form>
        <div class="mt-1 text-[10px] text-base-content/50">
          Filter flows where AS path contains this autonomous system number
        </div>
      </div>
      
    <!-- BGP Community Filter Input -->
      <div>
        <label class="text-xs font-semibold text-base-content/70 mb-1 block">
          BGP Community
        </label>
        <form phx-submit="bgp_add_community_filter" class="space-y-2">
          <div class="flex gap-2">
            <input
              type="text"
              name="community"
              placeholder="e.g., 65000:100 or 4259840100"
              class="input input-bordered input-sm flex-1 font-mono text-xs"
            />
            <button type="submit" class="btn btn-info btn-sm">
              Add Community Filter
            </button>
          </div>
          <div class="text-[10px] text-base-content/50">
            Enter as AS:value (e.g., 65000:100) or raw 32-bit integer (e.g., 4259840100)
          </div>
        </form>
      </div>
      
    <!-- Quick filters for well-known communities -->
      <div>
        <label class="text-xs font-semibold text-base-content/70 mb-1 block">
          Well-Known Communities
        </label>
        <div class="flex flex-wrap gap-2">
          <button
            type="button"
            phx-click="bgp_add_community_filter"
            phx-value-community="4294967041"
            class="btn btn-xs btn-outline btn-warning"
          >
            NO_EXPORT
          </button>
          <button
            type="button"
            phx-click="bgp_add_community_filter"
            phx-value-community="4294967042"
            class="btn btn-xs btn-outline btn-error"
          >
            NO_ADVERTISE
          </button>
          <button
            type="button"
            phx-click="bgp_add_community_filter"
            phx-value-community="4294967043"
            class="btn btn-xs btn-outline btn-warning"
          >
            NO_EXPORT_SUBCONFED
          </button>
        </div>
        <div class="mt-1 text-[10px] text-base-content/50">
          Quick add filters for RFC 1997 well-known communities
        </div>
      </div>
      
    <!-- Clear all BGP filters -->
      <div :if={@has_filters} class="pt-2">
        <button
          type="button"
          phx-click="bgp_clear_filters"
          class="btn btn-sm btn-ghost btn-outline text-error w-full"
        >
          Clear All BGP Filters
        </button>
      </div>
    </div>
    """
  end

  # Helper function to extract filter value from SRQL query
  defp extract_filter_value(query, field) when is_binary(query) do
    # Match patterns like: field:[value] or field:value
    regex = ~r/#{field}:\[?([^\]\s]+)\]?/

    case Regex.run(regex, query) do
      [_, value] -> value
      _ -> ""
    end
  end

  defp extract_filter_value(_, _), do: ""

  # Helper function to decode community for display
  defp decode_community_display(value) when is_binary(value) do
    case Integer.parse(value) do
      {community_int, ""} ->
        case community_int do
          0xFFFFFF01 ->
            "NO_EXPORT (#{value})"

          0xFFFFFF02 ->
            "NO_ADVERTISE (#{value})"

          0xFFFFFF03 ->
            "NO_EXPORT_SUBCONFED (#{value})"

          _ ->
            as_number = Bitwise.bsr(community_int, 16)
            val = Bitwise.band(community_int, 0xFFFF)
            "#{as_number}:#{val}"
        end

      _ ->
        value
    end
  end

  defp decode_community_display(value), do: value

  attr(:flow, :map, required: true)

  defp bgp_section(assigns) do
    # Extract BGP data from flow
    as_path = flow_get(assigns.flow, ["as_path"]) || []
    bgp_communities = flow_get(assigns.flow, ["bgp_communities"]) || []

    assigns =
      assigns
      |> assign(:as_path, as_path)
      |> assign(:bgp_communities, bgp_communities)
      |> assign(:has_bgp_data, not Enum.empty?(as_path) or not Enum.empty?(bgp_communities))
      |> assign(:as_path_collapsed, length(as_path) > 10)

    ~H"""
    <div class="text-xs uppercase tracking-wider text-base-content/50 mb-2">BGP Routing</div>

    <%= if @has_bgp_data do %>
      <!-- AS Path Display -->
      <div :if={length(@as_path) > 0} class="mb-3">
        <div class="text-xs font-semibold text-base-content/70 mb-1">AS Path</div>
        <div class="flex items-center gap-1 flex-wrap font-mono text-sm">
          <.as_path_display as_path={@as_path} />
        </div>
      </div>
      
    <!-- BGP Communities Display -->
      <div :if={length(@bgp_communities) > 0}>
        <div class="text-xs font-semibold text-base-content/70 mb-1">BGP Communities</div>
        <div class="flex items-center gap-1 flex-wrap">
          <%= for community <- @bgp_communities do %>
            <.bgp_community_badge community={community} />
          <% end %>
        </div>
      </div>
    <% else %>
      <div class="text-sm text-base-content/60">
        No BGP routing information available for this flow
      </div>
    <% end %>
    """
  end

  attr(:as_path, :list, required: true)

  defp as_path_display(assigns) do
    path_length = length(assigns.as_path)

    # If path is long, show first 5, ellipsis, and last 5
    {display_path, show_expand} =
      if path_length > 10 do
        first_five = Enum.take(assigns.as_path, 5)
        last_five = Enum.take(assigns.as_path, -5)
        {first_five ++ [:ellipsis] ++ last_five, true}
      else
        {assigns.as_path, false}
      end

    assigns =
      assigns
      |> assign(:display_path, display_path)
      |> assign(:show_expand, show_expand)
      |> assign(:path_length, path_length)

    ~H"""
    <%= for {item, index} <- Enum.with_index(@display_path) do %>
      <%= if item == :ellipsis do %>
        <span class="text-base-content/40 text-xs">
          ... ({@path_length - 10} more ASNs) ...
        </span>
      <% else %>
        <%= if index > 0 and Enum.at(@display_path, index - 1) != :ellipsis do %>
          <span class="text-base-content/40">→</span>
        <% end %>
        <span class="px-2 py-0.5 rounded bg-primary/10 text-primary border border-primary/20">
          AS{item}
        </span>
      <% end %>
    <% end %>
    """
  end

  attr(:community, :integer, required: true)

  defp bgp_community_badge(assigns) do
    # Decode BGP community from 32-bit integer to AS:value format
    # Format: (high 16 bits = AS number) : (low 16 bits = value)
    community_value = assigns.community

    {display_text, badge_class} =
      case community_value do
        # Well-known communities (RFC 1997)
        0xFFFFFF01 ->
          {"NO_EXPORT", "badge-warning"}

        0xFFFFFF02 ->
          {"NO_ADVERTISE", "badge-error"}

        0xFFFFFF03 ->
          {"NO_EXPORT_SUBCONFED", "badge-warning"}

        0xFFFFFF04 ->
          {"NOPEER", "badge-error"}

        # Regular community - decode to AS:value
        _ ->
          as_number = Bitwise.bsr(community_value, 16)
          value = Bitwise.band(community_value, 0xFFFF)
          {"#{as_number}:#{value}", "badge-info"}
      end

    assigns =
      assigns
      |> assign(:display_text, display_text)
      |> assign(:badge_class, badge_class)

    ~H"""
    <span class={"badge badge-sm #{@badge_class} font-mono"} title={"Raw value: #{@community}"}>
      {@display_text}
    </span>
    """
  end

  attr(:flow, :map, required: true)
  attr(:rdns_map, :map, default: %{})
  attr(:context, :map, default: %{})
  attr(:arin_lookup, :map, default: %{})

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
        <% src_mac = flow_get(@flow, ["src_mac"]) || flow_get_in(ocsf, ["unmapped", "src_mac"]) %>
        <% dst_mac = flow_get(@flow, ["dst_mac"]) || flow_get_in(ocsf, ["unmapped", "dst_mac"]) %>
        <% src_mac_vendor =
          flow_get(@flow, ["src_mac_vendor"]) || flow_get_in(ocsf, ["enrichment", "src_mac_vendor"]) %>
        <% dst_mac_vendor =
          flow_get(@flow, ["dst_mac_vendor"]) || flow_get_in(ocsf, ["enrichment", "dst_mac_vendor"]) %>
        <% src_provider =
          flow_get(@flow, ["src_hosting_provider"]) ||
            flow_get_in(ocsf, ["enrichment", "src_hosting_provider"]) %>
        <% dst_provider =
          flow_get(@flow, ["dst_hosting_provider"]) ||
            flow_get_in(ocsf, ["enrichment", "dst_hosting_provider"]) %>
        <% direction_label =
          flow_get(@flow, ["direction_label"]) || flow_get_in(ocsf, ["enrichment", "direction_label"]) %>
        <% service_label =
          flow_get(@flow, ["dst_service_label"]) ||
            flow_get_in(ocsf, ["enrichment", "dst_service_label"]) %>
        <% tcp_flags_labels =
          flow_get(@flow, ["tcp_flags_labels"]) ||
            flow_get_in(ocsf, ["enrichment", "tcp_flags_labels"]) %>
        <% tcp_flags_labels =
          if is_list(tcp_flags_labels),
            do: Enum.map(tcp_flags_labels, &to_string/1),
            else: [] %>
        <% protocol_num = flow_get(@flow, ["protocol_num"]) %>
        <% tcp_flags_raw = flow_get(@flow, ["tcp_flags"]) %>
        <% protocol_label =
          flow_get(@flow, ["protocol_name", "protocol_group", "proto"]) ||
            get_in(ocsf, ["connection_info", "protocol_name"]) %>
        <% sampler =
          flow_get(@flow, ["sampler_address"]) ||
            flow_get_in(ocsf, ["observables"])
            |> case do
              [%{} = first | _] -> flow_get(first, ["value"]) || flow_get(first, ["name"])
              _ -> nil
            end %>
        <% mapbox = Map.get(@context, :mapbox) %>
        <% map_markers = netflow_map_markers(@context, @flow) %>
        <% arin_lookup = @arin_lookup || %{} %>

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
                  <div :if={is_binary(src_mac_vendor) and src_mac_vendor != ""}>
                    vendor: <span class="font-mono">{src_mac_vendor}</span>
                  </div>
                  <div :if={is_binary(src_provider) and src_provider != ""}>
                    provider: <span class="font-mono">{src_provider}</span>
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
                  <div :if={is_binary(dst_mac_vendor) and dst_mac_vendor != ""}>
                    vendor: <span class="font-mono">{dst_mac_vendor}</span>
                  </div>
                  <div :if={is_binary(dst_provider) and dst_provider != ""}>
                    provider: <span class="font-mono">{dst_provider}</span>
                  </div>
                </div>
              </div>

              <div class="p-2 rounded-lg border border-base-200 bg-base-200/30">
                <div class="text-xs uppercase tracking-wider text-base-content/50">Protocol</div>
                <% src_port = flow_get(@flow, ["src_endpoint_port", "src_port"]) %>
                <% dst_port = flow_get(@flow, ["dst_endpoint_port", "dst_port"]) %>
                <% flag_set = MapSet.new(Enum.map(tcp_flags_labels, &String.upcase(to_string(&1)))) %>
                <% is_tcp =
                  (is_binary(protocol_label) and String.upcase(protocol_label) == "TCP") or
                    protocol_num == 6 %>
                <div class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 font-mono text-xs">
                  <span class="badge badge-xs badge-outline">{protocol_label || "Unknown"}</span>
                  <span :if={not is_nil(protocol_num)} class="text-base-content/60">
                    proto {protocol_num}
                  </span>
                  <span class="text-base-content/60">{src_port || "—"} → {dst_port || "—"}</span>
                </div>
                <div :if={is_tcp} class="mt-1 rounded border border-base-300 bg-base-100/60 p-1.5">
                  <div class="text-[10px] uppercase tracking-wide text-base-content/50">
                    TCP Flags
                  </div>
                  <div class="mt-1 flex flex-wrap gap-1">
                    <%= for flag <- ["CWR", "ECE", "URG", "ACK", "PSH", "RST", "SYN", "FIN"] do %>
                      <% active = MapSet.member?(flag_set, flag) %>
                      <span class="tooltip tooltip-top" data-tip={tcp_flag_tooltip(flag)}>
                        <span class={[
                          "inline-flex h-5 min-w-6 items-center justify-center rounded border px-1 text-[10px] font-mono cursor-help",
                          if(active,
                            do: "border-primary bg-primary/15 text-primary",
                            else: "border-base-300 text-base-content/50"
                          )
                        ]}>
                          {flag}
                        </span>
                      </span>
                    <% end %>
                  </div>
                  <div
                    :if={not is_nil(tcp_flags_raw) and tcp_flags_labels == []}
                    class="mt-1 text-[10px] text-base-content/60"
                  >
                    raw mask: <span class="font-mono">{tcp_flags_raw}</span>
                  </div>
                </div>
                <div class="mt-1 text-[10px] text-base-content/60 space-y-0.5">
                  <div :if={is_binary(direction_label) and direction_label != ""}>
                    direction: <span class="font-mono">{direction_label}</span>
                  </div>
                  <div :if={is_binary(service_label) and service_label != ""}>
                    dst_service: <span class="font-mono">{service_label}</span>
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
              
    <!-- BGP Information Section -->
              <div class="p-3 rounded-lg border border-base-200 bg-base-200/30 md:col-span-2">
                <.bgp_section flow={@flow} />
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
                      phx-update="ignore"
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
                <.netflow_geoip_asn_line
                  side="Source"
                  geo={Map.get(@context, :src_geo)}
                  arin_lookup={arin_lookup}
                />
                <.netflow_geoip_asn_line
                  side="Dest"
                  geo={Map.get(@context, :dst_geo)}
                  arin_lookup={arin_lookup}
                />
              </div>

              <div>
                <div class="font-semibold">ARIN ASN lookup</div>
                <div class="mt-1 text-base-content/70">
                  Click any AS number to load ARIN Whois details.
                </div>
                <%= if is_binary(Map.get(arin_lookup, :error)) and Map.get(arin_lookup, :error) != "" do %>
                  <div class="mt-2 text-error">
                    {Map.get(arin_lookup, :error)}
                  </div>
                <% end %>
                <%= if data = Map.get(arin_lookup, :data) do %>
                  <div class="mt-2 rounded-lg border border-base-200 bg-base-200/30 p-2">
                    <div class="flex items-center justify-between gap-2">
                      <div class="font-mono text-[11px] text-base-content/80">
                        {data.handle} {if is_binary(data.name), do: "- #{data.name}", else: ""}
                      </div>
                      <span
                        :if={is_binary(data.source) and data.source != ""}
                        class="badge badge-xs badge-outline"
                      >
                        {data.source}
                      </span>
                    </div>
                    <div class="mt-2 max-h-48 overflow-y-auto space-y-1 font-mono text-[11px] text-base-content/70 pr-1">
                      <div :if={is_binary(data.org_name) and data.org_name != ""}>
                        org: {data.org_name}
                        <span :if={is_binary(data.org_handle) and data.org_handle != ""}>
                          ({data.org_handle})
                        </span>
                      </div>
                      <div :if={is_binary(data.range) and data.range != ""}>range: {data.range}</div>
                      <div :if={is_binary(data.registration_date) and data.registration_date != ""}>
                        registered: {data.registration_date}
                      </div>
                      <div :if={is_binary(data.update_date) and data.update_date != ""}>
                        updated: {data.update_date}
                      </div>
                      <div :if={is_binary(data.comment) and data.comment != ""}>
                        comment: {data.comment}
                      </div>
                      <div :if={is_binary(data.rdap_ref) and data.rdap_ref != ""}>
                        rdap:
                        <a
                          href={data.rdap_ref}
                          target="_blank"
                          rel="noopener noreferrer"
                          class="link link-hover"
                        >
                          {data.rdap_ref}
                        </a>
                      </div>
                      <div :if={is_binary(data.ref) and data.ref != ""}>
                        whois:
                        <a
                          href={data.ref}
                          target="_blank"
                          rel="noopener noreferrer"
                          class="link link-hover"
                        >
                          {data.ref}
                        </a>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>

              <div>
                <div class="font-semibold">Threat intel</div>
                <div class="mt-1 text-base-content/70">
                  Source:
                  <%= if match = Map.get(@context, :src_threat) do %>
                    <span class="ml-2 badge badge-xs badge-warning">match</span>
                    <span class="ml-2 font-mono">{match.match_count} indicators</span>
                    <span
                      :if={match.max_severity}
                      class={"ml-2 badge badge-xs #{threat_severity_badge_class(match.max_severity)}"}
                    >
                      severity {match.max_severity}
                    </span>
                    <span
                      :for={source <- threat_sources(match)}
                      class="ml-1 badge badge-xs badge-outline"
                    >
                      {source}
                    </span>
                  <% else %>
                    <span class="ml-2 badge badge-xs badge-ghost">none</span>
                  <% end %>
                </div>
                <div class="mt-1 text-base-content/70">
                  Dest:
                  <%= if match = Map.get(@context, :dst_threat) do %>
                    <span class="ml-2 badge badge-xs badge-warning">match</span>
                    <span class="ml-2 font-mono">{match.match_count} indicators</span>
                    <span
                      :if={match.max_severity}
                      class={"ml-2 badge badge-xs #{threat_severity_badge_class(match.max_severity)}"}
                    >
                      severity {match.max_severity}
                    </span>
                    <span
                      :for={source <- threat_sources(match)}
                      class="ml-1 badge badge-xs badge-outline"
                    >
                      {source}
                    </span>
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
                        <button
                          type="button"
                          phx-click="netflow_lookup_asn"
                          phx-value-asn={info.as_number}
                          phx-value-rir-hint={asn_rir_hint(Map.get(info, :country_code))}
                          class={[
                            "ml-2 font-mono underline decoration-dotted underline-offset-2 hover:text-primary",
                            Map.get(arin_lookup, :asn) == info.as_number && "text-primary"
                          ]}
                        >
                          AS{info.as_number}
                        </button>
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
                        <button
                          type="button"
                          phx-click="netflow_lookup_asn"
                          phx-value-asn={info.as_number}
                          phx-value-rir-hint={asn_rir_hint(Map.get(info, :country_code))}
                          class={[
                            "ml-2 font-mono underline decoration-dotted underline-offset-2 hover:text-primary",
                            Map.get(arin_lookup, :asn) == info.as_number && "text-primary"
                          ]}
                        >
                          AS{info.as_number}
                        </button>
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
  attr(:arin_lookup, :map, default: %{})

  defp netflow_geoip_asn_line(assigns) do
    geo = assigns.geo

    {location_label, as_number, as_name, country_code} =
      if is_map(geo) do
        location =
          [Map.get(geo, :country_code), Map.get(geo, :country_name)]
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join(" ")

        {location, to_int(Map.get(geo, :as_number)), normalize_optional_string(Map.get(geo, :as_name)),
         normalize_optional_string(Map.get(geo, :country_code))}
      else
        {"", nil, nil, nil}
      end

    assigns =
      assigns
      |> assign(:location_label, if(location_label == "", do: "n/a", else: location_label))
      |> assign(:as_number, as_number)
      |> assign(:as_name, as_name)
      |> assign(:country_code, country_code)
      |> assign(:asn_selected, Map.get(assigns.arin_lookup || %{}, :asn))

    ~H"""
    <div class="mt-1 text-base-content/70">
      {@side}: <span class="font-mono">{@location_label}</span>
      <button
        :if={is_integer(@as_number) and @as_number > 0}
        type="button"
        phx-click="netflow_lookup_asn"
        phx-value-asn={@as_number}
        phx-value-rir-hint={asn_rir_hint(@country_code)}
        class={[
          "ml-2 font-mono underline decoration-dotted underline-offset-2 hover:text-primary",
          @asn_selected == @as_number && "text-primary"
        ]}
      >
        AS{@as_number}
      </button>
      <span :if={is_binary(@as_name) and @as_name != ""} class="ml-2 font-mono text-base-content/60">
        {@as_name}
      </span>
    </div>
    """
  end

  defp netflow_map_markers(context, flow) when is_map(context) and is_map(flow) do
    src_ip = flow_get(flow, ["src_endpoint_ip", "src_ip"])
    dst_ip = flow_get(flow, ["dst_endpoint_ip", "dst_ip"])

    []
    |> maybe_add_geo_marker("Source", src_ip, Map.get(context, :src_geo), Map.get(context, :src_threat))
    |> maybe_add_geo_marker("Dest", dst_ip, Map.get(context, :dst_geo), Map.get(context, :dst_threat))
    |> Enum.take(2)
  end

  defp netflow_map_markers(_context, _flow), do: []

  defp maybe_add_geo_marker(markers, side, ip, geo, threat) when is_list(markers) do
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
              label: label,
              threat_matched: threat_match?(threat),
              threat_match_count: threat_match_count(threat),
              threat_max_severity: threat_max_severity(threat),
              threat_sources: marker_threat_sources(threat)
            }
          ]
    end
  end

  defp threat_match?(%{matched: true}), do: true
  defp threat_match?(%{match_count: count}) when is_integer(count) and count > 0, do: true
  defp threat_match?(_), do: false

  defp threat_match_count(%{match_count: count}) when is_integer(count), do: count
  defp threat_match_count(_), do: 0

  defp threat_max_severity(%{max_severity: severity}) when is_integer(severity), do: severity
  defp threat_max_severity(_), do: 0

  defp marker_threat_sources(%{sources: sources}) when is_list(sources),
    do: sources |> Enum.reject(&(&1 in [nil, ""])) |> Enum.take(4)

  defp marker_threat_sources(_), do: []

  defp load_flow_context(flow, scope) when is_map(flow) do
    srql_module = Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
    user = scope && scope.user
    src_ip = flow |> flow_get(["src_endpoint_ip", "src_ip"]) |> normalize_ip()
    dst_ip = flow |> flow_get(["dst_endpoint_ip", "dst_ip"]) |> normalize_ip()
    dst_port = flow |> flow_get(["dst_endpoint_port", "dst_port"]) |> to_int()

    src_mac =
      normalize_mac(
        flow_get(flow, ["src_mac"]) || get_in(flow_get(flow, ["ocsf_payload"]) || %{}, ["unmapped", "src_mac"])
      )

    dst_mac =
      normalize_mac(
        flow_get(flow, ["dst_mac"]) || get_in(flow_get(flow, ["ocsf_payload"]) || %{}, ["unmapped", "dst_mac"])
      )

    src_device_uid =
      safe_flow_context_value(:src_device_uid, fn ->
        lookup_device_uid_by_ip_or_mac(srql_module, scope, src_ip, src_mac)
      end)

    dst_device_uid =
      safe_flow_context_value(:dst_device_uid, fn ->
        lookup_device_uid_by_ip_or_mac(srql_module, scope, dst_ip, dst_mac)
      end)

    %{
      mapbox: safe_flow_context_value(:mapbox, fn -> read_mapbox(user) end),
      src_rdns: safe_flow_context_value(:src_rdns, fn -> read_rdns(user, src_ip) end),
      dst_rdns: safe_flow_context_value(:dst_rdns, fn -> read_rdns(user, dst_ip) end),
      src_geo: safe_flow_context_value(:src_geo, fn -> read_geo(user, src_ip) end),
      dst_geo: safe_flow_context_value(:dst_geo, fn -> read_geo(user, dst_ip) end),
      src_ipinfo: safe_flow_context_value(:src_ipinfo, fn -> read_ipinfo(user, src_ip) end),
      dst_ipinfo: safe_flow_context_value(:dst_ipinfo, fn -> read_ipinfo(user, dst_ip) end),
      src_threat: safe_flow_context_value(:src_threat, fn -> read_threat(user, src_ip) end),
      dst_threat: safe_flow_context_value(:dst_threat, fn -> read_threat(user, dst_ip) end),
      src_port_scan: safe_flow_context_value(:src_port_scan, fn -> read_port_scan(user, src_ip) end),
      dst_port_anomaly: safe_flow_context_value(:dst_port_anomaly, fn -> read_port_anomaly(user, dst_port) end),
      src_device_uid: src_device_uid,
      dst_device_uid: dst_device_uid
    }
  end

  defp load_flow_context(_flow, _scope), do: %{}

  defp safe_flow_context_value(key, fun) when is_function(fun, 0) do
    fun.()
  rescue
    error ->
      Logger.debug("Failed to load flow context value",
        key: key,
        reason: inspect(error)
      )

      nil
  catch
    kind, reason ->
      Logger.debug("Failed to load flow context value",
        key: key,
        reason: inspect({kind, reason})
      )

      nil
  end

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
    query = Ash.Query.for_read(IpRdnsCache, :by_ip, %{ip: ip})

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
    query = Ash.Query.for_read(IpGeoEnrichmentCache, :by_ip, %{ip: ip})

    case Ash.read_one(query, actor: user) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  defp read_ipinfo(nil, _ip), do: nil
  defp read_ipinfo(_user, nil), do: nil

  defp read_ipinfo(user, ip) when is_binary(ip) do
    query = Ash.Query.for_read(IpIpinfoCache, :by_ip, %{ip: ip})

    case Ash.read_one(query, actor: user) do
      {:ok, %IpIpinfoCache{} = record} -> record
      _ -> nil
    end
  end

  defp read_threat(nil, _ip), do: nil
  defp read_threat(_user, nil), do: nil

  defp read_threat(user, ip) when is_binary(ip) do
    query = Ash.Query.for_read(IpThreatIntelCache, :by_ip, %{ip: ip})

    case Ash.read_one(query, actor: user) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  defp threat_sources(%{sources: sources}) do
    sources
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.take(4)
  end

  defp threat_sources(_match), do: []

  defp threat_severity_badge_class(severity) when is_integer(severity) and severity >= 80, do: "badge-error"

  defp threat_severity_badge_class(severity) when is_integer(severity) and severity >= 50, do: "badge-warning"

  defp threat_severity_badge_class(_severity), do: "badge-info"

  defp read_port_scan(nil, _ip), do: nil
  defp read_port_scan(_user, nil), do: nil

  defp read_port_scan(user, ip) when is_binary(ip) do
    query = Ash.Query.for_read(NetflowPortScanFlag, :by_src_ip, %{src_ip: ip})

    case Ash.read_one(query, actor: user) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  defp read_port_anomaly(nil, _port), do: nil

  defp read_port_anomaly(user, port) when is_integer(port) and port > 0 do
    query = Ash.Query.for_read(NetflowPortAnomalyFlag, :by_port, %{dst_port: port})

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

    "/observability/flows?" <> URI.encode_query(params)
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
    Enum.uniq(added ++ preserved)
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

  defp units_to_value_field_and_scale("pps", bucket), do: {"packets_total", rate_scale_fun(bucket, 1.0)}

  defp units_to_value_field_and_scale("bps", bucket), do: {"bytes_total", rate_scale_fun(bucket, 8.0)}

  defp units_to_value_field_and_scale("Bps", bucket), do: {"bytes_total", rate_scale_fun(bucket, 1.0)}

  defp units_to_value_field_and_scale(_, bucket), do: {"bytes_total", rate_scale_fun(bucket, 1.0)}

  defp rate_scale_fun(bucket, multiplier) when is_binary(bucket) and is_number(multiplier) do
    secs = bucket_to_seconds(bucket)
    fn v -> to_float(v) * multiplier / secs end
  end

  defp bucket_to_seconds("1m"), do: 60
  defp bucket_to_seconds("5m"), do: 300
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
    # "base flows" query without chart tokens. Preserve explicit `time:` from query when present.
    base = flows_list_base_query(chart_query, fallback_time)

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

  defp load_visualize_chart(socket, other, %{} = state), do: load_visualize_chart(socket, to_string(other || ""), state)

  defp flows_list_base_query(query, fallback_time) when is_binary(fallback_time) do
    query
    |> to_string()
    |> NFQuery.flows_base_query(fallback_time)
    |> NFQuery.flows_sanitize_for_stats()
    |> String.trim()
  end

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

  defp reduce_sankey_clutter(edges, dims, max_edges) when is_list(edges) and is_list(dims) and is_integer(max_edges) do
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
      |> MapSet.new(fn {k, _} -> k end)

    dst_top =
      dst_bytes
      |> Enum.sort_by(fn {_k, v} -> -v end)
      |> Enum.take(max(top_dst, 1))
      |> MapSet.new(fn {k, _} -> k end)

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

  defp fetch_arin_asn(asn) when is_integer(asn) and asn > 0 do
    case arin_cache_get(asn) do
      {:hit, result} ->
        result

      :miss ->
        result = fetch_arin_asn_remote(asn)
        arin_cache_put(asn, result)
        result
    end
  end

  defp fetch_arin_asn(_), do: {:error, :invalid_asn}

  defp fetch_asn_registry_data(asn, rir_hint) when is_integer(asn) and asn > 0 do
    strategy =
      case rir_hint do
        :ripe -> [:ripe, :arin]
        :arin -> [:arin, :ripe]
        _ -> [:arin, :ripe]
      end

    run_asn_lookup_strategy(asn, strategy)
  end

  defp fetch_asn_registry_data(_asn, _rir_hint), do: {:error, :invalid_asn}

  defp run_asn_lookup_strategy(asn, [first, second]) do
    case run_asn_lookup(asn, first) do
      {:ok, data} ->
        {:ok, data}

      {:error, first_reason} ->
        case run_asn_lookup(asn, second) do
          {:ok, data} ->
            {:ok, data}

          {:error, second_reason} ->
            {:error, {:lookup_failed, first, first_reason, second, second_reason}}
        end
    end
  end

  defp run_asn_lookup(asn, :arin), do: fetch_arin_asn(asn)
  defp run_asn_lookup(asn, :ripe), do: fetch_ripe_asn(asn)

  defp normalize_rir_hint(value) when is_binary(value) do
    case String.trim(String.downcase(value)) do
      "ripe" -> :ripe
      "arin" -> :arin
      _ -> :auto
    end
  end

  defp normalize_rir_hint(_), do: :auto

  defp fetch_arin_asn_remote(asn) when is_integer(asn) and asn > 0 do
    url = "https://whois.arin.net/rest/asn/AS#{asn}.json"

    case Req.get(url, http_req_opts()) do
      {:ok, %Req.Response{status: 200, body: %{"asn" => asn_payload}}} when is_map(asn_payload) ->
        {:ok, normalize_arin_asn(asn_payload)}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp fetch_arin_asn_remote(_), do: {:error, :invalid_asn}

  defp fetch_ripe_asn(asn) when is_integer(asn) and asn > 0 do
    url = "https://stat.ripe.net/data/whois/data.json?resource=AS#{asn}"

    case Req.get(url, http_req_opts()) do
      {:ok, %Req.Response{status: 200, body: %{"data" => %{"records" => records}}}}
      when is_list(records) ->
        case normalize_ripe_asn(asn, records) do
          %{} = data when map_size(data) > 0 -> {:ok, data}
          _ -> {:error, :not_found}
        end

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp fetch_ripe_asn(_), do: {:error, :invalid_asn}

  defp http_req_opts do
    opts = [receive_timeout: 8_000, retry: false, headers: [{"accept", "application/json"}]]

    if Process.whereis(ServiceRadar.Finch) do
      Keyword.put(opts, :finch, ServiceRadar.Finch)
    else
      opts
    end
  end

  defp arin_cache_get(asn) when is_integer(asn) do
    ensure_arin_cache_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@arin_cache_table, asn) do
      [{^asn, expires_at_ms, result}] when is_integer(expires_at_ms) and expires_at_ms > now ->
        {:hit, result}

      [{^asn, _expires_at_ms, _result}] ->
        _ = :ets.delete(@arin_cache_table, asn)
        :miss

      _ ->
        :miss
    end
  rescue
    _ -> :miss
  end

  defp arin_cache_put(asn, result) when is_integer(asn) do
    ensure_arin_cache_table()

    ttl_ms =
      if match?({:ok, _}, result), do: @arin_cache_ttl_ms, else: @arin_cache_negative_ttl_ms

    expires_at_ms = System.monotonic_time(:millisecond) + ttl_ms
    _ = :ets.insert(@arin_cache_table, {asn, expires_at_ms, result})
    :ok
  rescue
    _ -> :ok
  end

  defp ensure_arin_cache_table do
    case :ets.whereis(@arin_cache_table) do
      :undefined ->
        try do
          :ets.new(@arin_cache_table, [
            :named_table,
            :set,
            :public,
            {:read_concurrency, true},
            {:write_concurrency, true}
          ])

          :ok
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp normalize_arin_asn(%{} = asn_payload) do
    org_ref = Map.get(asn_payload, "orgRef")
    start_as = arin_leaf_value(Map.get(asn_payload, "startAsNumber"))
    end_as = arin_leaf_value(Map.get(asn_payload, "endAsNumber"))

    %{
      source: "ARIN Whois-RWS",
      handle: arin_leaf_value(Map.get(asn_payload, "handle")),
      name: arin_leaf_value(Map.get(asn_payload, "name")),
      range: arin_as_range(start_as, end_as),
      registration_date: arin_leaf_value(Map.get(asn_payload, "registrationDate")),
      update_date: arin_leaf_value(Map.get(asn_payload, "updateDate")),
      rdap_ref: arin_leaf_value(Map.get(asn_payload, "rdapRef")),
      ref: arin_leaf_value(Map.get(asn_payload, "ref")),
      org_handle: if(is_map(org_ref), do: Map.get(org_ref, "@handle")),
      org_name: if(is_map(org_ref), do: Map.get(org_ref, "@name")),
      org_ref: if(is_map(org_ref), do: Map.get(org_ref, "$")),
      comment: arin_comment(Map.get(asn_payload, "comment"))
    }
  end

  defp normalize_ripe_asn(asn, records) when is_integer(asn) and is_list(records) do
    flat =
      records
      |> List.flatten()
      |> Enum.filter(&is_map/1)

    name = ripe_record_value(flat, ["as-name", "ASName"])
    org_name = ripe_record_value(flat, ["org-name", "OrgName", "org"])
    descr = flat |> ripe_record_values(["descr", "Description", "remarks"]) |> Enum.join(" | ")
    country = ripe_record_value(flat, ["country"])
    registration_date = ripe_record_value(flat, ["RegDate", "created"])
    update_date = ripe_record_value(flat, ["Updated", "last-modified"])

    ref =
      ripe_record_details_link(flat, ["aut-num", "ASHandle", "ASNumber"]) ||
        "https://stat.ripe.net/AS#{asn}"

    %{
      source: "RIPE Stat Whois",
      handle: "AS#{asn}",
      name: normalize_optional_string(name),
      range: "AS#{asn}",
      registration_date: normalize_optional_string(registration_date),
      update_date: normalize_optional_string(update_date),
      org_handle: nil,
      org_name:
        [normalize_optional_string(org_name), normalize_optional_string(country)]
        |> Enum.filter(&is_binary/1)
        |> Enum.join(" ")
        |> normalize_optional_string(),
      org_ref: nil,
      comment: normalize_optional_string(descr),
      rdap_ref: nil,
      ref: normalize_optional_string(ref)
    }
  end

  defp normalize_ripe_asn(_asn, _records), do: %{}

  defp ripe_record_value(records, keys) when is_list(records) and is_list(keys) do
    Enum.find_value(records, fn
      %{"key" => key, "value" => value} when is_binary(key) and is_binary(value) ->
        if key in keys, do: String.trim(value)

      _ ->
        nil
    end)
  end

  defp ripe_record_values(records, keys) when is_list(records) and is_list(keys) do
    records
    |> Enum.flat_map(fn
      %{"key" => key, "value" => value} when is_binary(key) and is_binary(value) ->
        if Enum.member?(keys, key), do: [String.trim(value)], else: []

      _ ->
        []
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp ripe_record_details_link(records, keys) when is_list(records) and is_list(keys) do
    Enum.find_value(records, fn
      %{"key" => key, "details_link" => value} when is_binary(key) and is_binary(value) ->
        if key in keys, do: String.trim(value)

      _ ->
        nil
    end)
  end

  defp arin_leaf_value(%{"$" => value}) when is_binary(value), do: String.trim(value)
  defp arin_leaf_value(value) when is_binary(value), do: String.trim(value)
  defp arin_leaf_value(_), do: nil

  defp arin_comment(%{"line" => lines}) when is_list(lines) do
    lines
    |> Enum.map(&arin_leaf_value/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> normalize_optional_string()
  end

  defp arin_comment(%{"line" => line}) do
    arin_leaf_value(line)
  end

  defp arin_comment(_), do: nil

  defp arin_as_range(start_as, end_as) when is_binary(start_as) and is_binary(end_as) do
    if start_as == end_as, do: "AS#{start_as}", else: "AS#{start_as}-AS#{end_as}"
  end

  defp arin_as_range(_start_as, _end_as), do: nil

  defp arin_error_text(:invalid_asn), do: "Invalid ASN."
  defp arin_error_text({:lookup_failed, _, _, _, _}), do: "ASN lookup failed in ARIN and RIPE."
  # Use country as a cheap first-pass hint:
  # - US/CA usually ARIN first
  # - everything else RIPE first, with fallback still enabled
  defp asn_rir_hint(country_code) when is_binary(country_code) do
    case country_code |> String.trim() |> String.upcase() do
      "US" -> "arin"
      "CA" -> "arin"
      "" -> "arin"
      _ -> "ripe"
    end
  end

  defp asn_rir_hint(_), do: "arin"

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

  defp sankey_mid_label("dst_port", _mid_value, port) when is_integer(port) and port > 0, do: to_string(port)

  defp sankey_mid_label(_mid_field, mid_value, _port) when is_binary(mid_value) do
    v = String.trim(mid_value)
    if v == "", do: "PORT:?", else: v
  end

  defp sankey_mid_label(_mid_field, _mid_value, _port), do: "?"

  defp load_overlays(srql_module, base, scope, opts) do
    graph = Keyword.get(opts, :graph, "stacked")
    keys = opts |> Keyword.get(:keys, []) |> List.wrap()
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
            srql_module
            |> load_total_overlay_points(prev_query, scope,
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
    keys = opts |> Keyword.get(:keys, []) |> List.wrap()
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

  defp shift_points(points, seconds) when is_list(points) and is_integer(seconds) do
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

    points
  end

  defp parse_time_window_from_query(query) when is_binary(query) do
    case Regex.run(~r/(?:^|\s)time:(?:"([^"]+)"|(\[[^\]]+\])|(\S+))/, query) do
      [_, quoted, _, _] when is_binary(quoted) and quoted != "" -> parse_time_token(quoted)
      [_, _, bracket, _] when is_binary(bracket) and bracket != "" -> parse_time_token(bracket)
      [_, _, _, token] when is_binary(token) and token != "" -> parse_time_token(token)
      _ -> {:error, :no_time}
    end
  end

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

  defp relative_window(seconds) when is_integer(seconds) and seconds > 0 do
    end_dt = DateTime.truncate(DateTime.utc_now(), :second)
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

  defp bracket_range?(token) when is_binary(token) do
    String.starts_with?(token, "[") and String.ends_with?(token, "]")
  end

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

  defp flows_table_traffic_header("pps"), do: "Packets"
  defp flows_table_traffic_header("bps"), do: "Packets / Bits"
  defp flows_table_traffic_header(_), do: "Packets / Bytes"

  defp format_bits_parts(nil), do: {"—", ""}
  defp format_bits_parts(""), do: {"—", ""}

  defp format_bits_parts(value) do
    bits = to_int(value) * 8
    abs_bits = abs(bits)

    cond do
      abs_bits >= 1024 * 1024 * 1024 ->
        {format_float(bits / (1024 * 1024 * 1024)), "Gb"}

      abs_bits >= 1024 * 1024 ->
        {format_float(bits / (1024 * 1024)), "Mb"}

      abs_bits >= 1024 ->
        {format_float(bits / 1024), "Kb"}

      true ->
        {Integer.to_string(bits), "b"}
    end
  rescue
    _ -> {"—", ""}
  end

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
end
