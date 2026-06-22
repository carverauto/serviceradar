defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowContext.MapMarkers do
  @moduledoc false

  import ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowAccess, only: [flow_get: 2]

  def netflow_map_markers(context, flow) when is_map(context) and is_map(flow) do
    src_ip = flow_get(flow, ["src_endpoint_ip", "src_ip"])
    dst_ip = flow_get(flow, ["dst_endpoint_ip", "dst_ip"])

    []
    |> maybe_add_geo_marker("Source", src_ip, Map.get(context, :src_geo), Map.get(context, :src_threat))
    |> maybe_add_geo_marker("Dest", dst_ip, Map.get(context, :dst_geo), Map.get(context, :dst_threat))
    |> Enum.take(2)
  end

  def netflow_map_markers(_context, _flow), do: []

  def maybe_add_geo_marker(markers, side, ip, geo, threat) when is_list(markers) do
    cond do
      not is_map(geo) ->
        markers

      not is_number(Map.get(geo, :latitude)) or not is_number(Map.get(geo, :longitude)) ->
        markers

      true ->
        markers ++ [geo_marker(side, ip, geo, threat)]
    end
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
