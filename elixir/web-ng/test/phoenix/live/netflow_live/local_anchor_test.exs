defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowContext.LocalAnchorTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowContext.LocalAnchor

  @moduletag :db_free

  # Mirrors the real demo anchors: a k3s /24 (Carver) and an internal /16
  # (Minnetonka), both scoped to the "default" partition.
  @carver %{
    cidr: "10.0.2.0/24",
    partition: "default",
    latitude: 44.7636,
    longitude: -93.6258,
    location_label: "Carver, MN",
    label: "k3s node interfaces",
    updated_at: ~U[2026-07-01 00:00:00Z]
  }

  @internal_16 %{
    cidr: "192.168.0.0/16",
    partition: "default",
    latitude: 44.9212,
    longitude: -93.4687,
    location_label: "Minnetonka, MN",
    label: "internal",
    updated_at: ~U[2026-07-01 00:00:00Z]
  }

  describe "resolve/3" do
    test "resolves the enabled anchor for an IP inside a local CIDR" do
      assert %{latitude: 44.7636, longitude: -93.6258, label: "Carver, MN"} =
               LocalAnchor.resolve([@carver, @internal_16], "10.0.2.12", "default")
    end

    test "returns nil for a public IP so GeoIP is used instead" do
      assert LocalAnchor.resolve([@carver, @internal_16], "8.8.8.8", "default") == nil
    end

    test "returns nil for a private IP that matches no anchor" do
      assert LocalAnchor.resolve([@carver], "172.31.9.9", "default") == nil
    end

    test "prefers the most specific CIDR (longest prefix wins)" do
      broad = %{cidr: "192.168.0.0/16", partition: nil, latitude: 1.0, longitude: 1.0, label: "broad"}
      narrow = %{cidr: "192.168.1.0/24", partition: nil, latitude: 2.0, longitude: 2.0, label: "narrow"}

      assert %{label: "narrow", latitude: 2.0} =
               LocalAnchor.resolve([broad, narrow], "192.168.1.5", nil)
    end

    test "honors partition scoping — an anchor scoped to another partition does not match" do
      scoped = %{@carver | partition: "other"}
      assert LocalAnchor.resolve([scoped], "10.0.2.12", "default") == nil
    end

    test "matches regardless of anchor partition when the flow partition is unknown" do
      scoped = %{@carver | partition: "somepartition"}
      assert %{label: "Carver, MN"} = LocalAnchor.resolve([scoped], "10.0.2.12", nil)
    end

    test "a nil/blank anchor partition is global and matches any flow partition" do
      global = %{@carver | partition: nil}
      assert %{label: "Carver, MN"} = LocalAnchor.resolve([global], "10.0.2.12", "prod")
    end

    test "ignores anchors without coordinates and falls back to a coarser anchor that has them" do
      no_coords = %{cidr: "10.0.2.0/24", partition: nil, latitude: nil, longitude: nil, label: "no-coords"}
      region = %{cidr: "10.0.0.0/8", partition: nil, latitude: 5.0, longitude: 5.0, label: "region"}

      assert %{label: "region", latitude: 5.0} =
               LocalAnchor.resolve([no_coords, region], "10.0.2.12", nil)
    end

    test "supports IPv6 containment" do
      v6 = %{cidr: "2001:db8::/32", partition: nil, latitude: 3.0, longitude: 3.0, label: "v6"}
      assert %{label: "v6"} = LocalAnchor.resolve([v6], "2001:db8::1", nil)
    end

    test "returns nil for a malformed IP" do
      assert LocalAnchor.resolve([@carver], "not-an-ip", "default") == nil
    end

    test "returns nil when the IP is nil or anchors are empty" do
      assert LocalAnchor.resolve([@carver], nil, "default") == nil
      assert LocalAnchor.resolve([], "10.0.2.12", "default") == nil
    end
  end
end
