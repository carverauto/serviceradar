defmodule ServiceRadarWebNGWeb.DeviceLive.FlowRuntime do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [start_async: 3]

  alias ServiceRadarWebNGWeb.DeviceLive.DeviceTaskData
  alias ServiceRadarWebNGWeb.DeviceLive.FlowData
  alias ServiceRadarWebNGWeb.DeviceLive.FlowIpEnrichment
  alias ServiceRadarWebNGWeb.DeviceLive.QueryData

  # Interactive flow reloads run in the LiveView process itself, so an
  # unguarded Task.async child crash here kills the page outright. Everything
  # goes through DeviceTaskData, which runs the batch unlinked and bounded.
  @slow_flow_task_ms 1_500
  @flow_reload_timeout_ms 15_000

  @allowed_flow_filter_fields ~w(
    src_endpoint_ip dst_endpoint_ip dst_endpoint_port protocol_name
    protocol_group protocol_num proto direction_label dst_service_label app sampler_address
    src_port dst_port
  )

  def apply_topn_filter(socket, %{"field" => field, "value" => value}, srql_mod, flows_limit)
      when field in @allowed_flow_filter_fields do
    uid = socket.assigns.device_uid
    scope = socket.assigns.current_scope

    base =
      "in:flows device_id:\"#{QueryData.escape_value(uid)}\" #{field}:\"#{QueryData.escape_value(value)}\" time:last_24h"

    query = "#{base} sort:time:desc"
    opts = %{scope: scope, limit: flows_limit, cursor: nil}

    results = run_flow_reload(srql_mod, query, opts, uid, scope, base)

    srql = socket.assigns.srql |> Map.put(:query, base) |> Map.put(:draft, base)

    socket
    |> assign(:srql, srql)
    |> assign(:flow_zoom_range, nil)
    |> assign(:flow_active_facets, %{})
    |> assign_flow_results(results)
    |> assign(:flow_active_topn, %{field: field, value: value})
    |> FlowIpEnrichment.enrich_socket()
  end

  def apply_topn_filter(socket, _params, _srql_mod, _flows_limit), do: socket

  def clear_topn_filter(socket, srql_mod, flows_limit) do
    uid = socket.assigns.device_uid
    scope = socket.assigns.current_scope

    {flows, pagination, flows_error} = FlowData.load_flows(srql_mod, uid, scope, nil, flows_limit)

    default_query = QueryData.default_flows_query(uid)
    srql = socket.assigns.srql |> Map.put(:query, default_query) |> Map.put(:draft, default_query)

    socket
    |> assign(:srql, srql)
    |> assign(:flow_active_topn, nil)
    |> assign(:device_flows, flows)
    |> assign(:flows_pagination, pagination)
    |> assign(:flows_error, flows_error)
    |> FlowIpEnrichment.enrich_socket()
  end

  def toggle_facet(socket, %{"field" => field, "value" => value}, srql_mod, flows_limit)
      when field in @allowed_flow_filter_fields do
    uid = socket.assigns.device_uid
    active = socket.assigns.flow_active_facets

    updated =
      if Map.get(active, field) == value,
        do: Map.delete(active, field),
        else: Map.put(active, field, value)

    socket
    |> assign(:flow_active_facets, updated)
    |> reload_with_facets(uid, updated, srql_mod, flows_limit)
  end

  def toggle_facet(socket, _params, _srql_mod, _flows_limit), do: socket

  def clear_facets(socket, srql_mod, flows_limit) do
    uid = socket.assigns.device_uid

    socket
    |> assign(:flow_active_facets, %{})
    |> reload_with_facets(uid, %{}, srql_mod, flows_limit)
  end

  def apply_chart_zoom(socket, %{"start" => start_time, "end" => end_time}, srql_mod, flows_limit) do
    with {:ok, start_dt, _} <- DateTime.from_iso8601(start_time),
         {:ok, end_dt, _} <- DateTime.from_iso8601(end_time),
         :lt <- DateTime.compare(start_dt, end_dt) do
      safe_start = DateTime.to_iso8601(start_dt)
      safe_end = DateTime.to_iso8601(end_dt)
      uid = socket.assigns.device_uid
      scope = socket.assigns.current_scope
      zoomed_base = "in:flows device_id:\"#{QueryData.escape_value(uid)}\" time:[#{safe_start},#{safe_end}]"
      query = "#{zoomed_base} sort:time:desc"
      opts = %{scope: scope, limit: flows_limit, cursor: nil}

      results = run_flow_reload(srql_mod, query, opts, uid, scope, zoomed_base)
      srql = socket.assigns.srql |> Map.put(:query, zoomed_base) |> Map.put(:draft, zoomed_base)

      socket
      |> assign(:srql, srql)
      |> assign(:flow_zoom_range, %{start: safe_start, end: safe_end})
      |> assign(:flow_active_facets, %{})
      |> assign(:flow_active_topn, nil)
      |> assign_flow_results(results)
      |> FlowIpEnrichment.enrich_socket()
    else
      _ -> socket
    end
  end

  def apply_chart_zoom(socket, _params, _srql_mod, _flows_limit), do: socket

  def clear_zoom(socket, srql_mod, flows_limit) do
    uid = socket.assigns.device_uid
    scope = socket.assigns.current_scope

    results =
      DeviceTaskData.run(
        [
          DeviceTaskData.spec(@slow_flow_task_ms, :flows, fn ->
            FlowData.load_flows(srql_mod, uid, scope, nil, flows_limit)
          end),
          DeviceTaskData.spec(@slow_flow_task_ms, :stats, fn ->
            FlowData.load_device_flow_stats(srql_mod, uid, scope)
          end)
        ],
        @flow_reload_timeout_ms
      )

    default_query = QueryData.default_flows_query(uid)
    srql = socket.assigns.srql |> Map.put(:query, default_query) |> Map.put(:draft, default_query)

    socket
    |> assign(:srql, srql)
    |> assign(:flow_zoom_range, nil)
    |> assign(:flow_active_facets, %{})
    |> assign(:flow_active_topn, nil)
    |> assign_flow_results(results)
    |> FlowIpEnrichment.enrich_socket()
  end

  def begin_background_loads(socket, active_tab, uid, flows, srql_mod, opts \\ [])

  def begin_background_loads(socket, "flows", uid, flows, srql_mod, opts) do
    socket
    |> begin_stats_refresh(uid, srql_mod, opts)
    |> begin_ip_enrichment(uid, flows)
  end

  def begin_background_loads(socket, _active_tab, _uid, _flows, _srql_mod, _opts), do: socket

  def begin_stats_refresh(socket, uid, srql_mod, opts \\ []) do
    scope = socket.assigns.current_scope
    request_ref = make_ref()

    socket
    |> maybe_reset_flow_stats(Keyword.get(opts, :preserve_rendered, false))
    |> assign(:flow_stats_request_ref, request_ref)
    |> start_async({:flow_stats, uid, request_ref}, fn ->
      FlowData.load_device_flow_stats(srql_mod, uid, scope)
    end)
  end

  # On a same-device refresh (preserve_rendered: true) keep the currently
  # rendered stats bundle on screen — the async result replaces it wholesale
  # when it lands. Blanking here unmounted the traffic-profile chart and
  # flipped the stat cards to loading skeletons on every refresh.
  defp maybe_reset_flow_stats(socket, true = _preserve_rendered?), do: socket

  defp maybe_reset_flow_stats(socket, false = _preserve_rendered?) do
    {flow_stats, sparkline_json, proto_json, chart_keys, chart_points, top_talkers_json, top_destinations_json,
     top_peers_json, top_ports_json, top_protocols_json, facets} =
      FlowData.empty_flow_stats_bundle()

    socket
    |> assign(:flow_stats, flow_stats)
    |> assign(:flow_stats_loading, true)
    |> assign(:flow_sparkline_json, sparkline_json)
    |> assign(:flow_proto_json, proto_json)
    |> assign(:flow_chart_keys_json, chart_keys)
    |> assign(:flow_chart_points_json, chart_points)
    |> assign(:flow_top_talkers_json, top_talkers_json)
    |> assign(:flow_top_destinations_json, top_destinations_json)
    |> assign(:flow_top_peers_json, top_peers_json)
    |> assign(:flow_top_ports_json, top_ports_json)
    |> assign(:flow_top_protocols_json, top_protocols_json)
    |> assign(:flow_facets, facets)
  end

  def begin_ip_enrichment(socket, uid, flows) do
    request_ref = make_ref()
    scope = Map.get(socket.assigns, :current_scope)
    ips = FlowIpEnrichment.ips(flows)

    if ips == [] do
      socket
      |> assign(:flow_ip_request_ref, request_ref)
      |> assign(:rdns_map, %{})
      |> assign(:geo_iso2_map, %{})
    else
      socket
      |> assign(:flow_ip_request_ref, request_ref)
      |> assign(:rdns_map, %{})
      |> assign(:geo_iso2_map, %{})
      |> start_async({:flow_ip_enrichment, uid, request_ref}, fn ->
        FlowIpEnrichment.load_maps(ips, scope)
      end)
    end
  end

  defp reload_with_facets(socket, uid, facets, srql_mod, flows_limit) do
    scope = socket.assigns.current_scope

    facet_tokens =
      facets
      |> Enum.filter(fn {field, _} -> field in @allowed_flow_filter_fields end)
      |> Enum.map_join(" ", fn {field, value} ->
        "#{field}:\"#{QueryData.escape_value(value)}\""
      end)

    base = "in:flows device_id:\"#{QueryData.escape_value(uid)}\" time:last_24h #{facet_tokens}"
    query = "#{base} sort:time:desc"
    opts = %{scope: scope, limit: flows_limit, cursor: nil}

    results = run_flow_reload(srql_mod, query, opts, uid, scope, base)

    socket
    |> assign_flow_results(results)
    |> FlowIpEnrichment.enrich_socket()
  end

  defp run_flow_reload(srql_mod, query, opts, uid, scope, base) do
    DeviceTaskData.run(
      [
        DeviceTaskData.spec(@slow_flow_task_ms, :flows, fn ->
          FlowData.load_zoomed_flows(srql_mod, query, opts)
        end),
        DeviceTaskData.spec(@slow_flow_task_ms, :stats, fn ->
          FlowData.load_device_flow_stats(srql_mod, uid, scope, base)
        end)
      ],
      @flow_reload_timeout_ms
    )
  end

  defp assign_flow_results(socket, results) do
    # Every caller of this function fills :flows from DeviceTaskData.run/3, so a
    # missing key means that load crashed or ran out of budget. Say so instead
    # of rendering an empty table that looks like "this device has no flows".
    {flows, pagination, flows_error} =
      Map.get(results, :flows, {[], %{}, "Failed to load flows for the selected range"})

    {flow_stats, sparkline_json, proto_json, chart_keys, chart_points, top_talkers_json, top_destinations_json,
     top_peers_json, top_ports_json, top_protocols_json, facet_data} =
      Map.get(results, :stats, FlowData.empty_flow_stats_bundle())

    socket
    |> assign(:device_flows, flows)
    |> assign(:flows_pagination, pagination)
    |> assign(:flows_error, flows_error)
    |> assign(:flow_stats, flow_stats)
    |> assign(:flow_sparkline_json, sparkline_json)
    |> assign(:flow_proto_json, proto_json)
    |> assign(:flow_chart_keys_json, chart_keys)
    |> assign(:flow_chart_points_json, chart_points)
    |> assign(:flow_top_talkers_json, top_talkers_json)
    |> assign(:flow_top_destinations_json, top_destinations_json)
    |> assign(:flow_top_peers_json, top_peers_json)
    |> assign(:flow_top_ports_json, top_ports_json)
    |> assign(:flow_top_protocols_json, top_protocols_json)
    |> assign(:flow_facets, facet_data)
  end
end
