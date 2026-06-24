defmodule ServiceRadar.EventWriter.Processors.FlowsTest do
  use ExUnit.Case, async: false

  alias Flowpb.AttributedFlowMessage
  alias Flowpb.FlowAttribution
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
      sampling_rate: 128,
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
    assert row.sampling_rate == 128
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
    assert row.ocsf_payload["traffic"]["sampling_rate"] == 128
    refute Map.has_key?(row.ocsf_payload["unmapped"], "sampling_rate")
    assert row.ocsf_payload["connection_info"]["input_snmp"] == 10
    assert row.ocsf_payload["connection_info"]["output_snmp"] == 20
  end

  test "row_from_flow_message preserves absent directional counters as unknown" do
    flow = %FlowMessage{
      type: :NETFLOW_V9,
      time_received_ns: 1_705_363_200_000_000_000,
      src_addr: <<192, 0, 2, 10>>,
      dst_addr: <<198, 51, 100, 20>>,
      proto: 17,
      bytes: 2048,
      packets: 4
    }

    row = Flows.row_from_flow_message(flow, %{subject: "flows.raw.netflow"})

    assert row.bytes_total == 2048
    assert row.packets_total == 4
    assert is_nil(row.bytes_in)
    assert is_nil(row.bytes_out)
    assert is_nil(row.packets_in)
    assert is_nil(row.packets_out)
    refute Map.has_key?(row.ocsf_payload, "bytes_in")
    refute Map.has_key?(row.ocsf_payload, "packets_in")
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
    assert row.bytes_in == nil
    assert row.bytes_out == nil
    assert row.packets_in == nil
    assert row.packets_out == nil
    assert row.ocsf_payload["flow_source"] == "sFlow v5"
    refute Map.has_key?(row.ocsf_payload["unmapped"], "bytes_in")
    refute Map.has_key?(row.ocsf_payload["unmapped"], "bytes_out")
    refute Map.has_key?(row.ocsf_payload["unmapped"], "packets_in")
    refute Map.has_key?(row.ocsf_payload["unmapped"], "packets_out")
  end

  test "parse_message accepts attributed_flow protobuf payloads" do
    flow = %FlowMessage{
      type: :NETFLOW_V9,
      time_received_ns: 1_705_363_200_000_000_000,
      src_addr: <<192, 0, 2, 10>>,
      dst_addr: <<198, 51, 100, 20>>,
      proto: 6,
      src_port: 53_000,
      dst_port: 443,
      bytes: 4096,
      packets: 8
    }

    message = %AttributedFlowMessage{
      event_type: "attributed_flow",
      flow: flow,
      attribution: %FlowAttribution{
        pid: 1234,
        comm: "nginx",
        redacted_cmdline: "nginx: worker process",
        uid: 33,
        container_id: "container-1"
      },
      agent_id: "agent-1",
      partition: "edge-a"
    }

    row =
      Flows.parse_message(%{
        data: AttributedFlowMessage.encode(message),
        metadata: %{subject: "flow.attributed.edge-a"}
      })

    assert row.partition == "edge-a"
    assert row.src_endpoint_ip == "192.0.2.10"
    assert row.dst_endpoint_ip == "198.51.100.20"
    assert row.ocsf_payload["event_type"] == "attributed_flow"
    assert row.ocsf_payload["agent_id"] == "agent-1"

    assert row.ocsf_payload["attribution"] == %{
             "pid" => 1234,
             "comm" => "nginx",
             "redacted_cmdline" => "nginx: worker process",
             "uid" => 33,
             "container_id" => "container-1"
           }
  end

  describe "attribution byte-capping (Mi-85)" do
    @telemetry_event [
      :serviceradar,
      :flow_collector,
      :attribution,
      :truncated
    ]

    defp attach_truncation_handler(test_pid) do
      ref = make_ref()
      handler_id = "attribution-truncation-#{inspect(ref)}"

      :ok =
        :telemetry.attach(
          handler_id,
          @telemetry_event,
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit_unattach(handler_id)
      handler_id
    end

    defp on_exit_unattach(handler_id) do
      ExUnit.Callbacks.on_exit(fn ->
        _ = :telemetry.detach(handler_id)
      end)
    end

    defp build_attributed_row(attribution) do
      flow = %FlowMessage{
        type: :NETFLOW_V9,
        time_received_ns: 1_705_363_200_000_000_000,
        src_addr: <<192, 0, 2, 10>>,
        dst_addr: <<198, 51, 100, 20>>,
        proto: 6,
        src_port: 53_000,
        dst_port: 443,
        bytes: 4096,
        packets: 8
      }

      message = %AttributedFlowMessage{
        event_type: "attributed_flow",
        flow: flow,
        attribution: attribution,
        agent_id: "agent-1",
        partition: "edge-a"
      }

      Flows.parse_message(%{
        data: AttributedFlowMessage.encode(message),
        metadata: %{subject: "flow.attributed.edge-a"}
      })
    end

    test "ASCII redacted_cmdline within cap passes through unchanged" do
      # No telemetry handler attached: we only need to assert that the value
      # round-trips unchanged. Attaching a handler here would risk false
      # positives from other async tests in the module firing the same global
      # telemetry event.
      cmdline = String.duplicate("a", 256)

      row =
        build_attributed_row(%FlowAttribution{
          pid: 1,
          comm: "nginx",
          redacted_cmdline: cmdline,
          uid: 0,
          container_id: "c1"
        })

      assert row.ocsf_payload["attribution"]["redacted_cmdline"] == cmdline
      assert byte_size(row.ocsf_payload["attribution"]["redacted_cmdline"]) == 256
    end

    test "ASCII redacted_cmdline above cap is byte-truncated and emits telemetry" do
      attach_truncation_handler(self())

      cmdline = String.duplicate("b", 300)

      row =
        build_attributed_row(%FlowAttribution{
          pid: 1,
          comm: "nginx",
          redacted_cmdline: cmdline,
          uid: 0,
          container_id: "c1"
        })

      truncated = row.ocsf_payload["attribution"]["redacted_cmdline"]
      assert byte_size(truncated) == 256
      assert truncated == String.duplicate("b", 256)

      assert_receive {:telemetry, @telemetry_event, measurements, metadata}
      assert measurements.count == 1
      assert measurements.original_bytes == 300
      assert measurements.truncated_bytes == 256
      assert metadata.field == "redacted_cmdline"
      assert metadata.partition == "edge-a"
    end

    test "multi-byte UTF-8 redacted_cmdline never splits a codepoint" do
      attach_truncation_handler(self())

      # "é" is 2 bytes in UTF-8 ("\xC3\xA9"). 200 "é" = 400 bytes.
      cmdline = String.duplicate("é", 200)

      row =
        build_attributed_row(%FlowAttribution{
          pid: 1,
          comm: "nginx",
          redacted_cmdline: cmdline,
          uid: 0,
          container_id: "c1"
        })

      truncated = row.ocsf_payload["attribution"]["redacted_cmdline"]

      # Must be valid UTF-8 (no half-codepoint at the tail).
      assert String.valid?(truncated)
      # Must not exceed the byte cap.
      assert byte_size(truncated) <= 256
      # 2-byte chars cap evenly at 256 -> 128 chars retained.
      assert truncated == String.duplicate("é", 128)
      assert byte_size(truncated) == 256

      assert_receive {:telemetry, @telemetry_event, measurements, %{field: "redacted_cmdline"}}
      assert measurements.original_bytes == 400
      assert measurements.truncated_bytes == 256
    end

    test "4-byte UTF-8 codepoints are trimmed to a valid boundary" do
      attach_truncation_handler(self())

      # "𝄞" (U+1D11E MUSICAL SYMBOL G CLEF) is 4 bytes in UTF-8.
      # 64 chars * 4 bytes = 256 bytes -> exactly at the cap.
      # 65 chars = 260 bytes -> would truncate; naive slice at 256
      # would land mid-codepoint (256 / 4 = 64, so 64th char ends at
      # byte 256, and the 65th codepoint occupies bytes 256-259).
      # The boundary trim must yield exactly 64 chars / 256 bytes.
      cmdline = String.duplicate("𝄞", 65)
      assert byte_size(cmdline) == 260

      row =
        build_attributed_row(%FlowAttribution{
          pid: 1,
          comm: "nginx",
          redacted_cmdline: cmdline,
          uid: 0,
          container_id: "c1"
        })

      truncated = row.ocsf_payload["attribution"]["redacted_cmdline"]
      assert String.valid?(truncated)
      assert byte_size(truncated) <= 256
      assert truncated == String.duplicate("𝄞", 64)
      assert byte_size(truncated) == 256

      assert_receive {:telemetry, @telemetry_event, measurements, %{field: "redacted_cmdline"}}
      assert measurements.original_bytes == 260
      assert measurements.truncated_bytes == 256
    end

    test "redacted_cmdline naive-slice mid-codepoint is trimmed back" do
      attach_truncation_handler(self())

      # Build a payload where byte 256 lands in the middle of a 3-byte
      # codepoint. 254 ASCII bytes + one 3-byte char "€" ("\xE2\x82\xAC").
      # Total = 257 bytes; cap at 256 puts us 2 bytes into the "€" — the
      # boundary walk must drop those 2 bytes, yielding 254 bytes.
      cmdline = String.duplicate("a", 254) <> "€"
      assert byte_size(cmdline) == 257

      row =
        build_attributed_row(%FlowAttribution{
          pid: 1,
          comm: "nginx",
          redacted_cmdline: cmdline,
          uid: 0,
          container_id: "c1"
        })

      truncated = row.ocsf_payload["attribution"]["redacted_cmdline"]
      assert String.valid?(truncated)
      assert byte_size(truncated) == 254
      assert truncated == String.duplicate("a", 254)

      assert_receive {:telemetry, @telemetry_event, measurements, %{field: "redacted_cmdline"}}
      assert measurements.original_bytes == 257
      assert measurements.truncated_bytes == 254
    end

    test "comm and container_id obey their byte caps" do
      attach_truncation_handler(self())

      # comm cap = 16 bytes; container_id cap = 64 bytes.
      long_comm = String.duplicate("x", 20)
      long_container = String.duplicate("c", 100)

      row =
        build_attributed_row(%FlowAttribution{
          pid: 1,
          comm: long_comm,
          redacted_cmdline: "ok",
          uid: 0,
          container_id: long_container
        })

      attribution = row.ocsf_payload["attribution"]
      assert byte_size(attribution["comm"]) == 16
      assert attribution["comm"] == String.duplicate("x", 16)
      assert byte_size(attribution["container_id"]) == 64
      assert attribution["container_id"] == String.duplicate("c", 64)

      # Both fields should emit a truncation event.
      assert_receive {:telemetry, @telemetry_event, %{original_bytes: 20, truncated_bytes: 16},
                      %{field: "comm"}}

      assert_receive {:telemetry, @telemetry_event, %{original_bytes: 100, truncated_bytes: 64},
                      %{field: "container_id"}}
    end
  end

  describe "partition mismatch telemetry (B-4)" do
    @partition_mismatch_event [
      :serviceradar,
      :event_writer,
      :flows,
      :partition_mismatch
    ]

    defp attach_partition_mismatch_handler(test_pid) do
      ref = make_ref()
      handler_id = "partition-mismatch-#{inspect(ref)}"

      :ok =
        :telemetry.attach(
          handler_id,
          @partition_mismatch_event,
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      detach_on_exit(handler_id)
      handler_id
    end

    defp detach_on_exit(handler_id) do
      ExUnit.Callbacks.on_exit(fn ->
        _ = :telemetry.detach(handler_id)
      end)
    end

    defp build_attributed_row_with_body_partition(body_partition, subject) do
      flow = %FlowMessage{
        type: :NETFLOW_V9,
        time_received_ns: 1_705_363_200_000_000_000,
        src_addr: <<192, 0, 2, 10>>,
        dst_addr: <<198, 51, 100, 20>>,
        proto: 6,
        src_port: 53_000,
        dst_port: 443,
        bytes: 4096,
        packets: 8
      }

      message = %AttributedFlowMessage{
        event_type: "attributed_flow",
        flow: flow,
        attribution: %FlowAttribution{
          pid: 1,
          comm: "nginx",
          redacted_cmdline: "ok",
          uid: 0,
          container_id: "c1"
        },
        agent_id: "agent-1",
        partition: body_partition
      }

      Flows.parse_message(%{
        data: AttributedFlowMessage.encode(message),
        metadata: %{subject: subject}
      })
    end

    test "emits partition_mismatch when body partition differs from subject partition" do
      attach_partition_mismatch_handler(self())

      row = build_attributed_row_with_body_partition("beta", "flow.attributed.alpha")

      assert_receive {:telemetry, @partition_mismatch_event, %{count: 1}, metadata}
      assert metadata.subject == "flow.attributed.alpha"
      assert metadata.body_partition == "beta"
      assert metadata.subject_partition == "alpha"

      # Subject wins per flows.ex:622.
      assert row.partition == "alpha"
      assert row.ocsf_payload["partition"] == "alpha"
    end

    test "does not emit when body partition matches subject partition" do
      attach_partition_mismatch_handler(self())

      row = build_attributed_row_with_body_partition("alpha", "flow.attributed.alpha")

      refute_receive {:telemetry, @partition_mismatch_event, _, _}, 50
      assert row.partition == "alpha"
    end

    test "does not emit when body partition is blank" do
      attach_partition_mismatch_handler(self())

      row = build_attributed_row_with_body_partition("", "flow.attributed.alpha")

      refute_receive {:telemetry, @partition_mismatch_event, _, _}, 50
      # Subject partition still wins when body is blank.
      assert row.partition == "alpha"
    end
  end

  describe "attributed-subject decode telemetry (Mi-86)" do
    @attributed_decode_event [
      :serviceradar,
      :event_writer,
      :flows,
      :attributed_decode_failed
    ]

    defp attach_attributed_decode_handler(test_pid) do
      ref = make_ref()
      handler_id = "attributed-decode-#{inspect(ref)}"

      :ok =
        :telemetry.attach(
          handler_id,
          @attributed_decode_event,
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      ExUnit.Callbacks.on_exit(fn ->
        _ = :telemetry.detach(handler_id)
      end)

      handler_id
    end

    test "emits :decode_error on malformed protobuf bytes for attributed subject" do
      attach_attributed_decode_handler(self())

      result =
        Flows.parse_message(%{
          data: <<0xFF, 0xFF, 0xFF, 0xFF>>,
          metadata: %{subject: "flow.attributed.alpha"}
        })

      assert is_nil(result)

      assert_receive {:telemetry, @attributed_decode_event, %{count: 1}, metadata}
      assert metadata.subject == "flow.attributed.alpha"
      assert metadata.reason == :decode_error
    end

    test "emits :event_type_mismatch on valid protobuf that decodes to a non-usable AttributedFlowMessage shape" do
      attach_attributed_decode_handler(self())

      # Encode an AttributedFlowMessage whose event_type does not match
      # @attributed_flow_event_type ("attributed_flow"). The decode succeeds,
      # but processed_from_attributed_flow_message/2 returns nil per the
      # head guard at flows.ex:166-172, triggering :event_type_mismatch.
      flow = %FlowMessage{
        type: :NETFLOW_V9,
        time_received_ns: 1_705_363_200_000_000_000,
        src_addr: <<192, 0, 2, 10>>,
        dst_addr: <<198, 51, 100, 20>>,
        proto: 6,
        src_port: 53_000,
        dst_port: 443,
        bytes: 4096,
        packets: 8
      }

      message = %AttributedFlowMessage{
        event_type: "not_attributed_flow",
        flow: flow,
        attribution: %FlowAttribution{
          pid: 1,
          comm: "nginx",
          redacted_cmdline: "ok",
          uid: 0,
          container_id: "c1"
        },
        agent_id: "agent-1",
        partition: "alpha"
      }

      result =
        Flows.parse_message(%{
          data: AttributedFlowMessage.encode(message),
          metadata: %{subject: "flow.attributed.alpha"}
        })

      assert is_nil(result)

      assert_receive {:telemetry, @attributed_decode_event, %{count: 1}, metadata}
      assert metadata.subject == "flow.attributed.alpha"
      assert metadata.reason == :event_type_mismatch
    end

    test "does not emit attributed_decode_failed for unattributed subjects with malformed payload" do
      attach_attributed_decode_handler(self())

      _result =
        Flows.parse_message(%{
          data: <<0xFF, 0xFF, 0xFF, 0xFF>>,
          metadata: %{subject: "flows.raw.netflow"}
        })

      # The Mi-86 gate only fires on attributed subjects (flows.ex:200-205).
      refute_receive {:telemetry, @attributed_decode_event, _, _}, 50
    end
  end
end
