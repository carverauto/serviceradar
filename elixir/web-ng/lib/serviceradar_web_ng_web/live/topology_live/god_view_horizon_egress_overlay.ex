defmodule ServiceRadarWebNGWeb.TopologyLive.GodViewHorizonEgressOverlay do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, put_flash: 3]

  alias ServiceRadar.NetworkDiscovery.TopologyGraph

  require Logger

  @cache_ttl_ms 10_000
  @default_max_hops 4
  @default_limit 200
  @max_external_nodes 500
  @max_edges 500

  @empty_payload %{
    egress_devices: [],
    external_nodes: [],
    edges: [],
    max_hops: 0,
    truncated: false
  }

  def empty_payload, do: @empty_payload

  def clear_egress_data(socket) do
    push_event(socket, "god_view:horizon_egress_data", @empty_payload)
  end

  @doc """
  Pushes the current inside-to-outside Internet egress graph to the God View
  hook, caching the normalized payload for 10 seconds on the LiveView socket.
  Returns a graceful empty payload when the graph store is unavailable, and
  surfaces unexpected graph read errors via flash.
  """
  def push_egress_data(socket, opts \\ []) when is_list(opts) do
    case cached_egress_data(socket, opts) do
      {:ok, payload, socket} ->
        push_event(socket, "god_view:horizon_egress_data", payload)

      {:error, socket} ->
        socket
        |> put_flash(:error, "Internet Egress / Horizon topology is unavailable: the topology graph could not be read.")
        |> clear_egress_data()
    end
  end

  defp cached_egress_data(socket, opts) do
    now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)
    ttl_ms = Keyword.get(opts, :ttl_ms, @cache_ttl_ms)
    force? = Keyword.get(opts, :force, false)

    case {force?, socket.assigns} do
      {false, %{horizon_egress_cache: %{at_ms: at_ms, data: data}}}
      when is_integer(at_ms) and now_ms - at_ms < ttl_ms and is_map(data) ->
        {:ok, data, socket}

      _ ->
        case load_egress_data(opts) do
          {:ok, data} ->
            {:ok, data, assign(socket, :horizon_egress_cache, %{at_ms: now_ms, data: data})}

          :error ->
            {:error, assign(socket, :horizon_egress_cache, nil)}
        end
    end
  end

  defp load_egress_data(opts) do
    max_hops = Keyword.get(opts, :max_hops, @default_max_hops)
    limit = Keyword.get(opts, :limit, @default_limit)

    egress_topology_fun =
      Keyword.get(opts, :egress_topology_fun) ||
        Application.get_env(
          :serviceradar_web_ng,
          :horizon_egress_topology_fun,
          &TopologyGraph.egress_topology/1
        )

    case egress_topology_fun.(max_hops: max_hops, limit: limit) do
      {:ok, raw} when is_map(raw) ->
        {:ok, normalize_payload(raw, limit)}

      {:error, :graph_store_unavailable} ->
        {:ok, @empty_payload}

      {:error, reason} ->
        Logger.warning("God View Horizon egress read failed: #{inspect(reason)}")
        :error
    end
  rescue
    error ->
      Logger.warning("God View Horizon egress read raised: #{Exception.message(error)}")
      :error
  end

  defp normalize_payload(raw, limit) do
    device_cap = min(max(limit, 1), @default_limit)
    node_cap = min(max(limit * 2, @default_limit), @max_external_nodes)
    edge_cap = min(max(limit * 2, @default_limit), @max_edges)

    raw_devices = raw |> field("egress_devices", :egress_devices, []) |> List.wrap()
    raw_nodes = raw |> field("external_nodes", :external_nodes, []) |> List.wrap()
    raw_edges = raw |> field("edges", :edges, []) |> List.wrap()

    egress_devices =
      raw_devices
      |> Enum.take(device_cap)
      |> Enum.flat_map(&normalize_egress_device/1)

    external_nodes =
      raw_nodes
      |> Enum.take(node_cap)
      |> Enum.flat_map(&normalize_external_node/1)

    edges =
      raw_edges
      |> Enum.take(edge_cap)
      |> Enum.flat_map(&normalize_edge/1)

    truncated? =
      truthy_bool(field(raw, "truncated", :truncated, false)) or
        length(raw_devices) > device_cap or
        length(raw_nodes) > node_cap or
        length(raw_edges) > edge_cap

    %{
      egress_devices: egress_devices,
      external_nodes: external_nodes,
      edges: edges,
      max_hops: normalize_int(field(raw, "max_hops", :max_hops, 0)) || 0,
      truncated: truncated?
    }
  end

  defp normalize_egress_device(device) when is_map(device) do
    case normalize_str(field(device, "id", :id)) do
      nil ->
        []

      id ->
        [
          %{
            id: id,
            kind: normalize_str(field(device, "kind", :kind)) || "Device",
            label: normalize_str(field(device, "label", :label)),
            ip: normalize_str(field(device, "ip", :ip)),
            if_name: normalize_str(field(device, "if_name", :if_name)),
            if_index: normalize_int(field(device, "if_index", :if_index)),
            egress_source: normalize_str(field(device, "egress_source", :egress_source)),
            port_speed_mbps: normalize_int(field(device, "port_speed_mbps", :port_speed_mbps))
          }
        ]
    end
  end

  defp normalize_egress_device(_), do: []

  defp normalize_external_node(node) when is_map(node) do
    case normalize_str(field(node, "id", :id)) do
      nil ->
        []

      id ->
        [
          %{
            id: id,
            kind: normalize_str(field(node, "kind", :kind)) || "External",
            label: normalize_str(field(node, "label", :label)),
            asn: normalize_int(field(node, "asn", :asn)),
            region: normalize_str(field(node, "region", :region)),
            ip: normalize_str(field(node, "ip", :ip)),
            rpki_state: normalize_str(field(node, "rpki_state", :rpki_state)),
            rtbh_active: normalize_bool(field(node, "rtbh_active", :rtbh_active)),
            outage_state: normalize_str(field(node, "outage_state", :outage_state)),
            port_speed_mbps: normalize_int(field(node, "port_speed_mbps", :port_speed_mbps)),
            metro: normalize_str(field(node, "metro", :metro)),
            iata: normalize_str(field(node, "iata", :iata)),
            country_code: normalize_str(field(node, "country_code", :country_code)),
            irr_status: normalize_str(field(node, "irr_status", :irr_status))
          }
        ]
    end
  end

  defp normalize_external_node(_), do: []

  defp normalize_edge(edge) when is_map(edge) do
    with src_id when is_binary(src_id) <- normalize_str(field(edge, "src_id", :src_id)),
         dst_id when is_binary(dst_id) <- normalize_str(field(edge, "dst_id", :dst_id)) do
      [
        %{
          src_id: src_id,
          dst_id: dst_id,
          kind: normalize_str(field(edge, "kind", :kind)) || "EGRESSES_TO",
          border_asn: normalize_int(field(edge, "border_asn", :border_asn)),
          as_boundary_confidence: normalize_float(field(edge, "as_boundary_confidence", :as_boundary_confidence)),
          avg_rtt_us: normalize_int(field(edge, "avg_rtt_us", :avg_rtt_us)),
          loss_pct: normalize_float(field(edge, "loss_pct", :loss_pct)),
          port_speed_mbps: normalize_int(field(edge, "port_speed_mbps", :port_speed_mbps)),
          if_name: normalize_str(field(edge, "if_name", :if_name)),
          if_index: normalize_int(field(edge, "if_index", :if_index)),
          egress_source: normalize_str(field(edge, "egress_source", :egress_source)),
          last_seen: normalize_str(field(edge, "last_seen", :last_seen))
        }
      ]
    else
      _ -> []
    end
  end

  defp normalize_edge(_), do: []

  defp field(map, str_key, atom_key, default \\ nil) do
    case Map.fetch(map, str_key) do
      {:ok, val} -> val
      :error -> Map.get(map, atom_key, default)
    end
  end

  defp normalize_str(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_str(val) when is_atom(val) and not is_nil(val), do: Atom.to_string(val)
  defp normalize_str(_), do: nil

  defp normalize_int(val) when is_integer(val), do: val

  defp normalize_int(val) when is_float(val) do
    if val == Float.round(val), do: trunc(val)
  end

  defp normalize_int(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_int(_), do: nil

  defp normalize_float(val) when is_float(val), do: val
  defp normalize_float(val) when is_integer(val), do: val / 1.0

  defp normalize_float(val) when is_binary(val) do
    case Float.parse(String.trim(val)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_float(_), do: nil

  defp normalize_bool(val) when is_boolean(val), do: val
  defp normalize_bool(_), do: nil

  defp truthy_bool(true), do: true
  defp truthy_bool(_), do: false
end
