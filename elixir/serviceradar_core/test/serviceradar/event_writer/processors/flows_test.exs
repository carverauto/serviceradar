defmodule ServiceRadar.EventWriter.Processors.FlowsTest do
  use ExUnit.Case, async: true

  alias Flowpb.FlowMessage
  alias ServiceRadar.EventWriter.Processors.Flows

  test "row_from_flow_message builds an OCSF-compatible row from protobuf flow data" do
    flow = %FlowMessage{
      type: :NETFLOW_V9,
      time_received_ns: 1_705_363_200_000_000_000,
      time_flow_start_ns: 1_705_363_100_000_000_000,
      time_flow_end_ns: 1_705_363_210_000_000_000,
      sampler_address: <<10, 1, 0, 1>>,
      src_addr: <<10, 1, 0, 100>>,
      dst_addr: <<198, 51, 100, 50>>,
      src_port: 49_876,
      dst_port: 443,
      proto: 6,
      bytes: 1_500_000,
      packets: 1000,
      bytes_in: 900_000,
      bytes_out: 600_000,
      packets_in: 600,
      packets_out: 400,
      in_if: 10,
      out_if: 20,
      src_as: 64_512,
      dst_as: 64_515,
      tcp_flags: 18,
      protocol_name: "TCP"
    }

    row = Flows.row_from_flow_message(flow, %{subject: "flows.raw.netflow"})

    assert row.src_endpoint_ip == "10.1.0.100"
    assert row.dst_endpoint_ip == "198.51.100.50"
    assert row.src_endpoint_port == 49_876
    assert row.dst_endpoint_port == 443
    assert row.protocol_num == 6
    assert row.protocol_name == "TCP"
    assert row.bytes_total == 1_500_000
    assert row.packets_total == 1000
    assert row.bytes_in == 900_000
    assert row.bytes_out == 600_000
    assert row.packets_in == 600
    assert row.packets_out == 400
    assert row.src_as_number == 64_512
    assert row.dst_as_number == 64_515
    assert row.sampler_address == "10.1.0.1"
    assert DateTime.compare(
             row.start_time,
             DateTime.from_unix!(1_705_363_100_000_000_000, :nanosecond)
           ) == :eq

    assert DateTime.compare(
             row.end_time,
             DateTime.from_unix!(1_705_363_210_000_000_000, :nanosecond)
           ) == :eq
    assert row.ocsf_payload["flow_source"] == "NetFlow v9"
    assert row.ocsf_payload["connection_info"]["input_snmp"] == 10
    assert row.ocsf_payload["connection_info"]["output_snmp"] == 20
  end

  test "parse_message accepts protobuf payloads on raw flow subjects" do
    flow = %FlowMessage{
      type: :SFLOW_5,
      time_received_ns: 1_705_363_200_000_000_000,
      src_addr: <<192, 0, 2, 10>>,
      dst_addr: <<198, 51, 100, 20>>,
      proto: 17,
      src_port: 53_000,
      dst_port: 53,
      bytes: 2048,
      packets: 4
    }

    row =
      Flows.parse_message(%{
        data: FlowMessage.encode(flow),
        metadata: %{subject: "flows.raw.sflow"}
      })

    assert row.src_endpoint_ip == "192.0.2.10"
    assert row.dst_endpoint_ip == "198.51.100.20"
    assert row.protocol_num == 17
    assert row.ocsf_payload["flow_source"] == "sFlow v5"
  end
end
