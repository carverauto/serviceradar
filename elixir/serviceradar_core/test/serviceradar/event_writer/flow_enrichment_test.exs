defmodule ServiceRadar.EventWriter.FlowEnrichmentTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.FlowEnrichment

  describe "decode_tcp_flags/1" do
    test "decodes SYN+ACK" do
      assert FlowEnrichment.decode_tcp_flags(18) == ["ACK", "SYN"]
    end

    test "returns empty for nil" do
      assert FlowEnrichment.decode_tcp_flags(nil) == []
    end
  end

  describe "service_label/2" do
    test "maps common TCP ports" do
      assert FlowEnrichment.service_label(6, 443) == "HTTPS"
      assert FlowEnrichment.service_label(6, 4222) == "NATS"
    end

    test "maps common UDP ports" do
      assert FlowEnrichment.service_label(17, 53) == "DNS"
      assert FlowEnrichment.service_label(17, 6343) == "sFlow"
    end
  end

  describe "direction_label/2" do
    test "classifies bidirectional" do
      assert FlowEnrichment.direction_label(100, 200) == "bidirectional"
    end

    test "classifies ingress" do
      assert FlowEnrichment.direction_label(100, 0) == "ingress"
    end

    test "classifies egress" do
      assert FlowEnrichment.direction_label(0, 100) == "egress"
    end
  end

  describe "normalize_mac/1" do
    test "normalizes separators and prefix length" do
      assert FlowEnrichment.normalize_mac("00:11:22:33:44:55") == "001122334455"
      assert FlowEnrichment.normalize_mac("0011.2233.4455/24") == "001122334455"
    end
  end

  describe "enrich/1" do
    test "enriches core protocol/port/tcp/direction fields without database lookups" do
      enriched =
        FlowEnrichment.enrich(%{
          protocol_num: 6,
          tcp_flags: 18,
          dst_port: 443,
          bytes_in: 12,
          bytes_out: 45,
          src_ip: "10.0.0.1",
          dst_ip: "10.0.0.2",
          src_mac: "00:11:22:33:44:55",
          dst_mac: "66:77:88:99:aa:bb"
        })

      assert enriched.protocol_name == "TCP"
      assert enriched.protocol_source == "iana"
      assert enriched.tcp_flags_labels == ["ACK", "SYN"]
      assert enriched.dst_service_label == "HTTPS"
      assert enriched.direction_label == "bidirectional"
      assert enriched.src_mac == "001122334455"
      assert enriched.dst_mac == "66778899AABB"
    end
  end
end
