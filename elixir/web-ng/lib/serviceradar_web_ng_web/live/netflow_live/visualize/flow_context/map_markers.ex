defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowContext.MapMarkers do
  @moduledoc false

  import ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowAccess, only: [flow_get: 2]

  def netflow_map_markers(context, flow) when is_map(context) and is_map(flow) do
    src_ip = flow_get(flow, ["src_endpoint_ip", "src_ip"])
    dst_ip = flow_get(flow, ["dst_endpoint_ip", "dst_ip"])

    []
    |> maybe_add_marker(
      "Source",
      src_ip,
      Map.get(context, :src_geo),
      Map.get(context, :src_anchor),
      Map.get(context, :src_threat)
    )
    |> maybe_add_marker(
      "Dest",
      dst_ip,
      Map.get(context, :dst_geo),
      Map.get(context, :dst_anchor),
      Map.get(context, :dst_threat)
    )
    |> Enum.take(2)
  end

  def netflow_map_markers(_context, _flow), do: []

  @doc """
  Adds one endpoint marker, resolving coordinates as: an operator-defined
  local-CIDR anchor (when the IP falls inside one) → else GeoIP → else no
  marker.

  The anchor takes precedence over GeoIP, matching the main dashboard NetFlow
  map's `COALESCE(anchor, geo)` behaviour, so a private/local endpoint plots at
  its configured site instead of islanding, and an operator anchor over a public
  range they own still pins to that site. Public IPs without an anchor keep
  their GeoIP coordinates.
  """
  def maybe_add_marker(markers, side, ip, geo, anchor, threat) when is_list(markers) do
    cond do
      anchor_point?(anchor) ->
        markers ++ [anchor_marker(side, ip, anchor, threat)]

      geo_point?(geo) ->
        markers ++ [geo_marker(side, ip, geo, threat)]

      true ->
        markers
    end
  end

  defp anchor_point?(anchor) do
    is_map(anchor) and is_number(Map.get(anchor, :latitude)) and
      is_number(Map.get(anchor, :longitude))
  end

  defp geo_point?(geo) do
    is_map(geo) and is_number(Map.get(geo, :latitude)) and is_number(Map.get(geo, :longitude))
  end

  defp anchor_marker(side, ip, anchor, threat) do
    label =
      [side, ip, Map.get(anchor, :label)]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" - ")

    %{
      lng: Map.get(anchor, :longitude),
      lat: Map.get(anchor, :latitude),
      label: label,
      local_anchor: true,
      threat_matched: threat_match?(threat),
      threat_match_count: threat_match_count(threat),
      threat_max_severity: threat_max_severity(threat),
      threat_sources: marker_threat_sources(threat)
    }
  end

  defp geo_marker(side, ip, geo, threat) do
    label =
      [side, ip, Map.get(geo, :city), Map.get(geo, :region), Map.get(geo, :country_name)]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" - ")

    %{
      lng: Map.get(geo, :longitude),
      lat: Map.get(geo, :latitude),
      label: label,
      local_anchor: false,
      threat_matched: threat_match?(threat),
      threat_match_count: threat_match_count(threat),
      threat_max_severity: threat_max_severity(threat),
      threat_sources: marker_threat_sources(threat)
    }
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
end
