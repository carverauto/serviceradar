defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.Events do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView
  import ServiceRadarWebNGWeb.NetflowLive.Visualize.AsnLookup
  import ServiceRadarWebNGWeb.NetflowLive.Visualize.Filters
  import ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowContext, only: [load_flow_context: 2]
  import ServiceRadarWebNGWeb.NetflowLive.Visualize.Format, only: [to_int: 1]
  import ServiceRadarWebNGWeb.NetflowLive.Visualize.Params
  import ServiceRadarWebNGWeb.NetflowLive.Visualize.QueryState

  alias ServiceRadarWebNGWeb.Netflow.PrefixTagQuery
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.Config
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.Events.Bgp
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowList
  alias ServiceRadarWebNGWeb.NetflowVisualize.Query, as: NFQuery
  alias ServiceRadarWebNGWeb.NetflowVisualize.State, as: NFState
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_time Config.default_time()

  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_paginate", params, socket) do
    # Session-position keyset page: keep intent URL (q + nf), cursor stays out of the bar.
    page =
      case Integer.parse(to_string(Map.get(params, "page") || "1")) do
        {n, ""} when n > 0 -> n
        _ -> 1
      end

    state = Map.get(socket.assigns, :netflow_viz_state) || NFState.default()

    load_params =
      %{}
      |> Map.put("cursor", Map.get(params, "cursor"))
      |> Map.put("page", Integer.to_string(page))

    socket =
      socket
      |> assign(:pagination_page, page)
      |> FlowList.load_flows_list(load_params, state)

    {:noreply, socket}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_submit", params,
       fallback_path: "/observability/flows",
       extra_params: srql_submit_extra_params(socket)
     )}
  end

  def handle_event("srql_reset", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_reset", params,
       fallback_path: "/observability/flows",
       extra_params: srql_submit_extra_params(socket),
       default_query: "in:flows time:#{@default_time} sort:time:desc"
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

  def handle_event("bgp_add_as_filter", params, socket), do: Bgp.add_as_filter(params, socket)

  def handle_event("bgp_add_community_filter", params, socket), do: Bgp.add_community_filter(params, socket)

  def handle_event("bgp_clear_filters", params, socket), do: Bgp.clear_filters(params, socket)

  def handle_event("nf_reset", _params, socket) do
    next = NFState.default()
    chart_query = chart_query_from_state("in:flows", next)

    socket = assign(socket, :netflow_viz_state, next)

    {:noreply,
     push_patch(socket,
       to: build_patch_url(socket, %{"nf" => nf_param(next), "q" => chart_query, "cursor" => nil})
     )}
  end

  def handle_event("nf_prefix_tag_filter", params, socket) do
    tag =
      params
      |> Map.get("tag", "")
      |> to_string()
      |> String.trim()

    current_q =
      case socket.assigns do
        %{srql: %{query: q}} when is_binary(q) and q != "" -> q
        %{query: q} when is_binary(q) and q != "" -> q
        _ -> "in:flows"
      end

    case PrefixTagQuery.apply_tag_filter(current_q, tag) do
      {:ok, next_q} ->
        state = socket.assigns.netflow_viz_state

        {:noreply,
         socket
         |> assign(:netflow_viz_state, state)
         |> push_patch(
           to:
             build_patch_url(socket, %{
               "nf" => nf_param(state),
               "q" => next_q,
               "cursor" => nil
             })
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Invalid prefix tag (use letters, digits, :._@+/-)")}
    end
  end

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
end
