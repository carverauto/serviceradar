defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowContext do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowAccess, only: [flow_get: 2]
  import ServiceRadarWebNGWeb.NetflowLive.Visualize.Format, only: [to_int: 1]

  alias ServiceRadar.Integrations.MapboxSettings
  alias ServiceRadar.Observability.IpGeoEnrichmentCache
  alias ServiceRadar.Observability.IpIpinfoCache
  alias ServiceRadar.Observability.IpRdnsCache
  alias ServiceRadar.Observability.IpThreatIntelCache
  alias ServiceRadar.Observability.NetflowPortAnomalyFlag
  alias ServiceRadar.Observability.NetflowPortScanFlag
  alias ServiceRadarWebNGWeb.NetFlow.EnrichmentExpiry
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowContext.LocalAnchor
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowContext.MapMarkers

  require Ash.Query
  require Logger

  def maybe_open_flow_from_params(socket, params) do
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

  defdelegate netflow_map_markers(context, flow), to: MapMarkers

  def load_flow_context(flow, scope) when is_map(flow) do
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

    # Load operator-defined local-CIDR anchors once, then resolve each endpoint
    # by inet containment. GeoIP has no coordinates for private/local endpoints,
    # so this is what stops them islanding on the flow-details map.
    partition = flow_partition(flow)

    anchors =
      safe_flow_context_value(:local_anchors, fn -> LocalAnchor.load_anchors(scope) end) || []

    src_anchor = LocalAnchor.resolve(anchors, src_ip, partition)
    dst_anchor = LocalAnchor.resolve(anchors, dst_ip, partition)

    %{
      mapbox: safe_flow_context_value(:mapbox, fn -> read_mapbox(user) end),
      src_rdns: safe_flow_context_value(:src_rdns, fn -> read_rdns(user, src_ip) end),
      dst_rdns: safe_flow_context_value(:dst_rdns, fn -> read_rdns(user, dst_ip) end),
      src_geo: safe_flow_context_value(:src_geo, fn -> read_geo(user, src_ip) end),
      dst_geo: safe_flow_context_value(:dst_geo, fn -> read_geo(user, dst_ip) end),
      src_anchor: src_anchor,
      dst_anchor: dst_anchor,
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

  def load_flow_context(_flow, _scope), do: %{}

  def safe_flow_context_value(key, fun) when is_function(fun, 0) do
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

  def normalize_ip(nil), do: nil
  def normalize_ip(""), do: nil

  def normalize_ip(ip) when is_binary(ip) do
    ip = String.trim(ip)
    if ip in ["", "—", "-"], do: nil, else: ip
  end

  def normalize_ip(_), do: nil

  @doc """
  Best-effort read of a flow's partition (matches the anchor partition scope).

  SRQL flow rows may or may not project `partition`; when absent this returns
  `nil`, and the anchor resolver then matches regardless of partition rather
  than islanding the endpoint.
  """
  def flow_partition(flow) when is_map(flow) do
    case Map.get(flow, "partition") || Map.get(flow, :partition) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  def flow_partition(_flow), do: nil

  def normalize_mac(nil), do: nil
  def normalize_mac(""), do: nil

  def normalize_mac(mac) when is_binary(mac) do
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

  def normalize_mac(_), do: nil

  def escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", " ")
    |> String.replace("\r", " ")
    |> String.trim()
  end

  def lookup_device_uid_by_ip_or_mac(_srql_module, _scope, nil, nil), do: nil

  def lookup_device_uid_by_ip_or_mac(srql_module, scope, ip, mac) do
    lookup_device_uid_by_ip(srql_module, scope, ip) ||
      lookup_device_uid_by_mac(srql_module, scope, mac)
  end

  def lookup_device_uid_by_ip(_srql_module, _scope, nil), do: nil

  def lookup_device_uid_by_ip(srql_module, scope, ip) when is_binary(ip) do
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

  def lookup_device_uid_by_mac(_srql_module, _scope, nil), do: nil

  def lookup_device_uid_by_mac(srql_module, scope, mac) when is_binary(mac) do
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

  def read_rdns(nil, _ip), do: nil
  def read_rdns(_user, nil), do: nil

  def read_rdns(user, ip) when is_binary(ip) do
    query =
      IpRdnsCache
      |> Ash.Query.for_read(:by_ip, %{ip: ip})
      |> EnrichmentExpiry.live(DateTime.utc_now())

    case Ash.read_one(query, actor: user) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  def read_mapbox(nil), do: nil

  def read_mapbox(user) do
    case MapboxSettings.get_settings(actor: user) do
      {:ok, %MapboxSettings{} = settings} -> settings
      _ -> nil
    end
  end

  def read_geo(nil, _ip), do: nil
  def read_geo(_user, nil), do: nil

  def read_geo(user, ip) when is_binary(ip) do
    query =
      IpGeoEnrichmentCache
      |> Ash.Query.for_read(:by_ip, %{ip: ip})
      |> EnrichmentExpiry.live(DateTime.utc_now())

    case Ash.read_one(query, actor: user) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  def read_ipinfo(nil, _ip), do: nil
  def read_ipinfo(_user, nil), do: nil

  def read_ipinfo(user, ip) when is_binary(ip) do
    query =
      IpIpinfoCache
      |> Ash.Query.for_read(:by_ip, %{ip: ip})
      |> EnrichmentExpiry.live(DateTime.utc_now())

    case Ash.read_one(query, actor: user) do
      {:ok, %IpIpinfoCache{} = record} -> record
      _ -> nil
    end
  end

  def read_threat(nil, _ip), do: nil
  def read_threat(_user, nil), do: nil

  def read_threat(user, ip) when is_binary(ip) do
    query =
      IpThreatIntelCache
      |> Ash.Query.for_read(:by_ip, %{ip: ip})
      |> EnrichmentExpiry.live(DateTime.utc_now())

    case Ash.read_one(query, actor: user) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  def threat_sources(%{sources: sources}) do
    sources
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.take(4)
  end

  def threat_sources(_match), do: []

  def threat_severity_badge_variant(severity) when is_integer(severity) and severity >= 80, do: "error"

  def threat_severity_badge_variant(severity) when is_integer(severity) and severity >= 50, do: "warning"

  def threat_severity_badge_variant(_severity), do: "info"

  def read_port_scan(nil, _ip), do: nil
  def read_port_scan(_user, nil), do: nil

  def read_port_scan(user, ip) when is_binary(ip) do
    query = Ash.Query.for_read(NetflowPortScanFlag, :by_src_ip, %{src_ip: ip})

    case Ash.read_one(query, actor: user) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  def read_port_anomaly(nil, _port), do: nil

  def read_port_anomaly(user, port) when is_integer(port) and port > 0 do
    query = Ash.Query.for_read(NetflowPortAnomalyFlag, :by_port, %{dst_port: port})

    case Ash.read_one(query, actor: user) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  def read_port_anomaly(_user, _port), do: nil
end
