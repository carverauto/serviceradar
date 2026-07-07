defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowContext.MapMarkersTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowContext.MapMarkers

  @moduletag :db_free

  # Real-world shape from the bug report: private local source, public dest.
  @flow %{"src_endpoint_ip" => "10.0.2.12", "dst_endpoint_ip" => "8.8.8.8"}

  defp source(markers), do: Enum.find(markers, &String.starts_with?(&1.label, "Source"))
  defp dest(markers), do: Enum.find(markers, &String.starts_with?(&1.label, "Dest"))

  test "draws a source marker at the local-CIDR anchor when GeoIP has no coordinates" do
    context = %{
      src_anchor: %{latitude: 44.7636, longitude: -93.6258, label: "Carver, MN"},
      # GeoIP cache holds a row for the private IP but with NULL lat/lon.
      src_geo: %{latitude: nil, longitude: nil},
      dst_anchor: nil,
      dst_geo: %{latitude: 39.0997, longitude: -94.5786, city: "Kansas City", country_name: "United States"}
    }

    markers = MapMarkers.netflow_map_markers(context, @flow)

    assert length(markers) == 2

    src = source(markers)
    assert src.lat == 44.7636
    assert src.lng == -93.6258
    assert src.local_anchor == true
    assert src.label =~ "10.0.2.12"
    assert src.label =~ "Carver, MN"

    dst = dest(markers)
    assert dst.lat == 39.0997
    assert dst.local_anchor == false
  end

  test "uses GeoIP for a public source that has no anchor" do
    context = %{
      src_anchor: nil,
      src_geo: %{latitude: 51.5074, longitude: -0.1278, city: "London", country_name: "United Kingdom"},
      dst_anchor: nil,
      dst_geo: nil
    }

    markers = MapMarkers.netflow_map_markers(context, @flow)
    src = source(markers)

    assert src.lat == 51.5074
    assert src.local_anchor == false
  end

  test "anchor takes precedence over GeoIP (consistent with the main dashboard map)" do
    context = %{
      src_anchor: %{latitude: 44.7636, longitude: -93.6258, label: "Carver, MN"},
      src_geo: %{latitude: 1.0, longitude: 1.0, city: "Elsewhere"},
      dst_anchor: nil,
      dst_geo: nil
    }

    src = context |> MapMarkers.netflow_map_markers(@flow) |> source()

    assert src.lat == 44.7636
    assert src.lng == -93.6258
    assert src.local_anchor == true
  end

  test "produces no marker when neither GeoIP nor an anchor has coordinates" do
    context = %{
      src_anchor: nil,
      src_geo: %{latitude: nil, longitude: nil},
      dst_anchor: nil,
      dst_geo: nil
    }

    assert MapMarkers.netflow_map_markers(context, @flow) == []
  end
end
