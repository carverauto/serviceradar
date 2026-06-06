defmodule ServiceRadar.ReferenceData.ServicePortsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.ReferenceData.ServicePorts

  describe "lookup/2" do
    test "returns structured registry metadata for common ports" do
      assert %{
               protocol_num: 6,
               protocol: "tcp",
               port: 443,
               name: "https",
               label: "HTTPS",
               source: "iana",
               label_source: "serviceradar"
             } = ServicePorts.lookup(6, 443)
    end

    test "returns raw service names and fallback labels from bundled services registry" do
      assert %{
               protocol_num: 6,
               protocol: "tcp",
               port: 4369,
               name: "epmd",
               label: "EPMD",
               source: "iana",
               label_source: "iana"
             } = ServicePorts.lookup(6, 4369)
    end

    test "returns nil for unsupported protocols and unregistered ports" do
      refute ServicePorts.lookup(1, 8)
      refute ServicePorts.lookup(6, 32_760)
    end

    test "accepts protocol names and numeric protocol strings" do
      assert %{protocol: "tcp", label: "HTTPS"} = ServicePorts.lookup("tcp", 443)
      assert %{protocol: "tcp", label: "HTTPS"} = ServicePorts.lookup(:tcp, 443)
      assert %{protocol: "udp", label: "sFlow"} = ServicePorts.lookup("17", 6343)
    end
  end

  describe "lookup/1" do
    test "falls back to TCP then UDP when protocol is not available" do
      assert %{protocol: "tcp", label: "HTTPS"} = ServicePorts.lookup(443)
      assert %{protocol: "tcp", label: "sFlow"} = ServicePorts.lookup(6343)
    end
  end

  describe "label/2" do
    test "preserves ServiceRadar display labels for common ports" do
      assert ServicePorts.label(6, 443) == "HTTPS"
      assert ServicePorts.label(6, 4222) == "NATS"
      assert ServicePorts.label(17, 6343) == "sFlow"
    end

    test "falls back to bundled services registry labels" do
      assert ServicePorts.label(6, 4369) == "EPMD"
      assert ServicePorts.label(17, 4369) == "EPMD"
    end

    test "returns nil for unsupported protocols and unregistered ports" do
      refute ServicePorts.label(1, 8)
      refute ServicePorts.label(6, 32_760)
    end

    test "accepts protocol names" do
      assert ServicePorts.label("udp", 6343) == "sFlow"
      assert ServicePorts.label(:tcp, 443) == "HTTPS"
    end
  end

  describe "label/1" do
    test "falls back to TCP then UDP when protocol is not available" do
      assert ServicePorts.label(443) == "HTTPS"
      assert ServicePorts.label(6343) == "sFlow"
    end

    test "returns nil for unknown or invalid ports" do
      refute ServicePorts.label(32_760)
      refute ServicePorts.label(nil)
    end
  end

  describe "registered?/2" do
    test "reports whether a TCP or UDP port is registered" do
      assert ServicePorts.registered?(6, 443)
      assert ServicePorts.registered?(17, 53)
      assert ServicePorts.registered?("udp", 53)
      refute ServicePorts.registered?(6, 32_760)
    end
  end
end
