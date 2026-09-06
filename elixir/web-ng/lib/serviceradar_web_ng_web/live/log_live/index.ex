defmodule ServiceRadarWebNGWeb.LogLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import Ecto.Query
  import ServiceRadarWebNGWeb.UIComponents

  alias Phoenix.LiveView.JS
  alias ServiceRadar.Events.PubSub, as: EventsPubSub
  alias ServiceRadar.Integrations.MapboxSettings
  alias ServiceRadar.Observability.AlertPubSub
  alias ServiceRadar.Observability.EventTitle
  alias ServiceRadar.Observability.FlowPubSub
  alias ServiceRadar.Observability.IpGeoEnrichmentCache
  alias ServiceRadar.Observability.IpInfo
  alias ServiceRadar.Observability.IpIpinfoCache
  alias ServiceRadar.Observability.IpRdnsCache
  alias ServiceRadar.Observability.IpThreatIntelCache
  alias ServiceRadar.Observability.LogPubSub
  alias ServiceRadar.Observability.NetflowPortAnomalyFlag
  alias ServiceRadar.Observability.NetflowPortScanFlag
  alias ServiceRadar.Observability.OtelPubSub
  alias ServiceRadar.ReferenceData.ServicePorts
  alias ServiceRadarWebNG.AlertActions
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNG.Repo
  alias ServiceRadarWebNGWeb.Components.PrefixTagChips
  alias ServiceRadarWebNGWeb.MetricSeries
  alias ServiceRadarWebNGWeb.NetFlow.EnrichmentExpiry
  alias ServiceRadarWebNGWeb.Netflow.PrefixTagQuery
  alias ServiceRadarWebNGWeb.Netflow.RangeSelection
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowContext
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowContext.LocalAnchor
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowContext.MapMarkers
  alias ServiceRadarWebNGWeb.NetflowVisualize.Query, as: NFQuery
  alias ServiceRadarWebNGWeb.NetflowVisualize.State, as: NFState
  alias ServiceRadarWebNGWeb.ObservabilityPaths
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage
  alias ServiceRadarWebNGWeb.Stats
  alias ServiceRadarWebNGWeb.Stats.Query, as: StatsQuery

  require Ash.Query
  require Logger

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @default_limit 20
  @max_limit 100
  @refresh_debounce_ms 5_000
  @default_events_limit 20
  @max_events_limit 100
  @default_alerts_limit 25
  @max_alerts_limit 200
  @default_netflow_window "last_1h"
  @default_netflow_limit 50
  @max_netflow_limit 200
  @netflow_sankey_query_limit 200
  @netflow_sankey_max_edges 40
  @netflow_sankey_max_sources 10
  @netflow_sankey_max_mids 8
  @netflow_sankey_max_dests 10
  @default_netflow_stack_mode "ports"
  @multi_span_filter "span_count:>1"
  @default_traces_query_base "in:otel_trace_summaries time:last_24h"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, LogPubSub.topic())
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, EventsPubSub.topic())
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, FlowPubSub.topic())
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, OtelPubSub.topic())
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, AlertPubSub.topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "Observability")
     |> assign(:active_tab, "logs")
     |> assign(:logs, [])
     |> assign(:traces, [])
     |> assign(:metrics, [])
     |> assign(:events, [])
     |> assign(:alerts, [])
     |> assign(:alert_selection, MapSet.new())
     |> assign(:alert_bulk_result, nil)
     |> assign(:alert_bulk_duration, AlertActions.default_snooze_value())
     |> assign(:can_manage_alerts?, RBAC.can?(socket.assigns[:current_scope], AlertActions.permission()))
     |> assign(:netflows, [])
     |> assign(:selected_netflow, nil)
     |> assign(:netflow_context, nil)
     |> assign(:netflow_arin_lookup, %{})
     |> assign(:netflow_top_talkers, [])
     |> assign(:netflow_top_ports, [])
     |> assign(:netflow_timeseries, %{bucket_seconds: 300, points: []})
     |> assign(:netflow_timeseries_compare, %{bucket_seconds: 300, points: []})
     |> assign(:netflow_timeseries_stacked, %{bucket_seconds: 300, points: []})
     |> assign(:netflow_protocol_activity, %{
       bucket_seconds: 300,
       keys: [],
       points: [],
       colors: %{}
     })
     |> assign(:netflow_app_activity, %{bucket_seconds: 300, keys: [], points: [], colors: %{}})
     |> assign(:netflow_frequent_talkers_packets, [])
     |> assign(:netflow_frequent_talkers_bytes, [])
     |> assign(:netflow_rdns_map, %{})
     |> assign(:netflow_threat_map, %{})
     |> assign(:netflow_compact?, false)
     |> assign(:netflow_talker_cidr, nil)
     |> assign(:netflow_compare_mode, "off")
     |> assign(:netflow_geo_side, "dst")
     |> assign(:netflow_geo_heatmap, [])
     |> assign(:netflow_sankey_prefix, 24)
     |> assign(:netflow_sankey, %{edges: [], sources: [], mids: [], dests: []})
     |> assign(:netflow_sankey_edges_json, "[]")
     |> assign(:netflow_stack_mode, @default_netflow_stack_mode)
     |> assign(:netflow_graph_mode, "stacked")
     |> assign(:netflow_view, "overview")
     |> assign(:netflow_auto_open, false)
     |> assign(:sparklines, %{})
     |> assign(:summary, %{total: 0, fatal: 0, error: 0, warning: 0, info: 0, debug: 0})
     |> assign(:event_summary, empty_event_summary())
     |> assign(:alert_summary, empty_alert_summary())
     |> assign(:netflow_summary, empty_netflow_summary())
     |> assign(:trace_stats, %{total: 0, error_traces: 0, slow_traces: 0})
     |> assign(:trace_latency, %{
       avg_duration_ms: 0.0,
       p95_duration_ms: 0.0,
       service_count: 0,
       sample_size: 0
     })
     |> assign(:logs_live?, false)
     |> assign(:netflows_live?, false)
     |> assign(:events_live?, false)
     |> assign(:traces_live?, false)
     |> assign(:metrics_live?, false)
     |> assign(:alerts_live?, false)
     |> assign(:current_params, %{})
     |> assign(:log_view_params, %{})
     |> assign(:logs_rollup_status, Stats.empty_logs_rollup_status())
     |> assign(:trace_rollup_status, Stats.empty_trace_rollup_status())
     |> assign(:metrics_stats, empty_metrics_stats())
     |> assign(:metrics_view, "samples")
     |> assign(:otlp_metric_names, [])
     |> assign(:otlp_selected_metric, nil)
     |> assign(:otlp_metric_series, [])
     |> assign(:limit, @default_limit)
     |> stream_configure(:logs, dom_id: &log_dom_id/1)
     |> stream_configure(:events, dom_id: &event_dom_id/1)
     |> stream(:logs, [])
     |> stream(:events, [])
     |> SRQLPage.init("logs", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    path = uri |> to_string() |> URI.parse() |> Map.get(:path)

    # Legacy /observability?tab=events → /observability/events?...
    case ObservabilityPaths.legacy_tab_redirect(path, params) do
      to when is_binary(to) ->
        {:noreply, push_navigate(socket, to: to, replace: true)}

      nil ->
        handle_params_resolved(params, uri, path, socket)
    end
  end

  defp handle_params_resolved(params, uri, path, socket) do
    tab =
      ObservabilityPaths.resolve_tab(
        socket.assigns.live_action,
        path,
        params,
        default_tab_for_path(path)
      )

    params = maybe_apply_netflow_nf_state(params, tab)
    {entity, _list_key} = tab_entity(tab)
    {default_limit, max_limit} = tab_limits(tab)
    params = maybe_default_netflows_query(params, tab)
    netflow_compact? = truthy_param?(Map.get(params, "compact"))
    netflow_talker_cidr = parse_netflow_talker_cidr(Map.get(params, "talker_cidr"))
    netflow_compare_mode = parse_netflow_compare_mode(Map.get(params, "compare"))
    netflow_geo_side = parse_netflow_geo_side(Map.get(params, "geo"))
    netflow_sankey_prefix = parse_netflow_sankey_prefix(Map.get(params, "sankey_prefix"))
    netflow_stack_mode = parse_netflow_stack_mode(Map.get(params, "stack"))
    netflow_view = parse_netflow_view(Map.get(params, "view"))
    netflow_auto_open = tab == "netflows" and truthy_param?(Map.get(params, "open_flow"))
    netflow_viz_state = extract_netflow_viz_state(params)

    netflow_graph_mode =
      parse_netflow_graph_mode(Map.get(params, "graph") || Map.get(netflow_viz_state, "graph"))

    metrics_view = if tab == "metrics", do: parse_metrics_view(Map.get(params, "mview")), else: "samples"

    otlp_selected_metric =
      if tab == "metrics" and metrics_view == "points",
        do: normalize_string(Map.get(params, "metric"))

    same_tab_query_change =
      socket.assigns[:_initial_load_done] && tab == socket.assigns[:_loaded_tab]

    logs_live? = next_logs_live_state(socket, tab, params)
    netflows_live? = next_netflows_live_state(socket, tab, params)
    events_live? = next_tab_live_state(socket, tab, params, "events", :events_live?)
    traces_live? = next_tab_live_state(socket, tab, params, "traces", :traces_live?)
    metrics_live? = next_tab_live_state(socket, tab, params, "metrics", :metrics_live?)
    alerts_live? = next_tab_live_state(socket, tab, params, "alerts", :alerts_live?)
    log_view_params = if tab == "logs", do: tracked_log_view_params(params), else: %{}

    # For same-tab query changes (stat card clicks), keep current data visible.
    # For tab switches and initial loads, reset to empty defaults.
    socket =
      if same_tab_query_change do
        socket
        |> assign(:active_tab, tab)
        |> assign(:logs_live?, logs_live?)
        |> assign(:netflows_live?, netflows_live?)
        |> assign(:events_live?, events_live?)
        |> assign(:traces_live?, traces_live?)
        |> assign(:metrics_live?, metrics_live?)
        |> assign(:alerts_live?, alerts_live?)
        |> assign(:current_params, params)
        |> assign(:log_view_params, log_view_params)
        |> assign(:netflow_compact?, netflow_compact?)
        |> assign(:netflow_talker_cidr, netflow_talker_cidr)
        |> assign(:netflow_compare_mode, netflow_compare_mode)
        |> assign(:netflow_geo_side, netflow_geo_side)
        |> assign(:netflow_sankey_prefix, netflow_sankey_prefix)
        |> assign(:netflow_stack_mode, netflow_stack_mode)
        |> assign(:netflow_graph_mode, netflow_graph_mode)
        |> assign(:netflow_view, netflow_view)
        |> assign(:netflow_auto_open, netflow_auto_open)
        |> assign(:netflow_viz_state, netflow_viz_state)
        |> assign(:metrics_view, metrics_view)
        |> assign(:otlp_selected_metric, otlp_selected_metric)
        |> ensure_srql_entity(entity, default_limit)
        |> SRQLPage.sync_from_params(params, uri,
          default_limit: default_limit,
          max_limit: max_limit
        )
      else
        socket
        |> assign(:active_tab, tab)
        |> assign(:logs_live?, logs_live?)
        |> assign(:netflows_live?, netflows_live?)
        |> assign(:events_live?, events_live?)
        |> assign(:traces_live?, traces_live?)
        |> assign(:metrics_live?, metrics_live?)
        |> assign(:alerts_live?, alerts_live?)
        |> assign(:current_params, params)
        |> assign(:log_view_params, log_view_params)
        |> assign(:logs, [])
        |> assign(:traces, [])
        |> assign(:metrics, [])
        |> assign(:events, [])
        |> assign(:alerts, [])
        |> assign(:netflows, [])
        |> assign(:selected_netflow, nil)
        |> assign(:netflow_context, nil)
        |> assign(:netflow_arin_lookup, %{})
        |> assign(:netflow_top_talkers, [])
        |> assign(:netflow_top_ports, [])
        |> assign(:netflow_timeseries, %{bucket_seconds: 300, points: []})
        |> assign(:netflow_timeseries_compare, %{bucket_seconds: 300, points: []})
        |> assign(:netflow_timeseries_stacked, %{bucket_seconds: 300, points: []})
        |> assign(:netflow_protocol_activity, %{
          bucket_seconds: 300,
          keys: [],
          points: [],
          colors: %{}
        })
        |> assign(:netflow_app_activity, %{
          bucket_seconds: 300,
          keys: [],
          points: [],
          colors: %{}
        })
        |> assign(:netflow_frequent_talkers_packets, [])
        |> assign(:netflow_frequent_talkers_bytes, [])
        |> assign(:netflow_rdns_map, %{})
        |> assign(:netflow_threat_map, %{})
        |> assign(:netflow_compact?, netflow_compact?)
        |> assign(:netflow_talker_cidr, netflow_talker_cidr)
        |> assign(:netflow_compare_mode, netflow_compare_mode)
        |> assign(:netflow_geo_side, netflow_geo_side)
        |> assign(:netflow_geo_heatmap, [])
        |> assign(:netflow_sankey_prefix, netflow_sankey_prefix)
        |> assign(:netflow_sankey, %{edges: [], sources: [], mids: [], dests: []})
        |> assign(:netflow_stack_mode, netflow_stack_mode)
        |> assign(:netflow_graph_mode, netflow_graph_mode)
        |> assign(:netflow_view, netflow_view)
        |> assign(:netflow_auto_open, netflow_auto_open)
        |> assign(:netflow_viz_state, netflow_viz_state)
        |> assign(:metrics_view, metrics_view)
        |> assign(:otlp_selected_metric, otlp_selected_metric)
        |> assign(:otlp_metric_names, [])
        |> assign(:otlp_metric_series, [])
        |> ensure_srql_entity(entity, default_limit)
        |> SRQLPage.sync_from_params(params, uri,
          default_limit: default_limit,
          max_limit: max_limit
        )
      end

    # A filter change invalidates the selection: the ids that were selected are
    # no longer provably the ids this viewer can currently see.
    socket =
      socket
      |> assign(:alert_selection, MapSet.new())
      |> assign(:alert_bulk_result, nil)

    socket =
      if connected?(socket) do
        dispatch_tab_load(socket, tab, params, uri)
      else
        # Disconnected mount — skip entirely (static HTML is replaced by WebSocket)
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("toggle_logs_live", _params, socket) do
    socket = assign(socket, :logs_live?, !Map.get(socket.assigns, :logs_live?, false))

    socket =
      if socket.assigns.active_tab == "logs" and socket.assigns.logs_live? do
        refresh_tab(socket, "logs")
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("toggle_events_live", _params, socket) do
    {:noreply, toggle_tab_live(socket, "events", :events_live?)}
  end

  def handle_event("toggle_traces_live", _params, socket) do
    {:noreply, toggle_tab_live(socket, "traces", :traces_live?)}
  end

  def handle_event("toggle_metrics_live", _params, socket) do
    {:noreply, toggle_tab_live(socket, "metrics", :metrics_live?)}
  end

  def handle_event("toggle_alerts_live", _params, socket) do
    {:noreply, toggle_tab_live(socket, "alerts", :alerts_live?)}
  end

  # Shared live-toggle behavior: flip the flag, and when turning live on,
  # reload the head of the current result set so the tail starts fresh.
  defp toggle_tab_live(socket, tab, flag) do
    socket = assign(socket, flag, !Map.get(socket.assigns, flag, false))

    if socket.assigns.active_tab == tab and Map.get(socket.assigns, flag, false) do
      refresh_tab(socket, tab)
    else
      socket
    end
  end

  def handle_event("srql_paginate", params, socket) do
    tab = socket.assigns.active_tab
    {_entity, list_key} = tab_entity(tab)
    {default_limit, max_limit} = tab_limits(tab)

    socket =
      socket
      # Paging is session position — leave the shareable URL alone and drop live tailing.
      |> assign(:logs_live?, false)
      |> assign(:netflows_live?, false)
      |> assign(:events_live?, false)
      |> assign(:traces_live?, false)
      |> assign(:metrics_live?, false)
      |> assign(:alerts_live?, false)
      |> then(fn sock ->
        SRQLPage.handle_event(sock, "srql_paginate", params,
          list_assign_key: list_key,
          default_limit: default_limit,
          max_limit: max_limit
        )
      end)
      |> apply_tab_assigns(tab, srql_module())
      |> stream_active_tab(tab)

    {:noreply, socket}
  end

  def handle_event("toggle_netflows_live", _params, socket) do
    live? =
      not paged_away_from_head?(socket) and
        not Map.get(socket.assigns, :netflows_live?, false)

    socket = assign(socket, :netflows_live?, live?)

    socket =
      if socket.assigns.active_tab == "netflows" and socket.assigns.netflows_live? do
        refresh_tab(socket, "netflows")
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("netflow_open", %{"idx" => idx}, socket) do
    selected =
      case Integer.parse(to_string(idx)) do
        {i, _} when i >= 0 -> Enum.at(socket.assigns.netflows, i)
        _ -> nil
      end

    ctx =
      if is_map(selected),
        do: load_netflow_context(selected, socket.assigns.current_scope)

    {:noreply,
     socket
     |> assign(:selected_netflow, selected)
     |> assign(:netflow_context, ctx)
     |> assign(:netflow_arin_lookup, %{})}
  end

  def handle_event("netflow_close", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_netflow, nil)
     |> assign(:netflow_context, nil)
     |> assign(:netflow_arin_lookup, %{})}
  end

  def handle_event("netflow_prefix_tag_filter", params, socket) do
    tag =
      params
      |> Map.get("tag", "")
      |> to_string()
      |> String.trim()

    base_path = socket.assigns.srql[:page_path] || "/observability"
    query = socket.assigns.srql[:query] || "in:flows"
    limit = socket.assigns.limit

    patch_opts =
      netflow_patch_opts(
        Map.get(socket.assigns, :netflow_compact?, false),
        Map.get(socket.assigns, :netflow_talker_cidr),
        Map.get(socket.assigns, :netflow_compare_mode, "off"),
        Map.get(socket.assigns, :netflow_geo_side, "dst"),
        Map.get(socket.assigns, :netflow_sankey_prefix, 24),
        Map.get(socket.assigns, :netflow_stack_mode, @default_netflow_stack_mode),
        Map.get(socket.assigns, :netflow_graph_mode, "stacked"),
        Map.get(socket.assigns, :netflow_view, "overview")
      )

    case PrefixTagQuery.apply_tag_filter(query, tag) do
      {:ok, next_q} ->
        href = base_path <> "?" <> URI.encode_query(netflow_params(next_q, limit, patch_opts))
        {:noreply, push_patch(socket, to: href)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Invalid prefix tag (use letters, digits, :._@+/-)")}
    end
  end

  def handle_event("netflow_lookup_asn", %{"asn" => asn_raw}, socket) do
    asn =
      case Integer.parse(to_string(asn_raw || "")) do
        {n, ""} when n > 0 -> n
        _ -> nil
      end

    if is_integer(asn) do
      lookup = %{asn: asn, loading: true, data: nil, error: nil}
      socket = assign(socket, :netflow_arin_lookup, lookup)

      lookup =
        case fetch_arin_asn(asn) do
          {:ok, data} ->
            %{asn: asn, loading: false, data: data, error: nil}

          {:error, reason} ->
            %{asn: asn, loading: false, data: nil, error: arin_error_text(reason)}
        end

      {:noreply, assign(socket, :netflow_arin_lookup, lookup)}
    else
      {:noreply,
       assign(socket, :netflow_arin_lookup, %{
         asn: nil,
         loading: false,
         data: nil,
         error: "Invalid ASN."
       })}
    end
  end

  def handle_event("netflow_range_selected", params, socket) do
    patch_opts =
      socket.assigns
      |> current_netflow_patch_opts()
      |> Map.put(:view, "explorer")

    maybe_patch_netflow_range(
      socket,
      params,
      netflow_range_selector_points(socket.assigns),
      patch_opts
    )
  end

  def handle_event("netflow_bucket", params, socket) do
    maybe_patch_netflow_range(
      socket,
      params,
      Enum.reject([netflow_bucket_selector_points(socket.assigns)], &(&1 == [])),
      current_netflow_patch_opts(socket.assigns)
    )
  end

  def handle_event("netflow_geo_click", %{"country" => country}, socket) do
    base_path = socket.assigns.srql[:page_path] || "/observability"
    query = socket.assigns.srql[:query] || ""
    limit = socket.assigns.limit
    compact? = Map.get(socket.assigns, :netflow_compact?, false)
    talker_cidr = Map.get(socket.assigns, :netflow_talker_cidr)
    compare_mode = Map.get(socket.assigns, :netflow_compare_mode, "off")
    geo_side = Map.get(socket.assigns, :netflow_geo_side, "dst")
    sankey_prefix = Map.get(socket.assigns, :netflow_sankey_prefix, 24)
    stack_mode = Map.get(socket.assigns, :netflow_stack_mode, @default_netflow_stack_mode)
    graph_mode = Map.get(socket.assigns, :netflow_graph_mode, "stacked")
    view = Map.get(socket.assigns, :netflow_view, "overview")

    patch_opts =
      netflow_patch_opts(
        compact?,
        talker_cidr,
        compare_mode,
        geo_side,
        sankey_prefix,
        stack_mode,
        graph_mode,
        view
      )

    field = if geo_side == "src", do: "src_country_iso2", else: "dst_country_iso2"
    country = (country || "") |> to_string() |> String.trim() |> String.upcase()

    if String.length(country) == 2 do
      href =
        netflow_filter_patch(
          base_path,
          query,
          limit,
          field,
          country,
          patch_opts
        )

      {:noreply, push_patch(socket, to: href)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("netflow_sankey_edge", %{"src" => src, "dst" => dst, "port" => port_raw}, socket) do
    base_path = socket.assigns.srql[:page_path] || "/observability"
    query = socket.assigns.srql[:query] || ""
    limit = socket.assigns.limit
    compact? = Map.get(socket.assigns, :netflow_compact?, false)
    talker_cidr = Map.get(socket.assigns, :netflow_talker_cidr)
    compare_mode = Map.get(socket.assigns, :netflow_compare_mode, "off")
    geo_side = Map.get(socket.assigns, :netflow_geo_side, "dst")
    sankey_prefix = Map.get(socket.assigns, :netflow_sankey_prefix, 24)
    stack_mode = Map.get(socket.assigns, :netflow_stack_mode, @default_netflow_stack_mode)
    graph_mode = Map.get(socket.assigns, :netflow_graph_mode, "stacked")

    port =
      case Integer.parse(to_string(port_raw || "")) do
        {n, ""} when n > 0 -> n
        _ -> nil
      end

    new_query =
      query
      |> upsert_query_filter("src_cidr", (src || "") |> to_string() |> String.trim())
      |> upsert_query_filter("dst_cidr", (dst || "") |> to_string() |> String.trim())
      |> then(fn q ->
        if is_integer(port) do
          upsert_query_filter(q, "dst_port", to_string(port))
        else
          q
        end
      end)

    href =
      base_path
      |> netflow_talker_cidr_patch(
        new_query,
        limit,
        netflow_patch_opts(
          compact?,
          talker_cidr,
          compare_mode,
          geo_side,
          sankey_prefix,
          stack_mode,
          graph_mode,
          "explorer"
        )
      )
      |> append_query_param("open_flow", "1")

    {:noreply, push_patch(socket, to: href)}
  end

  def handle_event("netflow_icicle_node", %{"kind" => kind_raw, "value" => value_raw}, socket) do
    kind = (kind_raw || "") |> to_string() |> String.trim() |> String.downcase()
    value = (value_raw || "") |> to_string() |> String.trim()

    {field, normalized} =
      case kind do
        "src" ->
          {"src_ip", value}

        "dst" ->
          {"dst_ip", value}

        "port" ->
          port =
            case Integer.parse(value) do
              {n, ""} when n > 0 -> Integer.to_string(n)
              _ -> ""
            end

          {"dst_port", port}

        _ ->
          {"", ""}
      end

    if field != "" and normalized != "" do
      base_path = socket.assigns.srql[:page_path] || "/observability"
      query = socket.assigns.srql[:query] || ""
      limit = socket.assigns.limit

      href =
        netflow_filter_patch(
          base_path,
          query,
          limit,
          field,
          normalized,
          netflow_patch_opts(
            Map.get(socket.assigns, :netflow_compact?, false),
            Map.get(socket.assigns, :netflow_talker_cidr),
            Map.get(socket.assigns, :netflow_compare_mode, "off"),
            Map.get(socket.assigns, :netflow_geo_side, "dst"),
            Map.get(socket.assigns, :netflow_sankey_prefix, 24),
            Map.get(socket.assigns, :netflow_stack_mode, @default_netflow_stack_mode),
            Map.get(socket.assigns, :netflow_graph_mode, "stacked"),
            Map.get(socket.assigns, :netflow_view, "overview")
          )
        )

      {:noreply, push_patch(socket, to: href)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("netflow_stack_series", %{"field" => field, "value" => value}, socket) do
    field = (field || "") |> to_string() |> String.trim()
    value = (value || "") |> to_string() |> String.trim()

    if field in ["app", "protocol_group"] and value != "" do
      base_path = socket.assigns.srql[:page_path] || "/observability"
      query = socket.assigns.srql[:query] || ""
      limit = socket.assigns.limit

      href =
        netflow_talker_cidr_patch(
          base_path,
          upsert_query_filter(query, field, value),
          limit,
          netflow_patch_opts(
            Map.get(socket.assigns, :netflow_compact?, false),
            Map.get(socket.assigns, :netflow_talker_cidr),
            Map.get(socket.assigns, :netflow_compare_mode, "off"),
            Map.get(socket.assigns, :netflow_geo_side, "dst"),
            Map.get(socket.assigns, :netflow_sankey_prefix, 24),
            Map.get(socket.assigns, :netflow_stack_mode, @default_netflow_stack_mode),
            Map.get(socket.assigns, :netflow_graph_mode, "stacked"),
            Map.get(socket.assigns, :netflow_view, "overview")
          )
        )

      {:noreply, push_patch(socket, to: href)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("netflow_modal_filter", %{"field" => field_raw, "value" => value_raw}, socket) do
    field = (field_raw || "") |> to_string() |> String.trim()
    value = (value_raw || "") |> to_string() |> String.trim()

    if field != "" and value != "" do
      base_path = socket.assigns.srql[:page_path] || "/observability"
      query = socket.assigns.srql[:query] || ""
      limit = socket.assigns.limit

      patch_opts =
        netflow_patch_opts(
          Map.get(socket.assigns, :netflow_compact?, false),
          Map.get(socket.assigns, :netflow_talker_cidr),
          Map.get(socket.assigns, :netflow_compare_mode, "off"),
          Map.get(socket.assigns, :netflow_geo_side, "dst"),
          Map.get(socket.assigns, :netflow_sankey_prefix, 24),
          Map.get(socket.assigns, :netflow_stack_mode, @default_netflow_stack_mode),
          Map.get(socket.assigns, :netflow_graph_mode, "stacked"),
          Map.get(socket.assigns, :netflow_view, "overview")
        )

      params =
        query
        |> upsert_query_filter(field, value)
        |> netflow_params(limit, patch_opts)
        |> Map.put(:open_flow, "1")

      href = base_path <> "?" <> URI.encode_query(params)

      {:noreply,
       socket
       |> assign(:selected_netflow, nil)
       |> assign(:netflow_context, nil)
       |> assign(:netflow_arin_lookup, %{})
       |> push_patch(to: href)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_submit", params,
       fallback_path: "/observability",
       extra_params: srql_submit_extra_params(socket)
     )}
  end

  def handle_event("srql_reset", params, socket) do
    default_query =
      Map.get(maybe_default_netflows_query(%{}, socket.assigns.active_tab), "q")

    {:noreply,
     SRQLPage.handle_event(socket, "srql_reset", params,
       fallback_path: "/observability",
       extra_params: srql_submit_extra_params(socket),
       default_query: default_query
     )}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: current_entity(socket))}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    extra_params = srql_submit_extra_params(socket)

    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_run", %{},
       fallback_path: "/observability",
       extra_params: extra_params
     )}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: current_entity(socket))}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: current_entity(socket))}
  end

  # -- alert bulk acknowledgement --------------------------------------------
  #
  # Selection lives on the server. The ids a client submits are never treated
  # as evidence of visibility: `AlertActions.bulk/4` is handed the ids this
  # server rendered for the viewer's active filter and refuses anything else,
  # and it re-derives the caller's authority from persistence before it moves
  # a single alert.

  def handle_event("alert_select_toggle", %{"id" => id}, socket) when is_binary(id) do
    {:noreply, toggle_alert_selection(socket, id)}
  end

  def handle_event("alert_select_toggle", _params, socket), do: {:noreply, socket}

  def handle_event("alert_select_all", _params, socket) do
    visible = visible_alert_ids(socket)

    selection =
      if MapSet.size(socket.assigns.alert_selection) >= length(visible) and visible != [] do
        MapSet.new()
      else
        MapSet.new(Enum.take(visible, AlertActions.bulk_limit()))
      end

    {:noreply, assign(socket, :alert_selection, selection)}
  end

  def handle_event("alert_select_clear", _params, socket) do
    {:noreply,
     socket
     |> assign(:alert_selection, MapSet.new())
     |> assign(:alert_bulk_result, nil)}
  end

  def handle_event("alert_bulk_duration", %{"duration" => duration}, socket) when is_binary(duration) do
    {:noreply, assign(socket, :alert_bulk_duration, whitelisted_bulk_duration(duration))}
  end

  def handle_event("alert_bulk_duration", _params, socket), do: {:noreply, socket}

  def handle_event("alert_bulk_acknowledge", _params, socket) do
    run_alert_bulk(socket, :acknowledge, [])
  end

  def handle_event("alert_bulk_snooze", params, socket) do
    params = if is_map(params), do: params, else: %{}
    duration = whitelisted_bulk_duration(Map.get(params, "duration") || socket.assigns.alert_bulk_duration)
    socket = assign(socket, :alert_bulk_duration, duration)

    case AlertActions.snooze_seconds(%{"duration" => duration}) do
      {:ok, seconds} -> run_alert_bulk(socket, :snooze, seconds: seconds)
      :error -> {:noreply, put_flash(socket, :error, AlertActions.describe_error(:invalid_duration))}
    end
  end

  defp maybe_patch_netflow_range(socket, params, selector_points, patch_opts) do
    case validate_netflow_range(params, selector_points) do
      {:ok, %{start: start_time, end: end_time}} ->
        query = socket.assigns.srql[:query] || ""
        limit = socket.assigns.limit
        value = "[#{start_time},#{end_time}]"

        href =
          netflow_filter_patch(
            socket.assigns.srql[:page_path],
            query,
            limit,
            "time",
            value,
            patch_opts
          )

        {:noreply, push_patch(socket, to: href)}

      _ ->
        {:noreply, socket}
    end
  end

  defp validate_netflow_range(params, selector_points) when is_list(selector_points) do
    Enum.find_value(selector_points, :error, fn points ->
      case RangeSelection.validate(params, points) do
        {:ok, _range} = valid -> valid
        :error -> nil
      end
    end)
  end

  defp validate_netflow_range(_params, _selector_points), do: :error

  defp current_netflow_patch_opts(assigns) do
    netflow_patch_opts(
      Map.get(assigns, :netflow_compact?, false),
      Map.get(assigns, :netflow_talker_cidr),
      Map.get(assigns, :netflow_compare_mode, "off"),
      Map.get(assigns, :netflow_geo_side, "dst"),
      Map.get(assigns, :netflow_sankey_prefix, 24),
      Map.get(assigns, :netflow_stack_mode, @default_netflow_stack_mode),
      Map.get(assigns, :netflow_graph_mode, "stacked"),
      Map.get(assigns, :netflow_view, "overview")
    )
  end

  defp netflow_range_selector_points(assigns) do
    Enum.reject(
      [
        netflow_bucket_selector_points(assigns),
        netflow_stacked_selector_points(assigns),
        netflow_activity_selector_points(assigns, :netflow_protocol_activity),
        netflow_activity_selector_points(assigns, :netflow_app_activity)
      ],
      &(&1 == [])
    )
  end

  defp netflow_bucket_selector_points(assigns) do
    if netflow_bucket_selector_rendered?(assigns), do: netflow_canonical_points(assigns), else: []
  end

  defp netflow_stacked_selector_points(assigns) do
    if netflow_stacked_selector_rendered?(assigns) do
      netflow_points_rendered_by_series(assigns, :netflow_timeseries_stacked)
    else
      []
    end
  end

  defp netflow_activity_selector_points(assigns, key) do
    if netflow_activity_selector_rendered?(assigns, key) do
      netflow_points_rendered_by_series(assigns, key)
    else
      []
    end
  end

  defp netflow_bucket_selector_rendered?(assigns) do
    Map.get(assigns, :active_tab) == "netflows" and
      Map.get(assigns, :netflow_view, "overview") in ["overview", "traffic"] and
      Map.get(assigns, :netflow_graph_mode, "stacked") in ["lines", "grid"] and
      netflow_canonical_points(assigns) != []
  end

  defp netflow_stacked_selector_rendered?(assigns) do
    Map.get(assigns, :active_tab) == "netflows" and
      Map.get(assigns, :netflow_view, "overview") in ["overview", "traffic"] and
      Map.get(assigns, :netflow_graph_mode, "stacked") in ["stacked", "stacked100"] and
      populated_netflow_series?(Map.get(assigns, :netflow_timeseries_stacked))
  end

  defp netflow_activity_selector_rendered?(assigns, key) do
    Map.get(assigns, :active_tab) == "netflows" and
      Map.get(assigns, :netflow_view, "overview") == "traffic" and
      Map.get(assigns, :netflow_graph_mode, "stacked") != "sankey" and
      populated_netflow_series?(Map.get(assigns, key))
  end

  defp populated_netflow_series?(%{points: [_ | _], keys: [_ | _]}), do: true
  defp populated_netflow_series?(_series), do: false

  defp netflow_canonical_points(assigns) do
    assigns
    |> Map.get(:netflow_timeseries, %{})
    |> Map.get(:points, [])
  end

  defp netflow_points_rendered_by_series(assigns, series_key) do
    rendered_times =
      assigns
      |> Map.get(series_key, %{})
      |> Map.get(:points, [])
      |> Enum.flat_map(fn
        point when is_map(point) ->
          case parse_srql_datetime(Map.get(point, "t") || Map.get(point, :t)) do
            {:ok, timestamp} -> [DateTime.to_unix(timestamp, :millisecond)]
            :error -> []
          end

        _point ->
          []
      end)
      |> MapSet.new()

    assigns
    |> netflow_canonical_points()
    |> Enum.filter(fn
      point when is_map(point) ->
        case parse_srql_datetime(Map.get(point, :bucket_start)) do
          {:ok, bucket_start} ->
            MapSet.member?(rendered_times, DateTime.to_unix(bucket_start, :millisecond))

          :error ->
            false
        end

      _point ->
        false
    end)
  end

  defp run_alert_bulk(socket, action, opts) do
    if RBAC.can?(socket.assigns[:current_scope], AlertActions.permission()) do
      visible = visible_alert_ids(socket)
      ids = socket.assigns.alert_selection |> MapSet.to_list() |> Enum.sort()

      case AlertActions.bulk(
             socket.assigns.current_scope,
             action,
             ids,
             Keyword.put(opts, :visible_ids, visible)
           ) do
        {:ok, result} ->
          {:noreply,
           socket
           |> assign(:alert_bulk_result, Map.put(result, :action, action))
           |> assign(:alert_selection, MapSet.new())
           |> put_flash(bulk_flash_kind(result), bulk_flash_message(action, result))
           |> reload_alerts_tab()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, AlertActions.describe_error(reason))}
      end
    else
      {:noreply, put_flash(socket, :error, AlertActions.describe_error(:not_authorized))}
    end
  end

  # A partial failure is never reported as success.
  defp bulk_flash_kind(%{failed: []}), do: :info
  defp bulk_flash_kind(_result), do: :error

  defp bulk_flash_message(action, %{succeeded: succeeded, failed: failed}) do
    verb = if action == :snooze, do: "snoozed", else: "acknowledged"
    base = "#{length(succeeded)} #{verb}, #{length(failed)} failed"

    case failed do
      [] -> base
      _ -> base <> ". " <> failure_detail(failed)
    end
  end

  defp failure_detail(failed) do
    failed
    |> Enum.take(5)
    |> Enum.map_join("; ", fn {id, reason} -> String.slice(id, 0, 8) <> ": " <> reason end)
  end

  defp toggle_alert_selection(socket, id) do
    selection = socket.assigns.alert_selection

    cond do
      MapSet.member?(selection, id) ->
        assign(socket, :alert_selection, MapSet.delete(selection, id))

      id not in visible_alert_ids(socket) ->
        socket

      MapSet.size(selection) >= AlertActions.bulk_limit() ->
        put_flash(socket, :error, AlertActions.describe_error({:selection_too_large, AlertActions.bulk_limit()}))

      true ->
        assign(socket, :alert_selection, MapSet.put(selection, id))
    end
  end

  defp visible_alert_ids(socket) do
    socket.assigns
    |> Map.get(:alerts, [])
    |> Enum.map(&alert_id/1)
    |> Enum.filter(&(is_binary(&1) and &1 != "" and &1 != "unknown"))
  end

  defp whitelisted_bulk_duration(value) when is_binary(value) do
    if Enum.any?(AlertActions.snooze_options(), &(&1.value == value)) do
      value
    else
      AlertActions.default_snooze_value()
    end
  end

  defp whitelisted_bulk_duration(_value), do: AlertActions.default_snooze_value()

  # Re-reads the list from the server so the table shows the state the engine
  # returned rather than an optimistic local edit. The current page path is
  # passed as the uri so the SRQL bar keeps its `page_path`.
  defp reload_alerts_tab(socket) do
    if connected?(socket) and socket.assigns.active_tab == "alerts" do
      uri = Map.get(socket.assigns[:srql] || %{}, :page_path) || "/observability/alerts"
      dispatch_tab_load(socket, "alerts", socket.assigns.current_params, uri)
    else
      socket
    end
  end

  defp normalize_netflow_compare_param(mode) when mode in ["previous", "yesterday"], do: mode
  defp normalize_netflow_compare_param(_), do: nil

  defp normalize_netflow_geo_param(side) when side in ["src", "dst"], do: side
  defp normalize_netflow_geo_param(_), do: nil

  defp normalize_netflow_sankey_prefix_param(p) when is_integer(p) and p in [16, 24], do: to_string(p)

  defp normalize_netflow_sankey_prefix_param(_), do: nil

  defp normalize_netflow_stack_param(mode) when mode in ["ports", "talkers"], do: mode
  defp normalize_netflow_stack_param(_), do: nil

  defp normalize_netflow_graph_param(mode) when mode in ["stacked", "stacked100", "lines", "grid", "sankey"], do: mode

  defp normalize_netflow_graph_param(_), do: nil

  defp normalize_netflow_view_param(view) when view in ["overview", "traffic", "topology", "talkers", "explorer", "all"],
    do: view

  defp normalize_netflow_view_param(_), do: nil

  defp srql_submit_extra_params(socket) do
    if socket.assigns.active_tab == "netflows" do
      # Tab is in the path (/observability/netflows); only pass view chrome extras.
      %{
        "compact" => if(Map.get(socket.assigns, :netflow_compact?, false), do: "1"),
        "talker_cidr" =>
          if(is_integer(Map.get(socket.assigns, :netflow_talker_cidr)),
            do: to_string(socket.assigns.netflow_talker_cidr)
          ),
        "compare" => normalize_netflow_compare_param(Map.get(socket.assigns, :netflow_compare_mode)),
        "geo" => normalize_netflow_geo_param(Map.get(socket.assigns, :netflow_geo_side)),
        "sankey_prefix" => normalize_netflow_sankey_prefix_param(Map.get(socket.assigns, :netflow_sankey_prefix)),
        "stack" => normalize_netflow_stack_param(Map.get(socket.assigns, :netflow_stack_mode)),
        "graph" => normalize_netflow_graph_param(Map.get(socket.assigns, :netflow_graph_mode)),
        "view" => normalize_netflow_view_param(Map.get(socket.assigns, :netflow_view))
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()
    else
      # Tab is encoded in the route path; no extra intent params needed.
      %{}
    end
  end

  defp maybe_default_netflows_query(params, tab) when is_map(params) do
    if tab == "netflows" and Map.get(params, "q") in [nil, ""] do
      Map.put(params, "q", "in:flows time:#{@default_netflow_window} sort:time:desc")
    else
      params
    end
  end

  defp maybe_default_netflows_query(params, _tab), do: params

  defp maybe_apply_netflow_nf_state(params, tab) when is_map(params) and tab == "netflows" do
    nf_raw = Map.get(params, "nf")

    maybe_apply_decoded_netflow_nf_state(params, nf_raw)
  end

  defp maybe_apply_netflow_nf_state(params, _tab), do: params

  # Without an explicit `nf` state param there is nothing to restore;
  # decoding `nil` yields the default state, which would clobber an explicit
  # time window in `q` with the default netflow window.
  defp maybe_apply_decoded_netflow_nf_state(params, nf_raw) when nf_raw in [nil, ""], do: params

  defp maybe_apply_decoded_netflow_nf_state(params, nf_raw) do
    case NFState.decode_param(nf_raw) do
      {:ok, state} when is_map(state) ->
        query =
          params
          |> Map.get("q")
          |> NFQuery.flows_base_query(@default_netflow_window)
          |> NFQuery.flows_replace_time(Map.get(state, "time", @default_netflow_window))

        view =
          case Map.get(state, "graph") do
            "sankey" -> "topology"
            "grid" -> "talkers"
            _ -> Map.get(params, "view")
          end

        stack_mode =
          case NFQuery.downsample_series_field_from_dims(Map.get(state, "dims", [])) do
            "src_ip" -> "talkers"
            "dst_ip" -> "talkers"
            _ -> Map.get(params, "stack")
          end

        graph_mode =
          state
          |> Map.get("graph")
          |> normalize_netflow_graph_param()

        params
        |> Map.put("q", query)
        |> maybe_put_new_param("view", view)
        |> maybe_put_new_param("stack", stack_mode)
        |> maybe_put_new_param("graph", graph_mode)

      _ ->
        params
    end
  end

  defp extract_netflow_viz_state(params) when is_map(params) do
    case NFState.decode_param(Map.get(params, "nf")) do
      {:ok, %{} = state} -> state
      _ -> NFState.default()
    end
  end

  defp load_netflow_context(flow, scope) when is_map(flow) do
    user = scope && scope.user

    src_ip = netflow_addr(flow, :src)
    dst_ip = netflow_addr(flow, :dst)
    dst_port = to_int(netflow_port(flow, :dst))
    partition = FlowContext.flow_partition(flow)

    anchors =
      safe_netflow_context_value(:local_anchors, fn -> LocalAnchor.load_anchors(scope) end) || []

    %{
      mapbox: safe_netflow_context_value(:mapbox, fn -> read_mapbox(user) end),
      src_rdns: safe_netflow_context_value(:src_rdns, fn -> read_rdns(user, src_ip) end),
      dst_rdns: safe_netflow_context_value(:dst_rdns, fn -> read_rdns(user, dst_ip) end),
      src_geo: safe_netflow_context_value(:src_geo, fn -> read_geo(user, src_ip) end),
      dst_geo: safe_netflow_context_value(:dst_geo, fn -> read_geo(user, dst_ip) end),
      src_anchor: LocalAnchor.resolve(anchors, src_ip, partition),
      dst_anchor: LocalAnchor.resolve(anchors, dst_ip, partition),
      src_ipinfo: safe_netflow_context_value(:src_ipinfo, fn -> read_ipinfo(user, src_ip) end),
      dst_ipinfo: safe_netflow_context_value(:dst_ipinfo, fn -> read_ipinfo(user, dst_ip) end),
      src_threat: safe_netflow_context_value(:src_threat, fn -> read_threat(user, src_ip) end),
      dst_threat: safe_netflow_context_value(:dst_threat, fn -> read_threat(user, dst_ip) end),
      src_port_scan: safe_netflow_context_value(:src_port_scan, fn -> read_port_scan(user, src_ip) end),
      dst_port_anomaly: safe_netflow_context_value(:dst_port_anomaly, fn -> read_port_anomaly(user, dst_port) end)
    }
  end

  defp load_netflow_context(_flow, _scope), do: %{}

  defp safe_netflow_context_value(key, fun) when is_function(fun, 0) do
    fun.()
  rescue
    error ->
      Logger.debug("Failed to load netflow context value",
        key: key,
        reason: inspect(error)
      )

      nil
  catch
    kind, reason ->
      Logger.debug("Failed to load netflow context value",
        key: key,
        reason: inspect({kind, reason})
      )

      nil
  end

  defp read_rdns(nil, _ip), do: nil

  defp read_rdns(user, ip) when is_binary(ip) do
    ip = String.trim(ip)

    if ip in ["", "—", "-"] do
      nil
    else
      now = DateTime.utc_now()

      query =
        IpRdnsCache
        |> Ash.Query.for_read(:by_ip, %{ip: ip})
        |> EnrichmentExpiry.live(now)

      case Ash.read_one(query, actor: user) do
        {:ok, record} -> record
        _ -> nil
      end
    end
  end

  defp read_rdns(_user, _ip), do: nil

  defp read_mapbox(nil), do: nil

  defp read_mapbox(user) do
    case MapboxSettings.get_settings(actor: user) do
      {:ok, %MapboxSettings{} = settings} ->
        settings

      _ ->
        nil
    end
  end

  defp read_ipinfo(nil, _ip), do: nil

  defp read_ipinfo(user, ip) when is_binary(ip) do
    ip = String.trim(ip)

    if ip in ["", "—", "-"] do
      nil
    else
      query = Ash.Query.for_read(IpIpinfoCache, :by_ip, %{ip: ip})

      case Ash.read_one(query, actor: user) do
        {:ok, %IpIpinfoCache{} = record} ->
          record

        _ ->
          maybe_enrich_ipinfo(user, ip)
      end
    end
  end

  defp read_ipinfo(_user, _ip), do: nil

  defp maybe_enrich_ipinfo(nil, _ip), do: nil

  defp maybe_enrich_ipinfo(user, ip) when is_binary(ip) do
    if IpInfo.available?() do
      now = DateTime.utc_now()
      expires_at = DateTime.add(now, 604_800, :second)

      {attrs, err} =
        case IpInfo.lookup(ip) do
          {:ok, %{} = a} -> {a, nil}
          {:error, reason} -> {nil, inspect(reason)}
        end

      attrs =
        (attrs || %{})
        |> Map.drop([:latitude, :longitude])
        |> Map.merge(%{
          ip: ip,
          looked_up_at: now,
          expires_at: expires_at,
          error: err,
          error_count: if(is_nil(err), do: 0, else: 1)
        })

      changeset = Ash.Changeset.for_create(IpIpinfoCache, :upsert, attrs)

      case Ash.create(changeset, actor: user) do
        {:ok, %IpIpinfoCache{} = record} -> record
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end

  defp read_geo(nil, _ip), do: nil

  defp read_geo(user, ip) when is_binary(ip) do
    ip = String.trim(ip)

    if ip in ["", "—", "-"] do
      nil
    else
      now = DateTime.utc_now()

      query =
        IpGeoEnrichmentCache
        |> Ash.Query.for_read(:by_ip, %{ip: ip})
        |> EnrichmentExpiry.live(now)

      case Ash.read_one(query, actor: user) do
        {:ok, record} -> record
        _ -> nil
      end
    end
  end

  defp read_geo(_user, _ip), do: nil

  defp read_threat(nil, _ip), do: nil

  defp read_threat(user, ip) when is_binary(ip) do
    ip = String.trim(ip)

    if ip in ["", "—", "-"] do
      nil
    else
      query = Ash.Query.for_read(IpThreatIntelCache, :by_ip, %{ip: ip})

      case Ash.read_one(query, actor: user) do
        {:ok, record} -> record
        _ -> nil
      end
    end
  end

  defp read_threat(_user, _ip), do: nil

  defp read_port_scan(nil, _ip), do: nil

  defp read_port_scan(user, ip) when is_binary(ip) do
    ip = String.trim(ip)

    if ip in ["", "—", "-"] do
      nil
    else
      query = Ash.Query.for_read(NetflowPortScanFlag, :by_src_ip, %{src_ip: ip})

      case Ash.read_one(query, actor: user) do
        {:ok, record} -> record
        _ -> nil
      end
    end
  end

  defp read_port_scan(_user, _ip), do: nil

  defp read_port_anomaly(nil, _port), do: nil

  defp read_port_anomaly(user, port) when is_integer(port) do
    query = Ash.Query.for_read(NetflowPortAnomalyFlag, :by_port, %{dst_port: port})

    case Ash.read_one(query, actor: user) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  @impl true
  def handle_info({:load_tab_data, tab, params, uri}, socket) do
    if current_tab_load?(socket, tab, params) do
      {:noreply, load_tab(socket, tab, params, uri)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:logs_ingested, _event}, socket) do
    {:noreply, maybe_schedule_live_logs_refresh(socket)}
  end

  @impl true
  def handle_info({:ocsf_event, _event}, socket) do
    {:noreply, maybe_schedule_tab_live_refresh(socket, "events", :events_live?)}
  end

  @impl true
  def handle_info({:otel_traces_ingested, _event}, socket) do
    {:noreply, maybe_schedule_tab_live_refresh(socket, "traces", :traces_live?)}
  end

  @impl true
  def handle_info({:otel_trace_summaries_refreshed, _event}, socket) do
    # Span ingest can precede summary availability; the worker's post-commit
    # pulse lets the tail read the completed summaries.
    {:noreply, maybe_schedule_tab_live_refresh(socket, "traces", :traces_live?)}
  end

  @impl true
  def handle_info({:otel_metrics_ingested, _event}, socket) do
    {:noreply, maybe_schedule_tab_live_refresh(socket, "metrics", :metrics_live?)}
  end

  @impl true
  def handle_info({:alert_created, _event}, socket) do
    # See ServiceRadar.Monitoring.AlertNotifier for the shared creation boundary.
    {:noreply, maybe_schedule_tab_live_refresh(socket, "alerts", :alerts_live?)}
  end

  @impl true
  def handle_info({:flows_ingested, _event}, socket) do
    {:noreply, maybe_schedule_live_netflows_refresh(socket)}
  end

  @impl true
  def handle_info({:debounced_refresh, tab}, socket) do
    timers = Map.delete(socket.assigns[:_refresh_timers] || %{}, tab)
    socket = assign(socket, :_refresh_timers, timers)
    {:noreply, maybe_refresh_tab(socket, tab)}
  end

  @impl true
  def render(assigns) do
    pagination = get_in(assigns, [:srql, :pagination]) || %{}
    assigns = assign(assigns, :pagination, pagination)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="sr-observability-page mx-auto max-w-7xl p-6 font-sans">
        <div class="space-y-4">
          <.observability_chrome active_pane={@active_tab} tab_link_kind="patch" />

          <div :if={@active_tab == "traces" and trace_rollup_warning?(@trace_rollup_status)}>
            <div role="alert" class={ui_alert_class("warning")}>
              <.icon name="hero-exclamation-triangle" class="size-5" />
              <div class="text-sm">
                <div class="font-semibold">Trace rollups need attention</div>
                <div>{trace_rollup_warning_text(@trace_rollup_status)}</div>
              </div>
            </div>
          </div>

          <div :if={@active_tab == "logs" and logs_rollup_warning?(@logs_rollup_status)}>
            <div id="logs-rollup-warning" role="alert" class={ui_alert_class("warning")}>
              <.icon name="hero-exclamation-triangle" class="size-5" />
              <div class="text-sm">
                <div class="font-semibold">Log level rollup unavailable</div>
                <div>{logs_rollup_warning_text(@logs_rollup_status)}</div>
              </div>
            </div>
          </div>

          <.log_summary :if={@active_tab == "logs"} summary={@summary} />
          <.event_summary :if={@active_tab == "events"} summary={@event_summary} />
          <.alert_summary :if={@active_tab == "alerts"} summary={@alert_summary} />
          <.traces_summary
            :if={@active_tab == "traces"}
            stats={@trace_stats}
            latency={@trace_latency}
          />
          <.metrics_summary :if={@active_tab == "metrics"} stats={@metrics_stats} />
          <.netflow_summary
            :if={@active_tab == "netflows"}
            timezone={@current_scope.user.timezone}
            summary={@netflow_summary}
            top_talkers={@netflow_top_talkers}
            top_ports={@netflow_top_ports}
            rdns_map={@netflow_rdns_map}
            timeseries={@netflow_timeseries}
            timeseries_compare={@netflow_timeseries_compare}
            timeseries_stacked={@netflow_timeseries_stacked}
            protocol_activity={@netflow_protocol_activity}
            app_activity={@netflow_app_activity}
            frequent_talkers_packets={@netflow_frequent_talkers_packets}
            frequent_talkers_bytes={@netflow_frequent_talkers_bytes}
            geo_heatmap={@netflow_geo_heatmap}
            geo_side={@netflow_geo_side}
            compare_mode={@netflow_compare_mode}
            sankey_prefix={@netflow_sankey_prefix}
            sankey={@netflow_sankey}
            netflow_sankey_edges_json={@netflow_sankey_edges_json}
            stack_mode={@netflow_stack_mode}
            graph_mode={@netflow_graph_mode}
            base_path={Map.get(@srql, :page_path) || "/observability"}
            query={Map.get(@srql, :query, "")}
            limit={@limit}
            compact?={@netflow_compact?}
            talker_cidr={@netflow_talker_cidr}
            view={@netflow_view}
          />

          <.ui_panel :if={@active_tab != "netflows" or @netflow_view in ["explorer", "all"]}>
            <:header>
              <div class="min-w-0">
                <div class="text-sm font-semibold tracking-tight text-sr-ink">
                  {panel_title(@active_tab, panel_live?(@active_tab, assigns))}
                </div>
                <div class="text-xs leading-relaxed text-sr-muted">
                  {panel_subtitle(@active_tab, panel_live?(@active_tab, assigns))}
                </div>
              </div>

              <.log_panel_controls
                :if={@active_tab == "logs"}
                srql={@srql}
                limit={@limit}
                live?={@logs_live?}
              />
              <.traces_panel_controls
                :if={@active_tab == "traces"}
                srql={@srql}
                limit={@limit}
                live?={@traces_live?}
              />
              <.metrics_panel_controls
                :if={@active_tab == "metrics"}
                view={@metrics_view}
                srql={@srql}
                limit={@limit}
                live?={@metrics_live?}
              />
              <.events_panel_controls :if={@active_tab == "events"} live?={@events_live?} />
              <.alerts_panel_controls :if={@active_tab == "alerts"} live?={@alerts_live?} />
              <.netflow_presets
                :if={@active_tab == "netflows"}
                srql={@srql}
                limit={@limit}
                compact?={@netflow_compact?}
                talker_cidr={@netflow_talker_cidr}
                compare_mode={@netflow_compare_mode}
                geo_side={@netflow_geo_side}
                sankey_prefix={@netflow_sankey_prefix}
                stack_mode={@netflow_stack_mode}
                graph_mode={@netflow_graph_mode}
                view={@netflow_view}
                live?={@netflows_live?}
              />
            </:header>

            <.logs_table
              :if={@active_tab == "logs"}
              id="logs"
              logs={@streams.logs}
              count={length(@logs)}
              timezone={@current_scope.user.timezone}
            />
            <.traces_table
              :if={@active_tab == "traces"}
              id="traces"
              traces={@traces}
              query={Map.get(@srql, :query) || ""}
              limit={@limit}
              timezone={@current_scope.user.timezone}
            />
            <div :if={@active_tab == "metrics" and @metrics_view == "samples"}>
              <div
                id="metrics-pane-label-samples"
                class="mb-2 text-xs font-semibold uppercase tracking-wide text-sr-muted"
              >
                Span samples (slow-span exemplars)
              </div>
              <.metrics_table
                id="metrics"
                metrics={@metrics}
                sparklines={@sparklines}
                timezone={@current_scope.user.timezone}
              />
            </div>
            <div :if={@active_tab == "metrics" and @metrics_view == "points"}>
              <div
                id="metrics-pane-label-points"
                class="mb-2 text-xs font-semibold uppercase tracking-wide text-sr-muted"
              >
                OTLP metrics
              </div>
              <.otlp_points_view
                names={@otlp_metric_names}
                selected={@otlp_selected_metric}
                series={@otlp_metric_series}
                srql={@srql}
                limit={@limit}
              />
            </div>
            <.events_table
              :if={@active_tab == "events"}
              id="events"
              events={@streams.events}
              count={length(@events)}
              timezone={@current_scope.user.timezone}
            />
            <.alert_bulk_bar
              :if={@active_tab == "alerts" and @can_manage_alerts?}
              selection={@alert_selection}
              duration={@alert_bulk_duration}
              result={@alert_bulk_result}
              visible_count={length(@alerts)}
            />
            <.alerts_table
              :if={@active_tab == "alerts"}
              id="alerts"
              alerts={@alerts}
              selectable?={@can_manage_alerts?}
              selection={@alert_selection}
              timezone={@current_scope.user.timezone}
            />
            <.netflows_table
              :if={@active_tab == "netflows" and @netflow_view in ["explorer", "all"]}
              timezone={@current_scope.user.timezone}
              flows={@netflows}
              rdns_map={@netflow_rdns_map}
              threat_map={@netflow_threat_map}
              base_path={Map.get(@srql, :page_path) || "/observability"}
              query={Map.get(@srql, :query, "")}
              limit={@limit}
              compact?={@netflow_compact?}
              talker_cidr={@netflow_talker_cidr}
              compare_mode={@netflow_compare_mode}
              geo_side={@netflow_geo_side}
              sankey_prefix={@netflow_sankey_prefix}
              stack_mode={@netflow_stack_mode}
              graph_mode={@netflow_graph_mode}
              view={@netflow_view}
            />

            <div
              :if={@active_tab != "metrics" or @metrics_view == "samples"}
              class="mt-4 pt-4 border-t border-sr-line"
            >
              <.ui_pagination
                prev_cursor={Map.get(@pagination, "prev_cursor")}
                next_cursor={Map.get(@pagination, "next_cursor")}
                limit={@limit}
                current_page={Map.get(assigns, :pagination_page, 1)}
                result_count={
                  panel_result_count(
                    @active_tab,
                    @logs,
                    @traces,
                    @metrics,
                    @events,
                    @alerts,
                    @netflows
                  )
                }
              />
            </div>
          </.ui_panel>

          <.netflow_details_modal
            :if={@active_tab == "netflows" and is_map(@selected_netflow)}
            timezone={@current_scope.user.timezone}
            flow={@selected_netflow}
            context={@netflow_context}
            base_path={Map.get(@srql, :page_path) || "/observability"}
            query={Map.get(@srql, :query, "")}
            limit={@limit}
            compact?={@netflow_compact?}
            talker_cidr={@netflow_talker_cidr}
            compare_mode={@netflow_compare_mode}
            geo_side={@netflow_geo_side}
            sankey_prefix={@netflow_sankey_prefix}
            stack_mode={@netflow_stack_mode}
            graph_mode={@netflow_graph_mode}
            view={@netflow_view}
            arin_lookup={@netflow_arin_lookup}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr(:summary, :map, required: true)

  defp log_summary(assigns) do
    total = assigns.summary.total
    fatal = assigns.summary.fatal
    error = assigns.summary.error
    warning = assigns.summary.warning
    info = assigns.summary.info
    debug = assigns.summary.debug

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:fatal, fatal)
      |> assign(:error, error)
      |> assign(:warning, warning)
      |> assign(:info, info)
      |> assign(:debug, debug)

    ~H"""
    <div id="logs-level-summary" class="rounded-xl border border-sr-line bg-sr-surface p-4 font-sans">
      <div class="mb-3 flex items-center justify-between">
        <div class="flex items-center gap-3">
          <div class="text-[11px] font-semibold uppercase tracking-wider text-sr-muted">
            Log Level Breakdown
          </div>
          <div class="text-sm font-semibold tracking-tight tabular-nums text-sr-ink">
            {format_compact_int(@total)}
            <span class="text-xs font-normal text-sr-muted">total (24h)</span>
          </div>
        </div>
        <div class="flex items-center gap-1">
          <.ui_button patch={~p"/observability/logs"} size="xs" variant="ghost">
            All Logs
          </.ui_button>
          <.ui_button
            patch={
              ~p"/observability/logs?#{%{q: StatsQuery.logs_severity_data_query([:fatal, :error])}}"
            }
            size="xs"
            variant="danger"
          >
            Errors Only
          </.ui_button>
        </div>
      </div>
      <div class="grid grid-cols-2 sm:grid-cols-5 gap-3">
        <.level_stat
          label="Fatal"
          count={@fatal}
          total={@total}
          color="error"
          level={:fatal}
        />
        <.level_stat
          label="Error"
          count={@error}
          total={@total}
          color="warning"
          level={:error}
        />
        <.level_stat
          label="Warning"
          count={@warning}
          total={@total}
          color="info"
          level={:warning}
        />
        <.level_stat
          label="Info"
          count={@info}
          total={@total}
          color="primary"
          level={:info}
        />
        <.level_stat
          label="Debug"
          count={@debug}
          total={@total}
          color="success"
          level={:debug}
        />
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:count, :integer, required: true)
  attr(:total, :integer, required: true)
  attr(:color, :string, required: true)
  attr(:level, :atom, required: true)

  defp level_stat(assigns) do
    pct = if assigns.total > 0, do: round(assigns.count / assigns.total * 100), else: 0
    query = StatsQuery.logs_severity_data_query(assigns.level)

    assigns =
      assigns
      |> assign(:pct, pct)
      |> assign(:query, query)

    ~H"""
    <.link
      patch={~p"/observability/logs?#{%{q: @query}}"}
      class="group cursor-pointer rounded-lg bg-sr-subtle/50 p-3 transition-colors hover:bg-sr-subtle"
    >
      <div class="mb-1 flex items-center justify-between">
        <span class={["text-[11px] font-semibold tracking-wide", color_class(@color)]}>{@label}</span>
        <span class="text-[11px] tabular-nums text-sr-muted">{@pct}%</span>
      </div>
      <div class="text-xl font-semibold tracking-tight tabular-nums group-hover:text-sr-brand">
        {@count}
      </div>
      <div class="mt-2 h-1 overflow-hidden rounded-full bg-sr-control">
        <div class={["h-full rounded-full", color_bg(@color)]} style={"width: #{@pct}%"} />
      </div>
    </.link>
    """
  end

  attr(:summary, :map, required: true)

  defp event_summary(assigns) do
    total = Map.get(assigns.summary, :total, 0)
    critical = Map.get(assigns.summary, :critical, 0)
    high = Map.get(assigns.summary, :high, 0)
    medium = Map.get(assigns.summary, :medium, 0)
    low = Map.get(assigns.summary, :low, 0)

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:critical, critical)
      |> assign(:high, high)
      |> assign(:medium, medium)
      |> assign(:low, low)

    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface p-4">
      <div class="flex items-center justify-between mb-3">
        <div class="text-xs text-sr-muted uppercase tracking-wider">
          Event Severity Breakdown
        </div>
        <div class="flex items-center gap-1">
          <.ui_button patch={~p"/observability/events"} size="xs" variant="ghost">
            All Events
          </.ui_button>
          <.ui_button
            patch={
              ~p"/observability/events?#{%{q: "in:events severity:(Critical,High) time:last_24h sort:time:desc"}}"
            }
            size="xs"
            variant="danger"
          >
            Critical/High
          </.ui_button>
        </div>
      </div>
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <.event_severity_stat
          label="Critical"
          count={@critical}
          total={@total}
          color="error"
          severity="Critical"
        />
        <.event_severity_stat
          label="High"
          count={@high}
          total={@total}
          color="warning"
          severity="High"
        />
        <.event_severity_stat
          label="Medium"
          count={@medium}
          total={@total}
          color="info"
          severity="Medium"
        />
        <.event_severity_stat
          label="Low"
          count={@low}
          total={@total}
          color="success"
          severity="Low"
        />
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:count, :integer, required: true)
  attr(:total, :integer, required: true)
  attr(:color, :string, required: true)
  attr(:severity, :string, required: true)

  defp event_severity_stat(assigns) do
    pct = if assigns.total > 0, do: round(assigns.count / assigns.total * 100), else: 0
    query = "in:events severity:#{assigns.severity} time:last_24h sort:time:desc"

    assigns =
      assigns
      |> assign(:pct, pct)
      |> assign(:query, query)

    ~H"""
    <.link
      patch={~p"/observability/events?#{%{q: @query}}"}
      class="group cursor-pointer rounded-lg bg-sr-subtle/50 p-3 transition-colors hover:bg-sr-subtle"
    >
      <div class="mb-1 flex items-center justify-between">
        <span class={["text-[11px] font-semibold tracking-wide", color_class(@color)]}>{@label}</span>
        <span class="text-[11px] tabular-nums text-sr-muted">{@pct}%</span>
      </div>
      <div class="text-xl font-semibold tracking-tight tabular-nums group-hover:text-sr-brand">
        {@count}
      </div>
      <div class="mt-2 h-1 overflow-hidden rounded-full bg-sr-control">
        <div class={["h-full rounded-full", color_bg(@color)]} style={"width: #{@pct}%"} />
      </div>
    </.link>
    """
  end

  attr(:summary, :map, required: true)

  defp alert_summary(assigns) do
    assigns =
      assigns
      |> assign(:total, Map.get(assigns.summary, :total, 0))
      |> assign(:pending, Map.get(assigns.summary, :pending, 0))
      |> assign(:acknowledged, Map.get(assigns.summary, :acknowledged, 0))
      |> assign(:resolved, Map.get(assigns.summary, :resolved, 0))
      |> assign(:escalated, Map.get(assigns.summary, :escalated, 0))
      |> assign(:suppressed, Map.get(assigns.summary, :suppressed, 0))

    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface p-4">
      <div class="flex items-center justify-between mb-3">
        <div class="text-xs text-sr-muted uppercase tracking-wider">
          Alert Status Overview
        </div>
        <div class="flex items-center gap-1">
          <.ui_button patch={~p"/observability/alerts"} size="xs" variant="ghost">
            All Alerts
          </.ui_button>
          <.ui_button
            patch={
              ~p"/observability/alerts?#{%{q: "in:alerts status:pending time:last_7d sort:timestamp:desc"}}"
            }
            size="xs"
            variant="warning"
          >
            Pending
          </.ui_button>
        </div>
      </div>
      <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3">
        <.status_stat label="Pending" count={@pending} tone="warning" />
        <.status_stat label="Acked" count={@acknowledged} tone="info" />
        <.status_stat label="Resolved" count={@resolved} tone="success" />
        <.status_stat label="Escalated" count={@escalated} tone="error" />
        <.status_stat label="Suppressed" count={@suppressed} tone="neutral" />
        <.status_stat label="Total" count={@total} tone="ghost" />
      </div>
    </div>
    """
  end

  attr(:summary, :map, required: true)
  attr(:top_talkers, :list, default: [])
  attr(:top_ports, :list, default: [])
  attr(:rdns_map, :map, default: %{})
  attr(:timeseries, :map, required: true)
  attr(:timeseries_compare, :map, default: %{bucket_seconds: 300, points: []})
  attr(:timeseries_stacked, :map, default: %{bucket_seconds: 300, points: []})

  attr(:protocol_activity, :map, default: %{bucket_seconds: 300, keys: [], points: [], colors: %{}})

  attr(:app_activity, :map, default: %{bucket_seconds: 300, keys: [], points: [], colors: %{}})
  attr(:frequent_talkers_packets, :list, default: [])
  attr(:frequent_talkers_bytes, :list, default: [])
  attr(:compare_mode, :string, default: "off")
  attr(:geo_heatmap, :list, default: [])
  attr(:geo_side, :string, default: "dst")
  attr(:sankey_prefix, :integer, default: 24)
  attr(:sankey, :map, default: %{edges: [], sources: [], mids: [], dests: []})
  attr(:netflow_sankey_edges_json, :string, default: "[]")
  attr(:stack_mode, :string, default: @default_netflow_stack_mode)
  attr(:graph_mode, :string, default: "stacked")
  attr(:base_path, :string, required: true)
  attr(:query, :string, required: true)
  attr(:limit, :integer, required: true)
  attr(:compact?, :boolean, default: false)
  attr(:talker_cidr, :integer, default: nil)
  attr(:view, :string, default: "overview")
  attr(:timezone, :string, required: true)

  defp netflow_summary(assigns) do
    # This function is sometimes called directly (not as a component) with a
    # manually-built assigns map. Guard against missing keys that would
    # otherwise crash rendering (e.g. sankey JSON edges).
    assigns =
      assigns
      |> assign_new(:netflow_sankey_edges_json, fn -> "[]" end)
      |> assign_new(:sankey_prefix, fn -> 24 end)
      |> assign_new(:stack_mode, fn -> @default_netflow_stack_mode end)

    summary = assigns.summary

    assigns =
      assigns
      |> assign(:total, Map.get(summary, :total, 0))
      |> assign(:tcp, Map.get(summary, :tcp, 0))
      |> assign(:udp, Map.get(summary, :udp, 0))
      |> assign(:other, Map.get(summary, :other, 0))
      |> assign(:total_bytes, Map.get(summary, :total_bytes, 0))

    ~H"""
    <div class="space-y-3">
      <% patch_opts =
        netflow_patch_opts(
          @compact?,
          @talker_cidr,
          @compare_mode,
          @geo_side,
          @sankey_prefix,
          @stack_mode,
          @graph_mode,
          @view
        ) %>
      <.ui_panel class="p-3">
        <div class="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-4">
          <.link
            patch={
              netflow_talker_cidr_patch(
                @base_path,
                @query,
                @limit,
                Map.put(patch_opts, :view, "traffic")
              )
            }
            class={[
              "rounded-xl border bg-sr-surface p-3 transition hover:border-sr-brand/40 hover:bg-sr-subtle/30",
              @view == "traffic" && "border-sr-brand/50 bg-sr-brand/5",
              @view != "traffic" && "border-sr-line"
            ]}
          >
            <div class="text-sm font-semibold">Traffic Analysis</div>
            <div class="mt-1 text-xs text-sr-muted">
              Rate trends, protocol/app activity, stacked series
            </div>
          </.link>
          <.link
            patch={
              netflow_talker_cidr_patch(
                @base_path,
                @query,
                @limit,
                Map.put(patch_opts, :view, "talkers")
              )
            }
            class={[
              "rounded-xl border bg-sr-surface p-3 transition hover:border-sr-brand/40 hover:bg-sr-subtle/30",
              @view == "talkers" && "border-sr-brand/50 bg-sr-brand/5",
              @view != "talkers" && "border-sr-line"
            ]}
          >
            <div class="text-sm font-semibold">Talkers & Ports</div>
            <div class="mt-1 text-xs text-sr-muted">
              Heavy hitters, frequent talkers, top destinations
            </div>
          </.link>
          <.link
            patch={
              netflow_talker_cidr_patch(
                @base_path,
                @query,
                @limit,
                Map.put(patch_opts, :view, "topology")
              )
            }
            class={[
              "rounded-xl border bg-sr-surface p-3 transition hover:border-sr-brand/40 hover:bg-sr-subtle/30",
              @view == "topology" && "border-sr-brand/50 bg-sr-brand/5",
              @view != "topology" && "border-sr-line"
            ]}
          >
            <div class="text-sm font-semibold">Topology</div>
            <div class="mt-1 text-xs text-sr-muted">Sankey flow path and geo distribution</div>
          </.link>
          <.link
            patch={
              netflow_talker_cidr_patch(
                @base_path,
                @query,
                @limit,
                Map.put(patch_opts, :view, "explorer")
              )
            }
            class={[
              "rounded-xl border bg-sr-surface p-3 transition hover:border-sr-brand/40 hover:bg-sr-subtle/30",
              @view == "explorer" && "border-sr-brand/50 bg-sr-brand/5",
              @view != "explorer" && "border-sr-line"
            ]}
          >
            <div class="text-sm font-semibold">Flow Explorer</div>
            <div class="mt-1 text-xs text-sr-muted">
              Raw records table with SRQL-driven filtering
            </div>
          </.link>
        </div>
      </.ui_panel>

      <.ui_panel :if={@view in ["overview", "traffic"]} class="p-0" body_class="p-0">
        <div class="p-3 border-b border-sr-line bg-sr-subtle/30 flex items-center justify-between">
          <div class="text-xs uppercase tracking-wider text-sr-muted">Traffic Over Time</div>
          <div class="flex flex-wrap items-center gap-1">
            <.ui_button
              size="xs"
              variant="ghost"
              active={@graph_mode == "lines"}
              class="rounded-full"
              patch={
                netflow_talker_cidr_patch(
                  @base_path,
                  @query,
                  @limit,
                  Map.put(patch_opts, :graph_mode, "lines")
                )
              }
            >
              Lines
            </.ui_button>
            <.ui_button
              size="xs"
              variant="ghost"
              active={@graph_mode == "grid"}
              class="rounded-full"
              patch={
                netflow_talker_cidr_patch(
                  @base_path,
                  @query,
                  @limit,
                  Map.put(patch_opts, :graph_mode, "grid")
                )
              }
            >
              Grid
            </.ui_button>
            <.ui_button
              size="xs"
              variant="ghost"
              active={@graph_mode == "stacked"}
              class="rounded-full"
              patch={
                netflow_talker_cidr_patch(
                  @base_path,
                  @query,
                  @limit,
                  Map.put(patch_opts, :graph_mode, "stacked")
                )
              }
            >
              Stacked
            </.ui_button>
            <.ui_button
              size="xs"
              variant="ghost"
              active={@graph_mode == "stacked100"}
              class="rounded-full"
              patch={
                netflow_talker_cidr_patch(
                  @base_path,
                  @query,
                  @limit,
                  Map.put(patch_opts, :graph_mode, "stacked100")
                )
              }
            >
              100%
            </.ui_button>
            <.ui_button
              size="xs"
              variant="ghost"
              active={@graph_mode == "sankey"}
              class="rounded-full"
              patch={
                netflow_talker_cidr_patch(
                  @base_path,
                  @query,
                  @limit,
                  patch_opts
                  |> Map.put(:graph_mode, "sankey")
                  |> Map.put(:view, "topology")
                )
              }
            >
              Sankey
            </.ui_button>
            <span class="text-xs text-sr-muted font-mono">
              bucket: {format_bucket(@timeseries.bucket_seconds)}
            </span>
          </div>
        </div>
        <div class="p-3">
          <%= if @graph_mode in ["stacked", "stacked100"] do %>
            <div class="flex flex-wrap items-center justify-between gap-2 mb-2">
              <div class="text-xs uppercase tracking-wider text-sr-muted">Series</div>
              <div class="flex flex-wrap items-center gap-1">
                <.ui_button
                  size="xs"
                  variant="ghost"
                  active={@stack_mode == "ports"}
                  class="rounded-full"
                  patch={
                    netflow_talker_cidr_patch(
                      @base_path,
                      @query,
                      @limit,
                      Map.put(patch_opts, :stack_mode, "ports")
                    )
                  }
                >
                  Ports
                </.ui_button>
                <.ui_button
                  size="xs"
                  variant="ghost"
                  active={@stack_mode == "talkers"}
                  class="rounded-full"
                  patch={
                    netflow_talker_cidr_patch(
                      @base_path,
                      @query,
                      @limit,
                      Map.put(patch_opts, :stack_mode, "talkers")
                    )
                  }
                >
                  Talkers
                </.ui_button>
              </div>
            </div>
            <.netflow_timeseries_stacked_area_chart
              id="netflow-top-stacked"
              timezone={@timezone}
              points={
                if(
                  @graph_mode == "stacked100",
                  do:
                    netflow_stacked_percent_points(
                      Map.get(@timeseries_stacked, :points, []),
                      Map.get(@timeseries_stacked, :keys, [])
                    ),
                  else: Map.get(@timeseries_stacked, :points, [])
                )
              }
              keys={Map.get(@timeseries_stacked, :keys, [])}
              mode={@stack_mode}
              range_intervals={RangeSelection.canonical_intervals(@timeseries.points)}
              range_event="netflow_range_selected"
            />
          <% else %>
            <.netflow_timeseries_chart
              timezone={@timezone}
              points={@timeseries.points}
              compare_points={Map.get(@timeseries_compare, :points, [])}
              bucket_seconds={@timeseries.bucket_seconds}
              compare_mode={@compare_mode}
              mode={@graph_mode}
            />
          <% end %>
        </div>
      </.ui_panel>

      <.netflow_activity_cards
        :if={@view == "traffic"}
        timezone={@timezone}
        timeseries={@timeseries}
        protocol_activity={@protocol_activity}
        app_activity={@app_activity}
        graph_mode={@graph_mode}
      />

      <.ui_panel :if={@view == "talkers"} class="p-0" body_class="p-0">
        <div class="p-3 border-b border-sr-line bg-sr-subtle/30 flex items-center justify-between gap-3">
          <div class="text-xs uppercase tracking-wider text-sr-muted">
            Frequent Talkers Icicle (src → dst → port)
          </div>
          <div class="text-[11px] text-sr-muted">
            Click block to filter · click same depth to zoom out
          </div>
        </div>
        <div class="p-3">
          <div
            id="netflow-talkers-icicle"
            class="w-full h-72"
            phx-hook="NetflowTalkersIcicle"
            phx-update="ignore"
            data-edges={@netflow_sankey_edges_json || "[]"}
          >
            <svg class="w-full h-full" role="img" aria-label="Frequent talkers icicle chart"></svg>
          </div>
        </div>
      </.ui_panel>

      <.ui_panel :if={@view == "traffic" and @graph_mode in ["lines", "grid"]} class="p-3">
        <div>
          <div class="text-xs uppercase tracking-wider text-sr-muted">Compare</div>
          <div class="mt-2 flex flex-wrap items-center gap-2">
            <.ui_button
              size="xs"
              variant="ghost"
              active={@compare_mode == "off"}
              class="rounded-full"
              patch={
                netflow_talker_cidr_patch(
                  @base_path,
                  @query,
                  @limit,
                  Map.put(patch_opts, :compare_mode, "off")
                )
              }
            >
              Off
            </.ui_button>
            <.ui_button
              size="xs"
              variant="ghost"
              active={@compare_mode == "previous"}
              class="rounded-full"
              patch={
                netflow_talker_cidr_patch(
                  @base_path,
                  @query,
                  @limit,
                  Map.put(patch_opts, :compare_mode, "previous")
                )
              }
            >
              Previous Window
            </.ui_button>
            <.ui_button
              size="xs"
              variant="ghost"
              active={@compare_mode == "yesterday"}
              class="rounded-full"
              patch={
                netflow_talker_cidr_patch(
                  @base_path,
                  @query,
                  @limit,
                  Map.put(patch_opts, :compare_mode, "yesterday")
                )
              }
            >
              Yesterday
            </.ui_button>
          </div>
        </div>
      </.ui_panel>

      <.ui_panel :if={@view == "topology"} class="p-3">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <div class="text-xs uppercase tracking-wider text-sr-muted">Geo</div>
            <div class="mt-2 flex flex-wrap items-center gap-2">
              <.ui_button
                size="xs"
                variant="ghost"
                active={@geo_side == "dst"}
                class="rounded-full"
                patch={
                  netflow_talker_cidr_patch(
                    @base_path,
                    @query,
                    @limit,
                    Map.put(patch_opts, :geo_side, "dst")
                  )
                }
              >
                Destination
              </.ui_button>
              <.ui_button
                size="xs"
                variant="ghost"
                active={@geo_side == "src"}
                class="rounded-full"
                patch={
                  netflow_talker_cidr_patch(
                    @base_path,
                    @query,
                    @limit,
                    Map.put(patch_opts, :geo_side, "src")
                  )
                }
              >
                Source
              </.ui_button>
            </div>
          </div>

          <div>
            <div class="text-xs uppercase tracking-wider text-sr-muted">Sankey</div>
            <div class="mt-2 flex flex-wrap items-center gap-2">
              <.ui_button
                size="xs"
                variant="ghost"
                active={@sankey_prefix == 24}
                class="rounded-full"
                patch={
                  netflow_talker_cidr_patch(
                    @base_path,
                    @query,
                    @limit,
                    Map.put(patch_opts, :sankey_prefix, 24)
                  )
                }
              >
                /24
              </.ui_button>
              <.ui_button
                size="xs"
                variant="ghost"
                active={@sankey_prefix == 16}
                class="rounded-full"
                patch={
                  netflow_talker_cidr_patch(
                    @base_path,
                    @query,
                    @limit,
                    Map.put(patch_opts, :sankey_prefix, 16)
                  )
                }
              >
                /16
              </.ui_button>
              <.ui_button
                size="xs"
                variant="ghost"
                class="rounded-full"
                patch={
                  netflow_talker_cidr_patch(
                    @base_path,
                    @query
                    |> strip_filter("src_cidr")
                    |> strip_filter("dst_cidr")
                    |> strip_filter("dst_port"),
                    @limit,
                    patch_opts
                  )
                }
              >
                Reset Edge Filter
              </.ui_button>
              <.ui_button
                size="xs"
                variant="ghost"
                class="rounded-full"
                patch={
                  netflow_talker_cidr_patch(
                    @base_path,
                    @query
                    |> strip_filter("src_cidr")
                    |> strip_filter("dst_cidr")
                    |> strip_filter("dst_port")
                    |> strip_filter("src_country_iso2")
                    |> strip_filter("dst_country_iso2"),
                    @limit,
                    patch_opts
                  )
                }
              >
                Reset Topology
              </.ui_button>
            </div>
          </div>
        </div>
      </.ui_panel>

      <div
        :if={@view == "topology"}
        class="grid grid-cols-1 gap-3 lg:grid-cols-3"
      >
        <.ui_panel class="p-3 lg:col-span-2">
          <div class="flex items-center justify-between">
            <div class="text-xs uppercase tracking-wider text-sr-muted">
              Traffic Sankey (Top 40 Edges)
            </div>
            <div class="text-[10px] font-mono text-sr-muted">
              src:/{@sankey_prefix} -> port -> dst:/{@sankey_prefix}
            </div>
          </div>
          <div class="mt-3">
            <div
              id={"netflow-sankey-#{@sankey_prefix}"}
              phx-hook="NetflowSankeyChart"
              data-edges={@netflow_sankey_edges_json || "[]"}
              class="w-full"
            >
              <svg class="w-full h-[34rem]"></svg>
              <div
                :if={Map.get(@sankey, :edges, []) == []}
                class="py-8 text-center text-sm text-sr-muted"
              >
                No Sankey edges in this window.
              </div>
            </div>
          </div>
        </.ui_panel>

        <.ui_panel class="p-3">
          <div class="flex items-center justify-between">
            <div class="text-xs uppercase tracking-wider text-sr-muted">
              Geo Heatmap (Top Countries)
            </div>
            <div class="text-[10px] font-mono text-sr-muted">
              {@geo_side}
            </div>
          </div>
          <div class="mt-3">
            <.netflow_geo_heatmap rows={@geo_heatmap} />
          </div>
        </.ui_panel>
      </div>

      <div :if={@view == "overview"} class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <.ui_panel class="p-3">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-sr-muted">Total Flows</p>
              <p class="text-2xl font-bold">{@total}</p>
            </div>
            <.icon name="hero-arrow-trending-up" class="h-8 w-8 text-sr-muted" />
          </div>
        </.ui_panel>

        <.ui_panel class="p-3">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-sr-muted">TCP Flows</p>
              <p class="text-2xl font-bold">{@tcp}</p>
            </div>
            <.ui_badge variant="success">TCP</.ui_badge>
          </div>
        </.ui_panel>

        <.ui_panel class="p-3">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-sr-muted">UDP Flows</p>
              <p class="text-2xl font-bold">{@udp}</p>
            </div>
            <.ui_badge variant="info">UDP</.ui_badge>
          </div>
        </.ui_panel>

        <.ui_panel class="p-3">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-sr-muted">Other</p>
              <p class="text-2xl font-bold">{@other}</p>
            </div>
            <.ui_badge variant="ghost">Other</.ui_badge>
          </div>
        </.ui_panel>

        <.ui_panel class="p-3">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-sr-muted">Total Bytes</p>
              <p class="text-2xl font-bold">{format_netflow_bytes(@total_bytes)}</p>
            </div>
            <.icon name="hero-circle-stack" class="h-8 w-8 text-sr-muted" />
          </div>
        </.ui_panel>
      </div>

      <.ui_panel :if={@view == "overview"} class="p-3">
        <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div class="min-w-0">
            <div class="text-xs uppercase tracking-wider text-sr-muted">
              Protocol Distribution
            </div>
            <div class="mt-2 flex flex-wrap items-center gap-2">
              <.ui_button
                size="xs"
                variant="ghost"
                class="rounded-full"
                patch={
                  netflow_filter_patch(
                    @base_path,
                    @query,
                    @limit,
                    "proto",
                    "",
                    patch_opts
                  )
                }
              >
                All
              </.ui_button>
              <.ui_button
                size="xs"
                variant="ghost"
                class="rounded-full"
                patch={
                  netflow_filter_patch(
                    @base_path,
                    @query,
                    @limit,
                    "proto",
                    "6",
                    patch_opts
                  )
                }
              >
                TCP
              </.ui_button>
              <.ui_button
                size="xs"
                variant="ghost"
                class="rounded-full"
                patch={
                  netflow_filter_patch(
                    @base_path,
                    @query,
                    @limit,
                    "proto",
                    "17",
                    patch_opts
                  )
                }
              >
                UDP
              </.ui_button>
              <span class="text-xs text-sr-muted">
                Other: {format_compact_int(@other)}
              </span>
            </div>

            <div class="mt-3">
              <div class="text-xs uppercase tracking-wider text-sr-muted">
                Direction
              </div>
              <div class="mt-2 flex flex-wrap items-center gap-2">
                <.ui_button
                  size="xs"
                  variant="ghost"
                  class="rounded-full"
                  patch={
                    netflow_filter_patch(
                      @base_path,
                      @query,
                      @limit,
                      "direction",
                      "",
                      patch_opts
                    )
                  }
                >
                  All
                </.ui_button>
                <.ui_button
                  size="xs"
                  variant="ghost"
                  class="rounded-full"
                  patch={
                    netflow_filter_patch(
                      @base_path,
                      @query,
                      @limit,
                      "direction",
                      "internal",
                      patch_opts
                    )
                  }
                >
                  Internal
                </.ui_button>
                <.ui_button
                  size="xs"
                  variant="ghost"
                  class="rounded-full"
                  patch={
                    netflow_filter_patch(
                      @base_path,
                      @query,
                      @limit,
                      "direction",
                      "outbound",
                      patch_opts
                    )
                  }
                >
                  Outbound
                </.ui_button>
                <.ui_button
                  size="xs"
                  variant="ghost"
                  class="rounded-full"
                  patch={
                    netflow_filter_patch(
                      @base_path,
                      @query,
                      @limit,
                      "direction",
                      "inbound",
                      patch_opts
                    )
                  }
                >
                  Inbound
                </.ui_button>
                <.ui_button
                  size="xs"
                  variant="ghost"
                  class="rounded-full"
                  patch={
                    netflow_filter_patch(
                      @base_path,
                      @query,
                      @limit,
                      "direction",
                      "external",
                      patch_opts
                    )
                  }
                >
                  External
                </.ui_button>
              </div>
            </div>
          </div>

          <div class="shrink-0">
            <.netflow_protocol_donut tcp={@tcp} udp={@udp} other={@other} />
          </div>
        </div>
      </.ui_panel>

      <div :if={@view == "overview"} class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <.ui_panel class="p-3">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-sr-muted">Avg Bandwidth</p>
              <p class="text-xl font-bold">
                {format_netflow_bps(Map.get(@summary, :avg_bps, 0.0))}
              </p>
            </div>
            <.icon name="hero-bolt" class="h-8 w-8 text-sr-muted" />
          </div>
        </.ui_panel>

        <.ui_panel class="p-3">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-sr-muted">Avg PPS</p>
              <p class="text-xl font-bold">
                {format_netflow_pps(Map.get(@summary, :avg_pps, 0.0))}
              </p>
            </div>
            <.icon name="hero-signal" class="h-8 w-8 text-sr-muted" />
          </div>
        </.ui_panel>

        <.ui_panel class="p-3">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm font-medium text-sr-muted">Total Packets</p>
              <p class="text-xl font-bold">
                {format_compact_int(Map.get(@summary, :total_packets, 0))}
              </p>
            </div>
            <.icon name="hero-inbox-stack" class="h-8 w-8 text-sr-muted" />
          </div>
        </.ui_panel>
      </div>

      <div :if={@view == "talkers"} class="grid grid-cols-1 gap-3 lg:grid-cols-2">
        <.ui_panel class="p-0" body_class="p-0">
          <div class="p-4 border-b border-sr-line bg-sr-subtle/30 flex items-center justify-between">
            <div class="text-xs uppercase tracking-wider text-sr-muted">Top Talkers</div>
            <div class="flex items-center gap-2">
              <div class="flex items-center gap-1">
                <.ui_button
                  patch={
                    netflow_talker_cidr_patch(
                      @base_path,
                      @query,
                      @limit,
                      Map.put(patch_opts, :talker_cidr, nil)
                    )
                  }
                  size="xs"
                  variant={if is_nil(@talker_cidr), do: "primary", else: "ghost"}
                  class="font-mono"
                >
                  Host
                </.ui_button>
                <.ui_button
                  patch={
                    netflow_talker_cidr_patch(
                      @base_path,
                      @query,
                      @limit,
                      Map.put(patch_opts, :talker_cidr, 24)
                    )
                  }
                  size="xs"
                  variant={if @talker_cidr == 24, do: "primary", else: "ghost"}
                  class="font-mono"
                >
                  /24
                </.ui_button>
                <.ui_button
                  patch={
                    netflow_talker_cidr_patch(
                      @base_path,
                      @query,
                      @limit,
                      Map.put(patch_opts, :talker_cidr, 16)
                    )
                  }
                  size="xs"
                  variant={if @talker_cidr == 16, do: "primary", else: "ghost"}
                  class="font-mono"
                >
                  /16
                </.ui_button>
              </div>
              <.ui_badge variant="ghost" size="xs">{length(@top_talkers)}</.ui_badge>
            </div>
          </div>
          <div class="p-2">
            <div :if={@top_talkers == []} class="px-2 py-6 text-center text-sm text-sr-muted">
              No talker stats for this window.
            </div>
            <div :if={@top_talkers != []} class="space-y-1">
              <%= for row <- @top_talkers do %>
                <div class="flex items-center justify-between gap-3 rounded-lg px-3 py-2 hover:bg-sr-subtle/40">
                  <div class="min-w-0">
                    <% ip = Map.get(row, :ip) || "—" %>
                    <.link
                      patch={
                        netflow_filter_patch(
                          @base_path,
                          @query,
                          @limit,
                          "src_ip",
                          if(is_integer(@talker_cidr),
                            do: cidr_to_like_prefix(Map.get(row, :ip), @talker_cidr),
                            else: Map.get(row, :ip)
                          ),
                          patch_opts
                        )
                      }
                      class="text-sm font-mono hover:underline"
                    >
                      {ip}
                    </.link>
                    <div
                      :if={hostname = Map.get(@rdns_map, ip)}
                      class="mt-0.5 text-[11px] text-sr-muted max-w-60 truncate font-mono"
                      title={hostname}
                    >
                      {hostname}
                    </div>
                    <div class="text-[10px] uppercase tracking-wider text-sr-muted">
                      Source
                    </div>
                  </div>
                  <div class="shrink-0 text-right">
                    <div class="text-sm font-mono">{format_netflow_bytes(Map.get(row, :bytes))}</div>
                    <div class="text-[10px] uppercase tracking-wider text-sr-muted">Bytes</div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </.ui_panel>

        <.ui_panel class="p-0" body_class="p-0">
          <div class="p-4 border-b border-sr-line bg-sr-subtle/30 flex items-center justify-between">
            <div class="text-xs uppercase tracking-wider text-sr-muted">Top Ports</div>
            <.ui_badge variant="ghost" size="xs">{length(@top_ports)}</.ui_badge>
          </div>
          <div class="p-2">
            <div :if={@top_ports == []} class="px-2 py-6 text-center text-sm text-sr-muted">
              No port stats for this window.
            </div>
            <div :if={@top_ports != []} class="space-y-1">
              <%= for row <- @top_ports do %>
                <div class="flex items-center justify-between gap-3 rounded-lg px-3 py-2 hover:bg-sr-subtle/40">
                  <div class="min-w-0">
                    <div class="flex items-center gap-2">
                      <% service = netflow_service_label(Map.get(row, :port)) %>
                      <.link
                        patch={
                          netflow_filter_patch(
                            @base_path,
                            @query,
                            @limit,
                            "dst_port",
                            to_string(Map.get(row, :port)),
                            patch_opts
                          )
                        }
                        class="text-sm font-mono hover:underline"
                      >
                        {Map.get(row, :port) || "—"}
                      </.link>
                      <.ui_badge
                        :if={service}
                        variant="ghost"
                        size="xs"
                        class="font-mono"
                      >
                        {service}
                      </.ui_badge>
                    </div>
                    <div class="text-[10px] uppercase tracking-wider text-sr-muted">
                      Destination port{if(service, do: " · #{service}", else: "")}
                    </div>
                  </div>
                  <div class="shrink-0 text-right">
                    <div class="text-sm font-mono">{format_netflow_bytes(Map.get(row, :bytes))}</div>
                    <div class="text-[10px] uppercase tracking-wider text-sr-muted">Bytes</div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </.ui_panel>
      </div>
      <.ui_panel :if={@view == "explorer"} class="p-4">
        <div class="text-sm font-medium">Flow Explorer</div>
        <div class="text-xs text-sr-muted mt-1">
          Detailed flow rows are shown below in the table. Use SRQL and presets to refine the dataset.
        </div>
      </.ui_panel>
    </div>
    """
  end

  attr(:rows, :list, default: [])

  defp netflow_geo_heatmap(assigns) do
    rows =
      assigns.rows
      |> Enum.filter(&is_map/1)
      |> Enum.take(48)

    max_bytes =
      rows
      |> Enum.map(&Map.get(&1, :bytes, 0))
      |> Enum.max(fn -> 0 end)

    assigns =
      assigns
      |> assign(:rows, rows)
      |> assign(:max_bytes, max_bytes)

    ~H"""
    <div :if={@rows == []} class="py-6 text-center text-sm text-sr-muted">
      No GeoIP samples in this window.
    </div>

    <div :if={@rows != []} class="grid grid-cols-4 sm:grid-cols-6 gap-2">
      <%= for row <- @rows do %>
        {alpha = netflow_heat_alpha(Map.get(row, :bytes, 0), @max_bytes)}
        <button
          type="button"
          phx-click="netflow_geo_click"
          phx-value-country={Map.get(row, :country)}
          class="rounded-lg border border-sr-line p-2 text-left hover:border-sr-brand/50 transition-colors"
          style={"background-color: rgba(59, 130, 246, #{alpha})"}
        >
          <div class="text-xs font-mono">{Map.get(row, :country)}</div>
          <div class="text-[10px] text-sr-muted font-mono">
            {format_netflow_bytes(Map.get(row, :bytes))}
          </div>
        </button>
      <% end %>
    </div>
    """
  end

  defp netflow_heat_alpha(bytes, max_bytes) when is_integer(bytes) and is_integer(max_bytes) and max_bytes > 0 do
    ratio = bytes / max_bytes
    Float.round(0.08 + min(max(ratio, 0.0), 1.0) * 0.65, 3)
  end

  defp netflow_heat_alpha(_bytes, _max_bytes), do: 0.08

  attr(:tcp, :integer, required: true)
  attr(:udp, :integer, required: true)
  attr(:other, :integer, required: true)

  defp netflow_protocol_donut(assigns) do
    total = max(assigns.tcp + assigns.udp + assigns.other, 1)
    tcp = assigns.tcp * 1.0
    udp = assigns.udp * 1.0
    other = assigns.other * 1.0

    # Simple donut chart using stroke dasharray. Keep it small and readable.
    r = 14
    c = 2 * :math.pi() * r

    tcp_len = c * (tcp / total)
    udp_len = c * (udp / total)
    other_len = c * (other / total)

    # Start at 12 o'clock.
    tcp_off = 0.0
    udp_off = tcp_off - tcp_len
    other_off = udp_off - udp_len

    assigns =
      assigns
      |> assign(:circumference, c)
      |> assign(:tcp_len, tcp_len)
      |> assign(:udp_len, udp_len)
      |> assign(:other_len, other_len)
      |> assign(:tcp_off, tcp_off)
      |> assign(:udp_off, udp_off)
      |> assign(:other_off, other_off)
      |> assign(:total, total)

    ~H"""
    <div class="flex items-center gap-3">
      <svg viewBox="0 0 40 40" class="h-12 w-12">
        <g transform="rotate(-90 20 20)">
          <circle
            cx="20"
            cy="20"
            r="14"
            fill="none"
            stroke-width="6"
            class="stroke-sr-line"
          />
          <circle
            cx="20"
            cy="20"
            r="14"
            fill="none"
            stroke-width="6"
            stroke-linecap="butt"
            class="stroke-emerald-400"
            stroke-dasharray={"#{@tcp_len} #{@circumference}"}
            stroke-dashoffset={@tcp_off}
          />
          <circle
            cx="20"
            cy="20"
            r="14"
            fill="none"
            stroke-width="6"
            stroke-linecap="butt"
            class="stroke-sky-400"
            stroke-dasharray={"#{@udp_len} #{@circumference}"}
            stroke-dashoffset={@udp_off}
          />
          <circle
            cx="20"
            cy="20"
            r="14"
            fill="none"
            stroke-width="6"
            stroke-linecap="butt"
            class="stroke-sr-muted/30"
            stroke-dasharray={"#{@other_len} #{@circumference}"}
            stroke-dashoffset={@other_off}
          />
        </g>
      </svg>

      <div class="text-xs font-mono text-sr-muted leading-tight">
        <div class="flex items-center gap-2">
          <span class="inline-block size-2 rounded-full bg-emerald-400"></span>
          <span>TCP {format_compact_int(@tcp)}</span>
        </div>
        <div class="flex items-center gap-2">
          <span class="inline-block size-2 rounded-full bg-sky-400"></span>
          <span>UDP {format_compact_int(@udp)}</span>
        </div>
      </div>
    </div>
    """
  end

  attr(:points, :list, default: [])
  attr(:compare_points, :list, default: [])
  attr(:bucket_seconds, :integer, required: true)
  attr(:compare_mode, :string, default: "off")
  attr(:mode, :string, default: "grid")
  attr(:timezone, :string, required: true)

  def netflow_timeseries_chart(assigns) do
    points =
      Enum.filter(assigns.points, fn point ->
        is_map(point) and RangeSelection.canonical_intervals([point]) != []
      end)

    compare_points = Enum.filter(assigns.compare_points, &is_map/1)

    max_bytes =
      [points, compare_points]
      |> List.flatten()
      |> Enum.map(&Map.get(&1, :bytes, 0))
      |> Enum.max(fn -> 0 end)

    bucket_seconds = assigns.bucket_seconds

    mode = if assigns.mode == "lines", do: :lines, else: :grid

    range_points =
      points
      |> RangeSelection.intervals(mode, 1000)
      |> Enum.zip_with(points, fn interval, point -> Map.put(interval, :point, point) end)

    {axis_start, axis_middle, axis_end} =
      case points do
        [] ->
          {nil, nil, nil}

        [first_point | _] ->
          middle_point = Enum.at(points, div(length(points), 2)) || first_point
          last_point = List.last(points)

          {
            DateTime.to_iso8601(first_point.bucket_start),
            DateTime.to_iso8601(middle_point.bucket_start),
            DateTime.to_iso8601(last_point.bucket_end)
          }
      end

    assigns =
      assigns
      |> assign(:points, points)
      |> assign(:compare_points, compare_points)
      |> assign(:max_bytes, max_bytes)
      |> assign(:bucket_seconds, bucket_seconds)
      |> assign(:range_points, range_points)
      |> assign(:range_buckets, Enum.map(range_points, &Map.take(&1, [:x, :start, :end])))
      |> assign(:axis_start, axis_start)
      |> assign(:axis_middle, axis_middle)
      |> assign(:axis_end, axis_end)

    ~H"""
    <div :if={@points == []} class="py-8 text-center text-sm text-sr-muted">
      No traffic samples in this window.
    </div>

    <div
      :if={@points != []}
      id="netflow-traffic-timeseries"
      phx-hook="NetflowTrafficTooltip"
      data-timezone={@timezone}
      data-points={netflow_timeseries_tooltip_points_json(@range_points, @bucket_seconds)}
      data-bucket-seconds={@bucket_seconds}
      data-range-buckets={Jason.encode!(@range_buckets)}
      data-range-event="netflow_range_selected"
      data-chart-width="1000"
      data-chart-height="160"
      role="group"
      tabindex="0"
      aria-label="Select a Traffic Over Time range"
      aria-describedby="netflow-traffic-range-instructions"
      class="w-full relative touch-pan-y focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sr-brand/70"
    >
      <p id="netflow-traffic-range-instructions" class="sr-only">
        Use Left and Right Arrow to move through traffic buckets. Hold Shift to extend a range,
        press Enter to apply it, or Escape to clear it.
      </p>
      <svg
        viewBox="0 0 1000 160"
        class="w-full h-40"
        preserveAspectRatio="none"
        role="img"
        aria-label="NetFlow traffic over time"
        data-range-svg
      >
        <defs>
          <linearGradient id="netflowArea" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="currentColor" stop-opacity="0.20" />
            <stop offset="100%" stop-color="currentColor" stop-opacity="0.02" />
          </linearGradient>
        </defs>

        <%= for y <- [20, 50, 80, 110, 140] do %>
          <line
            x1="0"
            y1={y}
            x2="1000"
            y2={y}
            class="stroke-sr-line"
            stroke-width="1"
          />
        <% end %>

        <%= for x <- [0, 200, 400, 600, 800, 1000] do %>
          <line
            x1={x}
            y1="10"
            x2={x}
            y2="150"
            class="stroke-sr-line/60"
            stroke-width="1"
          />
        <% end %>

        <rect
          data-range-surface
          x="0"
          y="10"
          width="1000"
          height="140"
          fill="transparent"
          pointer-events="all"
        />

        <rect
          data-range-overlay
          y="10"
          height="140"
          class="hidden fill-sr-brand/15 stroke-sr-brand/70"
          stroke-width="1"
          pointer-events="none"
        />

        <text x="4" y="16" class="fill-sr-muted text-[10px] font-mono">
          {format_netflow_bytes(@max_bytes)}
        </text>
        <text x="4" y="82" class="fill-sr-muted text-[10px] font-mono">
          {format_netflow_bytes(trunc(@max_bytes / 2))}
        </text>
        <text x="4" y="150" class="fill-sr-muted text-[10px] font-mono">0 B</text>
        <text
          x="0"
          y="158"
          class="fill-sr-muted text-[10px] font-mono"
          data-netflow-time="axis"
          data-time-iso={@axis_start}
          data-time-fallback={@axis_start}
        >
          {@axis_start}
        </text>
        <text
          x="500"
          y="158"
          text-anchor="middle"
          class="fill-sr-muted text-[10px] font-mono"
          data-netflow-time="axis"
          data-time-iso={@axis_middle}
          data-time-fallback={@axis_middle}
        >
          {@axis_middle}
        </text>
        <text
          x="1000"
          y="158"
          text-anchor="end"
          class="fill-sr-muted text-[10px] font-mono"
          data-netflow-time="axis"
          data-time-iso={@axis_end}
          data-time-fallback={@axis_end}
        >
          {@axis_end}
        </text>

        <%= if @mode != "lines" do %>
          <%= for %{point: point, x: center_x, start: start_time, end: end_time} <- @range_points do %>
            {w = netflow_chart_bar_w(length(@points), 1000)}
            {x = center_x - w / 2}
            {h = netflow_chart_h(Map.get(point, :bytes, 0), @max_bytes, 140)}
            <% title = netflow_bucket_hover_title(point, @bucket_seconds, end_time) %>
            <rect
              x={x}
              y={150 - h}
              width={w}
              height={h}
              class="fill-sr-brand/20 hover:fill-sr-brand/35 transition-colors cursor-pointer"
              phx-click="netflow_bucket"
              phx-value-start={start_time}
              phx-value-end={end_time}
            >
              <title
                data-netflow-time="range-title"
                data-time-start={start_time}
                data-time-end={end_time}
                data-time-fallback={title}
              >
                {title}
              </title>
            </rect>
          <% end %>
        <% end %>

        <polyline
          points={netflow_timeseries_polyline(@points, @max_bytes, 1000, 140, @mode)}
          fill="none"
          class="stroke-sr-brand opacity-80"
          stroke-width="2"
        />

        <polyline
          :if={@compare_points != [] and @compare_mode in ["previous", "yesterday"]}
          points={netflow_timeseries_polyline(@compare_points, @max_bytes, 1000, 140, @mode)}
          fill="none"
          class="stroke-sr-muted/50"
          stroke-dasharray="4 4"
          stroke-width="2"
        />

        <%= for %{point: point, x: cx, start: start_time, end: end_time} <- @range_points do %>
          {cy = 150 - netflow_chart_h(Map.get(point, :bytes, 0), @max_bytes, 140)}
          <% title = netflow_bucket_hover_title(point, @bucket_seconds, end_time) %>
          <circle
            cx={cx}
            cy={cy}
            r="2.6"
            class="fill-sr-brand/80 stroke-sr-surface cursor-pointer"
            stroke-width="1"
            phx-click="netflow_bucket"
            phx-value-start={start_time}
            phx-value-end={end_time}
          >
            <title
              data-netflow-time="range-title"
              data-time-start={start_time}
              data-time-end={end_time}
              data-time-fallback={title}
            >
              {title}
            </title>
          </circle>
        <% end %>
      </svg>

      <p data-range-status aria-live="polite" class="sr-only"></p>

      <div class="mt-2 flex items-center justify-between text-[10px] text-sr-muted font-mono">
        <div>
          <.user_time
            id="netflow-chart-window-start"
            value={@axis_start}
            timezone={@timezone}
            style={:compact}
            fallback={@axis_start}
          />
        </div>
        <div :if={@compare_points != [] and @compare_mode in ["previous", "yesterday"]}>
          compare: {@compare_mode}
        </div>
        <div>
          max: {format_netflow_bytes(@max_bytes)}
        </div>
        <div>
          <.user_time
            id="netflow-chart-window-end"
            value={@axis_end}
            timezone={@timezone}
            style={:compact}
            fallback={@axis_end}
          />
        </div>
      </div>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:points, :list, default: [])
  attr(:keys, :list, default: [])
  attr(:mode, :string, default: @default_netflow_stack_mode)
  attr(:series_field, :string, default: nil)
  attr(:colors, :map, default: %{})
  attr(:range_intervals, :list, default: [])
  attr(:range_event, :string, default: nil)
  attr(:range_accessible_name, :string, default: "Select a NetFlow Traffic Over Time range")
  attr(:range_bucket_name, :string, default: "traffic")
  attr(:timezone, :string, required: true)

  def netflow_timeseries_stacked_area_chart(assigns) do
    points = Enum.filter(assigns.points, &is_map/1)

    assigns =
      assigns
      |> assign(:points, points)
      |> assign(:keys, Enum.filter(assigns.keys || [], &is_binary/1))

    ~H"""
    <div :if={@points == [] or @keys == []} class="py-6 text-center text-sm text-sr-muted">
      No {@mode} samples in this window.
    </div>

    <div :if={@points != [] and @keys != []} class="w-full">
      <div
        id={@id}
        class={["w-full h-56", @range_event && "touch-pan-y"]}
        phx-hook="NetflowStackedAreaChart"
        phx-update="ignore"
        data-timezone={@timezone}
        data-keys={Jason.encode!(@keys)}
        data-points={Jason.encode!(@points)}
        data-series-field={@series_field || ""}
        data-colors={Jason.encode!(@colors || %{})}
        data-range-intervals={@range_event && Jason.encode!(@range_intervals)}
        data-range-event={@range_event}
        role={@range_event && "group"}
        tabindex={@range_event && "0"}
        aria-label={@range_event && @range_accessible_name}
        aria-describedby={@range_event && "#{@id}-range-instructions"}
      >
        <svg class="w-full h-full" role="img" aria-label={"NetFlow #{@mode} over time"}></svg>
        <p :if={@range_event} id={"#{@id}-range-instructions"} class="sr-only">
          Use Left and Right Arrow to move through {@range_bucket_name} buckets. Hold Shift to
          extend a range, press Enter to apply it, or Escape to clear it.
        </p>
        <p :if={@range_event} data-range-status aria-live="polite" class="sr-only"></p>
      </div>
    </div>
    """
  end

  attr(:timeseries, :map, required: true)
  attr(:protocol_activity, :map, required: true)
  attr(:app_activity, :map, required: true)
  attr(:graph_mode, :string, required: true)
  attr(:timezone, :string, required: true)

  def netflow_activity_cards(assigns) do
    ~H"""
    <div class="grid grid-cols-1 gap-3 lg:grid-cols-2">
      <.ui_panel class="p-0" body_class="p-0">
        <div class="p-3 border-b border-sr-line bg-sr-subtle/30 flex items-center justify-between">
          <div class="text-xs uppercase tracking-wider text-sr-muted">
            Activity By Protocol
          </div>
          <div class="text-xs text-sr-muted font-mono">
            bucket: {format_bucket(
              Map.get(@protocol_activity, :bucket_seconds, @timeseries.bucket_seconds)
            )}
          </div>
        </div>
        <div class="p-3">
          <.netflow_timeseries_stacked_area_chart
            id="netflow-protocol-stacked"
            timezone={@timezone}
            points={Map.get(@protocol_activity, :points, [])}
            keys={Map.get(@protocol_activity, :keys, [])}
            colors={Map.get(@protocol_activity, :colors, %{})}
            series_field="protocol_group"
            mode="protocols"
            range_intervals={
              if(@graph_mode != "sankey",
                do: RangeSelection.canonical_intervals(@timeseries.points),
                else: []
              )
            }
            range_event={@graph_mode != "sankey" && "netflow_range_selected"}
            range_accessible_name="Select an Activity by Protocol time range"
            range_bucket_name="protocol activity"
          />
        </div>
      </.ui_panel>

      <.ui_panel class="p-0" body_class="p-0">
        <div class="p-3 border-b border-sr-line bg-sr-subtle/30 flex items-center justify-between">
          <div class="text-xs uppercase tracking-wider text-sr-muted">
            Activity By Application
          </div>
          <div class="text-xs text-sr-muted font-mono">
            top: {length(Map.get(@app_activity, :keys, []))}
          </div>
        </div>
        <div class="p-3">
          <.netflow_timeseries_stacked_area_chart
            id="netflow-app-stacked"
            timezone={@timezone}
            points={Map.get(@app_activity, :points, [])}
            keys={Map.get(@app_activity, :keys, [])}
            colors={Map.get(@app_activity, :colors, %{})}
            series_field="app"
            mode="apps"
            range_intervals={
              if(@graph_mode != "sankey",
                do: RangeSelection.canonical_intervals(@timeseries.points),
                else: []
              )
            }
            range_event={@graph_mode != "sankey" && "netflow_range_selected"}
            range_accessible_name="Select an Activity by Application time range"
            range_bucket_name="application activity"
          />
        </div>
      </.ui_panel>
    </div>
    """
  end

  defp netflow_stacked_percent_points(points, keys) when is_list(points) and is_list(keys) do
    Enum.map(points, fn
      %{"t" => _} = point -> normalize_point_to_percent(point, keys)
      other -> other
    end)
  end

  defp netflow_stacked_percent_points(points, _keys), do: points

  defp normalize_point_to_percent(point, keys) do
    total =
      keys
      |> Enum.map(fn key -> to_number(Map.get(point, key, 0)) end)
      |> Enum.sum()

    if total <= 0 do
      point
    else
      Enum.reduce(keys, point, fn key, acc ->
        pct = to_number(Map.get(point, key, 0)) * 100.0 / total
        Map.put(acc, key, Float.round(pct, 4))
      end)
    end
  end

  defp netflow_bucket_hover_title(point, bucket_seconds, canonical_end) when is_map(point) do
    bytes = to_int(Map.get(point, :bytes, 0))
    start_dt = Map.get(point, :bucket_start)
    bucket = if is_integer(bucket_seconds) and bucket_seconds > 0, do: bucket_seconds, else: 1
    avg_bps = bytes * 8.0 / bucket

    start_label =
      case start_dt do
        %DateTime{} = dt -> DateTime.to_iso8601(dt)
        _ -> "unknown"
      end

    end_label = if is_binary(canonical_end), do: canonical_end, else: "unknown"

    "window: #{start_label} → #{end_label}\nbytes: #{format_netflow_bytes(bytes)}\navg rate: #{format_netflow_bps(avg_bps)}"
  end

  defp netflow_timeseries_tooltip_points_json(points, bucket_seconds)
       when is_list(points) and is_integer(bucket_seconds) do
    points
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn %{point: point, start: start_time, end: end_time} ->
      %{
        "start" => start_time,
        "end" => end_time,
        "bytes" => to_int(Map.get(point, :bytes, 0)),
        "bucket_seconds" => bucket_seconds
      }
    end)
    |> Jason.encode!()
  rescue
    _ -> "[]"
  end

  defp netflow_timeseries_tooltip_points_json(_points, _bucket_seconds), do: "[]"

  attr(:label, :string, required: true)
  attr(:count, :integer, required: true)
  attr(:tone, :string, required: true)

  defp status_stat(assigns) do
    assigns = assign(assigns, :tone, tone_class(assigns.tone))

    ~H"""
    <div class="rounded-lg border border-sr-line bg-sr-subtle/40 p-3">
      <div class="text-xs text-sr-muted">{@label}</div>
      <div class={["text-xl font-bold", @tone]}>{@count}</div>
    </div>
    """
  end

  defp tone_class("warning"), do: "text-amber-400"
  defp tone_class("info"), do: "text-sky-400"
  defp tone_class("success"), do: "text-emerald-400"
  defp tone_class("error"), do: "text-rose-400"
  defp tone_class(_), do: "text-sr-ink"

  attr(:srql, :map, required: true)
  attr(:limit, :integer, required: true)

  defp log_source_filters(assigns) do
    query = Map.get(assigns.srql, :query) || ""

    active_source =
      query |> extract_filter_from_query("source") |> normalize_string() |> normalize_source()

    sources = [
      %{label: "All", value: nil},
      %{label: "Syslog", value: "syslog"},
      %{label: "OTel", value: "otel"},
      %{label: "SNMP", value: "snmp"},
      %{label: "Internal", value: "internal"}
    ]

    assigns =
      assigns
      |> assign(:query, query)
      |> assign(:active_source, active_source)
      |> assign(:sources, sources)

    ~H"""
    <div class="flex items-center gap-2">
      <div class="hidden sm:flex items-center gap-2">
        <span class="text-[10px] uppercase tracking-wider text-sr-muted">Source</span>
        <div class="flex flex-wrap gap-1">
          <%= for source <- @sources do %>
            <.log_source_chip
              label={source.label}
              value={source.value}
              active_source={@active_source}
              query={@query}
              limit={@limit}
            />
          <% end %>
        </div>
      </div>

      <div>
        <.ui_dropdown align="end">
          <:trigger>
            <.ui_button variant="ghost" size="xs" class="rounded-full">
              <.icon name="hero-funnel" class="size-4" />
              <span class="text-xs">Source</span>
            </.ui_button>
          </:trigger>
          <:item :for={source <- @sources}>
            <.link
              patch={log_source_patch(@query, source.value, @limit)}
              class={[
                "text-xs",
                source_active?(@active_source, source.value) && "font-semibold text-sr-brand"
              ]}
            >
              {source.label}
            </.link>
          </:item>
        </.ui_dropdown>
      </div>
    </div>
    """
  end

  attr(:srql, :map, required: true)
  attr(:limit, :integer, required: true)
  attr(:live?, :boolean, default: false)

  defp log_panel_controls(assigns) do
    assigns =
      assigns
      |> assign(:toggle_title, if(assigns.live?, do: "Pause live log streaming", else: "Start live log streaming"))
      |> assign(:toggle_badge_variant, if(assigns.live?, do: "success", else: "ghost"))
      |> assign(:toggle_variant, if(assigns.live?, do: "primary", else: "outline"))

    ~H"""
    <div class="flex flex-wrap items-center justify-end gap-2">
      <.ui_button
        id="logs-live-toggle"
        phx-click="toggle_logs_live"
        variant={@toggle_variant}
        size="xs"
        active={@live?}
        class="rounded-full gap-2"
        title={@toggle_title}
      >
        <span class="text-xs font-medium">Live</span>
        <.ui_badge id="logs-live-status" size="xs" variant={@toggle_badge_variant}>
          {if @live?, do: "On", else: "Off"}
        </.ui_badge>
      </.ui_button>

      <.log_source_filters srql={@srql} limit={@limit} />
    </div>
    """
  end

  # Shared Live on/off toggle matching the logs live-feed pattern. Each
  # observability tab passes its own DOM id and toggle event; the flag assign
  # carries that tab's live state.
  attr(:id, :string, required: true)
  attr(:toggle_event, :string, required: true)
  attr(:live?, :boolean, default: false)
  attr(:start_title, :string, required: true)
  attr(:pause_title, :string, required: true)

  defp live_toggle_button(assigns) do
    assigns =
      assigns
      |> assign(:toggle_title, if(assigns.live?, do: assigns.pause_title, else: assigns.start_title))
      |> assign(:toggle_badge_variant, if(assigns.live?, do: "success", else: "ghost"))
      |> assign(:toggle_variant, if(assigns.live?, do: "primary", else: "outline"))
      # The badge id drops the button's "-toggle" suffix so `id="logs-live-toggle"`
      # renders badge `id="logs-live-status"`, matching the established convention.
      |> assign(:toggle_badge_id, String.replace_suffix(assigns.id, "-toggle", "-status"))

    ~H"""
    <.ui_button
      id={@id}
      phx-click={@toggle_event}
      variant={@toggle_variant}
      size="xs"
      active={@live?}
      class="rounded-full gap-2"
      title={@toggle_title}
    >
      <span class="text-xs font-medium">Live</span>
      <.ui_badge id={@toggle_badge_id} size="xs" variant={@toggle_badge_variant}>
        {if @live?, do: "On", else: "Off"}
      </.ui_badge>
    </.ui_button>
    """
  end

  # The events and alerts panes have no other header filters, so their panel
  # controls are just the live toggle, right-aligned like the logs pane.
  attr(:live?, :boolean, default: false)

  defp events_panel_controls(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-end gap-2">
      <.live_toggle_button
        id="events-live-toggle"
        toggle_event="toggle_events_live"
        live?={@live?}
        start_title="Start live event streaming"
        pause_title="Pause live event streaming"
      />
    </div>
    """
  end

  attr(:live?, :boolean, default: false)

  defp alerts_panel_controls(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-end gap-2">
      <.live_toggle_button
        id="alerts-live-toggle"
        toggle_event="toggle_alerts_live"
        live?={@live?}
        start_title="Start live alert streaming"
        pause_title="Pause live alert streaming"
      />
    </div>
    """
  end

  attr(:srql, :map, required: true)
  attr(:limit, :integer, required: true)
  attr(:compact?, :boolean, default: false)
  attr(:talker_cidr, :integer, default: nil)
  attr(:compare_mode, :string, default: "off")
  attr(:geo_side, :string, default: "dst")
  attr(:sankey_prefix, :integer, default: 24)
  attr(:stack_mode, :string, default: @default_netflow_stack_mode)
  attr(:graph_mode, :string, default: "stacked")
  attr(:view, :string, default: "overview")
  attr(:live?, :boolean, default: false)

  defp netflow_presets(assigns) do
    query = Map.get(assigns.srql, :query) || ""

    presets = [
      %{label: "Recent", query: "in:flows time:#{@default_netflow_window} sort:time:desc"},
      %{
        label: "Top Bytes",
        query: "in:flows time:#{@default_netflow_window} sort:bytes_total:desc"
      },
      %{
        label: "Top Packets",
        query: "in:flows time:#{@default_netflow_window} sort:packets_total:desc"
      },
      %{
        label: "TCP",
        query: "in:flows time:#{@default_netflow_window} proto:6 sort:bytes_total:desc"
      },
      %{
        label: "UDP",
        query: "in:flows time:#{@default_netflow_window} proto:17 sort:bytes_total:desc"
      }
    ]

    assigns =
      assigns
      |> assign(:query, query)
      |> assign(:presets, presets)
      |> assign(:base_path, Map.get(assigns.srql, :page_path) || "/observability")
      |> assign(:compact?, assigns.compact?)
      |> assign(:talker_cidr, assigns.talker_cidr)
      |> assign(:compare_mode, assigns.compare_mode)
      |> assign(:geo_side, assigns.geo_side)
      |> assign(:sankey_prefix, assigns.sankey_prefix)
      |> assign(:stack_mode, assigns.stack_mode)
      |> assign(:graph_mode, assigns.graph_mode)
      |> assign(:view, assigns.view)
      |> assign(:toggle_title, if(assigns.live?, do: "Pause live flow refresh", else: "Start live flow refresh"))
      |> assign(:toggle_badge_variant, if(assigns.live?, do: "success", else: "ghost"))
      |> assign(:toggle_variant, if(assigns.live?, do: "primary", else: "outline"))

    current_tag =
      PrefixTagQuery.tag_from_query(query) || ""

    assigns = assign(assigns, :current_tag, current_tag)

    ~H"""
    <div class="flex flex-col items-end gap-2">
      <div class="flex items-center justify-end gap-2">
        <% patch_opts =
          netflow_patch_opts(
            @compact?,
            @talker_cidr,
            @compare_mode,
            @geo_side,
            @sankey_prefix,
            @stack_mode,
            @graph_mode,
            @view
          ) %>
        <.ui_button
          id="netflows-live-toggle"
          phx-click="toggle_netflows_live"
          variant={@toggle_variant}
          size="xs"
          active={@live?}
          class="rounded-full gap-2"
          title={@toggle_title}
        >
          <span class="text-xs font-medium">Live</span>
          <.ui_badge id="netflows-live-status" size="xs" variant={@toggle_badge_variant}>
            {if @live?, do: "On", else: "Off"}
          </.ui_badge>
        </.ui_button>
        <span class="text-[10px] uppercase tracking-wider text-sr-muted">Presets</span>
        <div class="flex flex-wrap gap-1">
          <%= for preset <- @presets do %>
            <.ui_button
              size="xs"
              variant="ghost"
              active={preset_active?(@query, preset.query)}
              class="rounded-full"
              patch={netflow_talker_cidr_patch(@base_path, preset.query, @limit, patch_opts)}
            >
              {preset.label}
            </.ui_button>
          <% end %>

          <.ui_button
            size="xs"
            variant="ghost"
            active={@compact?}
            class="rounded-full"
            patch={
              netflow_talker_cidr_patch(
                @base_path,
                @query,
                @limit,
                Map.put(patch_opts, :compact?, not @compact?)
              )
            }
          >
            Compact
          </.ui_button>
        </div>
      </div>

      <form phx-submit="netflow_prefix_tag_filter" class="flex items-center gap-2">
        <label class="text-[10px] uppercase tracking-wider text-sr-muted whitespace-nowrap">
          Prefix tag
        </label>
        <input
          type="text"
          name="tag"
          value={@current_tag}
          placeholder="site:austin"
          class={ui_field_class(size: "xs", mono: true, class: "w-40")}
          autocomplete="off"
        />
        <.ui_button type="submit" size="xs" variant="ghost">Filter</.ui_button>
      </form>
    </div>
    """
  end

  defp preset_active?(current, target) when is_binary(current) and is_binary(target) do
    String.trim(current) == target
  end

  defp preset_active?(_, _), do: false

  defp next_logs_live_state(socket, tab, params) do
    cond do
      tab != "logs" ->
        false

      manual_log_navigation?(socket, tab, params) ->
        false

      true ->
        Map.get(socket.assigns, :logs_live?, false)
    end
  end

  defp next_netflows_live_state(socket, tab, params) do
    cond do
      tab != "netflows" ->
        false

      # Legacy bookmarked page URLs or session-paged result sets disable live tailing.
      has_cursor_param?(params) or paged_away_from_head?(socket) ->
        false

      socket.assigns[:_initial_load_done] && socket.assigns.active_tab == "netflows" ->
        Map.get(socket.assigns, :netflows_live?, false)

      true ->
        false
    end
  end

  # Generic live-tail state for the events/traces/metrics/alerts tabs, mirroring
  # the logs/netflows rules: live survives only on the head of the same result
  # set — same tab, same tracked query params, no cursor or paged position.
  defp next_tab_live_state(socket, tab, params, expected_tab, flag) do
    cond do
      tab != expected_tab ->
        false

      has_cursor_param?(params) or paged_away_from_head?(socket) ->
        false

      manual_tab_navigation?(socket, tab, params) ->
        false

      true ->
        Map.get(socket.assigns, flag, false)
    end
  end

  defp manual_tab_navigation?(socket, tab, params) do
    socket.assigns[:_initial_load_done] &&
      socket.assigns.active_tab == tab &&
      tracked_tab_view_params(params) != tracked_tab_view_params(Map.get(socket.assigns, :current_params, %{}))
  end

  defp tracked_tab_view_params(params) when is_map(params) do
    Map.take(params, ["q", "limit", "cursor", "page", "tab"])
  end

  defp tracked_tab_view_params(_), do: %{}

  defp has_cursor_param?(params) when is_map(params) do
    value = Map.get(params, "cursor")
    is_binary(value) and String.trim(value) != ""
  end

  defp has_cursor_param?(_), do: false

  defp paged_away_from_head?(socket) do
    Map.get(socket.assigns, :pagination_page, 1) > 1
  end

  defp manual_log_navigation?(socket, tab, params) do
    socket.assigns[:_initial_load_done] &&
      socket.assigns.active_tab == "logs" &&
      tab == "logs" &&
      tracked_log_view_params(params) != Map.get(socket.assigns, :log_view_params, %{})
  end

  defp tracked_log_view_params(params) when is_map(params) do
    Map.take(params, ["q", "limit", "cursor", "page", "tab"])
  end

  defp tracked_log_view_params(_), do: %{}

  attr(:label, :string, required: true)
  attr(:value, :string, default: nil)
  attr(:active_source, :string, default: nil)
  attr(:query, :string, required: true)
  attr(:limit, :integer, required: true)

  defp log_source_chip(assigns) do
    active? = source_active?(assigns.active_source, assigns.value)
    href = log_source_patch(assigns.query, assigns.value, assigns.limit)

    assigns =
      assigns
      |> assign(:active?, active?)
      |> assign(:href, href)

    ~H"""
    <.ui_button
      patch={@href}
      size="xs"
      variant="ghost"
      active={@active?}
      class="rounded-full"
    >
      {@label}
    </.ui_button>
    """
  end

  defp normalize_source(nil), do: nil
  defp normalize_source(""), do: nil

  defp normalize_source(value) when is_binary(value), do: value |> String.trim() |> String.downcase()

  defp normalize_source(_), do: nil

  defp source_active?(current, value) do
    current = normalize_source(current)
    value = normalize_source(value)

    if is_nil(value) do
      is_nil(current)
    else
      current == value
    end
  end

  defp log_source_patch(query, source, _limit) do
    new_query = log_source_query(query, source)
    ObservabilityPaths.path("logs", maybe_put_param(%{}, :q, new_query))
  end

  defp log_source_query(query, source) do
    cleaned = strip_filter(query, "source")

    cond do
      is_nil(source) or source == "" -> cleaned
      cleaned == "" -> "in:logs source:#{source} time:last_24h sort:timestamp:desc"
      true -> cleaned <> " source:#{source}"
    end
  end

  defp strip_filter(nil, _field), do: ""
  defp strip_filter("", _field), do: ""

  defp strip_filter(query, field) when is_binary(query) and is_binary(field) do
    pattern = ~r/(?:^|\s)#{Regex.escape(field)}:(?:"[^"]+"|\S+)/

    query
    |> then(&Regex.replace(pattern, &1, ""))
    |> then(&Regex.replace(~r/\s+/, &1, " "))
    |> String.trim()
  end

  defp maybe_put_param(params, _key, nil), do: params
  defp maybe_put_param(params, _key, ""), do: params
  defp maybe_put_param(params, key, value), do: Map.put(params, key, value)

  defp append_query_param(path, key, value) do
    joiner = if String.contains?(path, "?"), do: "&", else: "?"
    path <> joiner <> URI.encode_query(%{key => value})
  end

  defp maybe_put_new_param(params, _key, nil), do: params
  defp maybe_put_new_param(params, _key, ""), do: params

  defp maybe_put_new_param(params, key, value) do
    if Map.get(params, key) in [nil, ""] do
      Map.put(params, key, value)
    else
      params
    end
  end

  defp color_class("error"), do: "text-rose-400"
  defp color_class("warning"), do: "text-amber-400"
  defp color_class("info"), do: "text-sky-400"
  defp color_class("primary"), do: "text-sr-brand"
  defp color_class("success"), do: "text-emerald-400"
  defp color_class(_), do: "text-sr-ink"

  defp color_bg("error"), do: "bg-rose-500"
  defp color_bg("warning"), do: "bg-amber-400"
  defp color_bg("info"), do: "bg-sky-400"
  defp color_bg("primary"), do: "bg-sr-brand"
  defp color_bg("success"), do: "bg-emerald-400"
  defp color_bg(_), do: "bg-sr-ink"

  attr(:stats, :map, required: true)
  attr(:latency, :map, required: true)

  defp traces_summary(assigns) do
    total = Map.get(assigns.stats, :total, 0)
    error_traces = Map.get(assigns.stats, :error_traces, 0)
    slow_traces = Map.get(assigns.stats, :slow_traces, 0)
    error_rate = if total > 0, do: Float.round(error_traces / total * 100.0, 1), else: 0.0
    successful = max(total - error_traces, 0)

    avg_duration_ms = Map.get(assigns.latency, :avg_duration_ms, 0.0)
    p95_duration_ms = Map.get(assigns.latency, :p95_duration_ms, 0.0)
    services_count = Map.get(assigns.latency, :service_count, 0)
    sample_size = Map.get(assigns.latency, :sample_size, 0)

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:successful, successful)
      |> assign(:error_traces, error_traces)
      |> assign(:slow_traces, slow_traces)
      |> assign(:error_rate, error_rate)
      |> assign(:avg_duration_ms, avg_duration_ms)
      |> assign(:p95_duration_ms, p95_duration_ms)
      |> assign(:services_count, services_count)
      |> assign(:sample_size, sample_size)

    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-6 gap-3">
      <.obs_stat
        title="Total Traces"
        value={format_compact_int(@total)}
        icon="hero-clock"
        href={traces_card_href("in:otel_trace_summaries sort:timestamp:desc")}
      />
      <.obs_stat
        title="Successful"
        value={format_compact_int(@successful)}
        icon="hero-check-circle"
        tone="success"
        href={traces_card_href("in:otel_trace_summaries error_count:0 sort:timestamp:desc")}
      />
      <.obs_stat
        title="Errors"
        value={format_compact_int(@error_traces)}
        icon="hero-x-circle"
        tone={if @error_traces > 0, do: "error", else: "success"}
        href={traces_card_href("in:otel_trace_summaries error_count:>0 sort:timestamp:desc")}
      />
      <.obs_stat
        title="Error Rate"
        value={"#{format_pct(@error_rate)}%"}
        icon="hero-trending-up"
        tone={if @error_rate > 1.0, do: "error", else: "success"}
        href={traces_card_href("in:otel_trace_summaries error_count:>0 sort:timestamp:desc")}
      />
      <.obs_stat
        title="Avg Duration"
        value={format_duration_ms(@avg_duration_ms)}
        subtitle={if @sample_size > 0, do: "sample (#{@sample_size})", else: "sample"}
        icon="hero-chart-bar"
        tone="info"
      />
      <.obs_stat
        title="P95 Duration"
        value={format_duration_ms(@p95_duration_ms)}
        subtitle={if @services_count > 0, do: "#{@services_count} services", else: "sample"}
        icon="hero-bolt"
        tone="warning"
      />
    </div>
    """
  end

  attr(:stats, :map, required: true)

  defp metrics_summary(assigns) do
    total = Map.get(assigns.stats, :total, 0)
    slow_spans = Map.get(assigns.stats, :slow_spans, 0)
    error_spans = Map.get(assigns.stats, :error_spans, 0)
    error_rate = Map.get(assigns.stats, :error_rate, 0.0)
    avg_duration_ms = Map.get(assigns.stats, :avg_duration_ms, 0.0)
    p95_duration_ms = Map.get(assigns.stats, :p95_duration_ms, 0.0)
    sample_size = Map.get(assigns.stats, :sample_size, 0)

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:slow_spans, slow_spans)
      |> assign(:error_spans, error_spans)
      |> assign(:error_rate, error_rate)
      |> assign(:avg_duration_ms, avg_duration_ms)
      |> assign(:p95_duration_ms, p95_duration_ms)
      |> assign(:sample_size, sample_size)

    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-6 gap-3">
      <.obs_stat
        title="Total Metrics"
        value={format_compact_int(@total)}
        icon="hero-chart-bar"
        href={metrics_card_href("in:otel_metrics sort:timestamp:desc")}
      />
      <.obs_stat
        title="Slow Spans"
        value={format_compact_int(@slow_spans)}
        icon="hero-bolt"
        tone={if @slow_spans > 0, do: "warning", else: "success"}
        href={metrics_card_href("in:otel_metrics is_slow:true sort:timestamp:desc")}
      />
      <.obs_stat
        title="Errors"
        value={format_compact_int(@error_spans)}
        icon="hero-exclamation-triangle"
        tone={if @error_spans > 0, do: "error", else: "success"}
        href={traces_card_href("in:otel_trace_summaries error_count:>0 sort:timestamp:desc")}
      />
      <.obs_stat
        title="Error Rate"
        value={"#{format_pct(@error_rate)}%"}
        icon="hero-trending-up"
        tone={if @error_rate > 1.0, do: "error", else: "success"}
        href={traces_card_href("in:otel_trace_summaries error_count:>0 sort:timestamp:desc")}
      />
      <.obs_stat
        title="Avg Duration"
        value={format_duration_ms(@avg_duration_ms)}
        subtitle={if @sample_size > 0, do: "sample (#{@sample_size})", else: "sample"}
        icon="hero-clock"
        tone="info"
      />
      <.obs_stat
        title="P95 Duration"
        value={format_duration_ms(@p95_duration_ms)}
        subtitle="sample"
        icon="hero-chart-bar"
        tone="neutral"
      />
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:value, :string, required: true)
  attr(:subtitle, :string, default: nil)
  attr(:icon, :string, required: true)
  attr(:tone, :string, default: "neutral", values: ~w(neutral success warning error info))
  attr(:href, :string, default: nil)

  defp obs_stat(assigns) do
    {bg, fg} =
      case assigns.tone do
        "success" -> {"bg-emerald-400/10", "text-emerald-400"}
        "warning" -> {"bg-amber-400/10", "text-amber-400"}
        "error" -> {"bg-rose-500/10", "text-rose-400"}
        "info" -> {"bg-sky-400/10", "text-sky-400"}
        _ -> {"bg-sr-subtle/50", "text-sr-muted"}
      end

    assigns = assigns |> assign(:bg, bg) |> assign(:fg, fg)

    ~H"""
    <.link
      :if={is_binary(@href)}
      patch={@href}
      class="block rounded-xl border border-sr-line bg-sr-surface p-3 hover:bg-sr-subtle/40 transition-colors cursor-pointer"
    >
      <.obs_stat_body
        title={@title}
        value={@value}
        subtitle={@subtitle}
        icon={@icon}
        bg={@bg}
        fg={@fg}
      />
    </.link>
    <div :if={not is_binary(@href)} class="rounded-xl border border-sr-line bg-sr-surface p-3">
      <.obs_stat_body
        title={@title}
        value={@value}
        subtitle={@subtitle}
        icon={@icon}
        bg={@bg}
        fg={@fg}
      />
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:value, :string, required: true)
  attr(:subtitle, :string, default: nil)
  attr(:icon, :string, required: true)
  attr(:bg, :string, required: true)
  attr(:fg, :string, required: true)

  defp obs_stat_body(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <div class={["size-8 rounded-lg flex items-center justify-center shrink-0", @bg]}>
        <.icon name={@icon} class={["size-4", @fg]} />
      </div>
      <div class="min-w-0">
        <div class="text-xs text-sr-muted truncate">{@title}</div>
        <div class="text-lg font-bold tabular-nums truncate">{@value}</div>
        <div :if={is_binary(@subtitle)} class="text-[10px] text-sr-muted truncate">
          {@subtitle}
        </div>
      </div>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:logs, :any, required: true)
  attr(:count, :integer, required: true)
  attr(:timezone, :string, required: true)

  defp logs_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table id={@id} class={ui_table_class(size: "sm", zebra: true, class: "w-full")}>
        <thead>
          <tr>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-40">
              Time
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-20">
              Level
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-32">
              Service
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Message
            </th>
          </tr>
        </thead>
        <tbody id={"#{@id}-rows"} phx-update="stream">
          <tr :if={@count == 0}>
            <td colspan="4" class="text-sm text-sr-muted py-8 text-center">
              No log entries found.
            </td>
          </tr>

          <%= for {dom_id, log} <- @logs do %>
            <tr
              id={dom_id}
              class="hover:bg-sr-subtle/40 cursor-pointer transition-colors"
              phx-click={JS.navigate(~p"/logs/#{log_id(log)}")}
            >
              <td class="whitespace-nowrap text-xs font-mono">
                <% time = timestamp_meta(log) %>
                <.user_time
                  id={"log-time-#{dom_id}"}
                  value={time.value}
                  timezone={@timezone}
                  style={:full}
                  fallback={time.fallback}
                />
              </td>
              <td class="whitespace-nowrap text-xs">
                <.severity_badge value={Map.get(log, "severity_text")} />
              </td>
              <td class="whitespace-nowrap text-xs truncate max-w-[10rem]" title={log_service(log)}>
                {log_service(log)}
              </td>
              <td class="text-xs truncate max-w-[36rem]" title={log_message(log)}>
                {log_message(log)}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:traces, :list, default: [])
  attr(:query, :string, default: "")
  attr(:limit, :integer, default: @default_limit)
  attr(:timezone, :string, required: true)

  defp traces_table(assigns) do
    {sort_field, sort_dir} = trace_sort_state(assigns.query)

    assigns =
      assigns
      |> assign(:sort_field, sort_field)
      |> assign(:sort_dir, sort_dir)

    ~H"""
    <div class="sr-ui-table-shell">
      <table id={@id} class={ui_table_class(size: "sm", zebra: true, class: "w-full")}>
        <thead>
          <tr>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-40">
              Time
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-40">
              Service
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Operation
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-24 text-right">
              <.link
                id={"#{@id}-sort-duration"}
                patch={traces_sort_href(@query, "duration_ms", @limit)}
                class="inline-flex items-center gap-1 hover:text-sr-brand"
                title="Sort by duration"
              >
                Duration
                <.icon
                  :if={@sort_field == "duration_ms"}
                  name={if @sort_dir == "asc", do: "hero-chevron-up", else: "hero-chevron-down"}
                  class="size-3"
                />
              </.link>
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-20 text-right">
              <.link
                id={"#{@id}-sort-spans"}
                patch={traces_sort_href(@query, "span_count", @limit)}
                class="inline-flex items-center gap-1 hover:text-sr-brand"
                title="Sort by span count"
              >
                Spans
                <.icon
                  :if={@sort_field == "span_count"}
                  name={if @sort_dir == "asc", do: "hero-chevron-up", else: "hero-chevron-down"}
                  class="size-3"
                />
              </.link>
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-24 text-right">
              Errors
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@traces == []}>
            <td colspan="6" class="text-sm text-sr-muted py-8 text-center">
              No traces found.
            </td>
          </tr>

          <%= for {trace, idx} <- Enum.with_index(@traces) do %>
            <% trace_path = trace_detail_path(trace) %>
            <tr
              id={"#{@id}-row-#{idx}"}
              class={["hover:bg-sr-subtle/40 transition-colors", trace_path && "cursor-pointer"]}
              phx-click={trace_path && JS.navigate(trace_path)}
            >
              <td class="whitespace-nowrap text-xs font-mono">
                <% time = timestamp_meta(Map.get(trace, "timestamp")) %>
                <.user_time
                  id={
                    "trace-time-#{@id}-row-#{signal_time_key(trace, ["trace_id", "span_id"], idx)}"
                  }
                  value={time.value}
                  timezone={@timezone}
                  style={:full}
                  fallback={time.fallback}
                />
              </td>
              <td
                class="whitespace-nowrap text-xs truncate max-w-[14rem]"
                title={trace_service_name(trace)}
              >
                {trace_service_name(trace) || "—"}
              </td>
              <td class="text-xs truncate max-w-[28rem]" title={trace_operation_name(trace)}>
                {trace_operation_name(trace) || "—"}
              </td>
              <td class="whitespace-nowrap text-right">
                <% dur_ms = trace_duration_ms(trace) %>
                <span
                  class={[
                    "inline-flex min-w-[3.25rem] items-center justify-end rounded-md px-1.5 py-0.5 font-mono text-xs tabular-nums",
                    duration_ms_class(dur_ms)
                  ]}
                  title={duration_ms_title(dur_ms)}
                >
                  {format_duration_ms(dur_ms)}
                </span>
              </td>
              <td
                id={"#{@id}-row-#{idx}-spans"}
                class="whitespace-nowrap text-xs font-mono text-right"
              >
                {Map.get(trace, "span_count", 0) |> to_int()}
              </td>
              <td class="whitespace-nowrap text-xs font-mono text-right">
                <span class={error_count_class(trace_error_count(trace))}>
                  {trace_error_count(trace)}
                </span>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr(:srql, :map, required: true)
  attr(:limit, :integer, required: true)

  attr(:live?, :boolean, default: false)

  defp traces_panel_controls(assigns) do
    query = Map.get(assigns.srql, :query) || ""

    assigns =
      assigns
      |> assign(:active?, multi_span_active?(query))
      |> assign(:href, traces_multi_span_href(query, assigns.limit))

    ~H"""
    <div class="flex items-center gap-2">
      <.live_toggle_button
        id="traces-live-toggle"
        toggle_event="toggle_traces_live"
        live?={@live?}
        start_title="Start live trace streaming"
        pause_title="Pause live trace streaming"
      />
      <span class="text-[10px] uppercase tracking-wider text-sr-muted">Filter</span>
      <.ui_button
        id="traces-multi-span-toggle"
        patch={@href}
        size="xs"
        variant="ghost"
        active={@active?}
        class="rounded-full"
        title={if @active?, do: "Show all traces", else: "Show only traces with more than one span"}
      >
        Multi-span
      </.ui_button>
    </div>
    """
  end

  defp trace_sort_state(query) do
    case Regex.run(~r/(?:^|\s)sort:([A-Za-z0-9_]+)(?::(asc|desc))?(?=\s|$)/, to_string(query)) do
      [_, field] -> {field, "desc"}
      [_, field, dir] -> {field, dir}
      _ -> {nil, nil}
    end
  end

  defp traces_sort_href(query, field, _limit) do
    {current_field, current_dir} = trace_sort_state(query)
    dir = if current_field == field and current_dir == "desc", do: "asc", else: "desc"

    base =
      case strip_filter(to_string(query), "sort") do
        "" -> @default_traces_query_base
        cleaned -> cleaned
      end

    ObservabilityPaths.path(
      "traces",
      maybe_put_param(%{}, :q, base <> " sort:#{field}:#{dir}")
    )
  end

  defp multi_span_active?(query) do
    query |> to_string() |> String.split() |> Enum.member?(@multi_span_filter)
  end

  defp traces_multi_span_href(query, _limit) do
    query = to_string(query)

    new_query =
      if multi_span_active?(query) do
        query
        |> String.split()
        |> Enum.reject(&(&1 == @multi_span_filter))
        |> Enum.join(" ")
      else
        case String.trim(query) do
          "" -> "#{@default_traces_query_base} sort:timestamp:desc #{@multi_span_filter}"
          cleaned -> cleaned <> " #{@multi_span_filter}"
        end
      end

    ObservabilityPaths.path("traces", maybe_put_param(%{}, :q, new_query))
  end

  attr(:id, :string, required: true)
  attr(:metrics, :list, default: [])
  attr(:sparklines, :map, default: %{})
  attr(:timezone, :string, required: true)

  defp metrics_table(assigns) do
    values =
      assigns.metrics
      |> Enum.filter(&is_map/1)
      |> Enum.map(&metric_value_ms/1)
      |> Enum.filter(&is_number/1)

    {min_v, max_v} =
      case values do
        [] -> {0.0, 0.0}
        _ -> {Enum.min(values), Enum.max(values)}
      end

    assigns =
      assigns
      |> assign(:min_v, min_v)
      |> assign(:max_v, max_v)

    ~H"""
    <div class="sr-ui-table-shell">
      <table id={@id} class={ui_table_class(size: "sm", zebra: true, class: "w-full")}>
        <thead>
          <tr>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-40">
              Time
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-40">
              Service
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-36">
              Type
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Operation
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-24 text-right">
              Value
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-32">
              Trend
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-20 text-right">
              Logs
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@metrics == []}>
            <td colspan="7" class="text-sm text-sr-muted py-8 text-center">
              No metrics found.
            </td>
          </tr>

          <%= for {metric, idx} <- Enum.with_index(@metrics) do %>
            <tr id={"#{@id}-row-#{idx}"} class="hover:bg-sr-subtle/40 transition-colors">
              <td class="whitespace-nowrap text-xs font-mono">
                <% time = timestamp_meta(Map.get(metric, "timestamp")) %>
                <.user_time
                  id={
                    "metric-time-#{@id}-row-#{signal_time_key(metric, ["span_id", "trace_id"], idx)}"
                  }
                  value={time.value}
                  timezone={@timezone}
                  style={:full}
                  fallback={time.fallback}
                />
              </td>
              <td
                class="whitespace-nowrap text-xs truncate max-w-[14rem]"
                title={Map.get(metric, "service_name")}
              >
                {Map.get(metric, "service_name") || "—"}
              </td>
              <td
                class="whitespace-nowrap text-xs truncate max-w-[10rem]"
                title={Map.get(metric, "metric_type")}
              >
                <span class="inline-flex items-center gap-2">
                  <.ui_badge size="sm" variant={metric_type_badge_variant(metric)}>
                    {metric_type_label(metric)}
                  </.ui_badge>
                </span>
              </td>
              <td class="text-xs truncate max-w-[28rem]" title={metric_operation(metric)}>
                <.link
                  :if={is_binary(Map.get(metric, "span_id")) and Map.get(metric, "span_id") != ""}
                  navigate={~p"/observability/metrics/#{Map.get(metric, "span_id")}"}
                  class="text-sr-brand hover:underline"
                >
                  {metric_operation(metric)}
                </.link>
                <span :if={
                  not (is_binary(Map.get(metric, "span_id")) and Map.get(metric, "span_id") != "")
                }>
                  {metric_operation(metric)}
                </span>
              </td>
              <td class="whitespace-nowrap text-right">
                <% val_ms = metric_value_ms(metric) %>
                <span
                  class={[
                    "inline-flex min-w-[3.25rem] items-center justify-end rounded-md px-1.5 py-0.5 font-mono text-xs tabular-nums",
                    duration_ms_class(val_ms)
                  ]}
                  title={duration_ms_title(val_ms)}
                >
                  {format_metric_value(metric)}
                </span>
                <span
                  :if={cumulative_metric?(metric)}
                  class="ml-1 font-sans text-[10px] text-sr-muted"
                  title="Raw cumulative counter value; rate rendering arrives with OTLP metric points"
                >
                  cumulative
                </span>
              </td>
              <td class="whitespace-nowrap text-xs">
                <.metric_viz metric={metric} sparklines={@sparklines} />
              </td>
              <td class="whitespace-nowrap text-xs text-right">
                <.ui_icon_button
                  :if={is_binary(Map.get(metric, "trace_id")) and Map.get(metric, "trace_id") != ""}
                  navigate={correlate_metric_href(metric)}
                  size="xs"
                  variant="ghost"
                  title="View correlated logs"
                  aria-label="View correlated logs"
                >
                  <.icon name="hero-arrow-top-right-on-square" class="size-4" />
                </.ui_icon_button>
                <span
                  :if={
                    not (is_binary(Map.get(metric, "trace_id")) and Map.get(metric, "trace_id") != "")
                  }
                  class="text-sr-muted"
                >
                  —
                </span>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr(:view, :string, required: true)
  attr(:srql, :map, required: true)
  attr(:limit, :integer, required: true)
  attr(:live?, :boolean, default: false)

  # Toggle between the legacy span-sample exemplars and real OTLP metric
  # points (in:otel_metric_points). Patch links keep the toggle URL-driven,
  # matching the rest of the pane's navigation.
  defp metrics_panel_controls(assigns) do
    ~H"""
    <div id="metrics-view-toggle" class="flex items-center gap-1">
      <.live_toggle_button
        id="metrics-live-toggle"
        toggle_event="toggle_metrics_live"
        live?={@live?}
        start_title="Start live metric streaming"
        pause_title="Pause live metric streaming"
      />
      <.ui_button
        patch={metrics_view_href(@srql, @limit, "samples")}
        size="xs"
        variant={if @view == "samples", do: "primary", else: "ghost"}
      >
        Span samples
      </.ui_button>
      <.ui_button
        patch={metrics_view_href(@srql, @limit, "points")}
        size="xs"
        variant={if @view == "points", do: "primary", else: "ghost"}
      >
        OTLP metrics
      </.ui_button>
    </div>
    """
  end

  attr(:names, :list, default: [])
  attr(:selected, :any, default: nil)
  attr(:series, :list, default: [])
  attr(:srql, :map, required: true)
  attr(:limit, :integer, required: true)

  defp otlp_points_view(assigns) do
    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
      <div class="lg:col-span-1 overflow-x-auto">
        <table id="otlp-metric-names" class={ui_table_class(size: "sm", zebra: true, class: "w-full")}>
          <thead>
            <tr>
              <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
                Metric
              </th>
              <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-24">
                Type
              </th>
              <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-16">
                Unit
              </th>
              <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-20 text-right">
                Points
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@names == []}>
              <td colspan="4" class="text-sm text-sr-muted py-8 text-center">
                No OTLP metric points found in the active window.
              </td>
            </tr>
            <%= for {entry, idx} <- Enum.with_index(@names) do %>
              <tr
                id={"otlp-metric-name-#{idx}"}
                class={[
                  "hover:bg-sr-subtle/40 transition-colors",
                  @selected == entry.name && "bg-sr-subtle/60"
                ]}
              >
                <td class="text-xs max-w-[16rem]">
                  <.link
                    patch={otlp_metric_href(@srql, @limit, entry.name)}
                    class="text-sr-brand hover:underline font-mono break-all"
                  >
                    {entry.name}
                  </.link>
                </td>
                <td class="whitespace-nowrap text-xs">
                  <.ui_badge size="sm" variant={otlp_type_badge_variant(entry.type)}>
                    {entry.type || "—"}
                  </.ui_badge>
                </td>
                <td class="whitespace-nowrap text-xs">{entry.unit || "—"}</td>
                <td class="whitespace-nowrap text-xs font-mono text-right">
                  {format_compact_int(entry.points)}
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <div class="lg:col-span-2">
        <div :if={is_nil(@selected)} class="text-sm text-sr-muted py-8 text-center">
          Select a metric to load its recent points.
        </div>
        <div :if={is_binary(@selected)}>
          <div class="mb-3 flex flex-wrap items-center gap-2">
            <span class="font-mono text-sm font-semibold break-all">{@selected}</span>
            <.ui_badge :if={@series != []} size="sm" variant="ghost">
              temporality: {otlp_temporality_label(List.first(@series))}
            </.ui_badge>
            <span class="text-xs text-sr-muted">
              {length(@series)} series · grouped by attributes
            </span>
          </div>
          <div :if={@series == []} class="text-sm text-sr-muted py-8 text-center">
            No points found for this metric.
          </div>
          <div class="space-y-2">
            <%= for {series, idx} <- Enum.with_index(@series) do %>
              <.otlp_series_card series={series} idx={idx} />
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:series, :map, required: true)
  attr(:idx, :integer, required: true)

  defp otlp_series_card(assigns) do
    ~H"""
    <div
      id={"otlp-series-#{@idx}"}
      class="rounded-xl border border-sr-line bg-sr-surface p-3 flex flex-wrap items-center gap-3"
    >
      <div class="min-w-0 flex-1">
        <div
          class="text-xs font-mono text-sr-muted truncate max-w-[28rem]"
          title={@series.attributes || @series.attributes_hash}
        >
          {@series.attributes || "(no attributes)"}
        </div>
        <div class="mt-1 flex items-center gap-2 text-[10px] text-sr-muted">
          <.ui_badge size="sm" variant={otlp_type_badge_variant(@series.metric_type)}>
            {@series.metric_type || "—"}
          </.ui_badge>
          <span>{otlp_kind_label(@series.kind)}</span>
          <span>temporality: {otlp_temporality_label(@series)}</span>
          <span>{@series.point_count} pts</span>
        </div>
      </div>

      <div class="flex items-center gap-3">
        <%= case @series.kind do %>
          <% :rate -> %>
            <span class="text-xs text-sr-muted">current rate</span>
            <span class="text-sm font-mono font-semibold">
              {format_otlp_rate(@series.current_rate)}
            </span>
            <.sparkline :if={length(@series.rates) >= 3} data={@series.rates} />
          <% :delta_sum -> %>
            <span class="text-xs text-sr-muted">sum over window</span>
            <span class="text-sm font-mono font-semibold">
              {format_series_number(@series.window_sum)}{otlp_unit_suffix(@series.unit)}
            </span>
            <.sparkline :if={length(@series.values) >= 3} data={@series.values} />
          <% :gauge -> %>
            <span class="text-xs text-sr-muted">last value</span>
            <span class="text-sm font-mono font-semibold">
              {format_series_number(@series.last_value)}{otlp_unit_suffix(@series.unit)}
            </span>
            <.sparkline :if={length(@series.values) >= 3} data={@series.values} />
          <% :histogram -> %>
            <span class="text-xs text-sr-muted">histogram</span>
            <span class="text-sm font-mono font-semibold">
              count {format_series_number(@series.histogram_count)} · sum {format_series_number(
                @series.histogram_sum
              )}
            </span>
          <% _ -> %>
            <span class="text-sr-ink/30">—</span>
        <% end %>
      </div>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:events, :any, required: true)
  attr(:count, :integer, required: true)
  attr(:timezone, :string, required: true)

  defp events_table(assigns) do
    ~H"""
    <div class="sr-ui-table-shell">
      <table id={@id} class={ui_table_class(size: "sm", zebra: true, class: "w-full")}>
        <thead>
          <tr>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-40">
              Time
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-24">
              Severity
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-40">
              Source
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Message
            </th>
          </tr>
        </thead>
        <tbody id={"#{@id}-rows"} phx-update="stream">
          <tr :if={@count == 0}>
            <td colspan="4" class="text-sm text-sr-muted py-8 text-center">
              No events found.
            </td>
          </tr>

          <%= for {dom_id, event} <- @events do %>
            <tr
              id={dom_id}
              class="hover:bg-sr-subtle/40 cursor-pointer transition-colors"
              phx-click={JS.navigate(~p"/events/#{event_id(event)}")}
            >
              <td class="whitespace-nowrap text-xs font-mono">
                <% time = timestamp_meta(event_timestamp(event)) %>
                <.user_time
                  id={"event-time-#{dom_id}"}
                  value={time.value}
                  timezone={@timezone}
                  style={:full}
                  fallback={time.fallback}
                />
              </td>
              <td class="whitespace-nowrap text-xs">
                <.event_severity_badge value={Map.get(event, "severity")} />
              </td>
              <td class="whitespace-nowrap text-xs truncate max-w-[12rem]" title={event_source(event)}>
                {event_source(event)}
              </td>
              <td class="text-xs truncate max-w-[32rem]" title={event_message(event)}>
                {event_message(event)}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr(:value, :any, default: nil)

  defp event_severity_badge(assigns) do
    variant = event_severity_variant(assigns.value)
    label = event_severity_label(assigns.value)

    assigns = assigns |> assign(:variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp event_severity_variant(value) do
    case normalize_event_severity(value) do
      s when s in ["critical", "fatal", "error"] -> "error"
      s when s in ["high", "warn", "warning"] -> "warning"
      s when s in ["medium", "info"] -> "info"
      s when s in ["low", "debug", "ok"] -> "success"
      _ -> "ghost"
    end
  end

  defp event_severity_label(nil), do: "—"
  defp event_severity_label(""), do: "—"
  defp event_severity_label(value) when is_binary(value), do: value
  defp event_severity_label(value), do: to_string(value)

  defp normalize_event_severity(nil), do: ""
  defp normalize_event_severity(v) when is_binary(v), do: v |> String.trim() |> String.downcase()
  defp normalize_event_severity(v), do: v |> to_string() |> normalize_event_severity()

  defp event_id(event) do
    Map.get(event, "id") || Map.get(event, "event_id") || "unknown"
  end

  defp event_dom_id(event) do
    id = event_id(event)

    if id == "unknown" do
      "event-" <> Integer.to_string(:erlang.phash2(event))
    else
      "event-" <> id
    end
  end

  defp event_timestamp(event),
    do: Map.get(event, "time") || Map.get(event, "event_timestamp") || Map.get(event, "timestamp")

  defp event_source(event) do
    source =
      Map.get(event, "log_provider") ||
        Map.get(event, "log_name") ||
        Map.get(event, "host") ||
        Map.get(event, "source") ||
        Map.get(event, "uid") ||
        Map.get(event, "device_id") ||
        Map.get(event, "subject")

    case source do
      nil -> "—"
      "" -> "—"
      v when is_binary(v) -> v
      v -> to_string(v)
    end
  end

  defp event_message(event) do
    message =
      Map.get(event, "short_message") ||
        Map.get(event, "message") ||
        Map.get(event, "subject") ||
        Map.get(event, "description")

    case message do
      nil -> "—"
      "" -> "—"
      v when is_binary(v) -> String.slice(v, 0, 200)
      v -> v |> to_string() |> String.slice(0, 200)
    end
  end

  attr(:selection, :any, required: true)
  attr(:duration, :string, required: true)
  attr(:result, :map, default: nil)
  attr(:visible_count, :integer, default: 0)

  defp alert_bulk_bar(assigns) do
    assigns =
      assigns
      |> assign(:selected_count, MapSet.size(assigns.selection))
      |> assign(:snooze_options, AlertActions.snooze_options())
      |> assign(:bulk_limit, AlertActions.bulk_limit())

    ~H"""
    <div class="mb-3 flex flex-wrap items-center gap-x-3 gap-y-2 rounded-sr-surface border border-sr-line bg-sr-subtle/30 px-3 py-2">
      <span class="text-xs text-sr-muted">
        {@selected_count} of {@visible_count} selected (limit {@bulk_limit})
      </span>

      <div
        class="flex flex-wrap items-center gap-1.5"
        role="group"
        aria-label="Bulk alert actions"
      >
        <.ui_button
          type="button"
          size="xs"
          variant="primary"
          phx-click="alert_bulk_acknowledge"
          disabled={@selected_count == 0}
          data-confirm="Acknowledge the selected alerts?"
        >
          Acknowledge selected
        </.ui_button>

        <form
          id="alert-bulk-snooze-form"
          phx-submit="alert_bulk_snooze"
          phx-change="alert_bulk_duration"
          class="flex items-center gap-1.5"
        >
          <label for="alert-bulk-duration" class="sr-only">Bulk snooze duration</label>
          <select
            id="alert-bulk-duration"
            name="duration"
            class={ui_field_class(size: "xs", class: "w-auto")}
          >
            <option
              :for={option <- @snooze_options}
              value={option.value}
              selected={option.value == @duration}
            >
              {option.label}
            </option>
          </select>
          <.ui_button type="submit" size="xs" variant="outline" disabled={@selected_count == 0}>
            Snooze selected
          </.ui_button>
        </form>

        <.ui_button
          type="button"
          size="xs"
          variant="ghost"
          phx-click="alert_select_clear"
          disabled={@selected_count == 0}
        >
          Clear selection
        </.ui_button>
      </div>

      <div :if={is_map(@result)} class="w-full text-xs">
        <p class={[
          "font-medium",
          if(@result.failed == [],
            do: "text-emerald-700 dark:text-emerald-300",
            else: "text-amber-700 dark:text-amber-300"
          )
        ]}>
          {length(@result.succeeded)} succeeded, {length(@result.failed)} failed
        </p>
        <ul :if={@result.failed != []} class="mt-1 space-y-0.5 text-sr-muted">
          <li :for={{id, reason} <- Enum.take(@result.failed, 10)} class="font-mono">
            {String.slice(id, 0, 8)}: <span class="font-sans">{reason}</span>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:alerts, :list, default: [])
  attr(:selectable?, :boolean, default: false)
  attr(:selection, :any, default: nil)
  attr(:timezone, :string, required: true)

  defp alerts_table(assigns) do
    assigns = assign(assigns, :colspan, if(assigns.selectable?, do: 5, else: 4))

    ~H"""
    <div class="sr-ui-table-shell">
      <table id={@id} class={ui_table_class(size: "sm", zebra: true, class: "w-full")}>
        <thead>
          <tr>
            <th :if={@selectable?} class="w-10 bg-sr-subtle/60">
              <input
                type="checkbox"
                id={"#{@id}-select-all"}
                checked={@alerts != [] and MapSet.size(@selection) >= length(@alerts)}
                phx-click="alert_select_all"
                aria-label="Select every alert on this page"
                class="size-4 cursor-pointer accent-sr-brand"
              />
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-40">
              Time
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-24">
              Severity
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60 w-28">
              Status
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Title
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@alerts == []}>
            <td colspan={@colspan} class="text-sm text-sr-muted py-8 text-center">
              No alerts found.
            </td>
          </tr>

          <%= for {alert, idx} <- Enum.with_index(@alerts) do %>
            <tr
              id={"#{@id}-row-#{idx}"}
              class="hover:bg-sr-subtle/40 transition-colors"
            >
              <td :if={@selectable?} class="w-10">
                <input
                  type="checkbox"
                  id={"#{@id}-select-#{idx}"}
                  checked={alert_selected?(@selection, alert_id(alert))}
                  phx-click="alert_select_toggle"
                  phx-value-id={alert_id(alert)}
                  aria-label={"Select alert " <> String.slice(to_string(alert_id(alert)), 0, 8)}
                  class="size-4 cursor-pointer accent-sr-brand"
                />
              </td>
              <td
                class="whitespace-nowrap text-xs font-mono cursor-pointer"
                phx-click={JS.navigate(~p"/alerts/#{alert_id(alert)}")}
              >
                <% time = timestamp_meta(alert_timestamp(alert)) %>
                <.user_time
                  id={
                    "alert-time-#{@id}-row-#{signal_time_key(alert, ["alert_id", "id"], idx)}"
                  }
                  value={time.value}
                  timezone={@timezone}
                  style={:full}
                  fallback={time.fallback}
                />
              </td>
              <td class="whitespace-nowrap text-xs">
                <.alert_severity_badge value={Map.get(alert, "severity")} />
              </td>
              <td class="whitespace-nowrap text-xs">
                <.alert_status_badge value={Map.get(alert, "status")} />
              </td>
              <td
                class="text-xs truncate max-w-[36rem] cursor-pointer"
                title={alert_title(alert)}
                phx-click={JS.navigate(~p"/alerts/#{alert_id(alert)}")}
              >
                {alert_title(alert)}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  defp alert_selected?(%MapSet{} = selection, id) when is_binary(id), do: MapSet.member?(selection, id)
  defp alert_selected?(_selection, _id), do: false

  attr(:value, :any, default: nil)

  defp alert_severity_badge(assigns) do
    variant = alert_severity_variant(assigns.value)
    label = alert_severity_label(assigns.value)

    assigns = assigns |> assign(:variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp alert_severity_variant(value) do
    case normalize_alert_severity(value) do
      s when s in ["emergency", "critical"] -> "error"
      s when s in ["warning"] -> "warning"
      s when s in ["info"] -> "info"
      _ -> "ghost"
    end
  end

  defp alert_severity_label(nil), do: "—"
  defp alert_severity_label(""), do: "—"
  defp alert_severity_label(value) when is_binary(value), do: value
  defp alert_severity_label(value), do: to_string(value)

  defp normalize_alert_severity(nil), do: ""
  defp normalize_alert_severity(v) when is_binary(v), do: v |> String.trim() |> String.downcase()
  defp normalize_alert_severity(v), do: v |> to_string() |> normalize_alert_severity()

  attr(:value, :any, default: nil)

  defp alert_status_badge(assigns) do
    variant = alert_status_variant(assigns.value)
    label = alert_status_label(assigns.value)

    assigns = assigns |> assign(:variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp alert_status_variant(value) do
    case normalize_alert_status(value) do
      "pending" -> "warning"
      "acknowledged" -> "info"
      "resolved" -> "success"
      "escalated" -> "error"
      "suppressed" -> "ghost"
      _ -> "ghost"
    end
  end

  defp alert_status_label(nil), do: "—"
  defp alert_status_label(""), do: "—"
  defp alert_status_label(value) when is_binary(value), do: String.capitalize(value)
  defp alert_status_label(value), do: value |> to_string() |> String.capitalize()

  defp normalize_alert_status(nil), do: ""
  defp normalize_alert_status(v) when is_binary(v), do: String.downcase(v)
  defp normalize_alert_status(v), do: v |> to_string() |> normalize_alert_status()

  defp alert_id(alert) do
    Map.get(alert, "id") || Map.get(alert, "alert_id") || "unknown"
  end

  defp alert_title(alert) do
    EventTitle.alert_title(alert)
  end

  defp alert_timestamp(alert) do
    raw = Map.get(alert, "triggered_at") || Map.get(alert, "timestamp")

    case parse_srql_datetime(raw) do
      {:ok, datetime} -> datetime
      _ -> raw
    end
  end

  attr(:flows, :list, default: [])
  attr(:rdns_map, :map, default: %{})
  attr(:threat_map, :map, default: %{})
  attr(:base_path, :string, required: true)
  attr(:query, :string, required: true)
  attr(:limit, :integer, required: true)
  attr(:compact?, :boolean, default: false)
  attr(:talker_cidr, :integer, default: nil)
  attr(:compare_mode, :string, default: "off")
  attr(:geo_side, :string, default: "dst")
  attr(:sankey_prefix, :integer, default: 24)
  attr(:stack_mode, :string, default: @default_netflow_stack_mode)
  attr(:graph_mode, :string, default: "stacked")
  attr(:view, :string, default: "overview")
  attr(:timezone, :string, required: true)

  defp netflows_table(assigns) do
    ~H"""
    <div class="w-full">
      <% patch_opts =
        netflow_patch_opts(
          @compact?,
          @talker_cidr,
          @compare_mode,
          @geo_side,
          @sankey_prefix,
          @stack_mode,
          @graph_mode,
          @view
        ) %>
      <table class={
        ui_table_class(
          size: if(@compact?, do: "xs", else: "sm"),
          zebra: true,
          fixed: true,
          class: "w-full"
        )
      }>
        <thead>
          <tr>
            <th class="w-40">Time</th>
            <th>Source</th>
            <th>Destination</th>
            <th class="w-24">Protocol</th>
            <th class="w-20">Version</th>
            <th class="w-32 text-right">Packets/Bytes</th>
            <th class="w-10 text-right"></th>
          </tr>
        </thead>
        <tbody>
          <%= for {flow, idx} <- Enum.with_index(@flows) do %>
            <tr>
              <td class="whitespace-nowrap text-xs font-mono">
                <% timestamp = Map.get(flow, "time") || Map.get(flow, "timestamp") %>
                <.user_time
                  id={"netflow-row-time-#{idx}"}
                  value={timestamp}
                  timezone={@timezone}
                  style={:compact}
                  fallback={timestamp || "—"}
                />
              </td>
              <td class="text-xs align-top">
                <% src_ip = netflow_addr(flow, :src) %>
                <% src_threat = netflow_threat(@threat_map, src_ip) %>
                <div class="flex items-baseline gap-0.5 min-w-0 font-mono">
                  <% src_port = netflow_port(flow, :src) %>
                  <span
                    :if={cc = netflow_country_iso2(flow, :src)}
                    class="shrink-0 text-sm leading-none"
                    title={cc}
                  >
                    {iso2_flag_emoji(cc)}
                  </span>
                  <.link
                    :if={netflow_present?(src_ip)}
                    patch={
                      netflow_filter_patch(
                        @base_path,
                        @query,
                        @limit,
                        "src_ip",
                        src_ip,
                        patch_opts
                      )
                    }
                    class="min-w-0 truncate hover:underline"
                  >
                    {src_ip}
                  </.link>
                  <span :if={not netflow_present?(src_ip)} class="min-w-0 truncate">{src_ip}</span>
                  <span class="shrink-0">{if src_port, do: ":#{src_port}", else: ""}</span>
                  <.netflow_threat_badge :if={src_threat} threat={src_threat} />
                </div>
                <div
                  :if={hostname = Map.get(@rdns_map, src_ip)}
                  class="mt-0.5 text-[11px] text-sr-muted max-w-60 truncate font-mono"
                  title={hostname}
                >
                  {hostname}
                </div>
                <div
                  :if={asn = netflow_asn(flow, :src)}
                  class="mt-0.5 text-[11px] text-sr-muted font-mono"
                >
                  AS{asn}
                </div>
                <PrefixTagChips.linked items={
                  netflow_linked_tag_items(
                    netflow_prefix_tags(flow, :src),
                    @base_path,
                    @query,
                    @limit,
                    patch_opts
                  )
                } />
              </td>
              <td class="text-xs align-top">
                <% dst_ip = netflow_addr(flow, :dst) %>
                <% dst_threat = netflow_threat(@threat_map, dst_ip) %>
                <div class="flex flex-col gap-0.5 min-w-0">
                  <div class="flex items-start gap-2 min-w-0">
                    <% dst_port = netflow_port(flow, :dst) %>
                    <div class="flex items-baseline gap-0.5 min-w-0 font-mono">
                      <span
                        :if={cc = netflow_country_iso2(flow, :dst)}
                        class="shrink-0 text-sm leading-none"
                        title={cc}
                      >
                        {iso2_flag_emoji(cc)}
                      </span>
                      <.link
                        :if={netflow_present?(dst_ip)}
                        patch={
                          netflow_filter_patch(
                            @base_path,
                            @query,
                            @limit,
                            "dst_ip",
                            dst_ip,
                            patch_opts
                          )
                        }
                        class="min-w-0 truncate hover:underline"
                      >
                        {dst_ip}
                      </.link>
                      <span :if={not netflow_present?(dst_ip)} class="min-w-0 truncate">
                        {dst_ip}
                      </span>
                      <span class="shrink-0">{if dst_port, do: ":#{dst_port}", else: ""}</span>
                      <.netflow_threat_badge :if={dst_threat} threat={dst_threat} />
                    </div>
                    <div :if={service_label = netflow_service_label(flow, dst_port)} class="shrink-0">
                      <.ui_badge variant="ghost" size="xs" class="font-mono">
                        {service_label}
                      </.ui_badge>
                    </div>
                  </div>
                  <div
                    :if={hostname = Map.get(@rdns_map, dst_ip)}
                    class="text-[11px] text-sr-muted max-w-60 truncate font-mono"
                    title={hostname}
                  >
                    {hostname}
                  </div>
                  <PrefixTagChips.linked items={
                    netflow_linked_tag_items(
                      netflow_prefix_tags(flow, :dst),
                      @base_path,
                      @query,
                      @limit,
                      patch_opts
                    )
                  } />
                  <div
                    :if={asn = netflow_asn(flow, :dst)}
                    class="text-[11px] text-sr-muted font-mono"
                  >
                    AS{asn}
                  </div>
                </div>
              </td>
              <td class="whitespace-nowrap text-xs">
                <.netflow_protocol_badge
                  protocol={netflow_protocol_num(flow)}
                  name={netflow_protocol_name(flow)}
                />
              </td>
              <td class="whitespace-nowrap text-xs">
                <.netflow_flow_type_badge flow_type={netflow_flow_type(flow)} />
              </td>
              <td class="whitespace-nowrap text-xs text-right font-mono">
                <div>{format_netflow_number(netflow_packets(flow))}</div>
                <div class="text-[10px] text-sr-muted">
                  {format_netflow_bytes(netflow_bytes(flow))}
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
                  <:item>
                    <.link
                      patch={
                        netflow_filter_patch(
                          @base_path,
                          @query,
                          @limit,
                          "src_ip",
                          netflow_addr(flow, :src),
                          patch_opts
                        )
                      }
                      class="text-xs"
                    >
                      Filter source
                    </.link>
                  </:item>
                  <:item>
                    <.link
                      patch={
                        netflow_filter_patch(
                          @base_path,
                          @query,
                          @limit,
                          "dst_ip",
                          netflow_addr(flow, :dst),
                          patch_opts
                        )
                      }
                      class="text-xs"
                    >
                      Filter destination
                    </.link>
                  </:item>
                  <:item :if={
                    is_integer(to_int(netflow_port(flow, :dst))) and
                      to_int(netflow_port(flow, :dst)) > 0
                  }>
                    <.link
                      patch={
                        netflow_filter_patch(
                          @base_path,
                          @query,
                          @limit,
                          "dst_port",
                          to_string(netflow_port(flow, :dst)),
                          patch_opts
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

      <div :if={@flows == []} class="py-12 text-center text-sr-muted">
        No network flows found. Generate some NetFlow data to see it here!
      </div>
    </div>
    """
  end

  attr(:threat, :map, required: true)

  defp netflow_threat_badge(assigns) do
    assigns =
      assigns
      |> assign(:count, Map.get(assigns.threat, :match_count, 0))
      |> assign(:severity, Map.get(assigns.threat, :max_severity, 0))
      |> assign(:sources, Map.get(assigns.threat, :sources, []))

    ~H"""
    <.ui_badge
      size="xs"
      variant={netflow_threat_badge_variant(@severity)}
      class="shrink-0 font-mono"
      title={netflow_threat_title(@count, @severity, @sources)}
    >
      IOC
    </.ui_badge>
    """
  end

  defp netflow_threat(threat_map, ip) when is_map(threat_map) and is_binary(ip) do
    case Map.get(threat_map, String.trim(ip)) do
      %{match_count: count} = threat when is_integer(count) and count > 0 -> threat
      _ -> nil
    end
  end

  defp netflow_threat(_threat_map, _ip), do: nil

  defp netflow_threat_badge_variant(severity) when is_integer(severity) and severity >= 4, do: "error"

  defp netflow_threat_badge_variant(severity) when is_integer(severity) and severity >= 2, do: "warning"

  defp netflow_threat_badge_variant(_severity), do: "info"

  defp netflow_threat_title(count, severity, sources) do
    source_text =
      sources
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))
      |> case do
        [] -> "unknown source"
        values -> Enum.join(values, ", ")
      end

    "#{count} IOC match#{if count == 1, do: "", else: "es"}; severity #{severity}; #{source_text}"
  end

  attr(:side, :string, required: true)
  attr(:geo, :any, default: nil)

  defp netflow_geoip_asn_line(assigns) do
    geo = assigns.geo

    assigns =
      assigns
      |> assign(:country_iso2, if(geo, do: geo.country_iso2))
      |> assign(:flag, country_flag_emoji(if(geo, do: geo.country_iso2)))
      |> assign(:loc, geo_loc_string(geo))
      |> assign(:asn, geo_asn_string(geo))
      |> assign(:as_org, if(geo, do: geo.as_org))

    ~H"""
    <div class="mt-1 text-sr-muted">
      {@side}:
      <%= if @geo do %>
        <span class="font-mono">
          <%= if is_binary(@country_iso2) and @country_iso2 != "" do %>
            <.ui_badge size="xs" variant="ghost" class="font-mono">{@country_iso2}</.ui_badge>
            <span :if={is_binary(@flag)} class="ml-1">{@flag}</span>
          <% end %>

          <%= if is_binary(@loc) and @loc != "" do %>
            <span class="ml-2">{@loc}</span>
          <% end %>

          <%= if is_binary(@asn) and @asn != "" do %>
            <span class="ml-2">{@asn}</span>
          <% end %>

          <%= if is_binary(@as_org) and @as_org != "" do %>
            <span class="ml-2 text-sr-muted">{@as_org}</span>
          <% end %>
        </span>
      <% else %>
        <span class="text-sr-muted">n/a</span>
      <% end %>
    </div>
    """
  end

  defp geo_loc_string(nil), do: nil

  defp geo_loc_string(geo) do
    [geo.city, geo.region, geo.country_name]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.join(", ")
    |> case do
      "" -> nil
      s -> s
    end
  end

  defp geo_asn_string(nil), do: nil

  defp geo_asn_string(geo) do
    case geo.asn do
      n when is_integer(n) and n > 0 -> "AS#{n}"
      _ -> nil
    end
  end

  defp country_flag_emoji(nil), do: nil

  defp country_flag_emoji(iso2) when is_binary(iso2) do
    iso2 = iso2 |> String.trim() |> String.upcase()

    if String.length(iso2) == 2 and Regex.match?(~r/^[A-Z]{2}$/, iso2) do
      <<a::utf8, b::utf8>> = iso2
      base = 0x1F1E6
      <<base + (a - ?A)::utf8, base + (b - ?A)::utf8>>
    end
  end

  defp country_flag_emoji(_), do: nil

  defp flow_get(flow, keys) when is_map(flow) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case key do
        k when is_binary(k) -> Map.get(flow, k)
        k when is_atom(k) -> Map.get(flow, k)
        _ -> nil
      end
    end)
  end

  defp flow_get(_flow, _keys), do: nil

  defp flow_get_in(data, path) when is_map(data) and is_list(path) do
    get_in(data, Enum.map(path, &to_string/1))
  end

  defp flow_get_in(_data, _path), do: nil

  defp tcp_flag_tooltip(flag) when is_binary(flag) do
    case String.upcase(String.trim(flag)) do
      "FIN" -> "FIN: sender finished sending data."
      "SYN" -> "SYN: synchronize sequence numbers."
      "RST" -> "RST: abort/reset connection."
      "PSH" -> "PSH: push buffered data immediately."
      "ACK" -> "ACK: acknowledgment field is valid."
      "URG" -> "URG: urgent pointer field is valid."
      "ECE" -> "ECE: ECN echo."
      "CWR" -> "CWR: congestion window reduced."
      "NS" -> "NS: ECN nonce protection flag."
      _ -> "TCP flag."
    end
  end

  defp tcp_flag_tooltip(_), do: "TCP flag."

  defp fetch_arin_asn(asn) when is_integer(asn) and asn > 0 do
    url = "https://whois.arin.net/rest/asn/AS#{asn}.json"

    case Req.get(url, arin_http_req_opts()) do
      {:ok, %Req.Response{status: 200, body: %{"asn" => %{} = asn_payload}}} ->
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

  defp fetch_arin_asn(_), do: {:error, :invalid_asn}

  defp arin_http_req_opts do
    opts = [receive_timeout: 8_000, retry: false, headers: [{"accept", "application/json"}]]

    if Process.whereis(ServiceRadar.Finch) do
      Keyword.put(opts, :finch, ServiceRadar.Finch)
    else
      opts
    end
  end

  defp normalize_arin_asn(%{} = asn_payload) do
    org_ref = Map.get(asn_payload, "orgRef")
    start_as = arin_leaf_value(Map.get(asn_payload, "startAsNumber"))
    end_as = arin_leaf_value(Map.get(asn_payload, "endAsNumber"))

    %{
      handle: arin_leaf_value(Map.get(asn_payload, "handle")),
      name: arin_leaf_value(Map.get(asn_payload, "name")),
      range: arin_as_range(start_as, end_as),
      registration_date: arin_leaf_value(Map.get(asn_payload, "registrationDate")),
      update_date: arin_leaf_value(Map.get(asn_payload, "updateDate")),
      ref: arin_leaf_value(Map.get(asn_payload, "ref")),
      org_name: if(is_map(org_ref), do: Map.get(org_ref, "@name"))
    }
  end

  defp arin_leaf_value(%{"$" => value}) when is_binary(value), do: String.trim(value)
  defp arin_leaf_value(value) when is_binary(value), do: String.trim(value)
  defp arin_leaf_value(_), do: nil

  defp arin_as_range(start_as, end_as) when is_binary(start_as) and is_binary(end_as) do
    if start_as == end_as, do: "AS#{start_as}", else: "AS#{start_as}-AS#{end_as}"
  end

  defp arin_as_range(_start_as, _end_as), do: nil

  defp arin_error_text(:invalid_asn), do: "Invalid ASN."
  defp arin_error_text(:not_found), do: "ASN not found in ARIN."
  defp arin_error_text(_), do: "ASN lookup failed."

  attr(:flow, :map, required: true)
  attr(:context, :map, default: %{})
  attr(:base_path, :string, required: true)
  attr(:query, :string, required: true)
  attr(:limit, :integer, required: true)
  attr(:compact?, :boolean, default: false)
  attr(:talker_cidr, :integer, default: nil)
  attr(:compare_mode, :string, default: "off")
  attr(:geo_side, :string, default: "dst")
  attr(:sankey_prefix, :integer, default: 24)
  attr(:stack_mode, :string, default: @default_netflow_stack_mode)
  attr(:graph_mode, :string, default: "stacked")
  attr(:view, :string, default: "overview")
  attr(:arin_lookup, :map, default: %{})
  attr(:timezone, :string, required: true)

  defp netflow_details_modal(assigns) do
    ocsf =
      case Map.get(assigns.flow, "ocsf_payload") do
        %{} = payload -> payload
        _ -> %{}
      end

    src_provider =
      flow_get(assigns.flow, ["src_hosting_provider"]) ||
        flow_get_in(ocsf, ["enrichment", "src_hosting_provider"])

    dst_provider =
      flow_get(assigns.flow, ["dst_hosting_provider"]) ||
        flow_get_in(ocsf, ["enrichment", "dst_hosting_provider"])

    src_prefix_tags = netflow_prefix_tags(assigns.flow, :src)
    dst_prefix_tags = netflow_prefix_tags(assigns.flow, :dst)

    direction_label =
      flow_get(assigns.flow, ["direction_label"]) ||
        flow_get_in(ocsf, ["enrichment", "direction_label"])

    tcp_flags_labels =
      flow_get(assigns.flow, ["tcp_flags_labels"]) ||
        flow_get_in(ocsf, ["enrichment", "tcp_flags_labels"])

    tcp_flags_labels =
      if is_list(tcp_flags_labels), do: Enum.map(tcp_flags_labels, &to_string/1), else: []

    tcp_flags_raw = flow_get(assigns.flow, ["tcp_flags"])
    attribution = netflow_attribution(assigns.flow)

    assigns =
      assigns
      |> assign(:src_ip, netflow_addr(assigns.flow, :src))
      |> assign(:dst_ip, netflow_addr(assigns.flow, :dst))
      |> assign(:src_port, netflow_port(assigns.flow, :src))
      |> assign(:dst_port, netflow_port(assigns.flow, :dst))
      |> assign(:service_label, netflow_service_label(assigns.flow, netflow_port(assigns.flow, :dst)))
      |> assign(:src_cc, netflow_country_iso2(assigns.flow, :src))
      |> assign(:dst_cc, netflow_country_iso2(assigns.flow, :dst))
      |> assign(:mapbox, Map.get(assigns.context || %{}, :mapbox))
      |> assign(:map_markers, netflow_map_markers(assigns.context || %{}, assigns.flow))
      |> assign(:src_provider, src_provider)
      |> assign(:dst_provider, dst_provider)
      |> assign(:src_prefix_tags, src_prefix_tags)
      |> assign(:dst_prefix_tags, dst_prefix_tags)
      |> assign(:direction_label, direction_label)
      |> assign(:tcp_flags_labels, tcp_flags_labels)
      |> assign(:tcp_flags_raw, tcp_flags_raw)
      |> assign(:attribution, attribution)

    ~H"""
    <dialog
      id="observability-netflow-details-modal"
      class="sr-ui-modal sr-ui-modal-open"
      phx-hook="DialogTopLayer"
      data-cancel="netflow_close"
      phx-window-keydown="netflow_close"
      phx-key="escape"
    >
      <div class="sr-ui-modal-box sr-ui-modal-box-wide">
        <div class="flex shrink-0 items-start justify-between gap-4 border-b border-sr-line px-5 py-4">
          <div class="min-w-0">
            <div class="text-sm font-semibold tracking-tight text-sr-ink">Flow details</div>
            <div class="text-xs text-sr-muted font-mono">
              <% timestamp = Map.get(@flow, "time") || Map.get(@flow, "timestamp") %>
              <.user_time
                id="netflow-flow-detail-time"
                value={timestamp}
                timezone={@timezone}
                style={:full}
                fallback={timestamp || "—"}
              />
            </div>
          </div>
          <.ui_icon_button variant="ghost" size="sm" phx-click="netflow_close" aria-label="Close">
            <.icon name="hero-x-mark" class="size-5" />
          </.ui_icon_button>
        </div>

        <div class="grid min-h-0 flex-1 grid-cols-1 gap-3 overflow-hidden p-3 lg:grid-cols-3">
          <.ui_panel
            class="min-h-0 min-w-0 max-h-full overflow-y-auto lg:col-span-2"
            body_class="!p-0"
          >
            <div class="divide-y divide-sr-line">
              <div class="p-4">
                <div class="text-xs font-medium uppercase tracking-wider text-sr-muted">
                  Endpoints
                </div>
                <div class="mt-2 grid grid-cols-1 gap-3 md:grid-cols-2">
                  <div class="min-w-0 rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
                    <div class="text-[10px] uppercase tracking-wider text-sr-muted">
                      Source
                    </div>
                    <div class="mt-1 break-all font-mono text-sm leading-snug text-sr-ink">
                      {@src_ip}{if @src_port, do: ":#{@src_port}", else: ""}
                    </div>
                    <div :if={@src_cc} class="mt-1 text-xs text-sr-muted">
                      <span class="mr-1">{country_flag_emoji(@src_cc)}</span>
                      <span class="font-mono">{@src_cc}</span>
                      <span :if={geo = Map.get(@context, :src_geo)} class="ml-2">
                        <%= if is_binary(geo.country_name) and geo.country_name != "" do %>
                          {geo.country_name}
                        <% end %>
                      </span>
                    </div>
                    <div
                      :if={is_binary(@src_provider) and @src_provider != ""}
                      class="mt-1 text-xs text-sr-muted"
                    >
                      Provider: <span class="font-mono">{@src_provider}</span>
                    </div>
                    <PrefixTagChips.static
                      tags={@src_prefix_tags}
                      wrapper_class="mt-1 flex flex-wrap gap-1"
                    />
                    <div class="mt-2 flex flex-wrap gap-2">
                      <.ui_button
                        size="xs"
                        variant="ghost"
                        phx-click="netflow_modal_filter"
                        phx-value-field="src_ip"
                        phx-value-value={@src_ip}
                      >
                        Filter src
                      </.ui_button>
                    </div>
                  </div>

                  <div class="min-w-0 rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
                    <div class="text-[10px] uppercase tracking-wider text-sr-muted">
                      Destination
                    </div>
                    <div class="mt-1 break-all font-mono text-sm leading-snug text-sr-ink">
                      {@dst_ip}{if @dst_port, do: ":#{@dst_port}", else: ""}
                    </div>
                    <div :if={@dst_cc} class="mt-1 text-xs text-sr-muted">
                      <span class="mr-1">{country_flag_emoji(@dst_cc)}</span>
                      <span class="font-mono">{@dst_cc}</span>
                      <span :if={geo = Map.get(@context, :dst_geo)} class="ml-2">
                        <%= if is_binary(geo.country_name) and geo.country_name != "" do %>
                          {geo.country_name}
                        <% end %>
                      </span>
                    </div>
                    <div :if={@service_label} class="mt-1 text-xs text-sr-muted">
                      Service: <span class="font-mono">{@service_label}</span>
                    </div>
                    <div
                      :if={is_binary(@dst_provider) and @dst_provider != ""}
                      class="mt-1 text-xs text-sr-muted"
                    >
                      Provider: <span class="font-mono">{@dst_provider}</span>
                    </div>
                    <PrefixTagChips.static
                      tags={@dst_prefix_tags}
                      wrapper_class="mt-1 flex flex-wrap gap-1"
                    />
                    <div class="mt-2 flex flex-wrap gap-2">
                      <.ui_button
                        size="xs"
                        variant="ghost"
                        phx-click="netflow_modal_filter"
                        phx-value-field="dst_ip"
                        phx-value-value={@dst_ip}
                      >
                        Filter dst
                      </.ui_button>
                      <.ui_button
                        :if={@dst_port}
                        size="xs"
                        variant="ghost"
                        phx-click="netflow_modal_filter"
                        phx-value-field="dst_port"
                        phx-value-value={to_string(@dst_port)}
                      >
                        Filter port
                      </.ui_button>
                    </div>
                  </div>
                </div>
              </div>

              <div class="p-4">
                <div class="text-xs uppercase tracking-wider text-sr-muted">Traffic</div>
                <div class="mt-2 grid grid-cols-1 sm:grid-cols-2 gap-3">
                  <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
                    <div class="text-[10px] uppercase tracking-wider text-sr-muted">Flow</div>
                    <div class="mt-1 flex flex-wrap items-center gap-2">
                      <.netflow_protocol_badge
                        protocol={netflow_protocol_num(@flow)}
                        name={netflow_protocol_name(@flow)}
                      />
                      <.netflow_flow_type_badge flow_type={netflow_flow_type(@flow)} />
                    </div>
                    <div
                      :if={is_binary(@direction_label) and @direction_label != ""}
                      class="mt-1 text-[11px] text-sr-muted"
                    >
                      direction: <span class="font-mono">{@direction_label}</span>
                    </div>
                  </div>
                  <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
                    <div class="text-[10px] uppercase tracking-wider text-sr-muted">
                      Volume
                    </div>
                    <div class="mt-1 flex items-center gap-4">
                      <div>
                        <div class="text-[10px] text-sr-muted">Packets</div>
                        <div class="font-mono text-sm">
                          {format_netflow_number(netflow_packets(@flow))}
                        </div>
                      </div>
                      <div>
                        <div class="text-[10px] text-sr-muted">Bytes</div>
                        <div class="font-mono text-sm">
                          {format_netflow_bytes(netflow_bytes(@flow))}
                        </div>
                      </div>
                    </div>
                  </div>
                </div>

                <div
                  :if={netflow_protocol_num(@flow) |> to_int() == 6}
                  class="mt-3 rounded border border-sr-line bg-sr-surface/60 p-2"
                >
                  <% flag_set = MapSet.new(Enum.map(@tcp_flags_labels, &String.upcase(to_string(&1)))) %>
                  <div class="text-[10px] uppercase tracking-wide text-sr-muted">
                    TCP Flags
                  </div>
                  <div class="mt-1 flex flex-wrap gap-1">
                    <%= for flag <- ["CWR", "ECE", "URG", "ACK", "PSH", "RST", "SYN", "FIN"] do %>
                      <% active = MapSet.member?(flag_set, flag) %>
                      <span class="sr-ui-tooltip sr-ui-tooltip-top" data-tip={tcp_flag_tooltip(flag)}>
                        <span class={[
                          "inline-flex h-5 min-w-6 items-center justify-center rounded border px-1 text-[10px] font-mono cursor-help",
                          if(active,
                            do: "border-sr-brand bg-sr-brand/15 text-sr-brand",
                            else: "border-sr-line text-sr-muted"
                          )
                        ]}>
                          {flag}
                        </span>
                      </span>
                    <% end %>
                  </div>
                  <div
                    :if={not is_nil(@tcp_flags_raw) and @tcp_flags_labels == []}
                    class="mt-1 text-[10px] text-sr-muted"
                  >
                    raw mask: <span class="font-mono">{@tcp_flags_raw}</span>
                  </div>
                </div>
              </div>

              <div class="p-4">
                <div class="text-xs uppercase tracking-wider text-sr-muted">Map</div>
                <%= if @mapbox && @mapbox.enabled &&
                      is_binary(Map.get(@mapbox, :access_token)) &&
                      String.trim(Map.get(@mapbox, :access_token)) != "" do %>
                  <div class="mt-2 rounded-lg overflow-hidden border border-sr-line bg-sr-subtle/30">
                    <div
                      id={netflow_map_dom_id(@flow)}
                      class="h-64 w-full"
                      phx-hook="MapboxFlowMap"
                      phx-update="ignore"
                      data-enabled="true"
                      data-access-token={Map.get(@mapbox, :access_token) || ""}
                      data-style-light={
                        Map.get(@mapbox, :style_light) || "mapbox://styles/mapbox/light-v11"
                      }
                      data-style-dark={
                        Map.get(@mapbox, :style_dark) || "mapbox://styles/mapbox/dark-v11"
                      }
                      data-markers={Jason.encode!(@map_markers)}
                    >
                    </div>
                  </div>
                  <div class="mt-1 text-xs text-sr-muted">
                    <%= if @map_markers != [] do %>
                      Tip: click markers for details.
                    <% else %>
                      No GeoIP coordinates available for this flow yet (showing default map).
                    <% end %>
                  </div>
                <% else %>
                  <div class="mt-2 text-sm text-sr-muted">
                    Mapbox is disabled or missing an access token.
                  </div>
                <% end %>
              </div>
            </div>
          </.ui_panel>

          <.ui_panel class="min-h-0 min-w-0 max-h-full overflow-y-auto lg:col-span-1">
            <div>
              <div class="text-xs font-medium uppercase tracking-wider text-sr-muted">
                Security and Enrichment
              </div>

              <div class="mt-3 space-y-4 text-xs leading-relaxed">
                <div>
                  <div class="font-semibold">Process attribution</div>
                  <%= if is_map(@attribution) do %>
                    <div class="mt-1 text-sr-muted">
                      Process:
                      <span class="font-mono">
                        {netflow_attribution_process_label(@attribution)}
                      </span>
                    </div>
                    <div class="mt-1 text-sr-muted">
                      Agent:
                      <span class="font-mono">
                        {display_text(netflow_attribution_agent_id(@flow))}
                      </span>
                    </div>
                    <div class="mt-1 text-sr-muted">
                      Workload:
                      <span class="font-mono">
                        {display_text(netflow_attribution_workload_label(@attribution))}
                      </span>
                    </div>
                    <div class="mt-2 flex flex-wrap gap-2">
                      <.ui_button href={attributed_flow_path(@flow)} variant="ghost" size="xs">
                        <.icon name="hero-cpu-chip" class="size-3.5" /> Attributed Flow
                      </.ui_button>
                    </div>
                  <% else %>
                    <div class="mt-1 text-sr-muted">
                      <.ui_badge size="xs" variant="ghost">no match</.ui_badge>
                      <span class="ml-2">No process context is attached to this flow row.</span>
                    </div>
                  <% end %>
                </div>

                <div>
                  <div class="font-semibold">GeoIP / ASN</div>
                  <.netflow_geoip_asn_line side="Source" geo={Map.get(@context, :src_geo)} />
                  <.netflow_geoip_asn_line side="Dest" geo={Map.get(@context, :dst_geo)} />
                </div>

                <div>
                  <div class="font-semibold">Threat intel</div>
                  <div class="mt-1 text-sr-muted">
                    Source: <span class="font-mono">{@src_ip}</span>
                    <%= if match = Map.get(@context, :src_threat) do %>
                      <.ui_badge size="xs" variant="warning" class="ml-2">match</.ui_badge>
                      <span class="ml-2 font-mono">
                        {match.match_count} indicators
                      </span>
                    <% else %>
                      <.ui_badge size="xs" variant="ghost" class="ml-2">none</.ui_badge>
                    <% end %>
                  </div>
                  <div class="mt-1 text-sr-muted">
                    Dest: <span class="font-mono">{@dst_ip}</span>
                    <%= if match = Map.get(@context, :dst_threat) do %>
                      <.ui_badge size="xs" variant="warning" class="ml-2">match</.ui_badge>
                      <span class="ml-2 font-mono">
                        {match.match_count} indicators
                      </span>
                    <% else %>
                      <.ui_badge size="xs" variant="ghost" class="ml-2">none</.ui_badge>
                    <% end %>
                  </div>
                </div>

                <div>
                  <div class="font-semibold">Port scan</div>
                  <%= if scan = Map.get(@context, :src_port_scan) do %>
                    <div class="mt-1 text-sr-muted">
                      <.ui_badge size="xs" variant="error">flagged</.ui_badge>
                      <span class="ml-2 font-mono">{scan.unique_ports} unique ports</span>
                    </div>
                  <% else %>
                    <div class="mt-1 text-sr-muted">
                      <.ui_badge size="xs" variant="ghost">not flagged</.ui_badge>
                    </div>
                  <% end %>
                </div>

                <div :if={anomaly = Map.get(@context, :dst_port_anomaly)}>
                  <div class="font-semibold">Port anomaly</div>
                  <div class="mt-1 text-sr-muted">
                    <.ui_badge size="xs" variant="error">anomalous</.ui_badge>
                    <span class="ml-2 font-mono">
                      {format_netflow_bytes(anomaly.current_bytes)} vs baseline {format_netflow_bytes(
                        anomaly.baseline_bytes
                      )}
                    </span>
                  </div>
                </div>

                <div>
                  <div class="font-semibold">ipinfo.io/lite</div>
                  <%= if info = Map.get(@context, :src_ipinfo) do %>
                    <div class="mt-1 text-sr-muted">
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
                            class={[
                              "ml-2 font-mono underline decoration-dotted underline-offset-2 hover:text-sr-brand",
                              Map.get(@arin_lookup || %{}, :asn) == info.as_number && "text-sr-brand"
                            ]}
                          >
                            AS{info.as_number}
                          </button>
                        <% end %>
                        <%= if is_binary(info.as_name) and info.as_name != "" do %>
                          <span class="ml-2 text-sr-muted">{info.as_name}</span>
                        <% end %>
                      </span>
                    </div>
                  <% else %>
                    <div class="mt-1 text-sr-muted">
                      Source: <span class="text-sr-muted">n/a</span>
                    </div>
                  <% end %>

                  <%= if info = Map.get(@context, :dst_ipinfo) do %>
                    <div class="mt-1 text-sr-muted">
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
                            class={[
                              "ml-2 font-mono underline decoration-dotted underline-offset-2 hover:text-sr-brand",
                              Map.get(@arin_lookup || %{}, :asn) == info.as_number && "text-sr-brand"
                            ]}
                          >
                            AS{info.as_number}
                          </button>
                        <% end %>
                        <%= if is_binary(info.as_name) and info.as_name != "" do %>
                          <span class="ml-2 text-sr-muted">{info.as_name}</span>
                        <% end %>
                      </span>
                    </div>
                  <% else %>
                    <div class="mt-1 text-sr-muted">
                      Dest: <span class="text-sr-muted">n/a</span>
                    </div>
                  <% end %>
                </div>

                <div>
                  <div class="font-semibold">ARIN ASN lookup</div>
                  <div class="mt-1 text-sr-muted">
                    Click any AS number above to load ARIN details.
                  </div>
                  <%= if is_binary(Map.get(@arin_lookup || %{}, :error)) and Map.get(@arin_lookup || %{}, :error) != "" do %>
                    <div class="mt-1 text-rose-400">{Map.get(@arin_lookup, :error)}</div>
                  <% end %>
                  <%= if data = Map.get(@arin_lookup || %{}, :data) do %>
                    <div class="mt-2 rounded-lg border border-sr-line bg-sr-subtle/30 p-2 text-[11px] font-mono space-y-1">
                      <div>
                        {data.handle} {if is_binary(data.name), do: "- #{data.name}", else: ""}
                      </div>
                      <div :if={is_binary(data.org_name) and data.org_name != ""}>
                        org: {data.org_name}
                      </div>
                      <div :if={is_binary(data.range) and data.range != ""}>range: {data.range}</div>
                      <div :if={is_binary(data.registration_date) and data.registration_date != ""}>
                        registered: {data.registration_date}
                      </div>
                      <div :if={is_binary(data.update_date) and data.update_date != ""}>
                        updated: {data.update_date}
                      </div>
                      <div :if={is_binary(data.ref) and data.ref != ""}>
                        whois:
                        <a
                          href={data.ref}
                          target="_blank"
                          rel="noopener noreferrer"
                          class="text-sr-brand hover:underline"
                        >
                          {data.ref}
                        </a>
                      </div>
                    </div>
                  <% end %>
                </div>

                <div>
                  <div class="font-semibold">rDNS</div>
                  <%= if rdns = Map.get(@context, :src_rdns) do %>
                    <div class="mt-1 text-sr-muted">
                      Source:
                      <span class="font-mono">
                        <%= if rdns.status == "ok" and is_binary(rdns.hostname) and rdns.hostname != "" do %>
                          {rdns.hostname}
                        <% else %>
                          <span class="text-sr-muted">n/a</span>
                        <% end %>
                      </span>
                    </div>
                  <% else %>
                    <div class="mt-1 text-sr-muted">
                      Source: <span class="text-sr-muted">n/a</span>
                    </div>
                  <% end %>

                  <%= if rdns = Map.get(@context, :dst_rdns) do %>
                    <div class="mt-1 text-sr-muted">
                      Dest:
                      <span class="font-mono">
                        <%= if rdns.status == "ok" and is_binary(rdns.hostname) and rdns.hostname != "" do %>
                          {rdns.hostname}
                        <% else %>
                          <span class="text-sr-muted">n/a</span>
                        <% end %>
                      </span>
                    </div>
                  <% else %>
                    <div class="mt-1 text-sr-muted">
                      Dest: <span class="text-sr-muted">n/a</span>
                    </div>
                  <% end %>
                </div>

                <% as_path = netflow_bgp_as_path(@flow) %>
                <% bgp_communities = netflow_bgp_communities(@flow) %>
                <%= if as_path || bgp_communities do %>
                  <div class="pt-3 border-t border-sr-line mt-3">
                    <div class="font-semibold">BGP Routing</div>

                    <%= if as_path do %>
                      <div class="mt-2">
                        <div class="text-[10px] uppercase tracking-wider text-sr-muted">
                          AS Path ({length(as_path)} hops)
                        </div>
                        <div class="mt-1 font-mono text-xs text-sr-ink/90 break-all">
                          {format_bgp_as_path(as_path)}
                        </div>
                      </div>
                    <% end %>

                    <%= if bgp_communities do %>
                      <div class="mt-2">
                        <div class="text-[10px] uppercase tracking-wider text-sr-muted">
                          BGP Communities
                        </div>
                        <div class="mt-1 flex flex-wrap gap-1">
                          <%= for community <- bgp_communities do %>
                            <.ui_badge size="sm" variant="outline" class="font-mono">
                              {format_bgp_community(community)}
                            </.ui_badge>
                          <% end %>
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          </.ui_panel>
        </div>
      </div>

      <form method="dialog" class="sr-ui-modal-backdrop">
        <button phx-click="netflow_close">close</button>
      </form>
    </dialog>
    """
  end

  attr(:protocol, :any, default: nil)
  attr(:name, :any, default: nil)

  defp netflow_protocol_badge(assigns) do
    protocol = assigns.protocol
    name = assigns.name
    protocol_num = to_int(protocol)

    {label, variant} = netflow_protocol_label_variant(protocol_num, protocol, name)

    assigns = assign(assigns, label: label, variant: variant)

    ~H"""
    <.ui_badge variant={@variant}>{@label}</.ui_badge>
    """
  end

  defp netflow_protocol_label_variant(6, _protocol, _name), do: {"TCP", "success"}
  defp netflow_protocol_label_variant(17, _protocol, _name), do: {"UDP", "info"}
  defp netflow_protocol_label_variant(1, _protocol, _name), do: {"ICMP", "ghost"}

  defp netflow_protocol_label_variant(_protocol_num, protocol, name) do
    label =
      cond do
        is_binary(name) and name != "" -> String.upcase(name)
        is_binary(protocol) and protocol != "" -> protocol
        true -> "Unknown"
      end

    {label, "ghost"}
  end

  defp netflow_flow_type_badge(assigns) do
    flow_type = assigns.flow_type

    {label, variant} =
      case flow_type do
        "SFLOW_5" -> {"sFlow v5", "primary"}
        "NETFLOW_V5" -> {"v5", "warning"}
        "NETFLOW_V9" -> {"v9", "info"}
        "IPFIX" -> {"IPFIX", "success"}
        nil -> {"Unknown", "ghost"}
        other -> {other, "ghost"}
      end

    assigns = assign(assigns, label: label, variant: variant)

    ~H"""
    <.ui_badge variant={@variant}>{@label}</.ui_badge>
    """
  end

  defp netflow_addr(flow, :src), do: netflow_value(flow, ["src_endpoint_ip", "src_addr"]) || "—"

  defp netflow_addr(flow, :dst), do: netflow_value(flow, ["dst_endpoint_ip", "dst_addr"]) || "—"

  defp netflow_port(flow, :src), do: netflow_value(flow, ["src_endpoint_port", "src_port"])
  defp netflow_port(flow, :dst), do: netflow_value(flow, ["dst_endpoint_port", "dst_port"])

  defp netflow_protocol_num(flow), do: netflow_value(flow, ["protocol_num", "protocol"])
  defp netflow_protocol_name(flow), do: netflow_value(flow, ["protocol_name"])

  defp netflow_packets(flow) do
    total = flow |> netflow_value(["packets_total", "packets"]) |> to_int()

    if total > 0 do
      total
    else
      flow
      |> netflow_value(["packets_in"])
      |> to_int()
      |> Kernel.+(to_int(netflow_value(flow, ["packets_out"])))
    end
  end

  defp netflow_bytes(flow), do: netflow_value(flow, ["bytes_total", "octets"])

  defp netflow_flow_type(flow) do
    payload =
      case Map.get(flow, "ocsf_payload") do
        %{} = data -> data
        _ -> nil
      end

    flow_type =
      if is_map(payload) do
        get_in(payload, ["unmapped", "flow_type"]) || get_in(payload, ["flow_type"])
      end

    case flow_type do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp netflow_attribution(flow) when is_map(flow) do
    case flow |> Map.get("ocsf_payload") |> flow_get_in(["attribution"]) do
      %{} = attribution when map_size(attribution) > 0 -> attribution
      _ -> nil
    end
  end

  defp netflow_attribution(_flow), do: nil

  defp netflow_attribution_process_label(%{} = attribution) do
    comm = attribution |> flow_get_in(["comm"]) |> clean_display_value()
    pid = attribution |> flow_get_in(["pid"]) |> clean_display_value()

    cond do
      is_binary(comm) and is_binary(pid) -> "#{comm} ##{pid}"
      is_binary(comm) -> comm
      is_binary(pid) -> "PID #{pid}"
      true -> "No process match"
    end
  end

  defp netflow_attribution_process_label(_), do: "No process match"

  defp netflow_attribution_agent_id(flow) when is_map(flow) do
    payload = Map.get(flow, "ocsf_payload") || %{}
    clean_display_value(Map.get(payload, "agent_id") || flow_get_in(payload, ["metadata", "agent_id"]))
  end

  defp netflow_attribution_agent_id(_), do: nil

  defp netflow_attribution_workload_label(%{} = attribution) do
    workload = flow_get_in(attribution, ["workload_identity"]) || %{}
    ns = workload |> flow_get_in(["pod_namespace"]) |> clean_display_value()
    pod = workload |> flow_get_in(["pod_name"]) |> clean_display_value()
    container = workload |> flow_get_in(["container_name"]) |> clean_display_value()

    cond do
      is_binary(ns) and is_binary(pod) -> "#{ns}/#{pod}"
      is_binary(pod) -> pod
      is_binary(container) -> container
      true -> nil
    end
  end

  defp netflow_attribution_workload_label(_), do: nil

  defp attributed_flow_path(flow) do
    "/observability/flows/attributed?" <>
      URI.encode_query(%{
        q: attributed_flow_query(flow),
        filter: "all",
        per_page: 50
      })
  end

  defp attributed_flow_query(flow) do
    [
      "in:attributed_flows",
      "time:last_24h",
      "sort:time:desc",
      maybe_srql_token("src_endpoint_ip", netflow_addr(flow, :src)),
      maybe_srql_token("dst_endpoint_ip", netflow_addr(flow, :dst)),
      maybe_srql_token("src_endpoint_port", netflow_port(flow, :src)),
      maybe_srql_token("dst_endpoint_port", netflow_port(flow, :dst)),
      maybe_srql_token("protocol_num", netflow_protocol_num(flow))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp maybe_srql_token(_field, nil), do: nil
  defp maybe_srql_token(_field, ""), do: nil
  defp maybe_srql_token(field, value), do: "#{field}:#{srql_literal(value)}"

  defp srql_literal(value) when is_integer(value), do: Integer.to_string(value)

  defp srql_literal(value) do
    value = to_string(value)

    if String.match?(value, ~r/^[A-Za-z0-9_.:\/-]+$/) do
      value
    else
      inspect(value)
    end
  end

  defp display_text(value), do: clean_display_value(value) || "-"

  defp clean_display_value(nil), do: nil
  defp clean_display_value(""), do: nil

  defp clean_display_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp clean_display_value(value), do: to_string(value)

  defp netflow_value(flow, keys) when is_map(flow) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      value = Map.get(flow, key)
      if is_nil(value) or value == "", do: nil, else: value
    end)
  end

  defp netflow_value(_flow, _keys), do: nil

  defp netflow_present?(nil), do: false
  defp netflow_present?(""), do: false

  defp netflow_present?(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> false
      "—" -> false
      "-" -> false
      _ -> true
    end
  end

  defp netflow_present?(_), do: false

  defp netflow_map_markers(context, flow) when is_map(context) and is_map(flow) do
    MapMarkers.netflow_map_markers(context, flow)
  end

  defp netflow_map_markers(_context, _flow), do: []

  defp netflow_map_dom_id(flow) when is_map(flow) do
    src = to_string(netflow_addr(flow, :src) || "")
    dst = to_string(netflow_addr(flow, :dst) || "")
    sp = to_string(netflow_port(flow, :src) || "")
    dp = to_string(netflow_port(flow, :dst) || "")
    ts = to_string(Map.get(flow, "time") || Map.get(flow, :time) || "")
    digest = :erlang.phash2({src, dst, sp, dp, ts})
    "netflow-flow-map-#{digest}"
  end

  defp netflow_map_dom_id(_), do: "netflow-flow-map"

  defp netflow_asn(flow, :src) when is_map(flow) do
    case to_int(netflow_value(flow, ["src_as_number", "src_asn"])) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  defp netflow_asn(flow, :dst) when is_map(flow) do
    case to_int(netflow_value(flow, ["dst_as_number", "dst_asn"])) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  defp netflow_asn(_flow, _side), do: nil

  defp netflow_country_iso2(flow, :src) when is_map(flow) do
    value = netflow_value(flow, ["src_country_iso2", "src_country"])
    normalize_iso2(value)
  end

  defp netflow_country_iso2(flow, :dst) when is_map(flow) do
    value = netflow_value(flow, ["dst_country_iso2", "dst_country"])
    normalize_iso2(value)
  end

  defp netflow_country_iso2(_flow, _side), do: nil

  # BGP data extraction
  defp netflow_bgp_as_path(flow) when is_map(flow) do
    case netflow_value(flow, ["as_path"]) do
      path when is_list(path) and path != [] -> path
      _ -> nil
    end
  end

  defp netflow_bgp_communities(flow) when is_map(flow) do
    case netflow_value(flow, ["bgp_communities"]) do
      communities when is_list(communities) and communities != [] -> communities
      _ -> nil
    end
  end

  # Format AS path as "AS1 → AS2 → AS3"
  defp format_bgp_as_path([]), do: nil

  defp format_bgp_as_path(path) when is_list(path) do
    Enum.map_join(path, " → ", &to_string/1)
  end

  # Format BGP community (decode 32-bit integer to AS:value format)
  defp format_bgp_community(community) when is_integer(community) do
    # Well-known communities (RFC 1997)
    case community do
      0xFFFFFF01 ->
        "NO_EXPORT"

      0xFFFFFF02 ->
        "NO_ADVERTISE"

      0xFFFFFF03 ->
        "NO_EXPORT_SUBCONFED"

      val when val > 0xFFFF0000 ->
        "RESERVED (#{val})"

      val ->
        # Standard format: upper 16 bits = AS, lower 16 bits = value
        as_num = Bitwise.bsr(val, 16)
        value = Bitwise.band(val, 0xFFFF)
        "#{as_num}:#{value}"
    end
  end

  defp format_bgp_community(community) when is_binary(community) do
    case Integer.parse(community) do
      {int_val, ""} -> format_bgp_community(int_val)
      _ -> community
    end
  end

  defp format_bgp_community(_), do: "—"

  defp normalize_iso2(value) when is_binary(value) do
    value = value |> String.trim() |> String.upcase()

    if String.length(value) == 2 and value =~ ~r/^[A-Z]{2}$/ do
      value
    end
  end

  defp normalize_iso2(nil), do: nil
  defp normalize_iso2(_), do: nil

  # Render country as a flag icon without adding an asset pipeline dependency.
  # Uses Unicode Regional Indicator Symbols.
  defp iso2_flag_emoji(iso2) when is_binary(iso2) do
    iso2 = iso2 |> String.trim() |> String.upcase()

    with true <- String.length(iso2) == 2,
         true <- iso2 =~ ~r/^[A-Z]{2}$/ do
      [a, b] = String.to_charlist(iso2)
      # 127_397 is the Regional Indicator Symbol offset.
      <<a + 127_397::utf8, b + 127_397::utf8>>
    else
      _ -> nil
    end
  end

  defp iso2_flag_emoji(_), do: nil

  defp parse_netflow_talker_cidr(nil), do: nil
  defp parse_netflow_talker_cidr(""), do: nil

  defp parse_netflow_talker_cidr(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n in [16, 24] -> n
      _ -> nil
    end
  end

  defp parse_netflow_talker_cidr(_), do: nil

  defp parse_netflow_compare_mode(nil), do: "off"
  defp parse_netflow_compare_mode(""), do: "off"

  defp parse_netflow_compare_mode(value) when is_binary(value) do
    case String.trim(String.downcase(value)) do
      "off" -> "off"
      "previous" -> "previous"
      "yesterday" -> "yesterday"
      _ -> "off"
    end
  end

  defp parse_netflow_compare_mode(_), do: "off"

  defp parse_netflow_geo_side(nil), do: "dst"
  defp parse_netflow_geo_side(""), do: "dst"

  defp parse_netflow_geo_side(value) when is_binary(value) do
    case String.trim(String.downcase(value)) do
      "src" -> "src"
      "dst" -> "dst"
      _ -> "dst"
    end
  end

  defp parse_netflow_geo_side(_), do: "dst"

  defp parse_netflow_sankey_prefix(nil), do: 24
  defp parse_netflow_sankey_prefix(""), do: 24

  defp parse_netflow_sankey_prefix(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n in [16, 24] -> n
      _ -> 24
    end
  end

  defp parse_netflow_sankey_prefix(_), do: 24

  defp parse_netflow_stack_mode(nil), do: @default_netflow_stack_mode
  defp parse_netflow_stack_mode(""), do: @default_netflow_stack_mode

  defp parse_netflow_stack_mode(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "talkers" -> "talkers"
      "ports" -> "ports"
      _ -> @default_netflow_stack_mode
    end
  end

  defp parse_netflow_stack_mode(_), do: @default_netflow_stack_mode

  defp parse_netflow_graph_mode(nil), do: "stacked"
  defp parse_netflow_graph_mode(""), do: "stacked"

  defp parse_netflow_graph_mode(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "stacked" -> "stacked"
      "stacked100" -> "stacked100"
      "lines" -> "lines"
      "grid" -> "grid"
      "sankey" -> "sankey"
      _ -> "stacked"
    end
  end

  defp parse_netflow_graph_mode(_), do: "stacked"

  defp parse_netflow_view(nil), do: "overview"
  defp parse_netflow_view(""), do: "overview"

  defp parse_netflow_view(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "overview" -> "overview"
      "traffic" -> "traffic"
      "topology" -> "topology"
      "talkers" -> "talkers"
      "explorer" -> "explorer"
      "all" -> "all"
      _ -> "overview"
    end
  end

  defp parse_netflow_view(_), do: "overview"

  defp cidr_to_like_prefix(nil, _cidr), do: ""
  defp cidr_to_like_prefix("", _cidr), do: ""
  defp cidr_to_like_prefix("Unknown", _cidr), do: ""

  defp cidr_to_like_prefix(value, cidr) when is_binary(value) and cidr in [16, 24] do
    # For /24 and /16, approximate the subnet as a string prefix match against src_endpoint_ip.
    # This relies on SRQL's '%' wildcard mapping to ILIKE.
    case String.split(value, "/") do
      [ip, _mask] ->
        parts = String.split(ip, ".")

        case {cidr, parts} do
          {24, [a, b, c, _]} -> Enum.join([a, b, c], ".") <> ".%"
          {16, [a, b, _, _]} -> Enum.join([a, b], ".") <> ".%"
          _ -> value
        end

      _ ->
        value
    end
  end

  defp cidr_to_like_prefix(value, _cidr) when is_binary(value), do: value

  defp netflow_talker_cidr_patch(_base_path, query, limit, %{} = opts) do
    ObservabilityPaths.path("netflows", netflow_params(query, limit, opts))
  end

  defp netflow_params(query, limit, %{} = opts) do
    compact? = Map.get(opts, :compact?, false)
    talker_cidr = Map.get(opts, :talker_cidr)
    compare_mode = Map.get(opts, :compare_mode, "off")
    geo_side = Map.get(opts, :geo_side, "dst")
    sankey_prefix = Map.get(opts, :sankey_prefix, 24)
    stack_mode = Map.get(opts, :stack_mode, @default_netflow_stack_mode)
    graph_mode = Map.get(opts, :graph_mode, "stacked")
    view = Map.get(opts, :view, "overview")

    # Intent URL path encodes tab; query holds q + view chrome only.
    %{}
    |> maybe_put_param(:q, query)
    |> maybe_put_param(:limit, netflow_legacy_limit(query, limit))
    |> maybe_put_param(:compact, if(compact?, do: "1"))
    |> maybe_put_param(
      :talker_cidr,
      if(is_integer(talker_cidr), do: to_string(talker_cidr))
    )
    |> maybe_put_param(
      :compare,
      if(compare_mode in ["previous", "yesterday"], do: compare_mode)
    )
    |> maybe_put_param(:geo, if(geo_side in ["src", "dst"], do: geo_side))
    |> maybe_put_param(
      :sankey_prefix,
      if(is_integer(sankey_prefix) and sankey_prefix in [16, 24],
        do: to_string(sankey_prefix)
      )
    )
    |> maybe_put_param(
      :stack,
      if(stack_mode in ["ports", "talkers"], do: stack_mode)
    )
    |> maybe_put_param(
      :graph,
      if(graph_mode in ["stacked", "stacked100", "lines", "grid", "sankey"],
        do: graph_mode
      )
    )
    |> maybe_put_param(
      :view,
      if(view in ["overview", "traffic", "topology", "talkers", "explorer", "all"],
        do: view
      )
    )
  end

  defp netflow_filter_patch(_base_path, query, limit, field, value, opts) do
    value = (value || "") |> to_string() |> String.trim()
    value = if value in ["—", "-"], do: "", else: value

    query =
      if String.downcase(field) == "time" do
        replace_netflow_time(query || "", value)
      else
        upsert_query_filter(query || "", field, value)
      end

    params = netflow_params(query, limit, opts)
    ObservabilityPaths.path("netflows", params)
  end

  defp netflow_legacy_limit(query, limit) when is_binary(query) and is_integer(limit) and limit > 0 do
    if Regex.match?(~r/(?:^|\s)limit:\d+(?=\s|$)/i, query), do: nil, else: Integer.to_string(limit)
  end

  defp netflow_legacy_limit(_query, _limit), do: nil

  defp netflow_prefix_tags(flow, side) when side in [:src, :dst] do
    prefix = to_string(side)

    tags =
      flow_get(flow, ["#{prefix}_prefix_tags"]) ||
        flow_get_in(flow, ["ocsf_payload", "enrichment", "#{prefix}_prefix_tags"])

    PrefixTagChips.normalize_tags(tags, 4)
  end

  defp netflow_linked_tag_items(tags, base_path, query, limit, patch_opts) do
    Enum.map(tags, fn tag ->
      %{
        tag: tag,
        path: netflow_filter_patch(base_path, query, limit, "tag", tag, patch_opts)
      }
    end)
  end

  defp upsert_query_filter(query, field, value) when is_binary(query) and is_binary(field) do
    pattern = ~r/(?:^|\s)#{Regex.escape(field)}:(?:"([^"]+)"|(\S+))/

    query =
      query
      |> String.replace(pattern, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if String.trim(value) == "" do
      query
    else
      String.trim(query <> " " <> "#{field}:#{value}")
    end
  end

  defp replace_netflow_time(query, value) when is_binary(query) and is_binary(value) do
    query
    |> split_srql_tokens()
    |> Enum.reject(&(srql_token_key(&1) in ["time", "timeframe"]))
    |> Kernel.++(["time:#{String.trim(value)}"])
    |> Enum.join(" ")
  end

  defp split_srql_tokens(query) do
    {tokens, current, _quote, _escaped?} =
      query
      |> String.graphemes()
      |> Enum.reduce({[], "", nil, false}, &split_srql_token/2)

    tokens = if current == "", do: tokens, else: [current | tokens]
    Enum.reverse(tokens)
  end

  defp split_srql_token(char, {tokens, current, quote, true}) do
    {tokens, current <> char, quote, false}
  end

  defp split_srql_token("\\", {tokens, current, quote, false}) when not is_nil(quote) do
    {tokens, current <> "\\", quote, true}
  end

  defp split_srql_token(char, {tokens, current, quote, false}) when char == quote and not is_nil(quote) do
    {tokens, current <> char, nil, false}
  end

  defp split_srql_token(char, {tokens, current, quote, false}) when not is_nil(quote) do
    {tokens, current <> char, quote, false}
  end

  defp split_srql_token(char, {tokens, current, nil, false}) when char in ["\"", "'"] do
    {tokens, current <> char, char, false}
  end

  defp split_srql_token(char, {tokens, current, nil, false}) when char in [" ", "\n", "\r", "\t"] do
    if current == "" do
      {tokens, "", nil, false}
    else
      {[current | tokens], "", nil, false}
    end
  end

  defp split_srql_token(char, {tokens, current, quote, escaped?}) do
    {tokens, current <> char, quote, escaped?}
  end

  defp srql_token_key(token) when is_binary(token) do
    token
    |> String.trim_leading("!")
    |> String.split(":", parts: 2)
    |> case do
      [key, _value] -> String.downcase(key)
      _token -> nil
    end
  end

  defp netflow_service_label(nil), do: nil
  defp netflow_service_label(""), do: nil

  defp netflow_service_label(port) do
    port
    |> to_int()
    |> ServicePorts.label()
  end

  defp netflow_service_label(flow, port) do
    protocol_num = flow |> netflow_protocol_num() |> to_int()
    port = to_int(port)

    ServicePorts.label(protocol_num, port) || ServicePorts.label(port)
  end

  defp format_netflow_bytes(nil), do: "0 B"

  defp format_netflow_bytes(bytes) when is_binary(bytes) do
    case Integer.parse(bytes) do
      {value, _} -> format_netflow_bytes(value)
      _ -> "—"
    end
  end

  defp format_netflow_bytes(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"

  defp format_netflow_bytes(bytes) when is_integer(bytes) and bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_netflow_bytes(bytes) when is_integer(bytes) and bytes < 1_073_741_824,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_netflow_bytes(bytes) when is_integer(bytes), do: "#{Float.round(bytes / 1_073_741_824, 2)} GB"

  defp format_netflow_bytes(_), do: "—"

  defp format_netflow_bps(nil), do: "0 bps"

  defp format_netflow_bps(value) when is_integer(value) do
    format_netflow_bps(value * 1.0)
  end

  defp format_netflow_bps(value) when is_float(value) do
    cond do
      value >= 1_000_000_000 -> "#{Float.round(value / 1_000_000_000, 2)} Gbps"
      value >= 1_000_000 -> "#{Float.round(value / 1_000_000, 2)} Mbps"
      value >= 1_000 -> "#{Float.round(value / 1_000, 1)} Kbps"
      value >= 0 -> "#{Float.round(value, 0)} bps"
      true -> "—"
    end
  end

  defp format_netflow_bps(_), do: "—"

  defp format_netflow_pps(nil), do: "0 pps"

  defp format_netflow_pps(value) when is_integer(value) do
    format_netflow_pps(value * 1.0)
  end

  defp format_netflow_pps(value) when is_float(value) do
    cond do
      value >= 1_000_000 -> "#{Float.round(value / 1_000_000, 2)} Mpps"
      value >= 1_000 -> "#{Float.round(value / 1_000, 1)} Kpps"
      value >= 10 -> "#{Float.round(value, 0)} pps"
      value >= 1 -> "#{Float.round(value, 1)} pps"
      value > 0 -> "#{Float.round(value, 2)} pps"
      value == 0 -> "0 pps"
      true -> "—"
    end
  end

  defp format_netflow_pps(_), do: "—"

  defp format_netflow_number(num) when is_integer(num), do: Integer.to_string(num)

  attr(:metric, :map, required: true)
  attr(:sparklines, :map, default: %{})

  defp metric_viz(assigns) do
    metric_type = normalize_string(Map.get(assigns.metric, "metric_type")) || ""
    metric_name = Map.get(assigns.metric, "metric_name")

    # Get sparkline data for this metric
    sparkline_data = Map.get(assigns.sparklines, metric_name, [])

    assigns =
      assigns
      |> assign(:metric_type, metric_type)
      |> assign(:sparkline_data, sparkline_data)

    ~H"""
    <%= case @metric_type do %>
      <% "histogram" -> %>
        <.histogram_viz metric={@metric} />
      <% type when type in ["gauge", "counter"] -> %>
        <%= if length(@sparkline_data) >= 3 do %>
          <.sparkline data={@sparkline_data} />
        <% else %>
          <span class="text-sr-ink/30">—</span>
        <% end %>
      <% "span" -> %>
        <.span_duration_viz metric={@metric} />
      <% _ -> %>
        <span class="text-sr-ink/30">—</span>
    <% end %>
    """
  end

  attr(:data, :list, required: true)

  defp sparkline(assigns) do
    data = Enum.map(assigns.data, &to_number/1)
    min_val = Enum.min(data, fn -> 0.0 end)
    max_val = Enum.max(data, fn -> 0.0 end)
    range = max_val - min_val

    # Normalize to 0-100 range for SVG, with some padding
    points =
      data
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {val, idx} ->
        x = idx / max(length(data) - 1, 1) * 100.0
        # Always floats — Float.round/2 rejects integers (flat series → y=50).
        y = if range > 0.0, do: 100.0 - (val - min_val) / range * 80.0 - 10.0, else: 50.0
        "#{Float.round(x * 1.0, 1)},#{Float.round(y * 1.0, 1)}"
      end)

    # Determine trend color based on first vs last value
    first_val = List.first(data) || 0
    last_val = List.last(data) || 0
    # Explicit stroke colors — daisy stroke-warning/info no longer resolve.
    trend_color = if last_val > first_val * 1.1, do: "stroke-amber-400", else: "stroke-sky-400"

    assigns =
      assigns
      |> assign(:points, points)
      |> assign(:trend_color, trend_color)

    ~H"""
    <svg viewBox="0 0 100 100" class="w-20 h-6" preserveAspectRatio="none">
      <polyline
        points={@points}
        fill="none"
        class={[@trend_color, "opacity-70"]}
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
    """
  end

  attr(:metric, :map, required: true)

  # Duration visualization for span-type metrics
  defp span_duration_viz(assigns) do
    duration_ms = extract_duration_ms(assigns.metric)
    is_slow = Map.get(assigns.metric, "is_slow") == true

    # If no duration, show dash
    if is_nil(duration_ms) or duration_ms <= 0 do
      ~H"""
      <span class="text-sr-ink/30">—</span>
      """
    else
      # Scale 0-1500ms to 0-100% (threshold at 500ms = 33%)
      threshold_ms = 500
      max_display_ms = threshold_ms * 3
      pct = min(duration_ms / max_display_ms * 100, 100)
      threshold_pct = threshold_ms / max_display_ms * 100

      # Color based on duration relative to threshold (no daisy tokens)
      bar_color =
        cond do
          duration_ms <= threshold_ms * 0.5 -> "bg-emerald-400"
          duration_ms <= threshold_ms -> "bg-emerald-400/80"
          duration_ms <= threshold_ms * 1.5 -> "bg-amber-400"
          duration_ms <= threshold_ms * 2 -> "bg-amber-500"
          true -> "bg-rose-500"
        end

      assigns =
        assigns
        |> assign(:pct, pct)
        |> assign(:threshold_pct, threshold_pct)
        |> assign(:bar_color, bar_color)
        |> assign(:is_slow, is_slow)
        |> assign(:duration_ms, duration_ms)

      ~H"""
      <div
        class="flex items-center gap-2 min-w-[5rem]"
        title={"#{Float.round(@duration_ms * 1.0, 1)}ms"}
      >
        <div class="relative h-2 w-16 overflow-visible rounded-sm bg-sr-subtle/60">
          <div class={["h-full rounded-sm", @bar_color]} style={"width: #{@pct}%"}></div>
          <div
            class="absolute top-0 h-full w-px bg-sr-muted/50"
            style={"left: #{@threshold_pct}%"}
            title="500ms threshold"
          >
          </div>
        </div>
        <span :if={@is_slow} class="text-[10px] font-semibold text-amber-400">SLOW</span>
      </div>
      """
    end
  end

  attr(:metric, :map, required: true)

  defp histogram_viz(assigns) do
    # For histograms with duration data, show a duration-based gauge bar
    # Most OTEL histograms are duration distributions
    duration_ms = extract_duration_value(assigns.metric)

    # Use reasonable bounds for duration visualization (0-1000ms as typical range)
    # Anything over 1s will show as full bar
    pct = histogram_pct(duration_ms)
    bar_color = histogram_bar_color(duration_ms)
    title = histogram_title(duration_ms)

    assigns =
      assigns
      |> assign(:pct, pct)
      |> assign(:bar_color, bar_color)
      |> assign(:duration_ms, duration_ms)
      |> assign(:title, title)

    ~H"""
    <div
      class="flex items-center gap-2 w-20"
      title={@title}
    >
      <div class="flex-1 h-1.5 bg-sr-subtle rounded-full overflow-hidden">
        <div class={[@bar_color, "h-full rounded-full transition-all"]} style={"width: #{@pct}%"}>
        </div>
      </div>
    </div>
    """
  end

  defp histogram_pct(duration_ms) do
    cond do
      not is_number(duration_ms) or duration_ms <= 0 -> 0
      duration_ms >= 1000 -> 100
      true -> duration_ms / 10
    end
  end

  defp histogram_bar_color(duration_ms) do
    cond do
      not is_number(duration_ms) or duration_ms <= 0 -> "bg-sr-muted/30"
      duration_ms >= 500 -> "bg-rose-500"
      duration_ms >= 100 -> "bg-amber-400"
      true -> "bg-emerald-400"
    end
  end

  defp histogram_title(duration_ms) do
    if is_number(duration_ms) and duration_ms > 0 do
      "#{Float.round(duration_ms * 1.0, 1)}ms"
    else
      "no duration"
    end
  end

  defp extract_histogram_count(metric) do
    cond do
      is_number(metric["count"]) -> trunc(metric["count"])
      is_binary(metric["count"]) -> trunc(extract_number(metric["count"]) || 0)
      is_number(metric["bucket_count"]) -> trunc(metric["bucket_count"])
      true -> 0
    end
  end

  defp extract_duration_ms(metric), do: duration_ms_from_metric(metric)

  defp metric_type_badge_variant(metric) do
    case metric |> Map.get("metric_type") |> normalize_severity() do
      "histogram" -> "info"
      "gauge" -> "success"
      "counter" -> "primary"
      "span" -> "warning"
      _ -> "ghost"
    end
  end

  # Span performance samples and OTLP metric points are distinct signals;
  # label them so the pane doesn't present slow-span samples as "metrics".
  defp metric_type_label(metric) do
    case metric |> Map.get("metric_type") |> normalize_severity() do
      "" -> "—"
      "span" -> "span sample"
      "sum" -> "sum (cumulative)"
      other -> other
    end
  end

  # Falco/OTLP sums are raw cumulative counters today; rate rendering arrives
  # once otel_metric_points data flows.
  defp cumulative_metric?(metric) do
    normalize_severity(Map.get(metric, "metric_type")) == "sum"
  end

  defp format_metric_value(metric) do
    # Get metric name from multiple possible fields
    metric_name = get_metric_name(metric)
    metric_type = normalize_string(Map.get(metric, "metric_type"))
    # NEW: Check for explicit unit field from backend
    unit = normalize_string(Map.get(metric, "unit"))

    # PRIORITY 0: Histograms are distributions - show sample count, not a single value
    # Trying to show one number for a histogram is misleading
    if metric_type == "histogram" do
      format_histogram_value(metric)
    else
      format_non_histogram_metric(metric, metric_name, metric_type, unit)
    end
  end

  defp format_non_histogram_metric(metric, metric_name, metric_type, unit) do
    with {:error} <- explicit_unit_format(metric, unit),
         {:error} <- named_metric_format(metric, metric_name),
         {:error} <- duration_metric_format(metric, metric_name, metric_type) do
      raw_metric_format(metric, metric_type)
    else
      {:ok, formatted} -> formatted
    end
  end

  defp explicit_unit_format(_metric, nil), do: {:error}
  defp explicit_unit_format(metric, unit), do: {:ok, format_with_explicit_unit(metric, unit)}

  defp named_metric_format(metric, metric_name) do
    cond do
      bytes_metric?(metric_name) ->
        {:ok, format_bytes_value(metric)}

      count_metric?(metric_name) or stats_metric?(metric_name) ->
        {:ok, format_count_value(metric)}

      true ->
        {:error}
    end
  end

  defp duration_metric_format(metric, metric_name, metric_type) do
    cond do
      duration_metric?(metric_name) and has_duration_field?(metric) ->
        {:ok, format_duration_value(metric)}

      metric_type == "span" and has_duration_field?(metric) ->
        {:ok, format_duration_value(metric)}

      actual_timing_span?(metric) and has_duration_field?(metric) ->
        {:ok, format_duration_value(metric)}

      true ->
        {:error}
    end
  end

  defp raw_metric_format(metric, metric_type) do
    if has_any_value?(metric) do
      format_raw_value(metric, metric_type)
    else
      "—"
    end
  end

  # Format metric value using explicit unit field from backend
  defp format_with_explicit_unit(metric, unit) do
    case extract_primary_value(metric) do
      value when is_number(value) -> format_explicit_unit_value(value, unit)
      _ -> "—"
    end
  end

  defp format_explicit_unit_value(value, unit) do
    cond do
      unit in ["ms", "s", "ns", "us"] ->
        format_duration_unit(value, unit)

      unit in ["bytes", "By", "kb", "KiB", "mb", "MiB", "gb", "GiB"] ->
        format_bytes_unit(value, unit)

      unit in ["1", "{request}", "{connection}", "{thread}", "{goroutine}"] ->
        format_count_from_value(value)

      unit == "%" ->
        "#{Float.round(value * 1.0, 1)}%"

      true ->
        "#{format_compact_value(value)} #{unit}"
    end
  end

  defp format_duration_unit(value, "ms"), do: format_ms_value(value)
  defp format_duration_unit(value, "s"), do: format_seconds_value(value)
  defp format_duration_unit(value, "ns"), do: format_ns_value(value)
  defp format_duration_unit(value, "us"), do: format_us_value(value)

  defp format_bytes_unit(value, unit) do
    multiplier =
      case unit do
        "bytes" -> 1
        "By" -> 1
        "kb" -> 1024
        "KiB" -> 1024
        "mb" -> 1024 * 1024
        "MiB" -> 1024 * 1024
        "gb" -> 1024 * 1024 * 1024
        "GiB" -> 1024 * 1024 * 1024
      end

    format_bytes_from_value(value * multiplier)
  end

  defp extract_primary_value(metric) do
    metric_numeric_value(metric, ["value", "duration_ms", "sum", "count"])
  end

  defp format_ms_value(ms) when is_number(ms) do
    cond do
      ms >= 60_000 -> "#{Float.round(ms / 60_000, 1)}m"
      ms >= 1000 -> "#{Float.round(ms / 1000, 2)}s"
      true -> "#{Float.round(ms * 1.0, 1)}ms"
    end
  end

  defp format_seconds_value(s) when is_number(s) do
    ms = s * 1000
    format_ms_value(ms)
  end

  defp format_ns_value(ns) when is_number(ns) do
    ms = ns / 1_000_000
    format_ms_value(ms)
  end

  defp format_us_value(us) when is_number(us) do
    ms = us / 1000
    format_ms_value(ms)
  end

  defp format_bytes_from_value(bytes) when is_number(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776 * 1.0, 1)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824 * 1.0, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576 * 1.0, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024 * 1.0, 1)} KB"
      true -> "#{trunc(bytes)} B"
    end
  end

  defp format_count_from_value(count) when is_number(count) do
    cond do
      count >= 1_000_000 -> "#{Float.round(count / 1_000_000 * 1.0, 1)}M"
      count >= 1_000 -> "#{Float.round(count / 1_000 * 1.0, 1)}k"
      is_float(count) -> "#{trunc(count)}"
      true -> "#{count}"
    end
  end

  defp format_compact_value(value) when is_number(value) do
    cond do
      value >= 1_000_000 -> "#{Float.round(value / 1_000_000 * 1.0, 1)}M"
      value >= 1_000 -> "#{Float.round(value / 1_000 * 1.0, 1)}k"
      is_float(value) -> "#{Float.round(value, 2)}"
      true -> "#{value}"
    end
  end

  # Histograms are distributions - show duration if available, otherwise sample count
  defp format_histogram_value(metric) do
    # For gRPC/HTTP histograms, duration_ms is the most meaningful value
    duration_ms = extract_duration_value(metric)
    unit = normalize_string(Map.get(metric, "unit"))

    cond do
      # If we have a duration value, show it
      is_number(duration_ms) and duration_ms > 0 ->
        format_duration_ms(duration_ms)

      # If we have an explicit unit with a value, use that
      unit != nil ->
        value = extract_primary_value(metric)

        if is_number(value) and value > 0 do
          format_with_explicit_unit(metric, unit)
        else
          format_histogram_count_or_dash(metric)
        end

      # Fallback to sample count
      true ->
        format_histogram_count_or_dash(metric)
    end
  end

  defp format_histogram_count_or_dash(metric) do
    count = extract_histogram_count(metric)

    if count > 0 do
      "#{format_number(count)} samples"
    else
      "—"
    end
  end

  defp extract_duration_value(metric), do: duration_ms_from_metric(metric)

  defp format_duration_ms(ms) when is_number(ms) do
    cond do
      ms >= 60_000 -> "#{Float.round(ms / 60_000, 1)}m"
      ms >= 1000 -> "#{Float.round(ms / 1000, 2)}s"
      ms >= 1 -> "#{Float.round(ms * 1.0, 1)}ms"
      ms > 0 -> "#{Float.round(ms * 1000, 0)}µs"
      true -> "0ms"
    end
  end

  defp format_duration_ms(_ms), do: "—"

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000 * 1.0, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000 * 1.0, 1)}k"
  defp format_number(n), do: "#{n}"

  defp get_metric_name(metric) do
    # Check multiple fields where the metric name might be stored
    normalize_string(Map.get(metric, "span_name")) ||
      normalize_string(Map.get(metric, "metric_name")) ||
      normalize_string(Map.get(metric, "name")) ||
      ""
  end

  defp normalize_string(nil), do: nil
  defp normalize_string(""), do: nil
  defp normalize_string(s) when is_binary(s), do: String.trim(s)
  defp normalize_string(_), do: nil

  defp bytes_metric?(nil), do: false
  defp bytes_metric?(""), do: false

  defp bytes_metric?(name) when is_binary(name) do
    downcased = String.downcase(name)

    String.contains?(downcased, "bytes") or
      String.contains?(downcased, "memory") or
      String.contains?(downcased, "heap") or
      String.contains?(downcased, "alloc")
  end

  defp count_metric?(nil), do: false
  defp count_metric?(""), do: false

  defp count_metric?(name) when is_binary(name) do
    downcased = String.downcase(name)

    String.ends_with?(downcased, "_count") or
      String.ends_with?(downcased, "_total") or
      String.contains?(downcased, "goroutines") or
      String.contains?(downcased, "threads")
  end

  # Stats/counter-like metrics (processed, skipped, etc.)
  defp stats_metric?(nil), do: false
  defp stats_metric?(""), do: false

  defp stats_metric?(name) when is_binary(name) do
    downcased = String.downcase(name)

    String.contains?(downcased, "_stats_") or
      String.contains?(downcased, "processed") or
      String.contains?(downcased, "skipped") or
      String.contains?(downcased, "inferred") or
      String.contains?(downcased, "canonical") or
      String.contains?(downcased, "requests") or
      String.contains?(downcased, "connections") or
      String.contains?(downcased, "errors") or
      String.contains?(downcased, "failures")
  end

  # Check if metric name explicitly suggests it's a duration/timing metric
  defp duration_metric?(nil), do: false
  defp duration_metric?(""), do: false

  defp duration_metric?(name) when is_binary(name) do
    downcased = String.downcase(name)

    String.contains?(downcased, "duration") or
      String.contains?(downcased, "latency") or
      String.contains?(downcased, "_time") or
      String.ends_with?(downcased, "time") or
      String.contains?(downcased, "elapsed") or
      String.contains?(downcased, "response_ms") or
      String.contains?(downcased, "request_ms")
  end

  # Check if this is an actual timing span with real HTTP/gRPC context (not empty strings)
  defp actual_timing_span?(metric) do
    has_http =
      non_empty_string?(metric["http_route"]) or
        non_empty_string?(metric["http_method"])

    has_grpc =
      non_empty_string?(metric["grpc_service"]) or
        non_empty_string?(metric["grpc_method"])

    # Also check for span type
    is_span = normalize_string(Map.get(metric, "metric_type")) == "span"

    (has_http or has_grpc) and is_span
  end

  defp non_empty_string?(nil), do: false
  defp non_empty_string?(""), do: false
  defp non_empty_string?(s) when is_binary(s), do: String.trim(s) != ""
  defp non_empty_string?(_), do: false

  defp has_duration_field?(metric) do
    is_number(metric["duration_ms"]) or is_binary(metric["duration_ms"]) or
      is_number(metric["duration_seconds"]) or is_binary(metric["duration_seconds"])
  end

  defp has_any_value?(metric) do
    is_number(metric["value"]) or is_binary(metric["value"]) or
      is_number(metric["sum"]) or is_binary(metric["sum"]) or
      is_number(metric["count"]) or is_binary(metric["count"]) or
      is_number(metric["duration_ms"]) or is_binary(metric["duration_ms"])
  end

  defp format_duration_value(metric) do
    ms = duration_ms_from_metric(metric) || 0.0

    if ms >= 1000 do
      "#{Float.round(ms / 1000.0, 2)}s"
    else
      "#{Float.round(ms * 1.0, 1)}ms"
    end
  end

  defp format_bytes_value(metric) do
    bytes = metric_numeric_value(metric, ["value", "sum", "duration_ms"]) || 0
    format_bytes_from_value(bytes)
  end

  defp format_count_value(metric) do
    count = metric_numeric_value(metric, ["value", "sum", "count", "duration_ms"]) || 0
    format_count_from_value(count)
  end

  defp format_raw_value(metric, _metric_type) do
    case metric_numeric_value(metric, ["value", "sum", "count", "duration_ms"]) do
      value when is_number(value) -> format_compact_value(value)
      _ -> "—"
    end
  end

  # Used for the visualization bar - extracts numeric value for comparison
  defp metric_value_ms(metric) when is_map(metric) do
    case duration_ms_from_metric(metric) do
      value when is_number(value) ->
        value * 1.0

      _ ->
        case metric_numeric_value(metric, ["value", "sum"]) do
          value when is_number(value) -> value * 1.0
          _ -> nil
        end
    end
  end

  defp metric_value_ms(_), do: nil

  attr(:value, :any, default: nil)

  defp severity_badge(assigns) do
    variant = severity_variant(assigns.value)
    label = severity_label(assigns.value)

    assigns = assigns |> assign(:variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp severity_variant(value) do
    case normalize_severity(value) do
      s when s in ["critical", "fatal", "error"] -> "error"
      s when s in ["high", "warn", "warning"] -> "warning"
      s when s in ["medium", "info"] -> "info"
      s when s in ["low", "debug", "trace", "ok"] -> "success"
      _ -> "ghost"
    end
  end

  defp severity_label(nil), do: "—"
  defp severity_label(""), do: "—"

  defp severity_label(value) do
    case normalize_severity(value) do
      "" -> "—"
      s -> String.upcase(s)
    end
  end

  defp normalize_severity(nil), do: ""

  defp normalize_severity(v) when is_binary(v) do
    # OTel-SDK producers write the raw SeverityNumber enum name into severity_text
    # (e.g. "SEVERITY_NUMBER_INFO", "SEVERITY_NUMBER_WARN3") and leave severity_number
    # null. Strip the enum prefix + any numbered-variant suffix so the badge resolves to
    # info/warn/error (label + color), matching the Go agent's lowercase severity_text.
    v
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("severity_number_", "")
    |> String.replace(~r/\d+$/, "")
  end

  defp normalize_severity(v), do: v |> to_string() |> normalize_severity()

  defp log_id(log) do
    # Use the UUID id field from the logs table
    case Map.get(log, "id") do
      nil -> "unknown"
      # Handle binary UUID (16 bytes) - convert to string format
      <<_::binary-size(16)>> = bin -> uuid_to_string(bin)
      # Already a string UUID
      id when is_binary(id) -> id
      _ -> "unknown"
    end
  end

  defp log_dom_id(log) do
    id = log_id(log)

    if id == "unknown" do
      "log-" <> Integer.to_string(:erlang.phash2(log))
    else
      "log-" <> id
    end
  end

  # Convert raw 16-byte binary UUID to string format
  defp uuid_to_string(<<a::32, b::16, c::16, d::16, e::48>>) do
    [a, b, c, d, e]
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map(&String.downcase/1)
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {hex, len} -> String.pad_leading(hex, len, "0") end)
  end

  defp uuid_to_string(_), do: "unknown"

  defp signal_time_key(row, identity_fields, index) when is_map(row) do
    identity =
      Enum.find_value(identity_fields, fn field ->
        case Map.get(row, field) do
          value when is_binary(value) ->
            case String.trim(value) do
              "" -> nil
              trimmed -> trimmed
            end

          nil ->
            nil

          value ->
            value
        end
      end)

    case identity do
      nil -> "i-#{index}"
      value -> signal_dom_token(value)
    end
  end

  defp signal_time_key(_row, _identity_fields, index), do: "i-#{index}"

  defp signal_dom_token(value) do
    value = to_string(value)

    if Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, value) do
      "s-#{value}"
    else
      "e-#{Base.url_encode64(value, padding: false)}"
    end
  end

  defp timestamp_meta(%DateTime{} = value), do: timestamp_meta_value(value)
  defp timestamp_meta(%NaiveDateTime{} = value), do: timestamp_meta_value(value)

  defp timestamp_meta(%{} = log) do
    log
    |> effective_log_timestamp()
    |> timestamp_meta_value()
  end

  defp timestamp_meta(value), do: timestamp_meta_value(value)

  defp timestamp_meta_value(value) do
    case parse_timestamp(value) do
      {:ok, dt} ->
        iso = DateTime.to_iso8601(dt)

        %{
          iso: iso,
          value: dt,
          fallback: iso
        }

      _ ->
        %{iso: nil, value: nil, fallback: value || "—"}
    end
  end

  # Syslog can retain an unzoned source wall-clock string in attributes. The
  # observed timestamp is the already-selected canonical instant and must be
  # displayed as-is, never reconstructed from that source wall clock.
  defp effective_log_timestamp(log) do
    Map.get(log, "observed_timestamp") || Map.get(log, "timestamp")
  end

  defp extract_time_from_query(""), do: nil

  defp extract_time_from_query(query) when is_binary(query) do
    case Regex.run(~r/(?:^|\s)time:(\S+)/, query) do
      [_, time] -> time
      _ -> nil
    end
  end

  defp extract_filter_from_query(nil, _field), do: nil
  defp extract_filter_from_query("", _field), do: nil

  defp extract_filter_from_query(query, field) when is_binary(query) and is_binary(field) do
    # Match both service_name:value and service_name:"quoted value"
    pattern = ~r/(?:^|\s)#{Regex.escape(field)}:(?:"([^"]+)"|(\S+))/

    case Regex.run(pattern, query) do
      [_, quoted, ""] -> quoted
      [_, "", unquoted] -> unquoted
      [_, value] -> value
      _ -> nil
    end
  end

  defp truthy_param?(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()
    value in ["1", "true", "t", "yes", "y", "on"]
  end

  defp truthy_param?(value) when is_integer(value), do: value != 0
  defp truthy_param?(true), do: true
  defp truthy_param?(_), do: false

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)

  defp to_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> 0
    end
  end

  defp to_int(_), do: 0

  defp numeric_to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp numeric_to_float(value) when is_number(value), do: value * 1.0
  defp numeric_to_float(_), do: 0.0

  defp extract_stats_count({:ok, %{"results" => [%{} | _]}} = result, key) when is_binary(key) do
    result
    |> extract_stats_row()
    |> Map.get(key)
    |> to_int()
  end

  defp extract_stats_count({:ok, %{"results" => [value | _]}}, _key), do: to_int(value)
  defp extract_stats_count(_result, _key), do: 0

  defp extract_stats_row({:ok, %{"results" => [%{} = raw | _]}}) do
    case Map.get(raw, "payload") do
      %{} = payload -> payload
      _ -> raw
    end
  end

  defp extract_stats_row(_), do: %{}

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  defp parse_timestamp(nil), do: :error
  defp parse_timestamp(""), do: :error
  defp parse_timestamp(%DateTime{} = value), do: {:ok, value}

  # Typed NaiveDateTime values are a canonical DB representation. Source text must carry an offset.
  defp parse_timestamp(%NaiveDateTime{} = value), do: {:ok, DateTime.from_naive!(value, "Etc/UTC")}

  defp parse_timestamp(value) when is_binary(value) do
    value = String.trim(value)

    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      {:error, _} ->
        :error
    end
  end

  defp parse_timestamp(_), do: :error

  defp compute_netflow_summary(flows) when is_list(flows) do
    Enum.reduce(
      flows,
      %{
        total: 0,
        tcp: 0,
        udp: 0,
        other: 0,
        total_bytes: 0,
        total_packets: 0,
        v5: 0,
        v9: 0,
        ipfix: 0,
        sflow: 0
      },
      fn flow, acc ->
        protocol = flow |> netflow_protocol_num() |> to_int()
        bytes = flow |> netflow_bytes() |> to_int()
        packets = flow |> netflow_packets() |> to_int()
        flow_type = netflow_flow_type(flow)

        updated =
          case protocol do
            6 -> Map.update!(acc, :tcp, &(&1 + 1))
            17 -> Map.update!(acc, :udp, &(&1 + 1))
            _ -> Map.update!(acc, :other, &(&1 + 1))
          end

        updated =
          case flow_type do
            "NETFLOW_V5" -> Map.update!(updated, :v5, &(&1 + 1))
            "NETFLOW_V9" -> Map.update!(updated, :v9, &(&1 + 1))
            "IPFIX" -> Map.update!(updated, :ipfix, &(&1 + 1))
            "SFLOW_5" -> Map.update!(updated, :sflow, &(&1 + 1))
            _ -> updated
          end

        updated
        |> Map.update!(:total, &(&1 + 1))
        |> Map.update!(:total_bytes, &(&1 + bytes))
        |> Map.update!(:total_packets, &(&1 + packets))
      end
    )
  end

  defp compute_netflow_summary(_), do: empty_netflow_summary()

  defp panel_live?("logs", assigns), do: Map.get(assigns, :logs_live?, false)
  defp panel_live?("netflows", assigns), do: Map.get(assigns, :netflows_live?, false)
  defp panel_live?("events", assigns), do: Map.get(assigns, :events_live?, false)
  defp panel_live?("traces", assigns), do: Map.get(assigns, :traces_live?, false)
  defp panel_live?("metrics", assigns), do: Map.get(assigns, :metrics_live?, false)
  defp panel_live?("alerts", assigns), do: Map.get(assigns, :alerts_live?, false)
  defp panel_live?(_, _), do: false

  defp panel_title("logs", true), do: "Log Stream"
  defp panel_title("logs", false), do: "Logs"
  defp panel_title("traces", true), do: "Trace Stream"
  defp panel_title("traces", false), do: "Traces"
  defp panel_title("metrics", true), do: "Metric Stream"
  defp panel_title("metrics", false), do: "Metrics"
  defp panel_title("events", true), do: "Event Stream"
  defp panel_title("events", false), do: "Events"
  defp panel_title("alerts", true), do: "Alert Stream"
  defp panel_title("alerts", false), do: "Alerts"
  defp panel_title("netflows", true), do: "Flow Stream"
  defp panel_title("netflows", false), do: "Flows"
  defp panel_title(_, _), do: "Logs"

  defp panel_subtitle("logs", true), do: "Streaming newest log updates. Click any log entry to view full details."
  defp panel_subtitle("logs", false), do: "Click any log entry to view full details."
  defp panel_subtitle("traces", true), do: "Streaming newest trace updates. Click a trace to open the span waterfall."
  defp panel_subtitle("traces", _), do: "Click a trace to open the span waterfall."

  defp panel_subtitle("metrics", true),
    do: "Streaming newest metric updates. Click a metric to jump to correlated logs (if trace_id is present)."

  defp panel_subtitle("metrics", _), do: "Click a metric to jump to correlated logs (if trace_id is present)."

  defp panel_subtitle("events", true), do: "Streaming newest event updates. Click any event to view full details."
  defp panel_subtitle("events", _), do: "Click any event to view full details."
  defp panel_subtitle("alerts", true), do: "Streaming newest alert updates. Click any alert to view full details."
  defp panel_subtitle("alerts", _), do: "Click any alert to view full details."
  defp panel_subtitle("netflows", true), do: "Refreshing newest network flow data from NetFlow collectors."
  defp panel_subtitle("netflows", false), do: "Network flow data from NetFlow collectors."
  defp panel_subtitle(_, _), do: "Click any log entry to view full details."

  defp panel_result_count("traces", _logs, traces, _metrics, _events, _alerts, _netflows), do: length(traces)

  defp panel_result_count("metrics", _logs, _traces, metrics, _events, _alerts, _netflows), do: length(metrics)

  defp panel_result_count("events", _logs, _traces, _metrics, events, _alerts, _netflows), do: length(events)

  defp panel_result_count("alerts", _logs, _traces, _metrics, _events, alerts, _netflows), do: length(alerts)

  defp panel_result_count("netflows", _logs, _traces, _metrics, _events, _alerts, netflows), do: length(netflows)

  defp panel_result_count(_, logs, _traces, _metrics, _events, _alerts, _netflows), do: length(logs)

  defp default_tab_for_path(path) when is_binary(path) do
    ObservabilityPaths.tab_from_path(path) ||
      case path do
        "/observability" -> "logs"
        "/flows" -> "netflows"
        _ -> "logs"
      end
  end

  defp default_tab_for_path(_), do: "logs"

  defp tab_entity("traces"), do: {"otel_trace_summaries", :traces}
  defp tab_entity("metrics"), do: {"otel_metrics", :metrics}
  defp tab_entity("events"), do: {"events", :events}
  defp tab_entity("alerts"), do: {"alerts", :alerts}
  defp tab_entity("netflows"), do: {"flows", :netflows}
  defp tab_entity(_), do: {"logs", :logs}

  defp tab_limits("events"), do: {@default_events_limit, @max_events_limit}
  defp tab_limits("alerts"), do: {@default_alerts_limit, @max_alerts_limit}
  defp tab_limits("netflows"), do: {@default_netflow_limit, @max_netflow_limit}
  defp tab_limits(_), do: {@default_limit, @max_limit}

  defp apply_tab_assigns(socket, "traces", srql_module) do
    scope = Map.get(socket.assigns, :current_scope)
    {trace_stats, trace_latency} = load_trace_summary_cards(srql_module, scope)

    socket
    |> assign(:trace_stats, trace_stats)
    |> assign(:trace_latency, trace_latency)
    |> assign(:trace_rollup_status, Stats.trace_rollup_status())
    |> assign(:metrics_stats, empty_metrics_stats())
  end

  defp apply_tab_assigns(socket, "metrics", srql_module) do
    scope = Map.get(socket.assigns, :current_scope)
    metrics_stats = build_metrics_stats(srql_module, scope)
    sparklines = load_sparklines(socket.assigns.metrics, scope)

    socket
    |> assign(:metrics_stats, metrics_stats)
    |> assign(:sparklines, sparklines)
    |> assign(:trace_stats, empty_trace_stats())
    |> assign(:trace_latency, empty_trace_latency())
    |> apply_otlp_points_assigns(srql_module, scope)
  end

  defp apply_tab_assigns(socket, "events", _srql_module) do
    query = socket.assigns |> Map.get(:srql, %{}) |> Map.get(:query, "")

    base_summary = Stats.events_summary(time: event_summary_time_window(query))

    summary = Map.put(base_summary, :critical, Map.get(base_summary, :critical, 0) + Map.get(base_summary, :fatal, 0))

    socket
    |> assign(:event_summary, summary)
    |> assign(:alert_summary, empty_alert_summary())
    |> assign(:netflow_summary, empty_netflow_summary())
    |> assign(:trace_stats, empty_trace_stats())
    |> assign(:trace_latency, empty_trace_latency())
    |> assign(:metrics_stats, empty_metrics_stats())
  end

  defp apply_tab_assigns(socket, "alerts", _srql_module) do
    summary = Stats.alerts_summary()

    socket
    |> assign(:alert_summary, summary)
    |> assign(:event_summary, empty_event_summary())
    |> assign(:netflow_summary, empty_netflow_summary())
    |> assign(:trace_stats, empty_trace_stats())
    |> assign(:trace_latency, empty_trace_latency())
    |> assign(:metrics_stats, empty_metrics_stats())
  end

  defp apply_tab_assigns(socket, "netflows", srql_module) do
    scope = Map.get(socket.assigns, :current_scope)
    summary = maybe_load_netflow_summary(socket, srql_module, scope)

    top_talkers =
      load_netflow_top_talkers(
        srql_module,
        Map.get(socket.assigns.srql, :query),
        scope,
        Map.get(socket.assigns, :netflow_talker_cidr)
      )

    rdns_map = load_netflow_rdns_map(socket.assigns.netflows, top_talkers, scope)
    threat_map = load_netflow_threat_map(socket.assigns.netflows)

    top_ports = load_netflow_top_ports(srql_module, Map.get(socket.assigns.srql, :query), scope)

    timeseries =
      load_netflow_timeseries(srql_module, Map.get(socket.assigns.srql, :query), scope)

    compare_mode = Map.get(socket.assigns, :netflow_compare_mode, "off")

    timeseries_compare =
      load_netflow_timeseries_compare(
        srql_module,
        Map.get(socket.assigns.srql, :query),
        scope,
        compare_mode,
        Map.get(timeseries, :bucket_seconds, 300)
      )

    timeseries_stacked =
      load_netflow_timeseries_stacked(
        srql_module,
        Map.get(socket.assigns.srql, :query),
        scope,
        Map.get(timeseries, :bucket_seconds, 300),
        Map.get(timeseries, :points, []),
        Map.get(socket.assigns, :netflow_stack_mode, @default_netflow_stack_mode)
      )

    protocol_activity =
      load_netflow_protocol_activity(
        srql_module,
        Map.get(socket.assigns.srql, :query),
        scope,
        Map.get(timeseries, :bucket_seconds, 300),
        Map.get(timeseries, :points, [])
      )

    app_activity =
      load_netflow_app_activity(
        srql_module,
        Map.get(socket.assigns.srql, :query),
        scope,
        Map.get(timeseries, :bucket_seconds, 300),
        Map.get(timeseries, :points, [])
      )

    frequent_talkers_packets =
      load_netflow_frequent_talkers_packets(
        srql_module,
        Map.get(socket.assigns.srql, :query),
        scope
      )

    frequent_talkers_bytes =
      load_netflow_frequent_talkers_bytes(
        srql_module,
        Map.get(socket.assigns.srql, :query),
        scope
      )

    geo_side = Map.get(socket.assigns, :netflow_geo_side, "dst")

    geo_heatmap =
      load_netflow_geo_heatmap(
        srql_module,
        Map.get(socket.assigns.srql, :query),
        scope,
        geo_side
      )

    sankey_prefix = Map.get(socket.assigns, :netflow_sankey_prefix, 24)

    sankey =
      load_netflow_sankey(
        srql_module,
        Map.get(socket.assigns.srql, :query),
        scope,
        sankey_prefix
      )

    sankey_edges_json =
      try do
        Jason.encode!(Map.get(sankey, :edges, []))
      rescue
        _ -> "[]"
      end

    socket
    |> assign(:netflow_summary, summary)
    |> assign(:netflow_rdns_map, rdns_map)
    |> assign(:netflow_threat_map, threat_map)
    |> assign(:netflow_top_talkers, top_talkers)
    |> assign(:netflow_top_ports, top_ports)
    |> assign(:netflow_timeseries, timeseries)
    |> assign(:netflow_timeseries_compare, timeseries_compare)
    |> assign(:netflow_timeseries_stacked, timeseries_stacked)
    |> assign(:netflow_protocol_activity, protocol_activity)
    |> assign(:netflow_app_activity, app_activity)
    |> assign(:netflow_frequent_talkers_packets, frequent_talkers_packets)
    |> assign(:netflow_frequent_talkers_bytes, frequent_talkers_bytes)
    |> assign(:netflow_geo_heatmap, geo_heatmap)
    |> assign(:netflow_sankey, sankey)
    |> assign(:netflow_sankey_edges_json, sankey_edges_json)
    |> assign(:event_summary, empty_event_summary())
    |> assign(:alert_summary, empty_alert_summary())
    |> assign(:trace_stats, empty_trace_stats())
    |> assign(:trace_latency, empty_trace_latency())
    |> assign(:metrics_stats, empty_metrics_stats())
    |> maybe_auto_open_netflow(scope)
  end

  defp apply_tab_assigns(socket, _tab, srql_module) do
    scope = Map.get(socket.assigns, :current_scope)
    {summary, logs_rollup_status} = maybe_load_log_summary(socket, srql_module, scope)

    socket
    |> assign(:summary, summary)
    |> assign(:logs_rollup_status, logs_rollup_status)
    |> assign(:_summary_loaded, true)
    |> assign(:event_summary, empty_event_summary())
    |> assign(:alert_summary, empty_alert_summary())
    |> assign(:netflow_summary, empty_netflow_summary())
    |> assign(:trace_stats, empty_trace_stats())
    |> assign(:trace_latency, empty_trace_latency())
    |> assign(:metrics_stats, empty_metrics_stats())
  end

  # The OTLP points view is loaded only when active: a metric-name rollup for
  # the list plus (when a metric is selected) its recent raw points.
  defp apply_otlp_points_assigns(socket, srql_module, scope) do
    if Map.get(socket.assigns, :metrics_view, "samples") == "points" do
      query = socket.assigns |> Map.get(:srql, %{}) |> Map.get(:query, "")
      names = load_otlp_metric_names(srql_module, scope, query)
      selected = Map.get(socket.assigns, :otlp_selected_metric)

      series =
        if is_binary(selected) and selected != "" do
          load_otlp_metric_series(srql_module, scope, selected)
        else
          []
        end

      socket
      |> assign(:otlp_metric_names, names)
      |> assign(:otlp_metric_series, series)
    else
      socket
      |> assign(:otlp_metric_names, [])
      |> assign(:otlp_metric_series, [])
    end
  end

  defp maybe_auto_open_netflow(socket, scope) do
    if Map.get(socket.assigns, :netflow_auto_open, false) do
      case List.first(Map.get(socket.assigns, :netflows, [])) do
        %{} = flow ->
          socket
          |> assign(:selected_netflow, flow)
          |> assign(:netflow_context, load_netflow_context(flow, scope))
          |> assign(:netflow_arin_lookup, %{})
          |> assign(:netflow_auto_open, false)

        _ ->
          assign(socket, :netflow_auto_open, false)
      end
    else
      socket
    end
  end

  defp dispatch_tab_load(socket, tab, params, uri) do
    cond do
      !socket.assigns[:_initial_load_done] ->
        # Initial connected mount — load synchronously so the first connected
        # render already contains the list. The page shell was already painted
        # by the dead render; deferring here used to produce a connected
        # render with an empty list ("No metrics found.") whose data only
        # existed in a follow-up diff, so the initial tab load dropped its
        # results until the user manually re-ran the query.
        load_tab(socket, tab, params, uri)

      tab != socket.assigns[:_loaded_tab] ->
        # Tab switch — load synchronously for instant transition (no flash)
        load_tab(socket, tab, params, uri)

      true ->
        # Same-tab query change (e.g. stat card click) — load async so the UI
        # stays responsive. Current data remains visible until results arrive.
        send(self(), {:load_tab_data, tab, params, uri})
        socket
    end
  end

  # A patch schedules same-tab data loading through the LiveView mailbox. If a
  # newer patch is already queued, its handle_params/3 call can run before this
  # message. Do not let the older load overwrite the newer query's results.
  defp current_tab_load?(socket, tab, params) do
    socket.assigns.active_tab == tab and
      Map.get(socket.assigns, :current_params, %{}) == params
  end

  defp load_tab(socket, tab, params, uri) do
    {_entity, list_key} = tab_entity(tab)
    {default_limit, max_limit} = tab_limits(tab)
    params = maybe_default_netflows_query(params, tab)

    socket
    |> SRQLPage.load_list(params, uri, list_key,
      default_limit: default_limit,
      max_limit: max_limit
    )
    |> maybe_fallback_to_raw_traces(tab, params, uri, default_limit, max_limit)
    |> apply_tab_assigns(tab, srql_module())
    |> stream_active_tab(tab)
    |> assign(:_initial_load_done, true)
    |> assign(:_loaded_tab, tab)
  end

  defp schedule_debounced_refresh(socket, tab) do
    timers = socket.assigns[:_refresh_timers] || %{}

    # If a refresh timer is already pending for this tab, skip
    if Map.has_key?(timers, tab) do
      socket
    else
      timer = Process.send_after(self(), {:debounced_refresh, tab}, @refresh_debounce_ms)
      assign(socket, :_refresh_timers, Map.put(timers, tab, timer))
    end
  end

  defp maybe_schedule_live_logs_refresh(socket) do
    if socket.assigns.active_tab == "logs" and Map.get(socket.assigns, :logs_live?, false) do
      schedule_debounced_refresh(socket, "logs")
    else
      socket
    end
  end

  defp maybe_schedule_live_netflows_refresh(socket) do
    if socket.assigns.active_tab == "netflows" and Map.get(socket.assigns, :netflows_live?, false) do
      schedule_debounced_refresh(socket, "netflows")
    else
      socket
    end
  end

  # Generic live-tail gate shared by the events/traces/metrics/alerts tabs:
  # schedule a debounced head refresh only while the tab is active and live.
  defp maybe_schedule_tab_live_refresh(socket, tab, flag) do
    if socket.assigns.active_tab == tab and Map.get(socket.assigns, flag, false) do
      schedule_debounced_refresh(socket, tab)
    else
      socket
    end
  end

  defp maybe_refresh_tab(socket, "logs") do
    if socket.assigns.active_tab == "logs" and Map.get(socket.assigns, :logs_live?, false) do
      refresh_tab(socket, "logs")
    else
      socket
    end
  end

  defp maybe_refresh_tab(socket, "events") do
    if socket.assigns.active_tab == "events" and Map.get(socket.assigns, :events_live?, false) do
      refresh_tab(socket, "events")
    else
      socket
    end
  end

  defp maybe_refresh_tab(socket, "traces") do
    if socket.assigns.active_tab == "traces" and Map.get(socket.assigns, :traces_live?, false) do
      refresh_tab(socket, "traces")
    else
      socket
    end
  end

  defp maybe_refresh_tab(socket, "metrics") do
    if socket.assigns.active_tab == "metrics" and Map.get(socket.assigns, :metrics_live?, false) do
      refresh_tab(socket, "metrics")
    else
      socket
    end
  end

  defp maybe_refresh_tab(socket, "alerts") do
    if socket.assigns.active_tab == "alerts" and Map.get(socket.assigns, :alerts_live?, false) do
      refresh_tab(socket, "alerts")
    else
      socket
    end
  end

  defp maybe_refresh_tab(socket, "netflows") do
    if socket.assigns.active_tab == "netflows" and Map.get(socket.assigns, :netflows_live?, false) do
      refresh_tab(socket, "netflows")
    else
      socket
    end
  end

  defp maybe_refresh_tab(socket, tab) do
    if socket.assigns.active_tab == tab do
      refresh_tab(socket, tab)
    else
      socket
    end
  end

  defp refresh_tab(socket, tab) do
    {entity, list_key} = tab_entity(tab)
    {default_limit, max_limit} = tab_limits(tab)
    srql = Map.get(socket.assigns, :srql, %{})
    query = Map.get(srql, :query, "")

    # Refresh reuses the active query; do not re-inject limit into URL params.
    # Drop cursor so live refresh returns to the head of the result set.
    params =
      socket.assigns
      |> Map.get(:current_params, %{})
      |> Map.put("q", query)
      |> Map.drop(["limit", "cursor", "page"])

    uri = Map.get(srql, :page_path, "/observability")

    socket
    # Clear summary cache so PubSub refresh gets fresh counts
    |> assign(:_summary_loaded, false)
    |> ensure_srql_entity(entity, default_limit)
    |> SRQLPage.load_list(params, uri, list_key,
      default_limit: default_limit,
      max_limit: max_limit
    )
    |> maybe_fallback_to_raw_traces(tab, params, uri, default_limit, max_limit)
    |> apply_tab_assigns(tab, srql_module())
    |> stream_active_tab(tab)
  end

  defp maybe_fallback_to_raw_traces(socket, "traces", params, uri, default_limit, max_limit) do
    if blank_param?(Map.get(params, "q")) and Map.get(socket.assigns, :traces, []) == [] and
         is_nil(get_in(socket.assigns, [:srql, :error])) do
      fallback_params = Map.put(params, "q", raw_traces_fallback_query(Map.get(socket.assigns, :limit, default_limit)))

      SRQLPage.load_list(socket, fallback_params, uri, :traces,
        default_limit: default_limit,
        max_limit: max_limit
      )
    else
      socket
    end
  end

  defp maybe_fallback_to_raw_traces(socket, _tab, _params, _uri, _default_limit, _max_limit), do: socket

  defp raw_traces_fallback_query(limit) when is_integer(limit) and limit > 0 do
    "in:traces time:last_24h sort:timestamp:desc limit:#{limit}"
  end

  defp raw_traces_fallback_query(_limit), do: raw_traces_fallback_query(@default_limit)

  defp stream_active_tab(socket, "logs") do
    stream(socket, :logs, socket.assigns.logs, reset: true, dom_id: &log_dom_id/1)
  end

  defp stream_active_tab(socket, "events") do
    stream(socket, :events, socket.assigns.events, reset: true, dom_id: &event_dom_id/1)
  end

  defp stream_active_tab(socket, _tab), do: socket

  defp build_metrics_stats(srql_module, scope) do
    # rollup_stats:red over spans_red_1h already includes error_rate (0-100).
    Stats.metrics_summary(srql_module: srql_module, scope: scope)
  end

  defp parse_metrics_view("points"), do: "points"
  defp parse_metrics_view(_), do: "samples"

  # Scope the OTLP points rollup to the pane's active window (time: token of
  # the current query) and service filter, mirroring how the stat cards
  # interpret the query bar.
  defp otlp_points_base_query(current_query) do
    query = to_string(current_query || "")
    window = extract_time_from_query(query) || "last_24h"
    service = extract_filter_from_query(query, "service_name")

    base = "in:otel_metric_points time:#{window}"

    if non_empty_string?(service) do
      base <> ~s| service_name:"#{escape_srql_value(service)}"|
    else
      base
    end
  end

  defp load_otlp_metric_names(srql_module, scope, current_query) do
    base = otlp_points_base_query(current_query)
    names_query = ~s|#{base} stats:"count() as points by metric_name" sort:points:desc limit:100|

    # otel_metric_points stats only support count() by a single field, so
    # type/unit/temporality come from a best-effort sample of recent points.
    sample_query = ~s|#{base} sort:timestamp:desc limit:250|

    name_rows = extract_stats_rows(srql_module.query(names_query, %{scope: scope}))
    sample_rows = extract_result_rows(srql_module.query(sample_query, %{scope: scope}))

    meta =
      Enum.reduce(sample_rows, %{}, fn row, acc ->
        name = Map.get(row, "metric_name")

        if is_binary(name) and name != "" and not Map.has_key?(acc, name) do
          Map.put(acc, name, %{
            type: row |> Map.get("metric_type") |> normalize_severity() |> presence(),
            unit: normalize_string(Map.get(row, "unit")),
            temporality: row |> Map.get("temporality") |> normalize_severity() |> presence()
          })
        else
          acc
        end
      end)

    name_rows
    |> Enum.map(fn row ->
      name = row |> Map.get("metric_name") |> to_string()
      info = Map.get(meta, name, %{})

      %{
        name: name,
        points: to_int(Map.get(row, "points")),
        type: Map.get(info, :type),
        unit: Map.get(info, :unit),
        temporality: Map.get(info, :temporality)
      }
    end)
    |> Enum.reject(&(&1.name == ""))
  rescue
    e ->
      Logger.warning("Failed to load OTLP metric names: #{inspect(e)}")
      []
  end

  defp load_otlp_metric_series(srql_module, scope, name) do
    query = ~s|in:otel_metric_points metric_name:"#{escape_srql_value(name)}" sort:timestamp:desc limit:500|

    query
    |> srql_module.query(%{scope: scope})
    |> extract_result_rows()
    |> MetricSeries.series()
  rescue
    e ->
      Logger.warning("Failed to load OTLP metric points: #{inspect(e)}")
      []
  end

  defp extract_result_rows({:ok, %{"results" => results}}) when is_list(results), do: Enum.filter(results, &is_map/1)

  defp extract_result_rows(_), do: []

  defp blank_param?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_param?(nil), do: true
  defp blank_param?(_value), do: false

  defp presence(""), do: nil
  defp presence(value), do: value

  defp metrics_view_href(srql, _limit, view) do
    params = %{q: Map.get(srql, :query, "")}
    params = if view == "points", do: Map.put(params, :mview, "points"), else: params
    ObservabilityPaths.path("metrics", params)
  end

  defp otlp_metric_href(srql, _limit, name) do
    ObservabilityPaths.path("metrics", %{
      q: Map.get(srql, :query, ""),
      mview: "points",
      metric: name
    })
  end

  defp otlp_type_badge_variant(type) do
    case type do
      "histogram" -> "info"
      "gauge" -> "success"
      "sum" -> "primary"
      _ -> "ghost"
    end
  end

  defp otlp_kind_label(:rate), do: "rate (cumulative counter)"
  defp otlp_kind_label(:delta_sum), do: "delta sum"
  defp otlp_kind_label(:gauge), do: "gauge"
  defp otlp_kind_label(:histogram), do: "histogram"
  defp otlp_kind_label(_), do: "—"

  # Temporality is labeled from the stored field — no hardcoded assumption
  # once real point data is available.
  defp otlp_temporality_label(%{temporality: temporality}) when is_binary(temporality) and temporality != "",
    do: temporality

  defp otlp_temporality_label(_), do: "—"

  defp format_otlp_rate(rate) when is_number(rate), do: "#{format_series_number(rate)}/s"
  defp format_otlp_rate(_), do: "—"

  defp otlp_unit_suffix(unit) when is_binary(unit) and unit not in ["", "1"], do: " #{unit}"
  defp otlp_unit_suffix(_), do: ""

  defp format_series_number(value) when is_integer(value), do: Integer.to_string(value)

  defp format_series_number(value) when is_float(value) do
    cond do
      value == trunc(value) -> Integer.to_string(trunc(value))
      abs(value) >= 100 -> :erlang.float_to_binary(value, decimals: 1)
      abs(value) >= 1 -> :erlang.float_to_binary(value, decimals: 2)
      true -> :erlang.float_to_binary(value, decimals: 4)
    end
  end

  defp format_series_number(_), do: "—"

  defp maybe_load_log_summary(socket, srql_module, scope) do
    # If we already attempted to load the summary (even if still 0 while async
    # counts are pending), don't re-query on every handle_params/refresh call.
    # The summary shows overall 24h breakdown — it doesn't change per-query.
    if socket.assigns[:_summary_loaded] do
      {socket.assigns.summary, socket.assigns.logs_rollup_status}
    else
      fetch_log_summary(socket, srql_module, scope)
    end
  end

  defp fetch_log_summary(_socket, srql_module, scope) do
    # Use the same simple call as the analytics page — no query-specific filters.
    # The stat cards always show the overall 24h picture.
    case Stats.logs_severity_result(srql_module: srql_module, scope: scope) do
      {:ok, summary} -> {summary, Stats.logs_rollup_status()}
      {:error, _reason} -> {Stats.empty_logs_severity(), unavailable_logs_rollup_status()}
    end
  end

  defp maybe_load_netflow_summary(socket, srql_module, scope) do
    summary = load_netflow_summary(srql_module, Map.get(socket.assigns.srql, :query), scope)

    case summary do
      %{total: 0} when is_list(socket.assigns.netflows) and socket.assigns.netflows != [] ->
        compute_netflow_summary(socket.assigns.netflows)

      %{total_packets: 0, window_seconds: window_seconds}
      when is_integer(window_seconds) and window_seconds > 0 and is_list(socket.assigns.netflows) and
             socket.assigns.netflows != [] ->
        fallback = compute_netflow_summary(socket.assigns.netflows)
        packets = Map.get(fallback, :total_packets, 0)

        summary
        |> Map.put(:total_packets, packets)
        |> Map.put(:avg_pps, packets * 1.0 / window_seconds)

      other ->
        other
    end
  end

  defp empty_trace_stats do
    %{total: 0, error_traces: 0, slow_traces: 0}
  end

  defp empty_trace_latency do
    %{avg_duration_ms: 0.0, p95_duration_ms: 0.0, service_count: 0, sample_size: 0}
  end

  defp empty_metrics_stats do
    Stats.empty_metrics_summary()
  end

  defp empty_event_summary do
    %{total: 0, critical: 0, high: 0, medium: 0, low: 0}
  end

  defp event_summary_time_window(query) when is_binary(query) do
    case Regex.run(~r/\btime:(last_\d+[hd])\b/i, query) do
      [_, value] -> String.downcase(value)
      _ -> "last_7d"
    end
  end

  defp event_summary_time_window(_), do: "last_7d"

  defp empty_alert_summary do
    %{total: 0, pending: 0, acknowledged: 0, resolved: 0, escalated: 0, suppressed: 0}
  end

  defp empty_netflow_summary do
    %{
      total: 0,
      tcp: 0,
      udp: 0,
      other: 0,
      total_bytes: 0,
      total_packets: 0,
      avg_bps: 0.0,
      avg_pps: 0.0,
      window_seconds: 0
    }
  end

  defp ensure_srql_entity(socket, entity, default_limit) when is_binary(entity) do
    current = socket.assigns |> Map.get(:srql, %{}) |> Map.get(:entity)

    if current == entity do
      socket
    else
      SRQLPage.init(socket, entity, default_limit: default_limit)
    end
  end

  defp current_entity(socket) do
    socket.assigns |> Map.get(:srql, %{}) |> Map.get(:entity) || "logs"
  end

  # Use pre-computed CAGG via rollup_stats pattern for trace stat cards.
  defp load_trace_summary_cards(srql_module, scope) do
    summary = Stats.traces_summary(srql_module: srql_module, scope: scope)

    trace_stats = %{
      total: Map.get(summary, :total, 0),
      error_traces: Map.get(summary, :errors, 0),
      slow_traces: 0
    }

    trace_latency = %{
      avg_duration_ms: Map.get(summary, :avg_duration_ms, 0.0),
      p95_duration_ms: Map.get(summary, :p95_duration_ms, 0.0),
      service_count: 0,
      sample_size: Map.get(summary, :total, 0)
    }

    {trace_stats, trace_latency}
  end

  defp load_netflow_summary(srql_module, current_query, scope) do
    base_query =
      current_query
      |> netflow_base_query()
      |> sanitize_srql_for_stats()

    time_token = extract_time_from_query(base_query) || @default_netflow_window

    window_seconds =
      case resolve_srql_time(time_token) do
        {:ok, %{start: start_dt, end: end_dt}} -> max(DateTime.diff(end_dt, start_dt, :second), 1)
        _ -> 60 * 60
      end

    total_query = ~s|#{base_query} stats:"count(*) as total" limit:1|
    bytes_query = ~s|#{base_query} stats:"sum(bytes_total) as total_bytes" limit:1|
    packets_total_query = ~s|#{base_query} stats:"sum(packets_total) as total_packets" limit:1|
    packets_alt_query = ~s|#{base_query} stats:"sum(packets) as total_packets" limit:1|
    packets_in_query = ~s|#{base_query} stats:"sum(packets_in) as total_packets_in" limit:1|
    packets_out_query = ~s|#{base_query} stats:"sum(packets_out) as total_packets_out" limit:1|

    proto_query =
      ~s|#{base_query} stats:"count(*) as total by protocol_num" sort:total:desc limit:50|

    total = extract_stats_count(srql_module.query(total_query, %{scope: scope}), "total")

    total_bytes =
      extract_stats_count(srql_module.query(bytes_query, %{scope: scope}), "total_bytes")

    packets_total_primary =
      extract_stats_count(
        srql_module.query(packets_total_query, %{scope: scope}),
        "total_packets"
      )

    packets_total_alt =
      extract_stats_count(srql_module.query(packets_alt_query, %{scope: scope}), "total_packets")

    packets_in =
      extract_stats_count(
        srql_module.query(packets_in_query, %{scope: scope}),
        "total_packets_in"
      )

    packets_out =
      extract_stats_count(
        srql_module.query(packets_out_query, %{scope: scope}),
        "total_packets_out"
      )

    total_packets =
      cond do
        packets_total_primary > 0 -> packets_total_primary
        packets_total_alt > 0 -> packets_total_alt
        packets_in + packets_out > 0 -> packets_in + packets_out
        true -> 0
      end

    proto_rows = extract_stats_rows(srql_module.query(proto_query, %{scope: scope}))

    tcp =
      Enum.find_value(proto_rows, 0, fn row ->
        if to_int(Map.get(row, "protocol_num")) == 6, do: to_int(row["total"])
      end)

    udp =
      Enum.find_value(proto_rows, 0, fn row ->
        if to_int(Map.get(row, "protocol_num")) == 17, do: to_int(row["total"])
      end)

    other = max(total - tcp - udp, 0)

    avg_bps = total_bytes * 8.0 / window_seconds
    avg_pps = total_packets * 1.0 / window_seconds

    %{
      total: total,
      tcp: tcp,
      udp: udp,
      other: other,
      total_bytes: total_bytes,
      total_packets: total_packets,
      avg_bps: avg_bps,
      avg_pps: avg_pps,
      window_seconds: window_seconds
    }
  rescue
    e ->
      Logger.warning("Failed to load netflow summary stats: #{inspect(e)}")
      empty_netflow_summary()
  end

  defp load_netflow_top_talkers(srql_module, current_query, scope, talker_cidr, limit \\ 10) do
    base_query =
      current_query
      |> netflow_base_query()
      |> sanitize_srql_for_stats()

    # SRQL group-by expressions like src_cidr:24 are not consistently supported
    # across backends; always group by raw src IP and collapse to CIDR in Elixir.
    query =
      ~s|#{base_query} stats:"sum(bytes_total) as total_bytes by src_endpoint_ip" sort:total_bytes:desc limit:1000|

    rows =
      srql_module
      |> apply(:query, [query, %{scope: scope}])
      |> extract_stats_rows()

    rows = aggregate_talker_rows(rows, talker_cidr)

    rows
    |> Enum.reject(fn row ->
      ip = row && Map.get(row, :ip)
      not (is_binary(ip) and String.trim(ip) != "") or to_int(Map.get(row, :bytes)) <= 0
    end)
    |> Enum.sort_by(fn row -> -to_int(Map.get(row, :bytes)) end)
    |> Enum.take(limit)
  rescue
    _ ->
      []
  end

  defp aggregate_talker_rows(rows, talker_cidr) when talker_cidr in [16, 24] do
    rows
    |> Enum.reduce(%{}, fn row, acc ->
      ip = Map.get(row, "src_endpoint_ip")
      cidr = ip_to_cidr(ip, talker_cidr)
      bytes = to_int(Map.get(row, "total_bytes"))

      if is_binary(cidr) and cidr != "" and bytes > 0 do
        Map.update(acc, cidr, bytes, &(&1 + bytes))
      else
        acc
      end
    end)
    |> Enum.map(fn {cidr, bytes} -> %{ip: cidr, bytes: bytes} end)
  end

  defp aggregate_talker_rows(rows, _talker_cidr) do
    Enum.map(rows, fn row ->
      %{
        ip: Map.get(row, "src_endpoint_ip"),
        bytes: to_int(Map.get(row, "total_bytes"))
      }
    end)
  end

  defp load_netflow_top_ports(srql_module, current_query, scope, limit \\ 10) do
    base_query =
      current_query
      |> netflow_base_query()
      |> sanitize_srql_for_stats()

    query =
      ~s|#{base_query} stats:"sum(bytes_total) as total_bytes by dst_endpoint_port" sort:total_bytes:desc limit:#{limit}|

    srql_module
    |> apply(:query, [query, %{scope: scope}])
    |> extract_stats_rows()
    |> Enum.map(fn row ->
      %{
        port: to_int(Map.get(row, "dst_endpoint_port")),
        bytes: to_int(Map.get(row, "total_bytes"))
      }
    end)
    |> Enum.reject(fn row -> row.port == 0 end)
  rescue
    _ ->
      []
  end

  defp extract_stats_rows({:ok, %{"results" => results}}) when is_list(results) do
    Enum.map(results, fn
      %{"payload" => %{} = payload} -> payload
      %{} = row -> row
      _ -> %{}
    end)
  end

  defp extract_stats_rows(_), do: []

  defp netflow_base_query(query), do: NFQuery.flows_base_query(to_string(query || ""), @default_netflow_window)

  defp load_netflow_rdns_map(flows, top_talkers, scope) when is_list(flows) do
    user = scope && scope.user

    ips =
      flows
      |> netflow_rdns_ips(user)
      |> Kernel.++(netflow_talker_rdns_ips(top_talkers, user))
      |> Enum.uniq()

    rdns_map_for_ips(ips, user)
  end

  defp load_netflow_rdns_map(_flows, _top_talkers, _scope), do: %{}

  defp netflow_rdns_ips(_flows, nil), do: []
  defp netflow_rdns_ips([], _user), do: []

  defp netflow_rdns_ips(flows, _user) do
    flows
    |> Enum.flat_map(fn flow -> [netflow_addr(flow, :src), netflow_addr(flow, :dst)] end)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 in ["", "—", "-", "Unknown"]))
    |> Enum.uniq()
  end

  defp netflow_talker_rdns_ips(_top_talkers, nil), do: []
  defp netflow_talker_rdns_ips([], _user), do: []

  defp netflow_talker_rdns_ips(top_talkers, _user) do
    top_talkers
    |> Enum.map(fn row -> row && Map.get(row, :ip) end)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn ip ->
      ip in ["", "—", "-", "Unknown"] or String.contains?(ip, "/")
    end)
    |> Enum.uniq()
  end

  defp rdns_map_for_ips([], _user), do: %{}

  defp rdns_map_for_ips(ips, user) when is_list(ips) do
    now = DateTime.utc_now()

    query =
      IpRdnsCache
      |> Ash.Query.for_read(:read, %{})
      |> EnrichmentExpiry.live_for_ips(ips, now)

    case Ash.read(query, actor: user) do
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

  defp load_netflow_threat_map(flows) when is_list(flows) do
    ips =
      flows
      |> Enum.flat_map(fn flow -> [netflow_addr(flow, :src), netflow_addr(flow, :dst)] end)
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 in ["", "—", "-", "Unknown"]))
      |> Enum.uniq()
      |> Enum.take(400)

    threat_map_for_ips(ips)
  end

  defp load_netflow_threat_map(_flows), do: %{}

  defp threat_map_for_ips([]), do: %{}

  @sobelow_skip ["SQL.Query"]
  defp threat_map_for_ips(ips) when is_list(ips) do
    sql = """
    SELECT ip, match_count, max_severity, sources
    FROM platform.ip_threat_intel_cache
    WHERE ip = ANY($1::text[])
      AND matched = true
      AND expires_at > now()
    """

    case Repo.query(sql, [ips]) do
      {:ok, %{rows: rows}} ->
        Map.new(rows, fn [ip, match_count, max_severity, sources] ->
          {ip,
           %{
             match_count: to_int(match_count),
             max_severity: to_int(max_severity),
             sources: sources |> List.wrap() |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == ""))
           }}
        end)

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp sanitize_srql_for_stats(query), do: NFQuery.flows_sanitize_for_stats(to_string(query))

  defp load_netflow_timeseries(srql_module, current_query, scope) do
    base_query =
      current_query
      |> netflow_base_query()
      |> sanitize_srql_for_stats()

    time_token = extract_time_from_query(base_query) || @default_netflow_window

    bucket_seconds =
      case resolve_srql_time(time_token) do
        {:ok, %{start: start_dt, end: end_dt}} -> choose_netflow_bucket_seconds(start_dt, end_dt)
        _ -> 300
      end

    bucket = bucket_seconds_to_srql(bucket_seconds)

    query =
      ~s|#{base_query} bucket:#{bucket} agg:sum value_field:bytes_total limit:120|

    rows =
      case srql_module.query(query, %{scope: scope}) do
        {:ok, %{"results" => results}} when is_list(results) ->
          results

        _ ->
          []
      end

    buckets =
      Enum.reduce(rows, %{}, fn
        %{"timestamp" => ts, "value" => value}, acc ->
          with {:ok, dt} <- parse_srql_datetime(ts),
               bytes when is_number(bytes) <- to_number(value) do
            Map.update(acc, dt, bytes, &(&1 + bytes))
          else
            _ -> acc
          end

        _row, acc ->
          acc
      end)

    points =
      buckets
      |> Enum.sort_by(fn {dt, _bytes} -> DateTime.to_unix(dt, :second) end)
      |> Enum.map(fn {bucket_start, bytes} ->
        %{
          bucket_start: bucket_start,
          bucket_end: DateTime.add(bucket_start, bucket_seconds, :second),
          bytes: trunc(bytes)
        }
      end)
      |> Enum.take(120)

    %{bucket_seconds: bucket_seconds, points: points}
  rescue
    _ ->
      %{bucket_seconds: 300, points: []}
  end

  defp load_netflow_timeseries_stacked(srql_module, current_query, scope, bucket_seconds, total_points, mode)
       when is_integer(bucket_seconds) and is_list(total_points) and is_binary(mode) do
    base_query =
      current_query
      |> netflow_base_query()
      |> sanitize_srql_for_stats()

    bucket = bucket_seconds_to_srql(bucket_seconds)

    {keys, series_maps} =
      netflow_stacked_series(srql_module, current_query, scope, base_query, bucket, mode)

    points =
      total_points
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn p ->
        start_dt = Map.get(p, :bucket_start)

        row =
          Enum.reduce(keys, %{"t" => DateTime.to_iso8601(start_dt)}, fn k, acc ->
            bytes = to_int(Map.get(Map.get(series_maps, k, %{}), start_dt, 0))
            Map.put(acc, k, bytes)
          end)

        row
      end)
      |> Enum.take(120)

    %{bucket_seconds: bucket_seconds, keys: keys, points: points}
  rescue
    _ ->
      %{bucket_seconds: bucket_seconds, keys: [], points: []}
  end

  defp load_netflow_timeseries_stacked(_srql_module, _current_query, _scope, bucket_seconds, _points, _mode),
    do: %{bucket_seconds: bucket_seconds, keys: [], points: []}

  defp load_netflow_protocol_activity(srql_module, current_query, scope, bucket_seconds, total_points)
       when is_integer(bucket_seconds) and is_list(total_points) do
    keys = ["tcp", "udp", "other"]

    colors =
      netflow_series_colors(keys, [
        "#4e79a7",
        "#59a14f",
        "#bab0ac"
      ])

    series_maps =
      load_netflow_timeseries_series_maps(
        srql_module,
        current_query,
        scope,
        bucket_seconds,
        total_points,
        "protocol_group",
        keys
      )

    %{bucket_seconds: bucket_seconds, keys: keys, points: series_maps.points, colors: colors}
  rescue
    _ ->
      %{bucket_seconds: bucket_seconds, keys: [], points: [], colors: %{}}
  end

  defp load_netflow_protocol_activity(_srql_module, _current_query, _scope, bucket_seconds, _points),
    do: %{bucket_seconds: bucket_seconds, keys: [], points: [], colors: %{}}

  defp load_netflow_app_activity(srql_module, current_query, scope, bucket_seconds, total_points)
       when is_integer(bucket_seconds) and is_list(total_points) do
    base_query =
      current_query
      |> netflow_base_query()
      |> sanitize_srql_for_stats()

    # Find top apps by bytes for this window, then downsample only those.
    keys =
      srql_module
      |> apply(:query, [
        ~s|#{base_query} stats:"sum(bytes_total) as total_bytes by app" sort:total_bytes:desc limit:8|,
        %{scope: scope}
      ])
      |> extract_stats_rows()
      |> Enum.map(&Map.get(&1, "app"))
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 in ["", "unknown", "Unknown", "—", "-"]))
      |> Enum.uniq()
      |> Enum.take(8)

    colors = netflow_series_colors(keys, netflow_default_palette())

    series_maps =
      load_netflow_timeseries_series_maps(
        srql_module,
        current_query,
        scope,
        bucket_seconds,
        total_points,
        "app",
        keys
      )

    %{bucket_seconds: bucket_seconds, keys: keys, points: series_maps.points, colors: colors}
  rescue
    _ ->
      %{bucket_seconds: bucket_seconds, keys: [], points: [], colors: %{}}
  end

  defp load_netflow_app_activity(_srql_module, _current_query, _scope, bucket_seconds, _points),
    do: %{bucket_seconds: bucket_seconds, keys: [], points: [], colors: %{}}

  defp load_netflow_frequent_talkers_packets(srql_module, current_query, scope, limit \\ 10) do
    base_query =
      current_query
      |> netflow_base_query()
      |> sanitize_srql_for_stats()

    query =
      ~s|#{base_query} stats:"sum(packets_total) as total_packets by src_endpoint_ip" sort:total_packets:desc limit:#{limit}|

    srql_module
    |> apply(:query, [query, %{scope: scope}])
    |> extract_stats_rows()
    |> Enum.map(fn row ->
      %{
        ip: Map.get(row, "src_endpoint_ip"),
        packets: to_int(Map.get(row, "total_packets"))
      }
    end)
    |> Enum.reject(fn row -> not (is_binary(row.ip) and String.trim(row.ip) != "") end)
  rescue
    _ ->
      []
  end

  defp load_netflow_frequent_talkers_bytes(srql_module, current_query, scope, limit \\ 10) do
    base_query =
      current_query
      |> netflow_base_query()
      |> sanitize_srql_for_stats()

    query =
      ~s|#{base_query} stats:"sum(bytes_total) as total_bytes by src_endpoint_ip" sort:total_bytes:desc limit:#{limit}|

    srql_module
    |> apply(:query, [query, %{scope: scope}])
    |> extract_stats_rows()
    |> Enum.map(fn row ->
      %{
        ip: Map.get(row, "src_endpoint_ip"),
        bytes: to_int(Map.get(row, "total_bytes"))
      }
    end)
    |> Enum.reject(fn row -> not (is_binary(row.ip) and String.trim(row.ip) != "") end)
  rescue
    _ ->
      []
  end

  defp load_netflow_timeseries_series_maps(
         srql_module,
         current_query,
         scope,
         bucket_seconds,
         total_points,
         series_field,
         keys
       )
       when is_integer(bucket_seconds) and is_list(total_points) and is_binary(series_field) do
    base_query =
      current_query
      |> netflow_base_query()
      |> sanitize_srql_for_stats()

    bucket = bucket_seconds_to_srql(bucket_seconds)

    query =
      base_query
      |> maybe_limit_series(series_field, keys)
      |> then(fn q ->
        ~s|#{q} bucket:#{bucket} agg:sum value_field:bytes_total series:#{series_field} limit:2000|
      end)

    rows =
      case srql_module.query(query, %{scope: scope}) do
        {:ok, %{"results" => results}} when is_list(results) -> results
        _ -> []
      end

    series_maps =
      Enum.reduce(rows, %{}, fn
        %{"timestamp" => ts, "series" => series, "value" => value}, acc ->
          with {:ok, dt} <- parse_srql_datetime(ts),
               series when is_binary(series) <- series,
               bytes when is_number(bytes) <- to_number(value) do
            put_netflow_series_value(acc, series, dt, bytes)
          else
            _ -> acc
          end

        _row, acc ->
          acc
      end)

    keys =
      keys
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 in ["", "unknown", "Unknown", "—", "-"]))
      |> Enum.uniq()

    points =
      total_points
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn p ->
        start_dt = Map.get(p, :bucket_start)

        Enum.reduce(keys, %{"t" => DateTime.to_iso8601(start_dt)}, fn k, acc ->
          bytes = to_int(Map.get(Map.get(series_maps, k, %{}), start_dt, 0))
          Map.put(acc, k, bytes)
        end)
      end)
      |> Enum.take(120)

    %{points: points, series_maps: series_maps}
  rescue
    _ ->
      %{points: [], series_maps: %{}}
  end

  defp put_netflow_series_value(acc, series, dt, bytes) when is_map(acc) and is_binary(series) do
    series = String.trim(series)

    if series == "" do
      acc
    else
      Map.update(acc, series, %{dt => bytes}, fn m ->
        Map.update(m, dt, bytes, &(&1 + bytes))
      end)
    end
  end

  defp put_netflow_series_value(acc, _series, _dt, _bytes), do: acc

  defp maybe_limit_series(query, series_field, keys) when is_binary(query) and is_binary(series_field) do
    values =
      keys
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 in ["", "unknown", "Unknown", "—", "-"]))
      |> Enum.uniq()
      |> Enum.take(20)

    if values == [] do
      query
    else
      upsert_query_filter(query, series_field, "(" <> Enum.join(values, ",") <> ")")
    end
  end

  defp netflow_default_palette do
    [
      "#4e79a7",
      "#f28e2b",
      "#e15759",
      "#76b7b2",
      "#59a14f",
      "#edc948",
      "#b07aa1",
      "#ff9da7",
      "#9c755f",
      "#bab0ac"
    ]
  end

  defp netflow_series_colors(keys, palette) when is_list(keys) and is_list(palette) do
    keys
    |> Enum.with_index()
    |> Map.new(fn {k, idx} -> {k, Enum.at(palette, rem(idx, max(length(palette), 1)))} end)
  end

  defp load_netflow_top_talkers_ips(srql_module, current_query, scope, limit) do
    base_query =
      current_query
      |> netflow_base_query()
      |> sanitize_srql_for_stats()

    query =
      ~s|#{base_query} stats:"sum(bytes_total) as total_bytes by src_endpoint_ip" sort:total_bytes:desc limit:#{limit}|

    srql_module
    |> apply(:query, [query, %{scope: scope}])
    |> extract_stats_rows()
    |> Enum.map(fn row ->
      %{
        ip: Map.get(row, "src_endpoint_ip"),
        bytes: to_int(Map.get(row, "total_bytes"))
      }
    end)
  rescue
    _ ->
      []
  end

  defp netflow_stacked_series(srql_module, current_query, scope, base_query, bucket, mode) do
    if mode == "talkers" do
      netflow_stacked_talkers_series(srql_module, current_query, scope, base_query, bucket)
    else
      netflow_stacked_ports_series(srql_module, current_query, scope, base_query, bucket)
    end
  end

  defp netflow_stacked_talkers_series(srql_module, current_query, scope, base_query, bucket) do
    talkers = load_netflow_top_talkers_ips(srql_module, current_query, scope, 8)

    keys =
      talkers
      |> Enum.map(&Map.get(&1, :ip))
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 in ["", "Unknown", "—", "-"]))
      |> Enum.uniq()
      |> Enum.take(8)

    maps =
      Map.new(keys, fn ip ->
        {ip,
         load_netflow_timeseries_bytes_map(
           srql_module,
           scope,
           base_query,
           bucket,
           " src_ip:#{ip}"
         )}
      end)

    {keys, maps}
  end

  defp netflow_stacked_ports_series(srql_module, current_query, scope, base_query, bucket) do
    ports = load_netflow_top_ports(srql_module, current_query, scope, 8)

    labeled =
      ports
      |> Enum.map(fn row ->
        port = Map.get(row, :port)

        label =
          case netflow_service_label(port) do
            s when is_binary(s) and s != "" -> "#{s}:#{port}"
            _ -> to_string(port)
          end

        %{label: label, port: port}
      end)
      |> Enum.reject(fn %{port: port} -> not is_integer(port) or port <= 0 end)
      |> Enum.uniq_by(& &1.label)
      |> Enum.take(8)

    keys = Enum.map(labeled, & &1.label)

    maps =
      Map.new(labeled, fn %{label: label, port: port} ->
        {label,
         load_netflow_timeseries_bytes_map(
           srql_module,
           scope,
           base_query,
           bucket,
           " dst_port:#{port}"
         )}
      end)

    {keys, maps}
  end

  defp load_netflow_timeseries_bytes_map(srql_module, scope, base_query, bucket, filter_suffix)
       when is_binary(base_query) and is_binary(bucket) and is_binary(filter_suffix) do
    query =
      ~s|#{base_query}#{filter_suffix} bucket:#{bucket} agg:sum value_field:bytes_total limit:120|

    rows =
      case srql_module.query(query, %{scope: scope}) do
        {:ok, %{"results" => results}} when is_list(results) -> results
        _ -> []
      end

    Enum.reduce(rows, %{}, fn
      %{"timestamp" => ts, "value" => value}, acc ->
        with {:ok, dt} <- parse_srql_datetime(ts),
             bytes when is_number(bytes) <- to_number(value) do
          Map.update(acc, dt, bytes, &(&1 + bytes))
        else
          _ -> acc
        end

      _row, acc ->
        acc
    end)
  rescue
    _ -> %{}
  end

  defp load_netflow_timeseries_compare(_srql_module, _current_query, _scope, mode, bucket_seconds)
       when mode not in ["previous", "yesterday"] do
    %{bucket_seconds: bucket_seconds, points: []}
  end

  defp load_netflow_timeseries_compare(srql_module, current_query, scope, mode, bucket_seconds)
       when mode in ["previous", "yesterday"] do
    base_query =
      current_query
      |> netflow_base_query()
      |> sanitize_srql_for_stats()

    time_token = extract_time_from_query(base_query) || @default_netflow_window

    case resolve_srql_time(time_token) do
      {:ok, %{start: start_dt, end: end_dt}} ->
        span_seconds = max(DateTime.diff(end_dt, start_dt, :second), 1)

        {cstart, cend} =
          case mode do
            "previous" ->
              {DateTime.add(start_dt, -span_seconds, :second), start_dt}

            "yesterday" ->
              {DateTime.add(start_dt, -86_400, :second), DateTime.add(end_dt, -86_400, :second)}
          end

        compare_time = "[#{DateTime.to_iso8601(cstart)},#{DateTime.to_iso8601(cend)}]"
        compare_query = upsert_query_filter(base_query, "time", compare_time)
        bucket = bucket_seconds_to_srql(bucket_seconds)

        query =
          ~s|#{compare_query} bucket:#{bucket} agg:sum value_field:bytes_total limit:120|

        rows =
          case srql_module.query(query, %{scope: scope}) do
            {:ok, %{"results" => results}} when is_list(results) -> results
            _ -> []
          end

        buckets =
          Enum.reduce(rows, %{}, fn
            %{"timestamp" => ts, "value" => value}, acc ->
              with {:ok, dt} <- parse_srql_datetime(ts),
                   bytes when is_number(bytes) <- to_number(value) do
                Map.update(acc, dt, bytes, &(&1 + bytes))
              else
                _ -> acc
              end

            _row, acc ->
              acc
          end)

        points =
          buckets
          |> Enum.sort_by(fn {dt, _bytes} -> DateTime.to_unix(dt, :second) end)
          |> Enum.map(fn {bucket_start, bytes} ->
            %{
              bucket_start: bucket_start,
              bucket_end: DateTime.add(bucket_start, bucket_seconds, :second),
              bytes: trunc(bytes)
            }
          end)
          |> Enum.take(120)

        %{bucket_seconds: bucket_seconds, points: points}

      _ ->
        %{bucket_seconds: bucket_seconds, points: []}
    end
  rescue
    _ ->
      %{bucket_seconds: bucket_seconds, points: []}
  end

  defp load_netflow_geo_heatmap(srql_module, current_query, scope, geo_side) do
    base_query =
      current_query
      |> netflow_base_query()
      |> sanitize_srql_for_stats()

    field =
      case geo_side do
        "src" -> "src_country_iso2"
        _ -> "dst_country_iso2"
      end

    query =
      ~s|#{base_query} stats:"sum(bytes_total) as total_bytes by #{field}" sort:total_bytes:desc limit:64|

    srql_module
    |> apply(:query, [query, %{scope: scope}])
    |> extract_stats_rows()
    |> Enum.map(fn row ->
      %{
        country: Map.get(row, field) || Map.get(row, String.replace(field, "_iso2", "")),
        bytes: to_int(Map.get(row, "total_bytes"))
      }
    end)
    |> Enum.reject(fn r -> is_nil(r.country) or r.country in ["", "Unknown"] or r.bytes <= 0 end)
  rescue
    _ ->
      []
  end

  defp load_netflow_sankey(srql_module, current_query, scope, prefix) when prefix in [16, 24] do
    base_query =
      current_query
      |> netflow_base_query()
      |> sanitize_srql_for_stats()

    # Always render Sankey if selected. We keep query guardrails (top-N preselection + caps)
    # inside `build_netflow_sankey/4` and accept that some windows may be slower.
    build_netflow_sankey(srql_module, base_query, scope, prefix)
  rescue
    _ ->
      empty_netflow_sankey()
  end

  defp load_netflow_sankey(_srql_module, _current_query, _scope, _prefix), do: empty_netflow_sankey()

  defp empty_netflow_sankey, do: %{edges: [], sources: [], mids: [], dests: []}

  defp build_netflow_sankey(srql_module, base_query, scope, prefix) do
    # SRQL doesn't guarantee support for expression-style group-by like `src_cidr:24` across all backends.
    # To keep Sankey reliable, always group by raw endpoint IPs in SRQL and CIDR-collapse in Elixir.
    ip_query =
      ~s|#{base_query} stats:"sum(bytes_total) as total_bytes by src_endpoint_ip, dst_endpoint_port, dst_endpoint_ip" sort:total_bytes:desc limit:#{@netflow_sankey_query_limit}|

    rows = srql_stats_rows(srql_module, ip_query, scope, "IP")

    edges =
      rows
      |> Enum.map(fn row ->
        netflow_sankey_edge_ip(row, prefix)
      end)
      |> Enum.reject(fn e ->
        is_nil(e.src) or e.src in ["", "Unknown"] or is_nil(e.dst) or e.dst in ["", "Unknown"] or
          e.bytes <= 0
      end)
      |> aggregate_netflow_sankey_edges()
      |> focus_netflow_sankey_edges()

    sources = sum_edges_by(edges, :src)
    mids = sum_edges_by(edges, :mid)
    dests = sum_edges_by(edges, :dst)

    %{
      edges: edges,
      sources: sources |> Enum.sort_by(fn {_k, v} -> -v end) |> Enum.take(@netflow_sankey_max_sources),
      mids: mids |> Enum.sort_by(fn {_k, v} -> -v end) |> Enum.take(@netflow_sankey_max_mids),
      dests: dests |> Enum.sort_by(fn {_k, v} -> -v end) |> Enum.take(@netflow_sankey_max_dests)
    }
  rescue
    _ ->
      empty_netflow_sankey()
  end

  defp aggregate_netflow_sankey_edges(edges) when is_list(edges) do
    edges
    |> Enum.reduce(%{}, fn edge, acc ->
      key = {edge.src, edge.mid, edge.port, edge.dst}

      Map.update(acc, key, edge, fn existing ->
        %{existing | bytes: existing.bytes + edge.bytes}
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.bytes, :desc)
  end

  defp focus_netflow_sankey_edges(edges) when is_list(edges) do
    top_sources = top_sankey_keys(edges, :src, @netflow_sankey_max_sources)
    top_mids = top_sankey_keys(edges, :mid, @netflow_sankey_max_mids)
    top_dests = top_sankey_keys(edges, :dst, @netflow_sankey_max_dests)

    edges
    |> Enum.filter(fn edge ->
      MapSet.member?(top_sources, edge.src) and MapSet.member?(top_mids, edge.mid) and
        MapSet.member?(top_dests, edge.dst)
    end)
    |> Enum.take(@netflow_sankey_max_edges)
  end

  defp top_sankey_keys(edges, key, limit) when is_list(edges) and is_atom(key) do
    edges
    |> sum_edges_by(key)
    |> Enum.sort_by(fn {_value, bytes} -> -bytes end)
    |> Enum.take(limit)
    |> MapSet.new(fn {value, _bytes} -> value end)
  end

  defp srql_stats_rows(srql_module, query, scope, label) when is_binary(query) and is_binary(label) do
    case apply(srql_module, :query, [query, %{scope: scope}]) do
      {:ok, _} = ok ->
        extract_stats_rows(ok)

      {:error, reason} ->
        Logger.warning("NetFlow sankey #{label} query failed: #{inspect(reason)}")
        []

      other ->
        Logger.warning("NetFlow sankey #{label} query unexpected result: #{inspect(other)}")
        []
    end
  end

  defp netflow_sankey_edge_ip(row, prefix) when prefix in [16, 24] do
    src = ip_to_cidr(Map.get(row, "src_endpoint_ip"), prefix)
    dst = ip_to_cidr(Map.get(row, "dst_endpoint_ip"), prefix)
    port = to_int(Map.get(row, "dst_endpoint_port"))
    bytes = to_int(Map.get(row, "total_bytes"))
    mid = netflow_port_mid_label(port)
    %{src: src, mid: mid, port: port, dst: dst, bytes: bytes}
  end

  defp ip_to_cidr(nil, _prefix), do: nil

  defp ip_to_cidr(ip, prefix) when is_binary(ip) and prefix in [16, 24] do
    ip = String.trim(ip)

    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, {a, b, c, _d}} ->
        case prefix do
          24 -> "#{a}.#{b}.#{c}.0/24"
          16 -> "#{a}.#{b}.0.0/16"
        end

      _ ->
        ip
    end
  end

  defp ip_to_cidr(ip, _prefix) when is_binary(ip), do: String.trim(ip)

  defp netflow_port_mid_label(port) when is_integer(port) and port > 0 do
    case netflow_service_label(port) do
      label when is_binary(label) -> "#{label}:#{port}"
      _ -> "PORT:#{port}"
    end
  end

  defp netflow_port_mid_label(_), do: "PORT:?"

  defp sum_edges_by(edges, key) when is_list(edges) do
    edges
    |> Enum.reduce(%{}, fn e, acc ->
      Map.update(acc, Map.get(e, key), e.bytes, &(&1 + e.bytes))
    end)
    |> Map.to_list()
  end

  defp resolve_srql_time(value) when is_binary(value) do
    value
    |> String.trim()
    |> resolve_srql_time(DateTime.utc_now())
  end

  defp resolve_srql_time("today", now) do
    start =
      now
      |> DateTime.to_date()
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    {:ok, %{start: start, end: now}}
  end

  defp resolve_srql_time("yesterday", now) do
    today = DateTime.to_date(now)
    start = today |> Date.add(-1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    end_dt = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")
    {:ok, %{start: start, end: end_dt}}
  end

  defp resolve_srql_time(value, now) do
    cond do
      bracketed_time?(value) ->
        parse_bracketed_time(value)

      last_duration?(value) ->
        resolve_last_duration(value, now)

      true ->
        {:error, :unsupported}
    end
  end

  defp bracketed_time?(value) do
    String.starts_with?(value, "[") and String.ends_with?(value, "]")
  end

  defp parse_bracketed_time(value) do
    inner = value |> String.trim_leading("[") |> String.trim_trailing("]")

    case String.split(inner, ",", parts: 2) do
      [start_raw, end_raw] ->
        with {:ok, start_dt, _} <- DateTime.from_iso8601(String.trim(start_raw)),
             {:ok, end_dt, _} <- DateTime.from_iso8601(String.trim(end_raw)),
             true <- DateTime.compare(start_dt, end_dt) in [:lt, :eq] do
          {:ok, %{start: start_dt, end: end_dt}}
        else
          _ -> {:error, :bad_time}
        end

      _ ->
        {:error, :bad_time}
    end
  end

  defp last_duration?(value) do
    Regex.match?(~r/^(?:last[_-])?\d+[mhd]$/i, value)
  end

  defp resolve_last_duration(value, now) do
    normalized = value |> String.downcase() |> String.replace(~r/^last[_-]/, "")
    amount = String.slice(normalized, 0, max(byte_size(normalized) - 1, 0))
    unit = String.slice(normalized, -1, 1)

    case Integer.parse(amount) do
      {n, ""} when n > 0 ->
        case duration_unit_multiplier(unit) do
          seconds when is_integer(seconds) and seconds > 0 ->
            {:ok, %{start: DateTime.add(now, -(n * seconds), :second), end: now}}

          _ ->
            {:error, :bad_time}
        end

      _ ->
        {:error, :bad_time}
    end
  end

  defp duration_unit_multiplier("m"), do: 60
  defp duration_unit_multiplier("h"), do: 3_600
  defp duration_unit_multiplier("d"), do: 86_400
  defp duration_unit_multiplier(_), do: 0

  defp netflow_patch_opts(compact?, talker_cidr, compare_mode, geo_side, sankey_prefix, stack_mode, graph_mode, view) do
    %{
      compact?: compact?,
      talker_cidr: talker_cidr,
      compare_mode: compare_mode,
      geo_side: geo_side,
      sankey_prefix: sankey_prefix,
      stack_mode: stack_mode,
      graph_mode: graph_mode,
      view: view
    }
  end

  defp choose_netflow_bucket_seconds(start_dt, end_dt) do
    span = DateTime.diff(end_dt, start_dt, :second)

    cond do
      span <= 60 * 60 -> 60
      span <= 6 * 60 * 60 -> 300
      span <= 24 * 60 * 60 -> 900
      span <= 7 * 24 * 60 * 60 -> 3600
      true -> 6 * 3600
    end
  end

  defp bucket_seconds_to_srql(60), do: "1m"
  defp bucket_seconds_to_srql(300), do: "5m"
  defp bucket_seconds_to_srql(900), do: "15m"
  defp bucket_seconds_to_srql(3600), do: "1h"
  defp bucket_seconds_to_srql(21_600), do: "6h"

  defp bucket_seconds_to_srql(seconds) when is_integer(seconds) and rem(seconds, 60) == 0, do: "#{div(seconds, 60)}m"

  defp bucket_seconds_to_srql(seconds) when is_integer(seconds), do: "#{seconds}s"

  defp parse_srql_datetime(value) when is_binary(value) do
    value = String.trim(value)

    case DateTime.from_iso8601(value) do
      {:ok, dt, _} ->
        {:ok, dt}

      _ ->
        # SRQL results may normalize timestamptz values as naive ISO8601 strings
        # (no timezone offset). Treat those as UTC for charting.
        case NaiveDateTime.from_iso8601(value) do
          {:ok, ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
          _ -> :error
        end
    end
  end

  defp parse_srql_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp parse_srql_datetime(%NaiveDateTime{} = ndt), do: {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}

  defp parse_srql_datetime(_), do: :error

  defp to_number(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_number(v) when is_integer(v), do: v * 1.0
  defp to_number(v) when is_float(v), do: v

  defp to_number(v) when is_binary(v) do
    case Float.parse(String.trim(v)) do
      {f, ""} -> f
      _ -> 0.0
    end
  end

  defp to_number(_), do: 0.0

  defp netflow_chart_bar_w(total, _width) when total <= 0, do: 1.0
  defp netflow_chart_bar_w(total, width), do: max(width / total, 1.0)

  defp netflow_chart_h(_bytes, 0, _height), do: 1.0

  defp netflow_chart_h(bytes, max_bytes, height) when is_integer(bytes) and is_integer(max_bytes) do
    scaled = bytes / max(max_bytes, 1) * height
    max(scaled, 1.0)
  end

  defp netflow_timeseries_polyline(points, max_bytes, width, height, mode) do
    chart_mode = if mode == "lines", do: :lines, else: :grid

    points
    |> Enum.zip(RangeSelection.x_positions(length(points), chart_mode, width))
    |> Enum.map_join(" ", fn {p, x} ->
      y = 150 - netflow_chart_h(Map.get(p, :bytes, 0), max_bytes, height)
      "#{Float.round(x, 1)},#{Float.round(y, 1)}"
    end)
  end

  defp format_bucket(seconds) when is_integer(seconds) and seconds < 60, do: "#{seconds}s"

  defp format_bucket(seconds) when is_integer(seconds) and rem(seconds, 3600) == 0, do: "#{div(seconds, 3600)}h"

  defp format_bucket(seconds) when is_integer(seconds) and rem(seconds, 60) == 0, do: "#{div(seconds, 60)}m"

  defp format_bucket(seconds) when is_integer(seconds), do: "#{seconds}s"

  # Load sparkline data for gauge/counter metrics
  # Returns a map of metric_name -> list of {bucket, avg_value} tuples
  defp load_sparklines(metrics, scope) when is_list(metrics) do
    metric_names = sparkline_metric_names(metrics)

    if metric_names == [] do
      %{}
    else
      fetch_sparklines(metric_names, scope)
    end
  rescue
    e ->
      # Log error but don't crash - sparklines are nice-to-have
      require Logger

      Logger.warning("Failed to load sparklines: #{inspect(e)}")
      %{}
  end

  defp load_sparklines(_, _), do: %{}

  defp sparkline_metric_names(metrics) do
    metrics
    |> Enum.filter(fn metric ->
      type = normalize_string(Map.get(metric, "metric_type"))
      type in ["gauge", "counter"]
    end)
    |> Enum.map(&Map.get(&1, "metric_name"))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp fetch_sparklines(metric_names, _scope) do
    cutoff = DateTime.add(DateTime.utc_now(), -2, :hour)

    query =
      from(m in "otel_metrics",
        where: m.metric_name in ^metric_names and m.timestamp >= ^cutoff,
        group_by: [m.metric_name, fragment("time_bucket('5 minutes', ?)", m.timestamp)],
        order_by: [m.metric_name, fragment("time_bucket('5 minutes', ?)", m.timestamp)],
        select: %{
          metric_name: m.metric_name,
          bucket: fragment("time_bucket('5 minutes', ?)", m.timestamp),
          avg_value: avg(m.value)
        }
      )

    query
    |> Repo.all()
    |> Enum.group_by(& &1.metric_name, fn row -> numeric_to_float(row.avg_value) end)
  end

  defp format_pct(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp format_pct(value) when is_integer(value), do: Integer.to_string(value)
  defp format_pct(_), do: "0.0"

  defp format_compact_int(n) when is_integer(n) and n >= 1_000_000 do
    (n / 1_000_000)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
    |> Kernel.<>("M")
  end

  defp format_compact_int(n) when is_integer(n) and n >= 1_000 do
    (n / 1_000)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
    |> Kernel.<>("k")
  end

  defp format_compact_int(n) when is_integer(n), do: Integer.to_string(n)
  defp format_compact_int(_), do: "0"

  defp error_count_class(count) when is_integer(count) and count > 0, do: "text-rose-400 font-bold"
  defp error_count_class(_), do: "text-sr-muted"

  # Heat scale for trace duration cells (absolute thresholds; easy to scan).
  defp duration_ms_class(ms) when is_number(ms) do
    cond do
      ms < 50 -> "text-sr-muted"
      ms < 100 -> "text-emerald-400/90"
      ms < 250 -> "text-emerald-300"
      ms < 500 -> "bg-amber-400/10 text-amber-300"
      ms < 1000 -> "bg-amber-400/15 text-amber-400 font-medium"
      ms < 3000 -> "bg-orange-500/15 text-orange-400 font-semibold"
      true -> "bg-rose-500/15 text-rose-400 font-semibold"
    end
  end

  defp duration_ms_class(_), do: "text-sr-muted"

  defp duration_ms_title(ms) when is_number(ms) do
    cond do
      ms < 50 -> "Fast (<50ms)"
      ms < 100 -> "Fast"
      ms < 250 -> "OK"
      ms < 500 -> "Elevated"
      ms < 1000 -> "Slow"
      ms < 3000 -> "Very slow"
      true -> "Critical latency"
    end
  end

  defp duration_ms_title(_), do: nil

  defp trace_service_name(trace) do
    normalize_string(Map.get(trace, "root_service_name")) ||
      normalize_string(Map.get(trace, "service_name")) ||
      first_service(Map.get(trace, "service_set"))
  end

  # Orphan traces (no exported root span) can have a NULL root_service_name in
  # the summary, but service_set still records the services seen on the trace.
  # Fall back to the first known service so the list never renders a blank.
  defp first_service(services) when is_list(services) do
    Enum.find_value(services, fn svc -> normalize_string(svc) end)
  end

  defp first_service(_), do: nil

  defp trace_operation_name(trace) do
    normalize_string(Map.get(trace, "root_span_name")) ||
      normalize_string(Map.get(trace, "span_name")) ||
      normalize_string(Map.get(trace, "name"))
  end

  defp trace_duration_ms(trace) do
    cond do
      is_number(Map.get(trace, "duration_ms")) ->
        Map.get(trace, "duration_ms")

      is_number(Map.get(trace, "end_time_unix_nano")) and is_number(Map.get(trace, "start_time_unix_nano")) ->
        (Map.get(trace, "end_time_unix_nano") - Map.get(trace, "start_time_unix_nano")) / 1_000_000

      true ->
        nil
    end
  end

  defp trace_error_count(trace) do
    cond do
      Map.has_key?(trace, "error_count") ->
        trace |> Map.get("error_count", 0) |> to_int()

      to_int(Map.get(trace, "status_code")) == 2 ->
        1

      true ->
        0
    end
  end

  defp metric_operation(metric) do
    grpc = grpc_operation(metric)
    http = http_operation(metric)

    cond do
      is_binary(grpc) -> grpc
      is_binary(http) -> http
      true -> Map.get(metric, "span_name") || "—"
    end
  end

  defp grpc_operation(metric) do
    grpc_service = Map.get(metric, "grpc_service")
    grpc_method = Map.get(metric, "grpc_method")

    if non_empty_string?(grpc_service) and non_empty_string?(grpc_method) do
      "#{grpc_service}/#{grpc_method}"
    end
  end

  defp http_operation(metric) do
    http_route = Map.get(metric, "http_route")
    http_method = Map.get(metric, "http_method")

    cond do
      non_empty_string?(http_method) and non_empty_string?(http_route) ->
        "#{http_method} #{http_route}"

      non_empty_string?(http_route) ->
        http_route

      true ->
        nil
    end
  end

  defp trace_detail_path(trace) do
    case ServiceRadarWebNGWeb.TraceLive.Show.normalize_trace_id(Map.get(trace, "trace_id")) do
      {:ok, trace_id} -> "/observability/traces/#{trace_id}"
      :error -> nil
    end
  end

  # Stat-card click-through targets (same patch pattern as the logs cards).
  defp traces_card_href(q), do: ObservabilityPaths.path("traces", %{q: q})
  defp metrics_card_href(q), do: ObservabilityPaths.path("metrics", %{q: q})

  defp correlate_metric_href(metric) do
    trace_id = Map.get(metric, "trace_id")

    if is_binary(trace_id) and trace_id != "" do
      q =
        "in:logs trace_id:\"#{escape_srql_value(trace_id)}\" #{correlated_logs_time_window(metric)} sort:timestamp:desc"

      ObservabilityPaths.path("logs", %{q: q})
    else
      ObservabilityPaths.path("logs")
    end
  end

  # Correlation windows derive from the source signal's own timestamp (±1h)
  # rather than a fixed relative window that can miss older samples.
  defp correlated_logs_time_window(metric) do
    case parse_timestamp(Map.get(metric, "timestamp") || Map.get(metric, "observed_timestamp")) do
      {:ok, dt} ->
        from = dt |> DateTime.add(-3600, :second) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        to = dt |> DateTime.add(3600, :second) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        "time:[#{from},#{to}]"

      _ ->
        "time:last_24h"
    end
  end

  defp escape_srql_value(nil), do: ""

  defp escape_srql_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_srql_value(value), do: value |> to_string() |> escape_srql_value()

  defp metric_numeric_value(metric, keys) when is_map(metric) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(metric, key) do
        value when is_number(value) -> value
        value when is_binary(value) -> extract_number(value)
        _ -> nil
      end
    end)
  end

  defp duration_ms_from_metric(metric) when is_map(metric) do
    case metric_numeric_value(metric, ["duration_ms"]) do
      value when is_number(value) ->
        value * 1.0

      _ ->
        case metric_numeric_value(metric, ["duration_seconds"]) do
          value when is_number(value) -> value * 1000.0
          _ -> nil
        end
    end
  end

  defp duration_ms_from_metric(_), do: nil

  defp extract_number(value) when is_number(value), do: value

  defp extract_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp extract_number(_), do: nil

  defp log_service(log) do
    service =
      Map.get(log, "service_name") ||
        Map.get(log, "source") ||
        Map.get(log, "scope_name")

    case service do
      nil -> "—"
      "" -> "—"
      v when is_binary(v) -> v
      v -> to_string(v)
    end
  end

  defp log_message(log) do
    message =
      Map.get(log, "body") ||
        Map.get(log, "message") ||
        Map.get(log, "short_message")

    case message do
      nil -> "—"
      "" -> "—"
      v when is_binary(v) -> String.slice(v, 0, 300)
      v -> v |> to_string() |> String.slice(0, 300)
    end
  end

  defp trace_rollup_warning?(%{healthy?: false}), do: true
  defp trace_rollup_warning?(_), do: false

  defp trace_rollup_warning_text(%{messages: messages}) when is_list(messages) do
    messages
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp trace_rollup_warning_text(_), do: "Trace observability data may be stale."

  defp logs_rollup_warning?(%{healthy?: false}), do: true
  defp logs_rollup_warning?(_), do: false

  defp logs_rollup_warning_text(%{messages: messages}) when is_list(messages) do
    messages
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp logs_rollup_warning_text(_), do: "Log severity rollup data may be unavailable or stale."

  defp unavailable_logs_rollup_status do
    Stats.empty_logs_rollup_status()
    |> Map.put(:healthy?, false)
    |> Map.put(:messages, ["The severity breakdown could not be loaded. Log rows below are still available."])
  end
end
