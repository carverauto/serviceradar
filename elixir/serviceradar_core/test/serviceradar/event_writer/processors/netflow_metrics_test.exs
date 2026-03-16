defmodule ServiceRadar.EventWriter.Processors.NetFlowMetricsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.NetFlowMetrics
  alias Flowpb.FlowMessage

  describe "table_name/0" do
    test "returns correct table name" do
      assert NetFlowMetrics.table_name() == "netflow_metrics"
    end
  end

  describe "parse_message/1 - valid FlowMessage" do
    test "parses valid FlowMessage protobuf" do
      flow = %FlowMessage{
        type: :IPFIX,
        time_received_ns: 1_705_363_200_000_000_000,
        time_flow_start_ns: 1_705_363_100_000_000_000,
        time_flow_end_ns: 1_705_363_110_000_000_000,
        sequence_num: 100,
        sampling_rate: 100,
        sampler_address: <<10, 1, 0, 1>>,
        src_addr: <<10, 1, 0, 100>>,
        dst_addr: <<198, 51, 100, 50>>,
        src_port: 49876,
        dst_port: 443,
        proto: 6,
        bytes: 1_500_000,
        packets: 1000,
        as_path: [64512, 64515],
        bgp_communities: [4_259_840_100],
        in_if: 10,
        out_if: 20,
        vlan_id: 100,
        tcp_flags: 18
      }

      encoded = FlowMessage.encode(flow)
      message = %{data: encoded, metadata: %{subject: "flows.raw.netflow"}}

      row = NetFlowMetrics.parse_message(message)

      # Verify timestamp extraction (uses flow_start_ns)
      assert %DateTime{} = row.timestamp
      assert row.timestamp == DateTime.from_unix!(1_705_363_100_000_000_000, :nanosecond)

      # Verify IP addresses
      assert %Postgrex.INET{address: {10, 1, 0, 100}, netmask: 32} = row.src_ip
      assert %Postgrex.INET{address: {198, 51, 100, 50}, netmask: 32} = row.dst_ip
      assert %Postgrex.INET{address: {10, 1, 0, 1}, netmask: 32} = row.sampler_address

      # Verify ports and protocol
      assert row.src_port == 49876
      assert row.dst_port == 443
      assert row.protocol == 6

      # Verify traffic statistics
      assert row.bytes_total == 1_500_000
      assert row.packets_total == 1000

      # Verify BGP fields
      assert row.as_path == [64512, 64515]
      assert row.bgp_communities == [4_259_840_100]

      # Verify partition
      assert row.partition == "default"

      # Verify metadata contains unmapped fields
      assert row.metadata["in_if"] == 10
      assert row.metadata["out_if"] == 20
      assert row.metadata["vlan_id"] == 100
      assert row.metadata["sampling_rate"] == 100
      assert row.metadata["tcp_flags"] == 18
    end
  end

  describe "parse_message/1 - invalid protobuf" do
    test "returns nil for malformed protobuf data" do
      message = %{data: <<1, 2, 3, 4>>, metadata: %{subject: "flows.raw.netflow"}}

      row = NetFlowMetrics.parse_message(message)

      assert row == nil
    end

    test "returns nil for empty data" do
      message = %{data: "", metadata: %{subject: "flows.raw.netflow"}}

      row = NetFlowMetrics.parse_message(message)

      assert row == nil
    end
  end

  describe "parse_message/1 - IPv4 address conversion" do
    test "converts 4-byte IPv4 addresses to Postgrex.INET" do
      flow = %FlowMessage{
        time_received_ns: 1_705_363_200_000_000_000,
        src_addr: <<192, 168, 1, 100>>,
        dst_addr: <<8, 8, 8, 8>>,
        sampler_address: <<10, 0, 0, 1>>,
        proto: 17,
        src_port: 12345,
        dst_port: 53
      }

      encoded = FlowMessage.encode(flow)
      message = %{data: encoded, metadata: %{subject: "flows.raw.netflow"}}

      row = NetFlowMetrics.parse_message(message)

      assert %Postgrex.INET{address: {192, 168, 1, 100}, netmask: 32} = row.src_ip
      assert %Postgrex.INET{address: {8, 8, 8, 8}, netmask: 32} = row.dst_ip
      assert %Postgrex.INET{address: {10, 0, 0, 1}, netmask: 32} = row.sampler_address
    end
  end

  describe "parse_message/1 - IPv6 address conversion" do
    test "converts 16-byte IPv6 addresses to Postgrex.INET" do
      # IPv6: 2001:0db8:85a3:0000:0000:8a2e:0370:7334
      ipv6_src = <<0x20, 0x01, 0x0D, 0xB8, 0x85, 0xA3, 0x00, 0x00, 0x00, 0x00, 0x8A, 0x2E, 0x03, 0x70, 0x73, 0x34>>
      # IPv6: fe80::1
      ipv6_dst = <<0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01>>

      flow = %FlowMessage{
        time_received_ns: 1_705_363_200_000_000_000,
        src_addr: ipv6_src,
        dst_addr: ipv6_dst,
        proto: 6,
        src_port: 8080,
        dst_port: 80
      }

      encoded = FlowMessage.encode(flow)
      message = %{data: encoded, metadata: %{subject: "flows.raw.netflow"}}

      row = NetFlowMetrics.parse_message(message)

      assert %Postgrex.INET{address: {0x2001, 0x0DB8, 0x85A3, 0, 0, 0x8A2E, 0x0370, 0x7334}, netmask: 128} = row.src_ip
      assert %Postgrex.INET{address: {0xFE80, 0, 0, 0, 0, 0, 0, 1}, netmask: 128} = row.dst_ip
    end
  end

  describe "parse_message/1 - invalid IP address length" do
    test "sets nil for invalid IP address byte length" do
      # Invalid: 3 bytes (not 4 or 16)
      flow = %FlowMessage{
        time_received_ns: 1_705_363_200_000_000_000,
        src_addr: <<10, 1, 0>>,
        dst_addr: <<198, 51, 100, 50>>,
        proto: 6,
        src_port: 1234,
        dst_port: 5678
      }

      encoded = FlowMessage.encode(flow)
      message = %{data: encoded, metadata: %{subject: "flows.raw.netflow"}}

      row = NetFlowMetrics.parse_message(message)

      # src_addr is invalid, should be nil
      assert row.src_ip == nil
      # dst_addr is valid
      assert %Postgrex.INET{address: {198, 51, 100, 50}, netmask: 32} = row.dst_ip
    end
  end

  describe "parse_message/1 - AS path extraction with normal values" do
    test "extracts AS path as list of integers" do
      flow = %FlowMessage{
        time_received_ns: 1_705_363_200_000_000_000,
        src_addr: <<10, 1, 0, 100>>,
        dst_addr: <<198, 51, 100, 50>>,
        proto: 6,
        src_port: 1234,
        dst_port: 5678,
        as_path: [64512, 64513, 64514, 15169]
      }

      encoded = FlowMessage.encode(flow)
      message = %{data: encoded, metadata: %{subject: "flows.raw.netflow"}}

      row = NetFlowMetrics.parse_message(message)

      assert row.as_path == [64512, 64513, 64514, 15169]
    end
  end

  describe "parse_message/1 - AS path extraction with values > max int32 (capping)" do
    test "caps AS numbers exceeding max int32 value" do
      # Max int32 is 2,147,483,647
      # Use uint32 max (4,294,967,295) to test capping
      flow = %FlowMessage{
        time_received_ns: 1_705_363_200_000_000_000,
        src_addr: <<10, 1, 0, 100>>,
        dst_addr: <<198, 51, 100, 50>>,
        proto: 6,
        src_port: 1234,
        dst_port: 5678,
        as_path: [64512, 4_294_967_295]
      }

      encoded = FlowMessage.encode(flow)
      message = %{data: encoded, metadata: %{subject: "flows.raw.netflow"}}

      row = NetFlowMetrics.parse_message(message)

      # 4,294,967,295 should be capped to 2,147,483,647
      assert row.as_path == [64512, 2_147_483_647]
    end
  end

  describe "parse_message/1 - AS path extraction with empty/nil" do
    test "returns nil for empty AS path" do
      flow = %FlowMessage{
        time_received_ns: 1_705_363_200_000_000_000,
        src_addr: <<10, 1, 0, 100>>,
        dst_addr: <<198, 51, 100, 50>>,
        proto: 6,
        src_port: 1234,
        dst_port: 5678,
        as_path: []
      }

      encoded = FlowMessage.encode(flow)
      message = %{data: encoded, metadata: %{subject: "flows.raw.netflow"}}

      row = NetFlowMetrics.parse_message(message)

      assert row.as_path == nil
    end

    test "returns nil for nil AS path" do
      flow = %FlowMessage{
        time_received_ns: 1_705_363_200_000_000_000,
        src_addr: <<10, 1, 0, 100>>,
        dst_addr: <<198, 51, 100, 50>>,
        proto: 6,
        src_port: 1234,
        dst_port: 5678
        # as_path field omitted (defaults to nil)
      }

      encoded = FlowMessage.encode(flow)
      message = %{data: encoded, metadata: %{subject: "flows.raw.netflow"}}

      row = NetFlowMetrics.parse_message(message)

      assert row.as_path == nil
    end
  end

  describe "parse_message/1 - BGP communities extraction with normal values" do
    test "extracts BGP communities as list of integers" do
      flow = %FlowMessage{
        time_received_ns: 1_705_363_200_000_000_000,
        src_addr: <<10, 1, 0, 100>>,
        dst_addr: <<198, 51, 100, 50>>,
        proto: 6,
        src_port: 1234,
        dst_port: 5678,
        bgp_communities: [4_259_840_100, 4_259_840_200]
      }

      encoded = FlowMessage.encode(flow)
      message = %{data: encoded, metadata: %{subject: "flows.raw.netflow"}}

      row = NetFlowMetrics.parse_message(message)

      assert row.bgp_communities == [4_259_840_100, 4_259_840_200]
    end
  end

  describe "parse_message/1 - BGP communities extraction with values > max int32" do
    test "caps BGP community values exceeding max int32" do
      flow = %FlowMessage{
        time_received_ns: 1_705_363_200_000_000_000,
        src_addr: <<10, 1, 0, 100>>,
        dst_addr: <<198, 51, 100, 50>>,
        proto: 6,
        src_port: 1234,
        dst_port: 5678,
        bgp_communities: [100, 4_294_967_295]
      }

      encoded = FlowMessage.encode(flow)
      message = %{data: encoded, metadata: %{subject: "flows.raw.netflow"}}

      row = NetFlowMetrics.parse_message(message)

      # 4,294,967,295 should be capped to 2,147,483,647
      assert row.bgp_communities == [100, 2_147_483_647]
    end
  end

  describe "parse_message/1 - timestamp extraction with flow_start_ns" do
    test "uses flow_start_ns when available" do
      flow_start = 1_705_363_100_000_000_000
      flow = %FlowMessage{
        time_flow_start_ns: flow_start,
        time_received_ns: 1_705_363_200_000_000_000,
        src_addr: <<10, 1, 0, 100>>,
        dst_addr: <<198, 51, 100, 50>>,
        proto: 6,
        src_port: 1234,
        dst_port: 5678
      }

      encoded = FlowMessage.encode(flow)
      message = %{data: encoded, metadata: %{subject: "flows.raw.netflow"}}

      row = NetFlowMetrics.parse_message(message)

      assert row.timestamp == DateTime.from_unix!(flow_start, :nanosecond)
    end
  end

  describe "parse_message/1 - timestamp extraction with received_ns fallback" do
    test "uses received_ns when flow_start_ns is 0" do
      received_time = 1_705_363_200_000_000_000
      flow = %FlowMessage{
        time_flow_start_ns: 0,
        time_received_ns: received_time,
        src_addr: <<10, 1, 0, 100>>,
        dst_addr: <<198, 51, 100, 50>>,
        proto: 6,
        src_port: 1234,
        dst_port: 5678
      }

      encoded = FlowMessage.encode(flow)
      message = %{data: encoded, metadata: %{subject: "flows.raw.netflow"}}

      row = NetFlowMetrics.parse_message(message)

      assert row.timestamp == DateTime.from_unix!(received_time, :nanosecond)
    end
  end

  describe "parse_message/1 - timestamp extraction with current time fallback" do
    test "uses current time when both timestamp fields are 0" do
      flow = %FlowMessage{
        time_flow_start_ns: 0,
        time_received_ns: 0,
        src_addr: <<10, 1, 0, 100>>,
        dst_addr: <<198, 51, 100, 50>>,
        proto: 6,
        src_port: 1234,
        dst_port: 5678
      }

      encoded = FlowMessage.encode(flow)
      message = %{data: encoded, metadata: %{subject: "flows.raw.netflow"}}

      before_parse = DateTime.utc_now()
      row = NetFlowMetrics.parse_message(message)
      after_parse = DateTime.utc_now()

      # Timestamp should be close to current time
      assert DateTime.compare(row.timestamp, before_parse) in [:eq, :gt]
      assert DateTime.compare(row.timestamp, after_parse) in [:eq, :lt]
    end
  end

  describe "parse_message/1 - metadata with interface fields" do
    test "includes interface, vlan, and sampling rate in metadata" do
      flow = %FlowMessage{
        time_received_ns: 1_705_363_200_000_000_000,
        src_addr: <<10, 1, 0, 100>>,
        dst_addr: <<198, 51, 100, 50>>,
        proto: 6,
        src_port: 1234,
        dst_port: 5678,
        in_if: 10,
        out_if: 20,
        vlan_id: 100,
        sampling_rate: 1000,
        tcp_flags: 18,
        observation_domain_id: 5,
        protocol_name: "TCP"
      }

      encoded = FlowMessage.encode(flow)
      message = %{data: encoded, metadata: %{subject: "flows.raw.netflow"}}

      row = NetFlowMetrics.parse_message(message)

      assert row.metadata["in_if"] == 10
      assert row.metadata["out_if"] == 20
      assert row.metadata["vlan_id"] == 100
      assert row.metadata["sampling_rate"] == 1000
      assert row.metadata["tcp_flags"] == 18
      assert row.metadata["observation_domain_id"] == 5
      assert row.metadata["protocol_name"] == "TCP"
    end
  end

  describe "parse_message/1 - metadata with empty metadata" do
    test "returns nil when all metadata fields are 0 or empty" do
      flow = %FlowMessage{
        time_received_ns: 1_705_363_200_000_000_000,
        src_addr: <<10, 1, 0, 100>>,
        dst_addr: <<198, 51, 100, 50>>,
        proto: 6,
        src_port: 1234,
        dst_port: 5678
        # All metadata fields default to 0 or empty
      }

      encoded = FlowMessage.encode(flow)
      message = %{data: encoded, metadata: %{subject: "flows.raw.netflow"}}

      row = NetFlowMetrics.parse_message(message)

      assert row.metadata == nil
    end
  end
end
