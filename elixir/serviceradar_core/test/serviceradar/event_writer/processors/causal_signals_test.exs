defmodule ServiceRadar.EventWriter.Processors.CausalSignalsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Pipeline
  alias ServiceRadar.EventWriter.Processors.CausalSignals

  describe "table_name/0" do
    test "returns ocsf_events" do
      assert CausalSignals.table_name() == "ocsf_events"
    end
  end

  describe "parse_message/1" do
    test "normalizes BMP payload into causal envelope row" do
      payload = %{
        "event_id" => "bmp-123",
        "timestamp" => "2026-02-16T12:00:00Z",
        "severity" => "high",
        "peer_ip" => "192.0.2.10",
        "peer_asn" => "64513",
        "router_id" => "router-a",
        "router_ip" => "10.0.0.1",
        "device_id" => "mac-aabbccddeeff",
        "message" => "BGP peer down"
      }

      message = %{
        data: Jason.encode!(payload),
        metadata: %{subject: "bmp.events.peer", received_at: DateTime.utc_now()}
      }

      row = CausalSignals.parse_message(message)

      refute is_nil(row)
      assert is_binary(row.id)
      assert byte_size(row.id) == 16
      assert row.class_uid == 1008
      assert row.type_uid == 100_811
      assert row.severity_id == 4
      assert row.metadata["signal_type"] == "bmp"
      assert row.metadata["event_type"] == "peer"
      assert row.metadata["schema_version"] == "1.0"
      assert row.metadata["primary_domain"] == "routing"
      assert row.metadata["source_identity"]["router_id"] == "router-a"
      assert row.metadata["routing_correlation"]["peer_asn"] == 64_513
      assert row.metadata["routing_correlation"]["router_ip"] == "10.0.0.1"
      assert "192.0.2.10" in row.metadata["routing_correlation"]["topology_keys"]
      assert row.device["uid"] == "mac-aabbccddeeff"
      assert row.src_endpoint["ip"] == "192.0.2.10"
      assert row.src_endpoint["asn"] == 64_513
    end

    test "normalizes SIEM payload and clamps numeric severity" do
      payload = %{
        "id" => "siem-evt-1",
        "time" => "2026-02-16T12:10:00Z",
        "severity_id" => 9,
        "message" => "intrusion detected"
      }

      message = %{
        data: Jason.encode!(payload),
        metadata: %{subject: "siem.events.alert", received_at: DateTime.utc_now()}
      }

      row = CausalSignals.parse_message(message)

      refute is_nil(row)
      assert row.type_uid == 100_812
      assert row.severity_id == 6
      assert row.severity == "Fatal"
      assert row.metadata["signal_type"] == "siem"
      assert row.metadata["primary_domain"] == "security"
    end

    test "returns nil on invalid JSON" do
      row =
        CausalSignals.parse_message(%{data: "not-json", metadata: %{subject: "bmp.events.peer"}})

      assert row == nil
    end

    test "uses deterministic ID for identical payloads" do
      payload = %{
        "event_id" => "stable-id",
        "timestamp" => "2026-02-16T12:20:00Z",
        "severity" => "medium"
      }

      metadata = %{subject: "bmp.events.peer", received_at: DateTime.utc_now()}
      message = %{data: Jason.encode!(payload), metadata: metadata}

      row1 = CausalSignals.parse_message(message)
      row2 = CausalSignals.parse_message(message)

      assert row1.id == row2.id
    end

    test "includes grouped contexts and explainability metadata" do
      payload = %{
        "event_id" => "ctx-1",
        "timestamp" => "2026-02-16T12:20:00Z",
        "severity" => "high",
        "signal_domains" => ["routing", "security"],
        "security_zones" => ["zone-a", "zone-b"],
        "bgp_prefix_groups" => ["as64512-core"]
      }

      message = %{
        data: Jason.encode!(payload),
        metadata: %{subject: "bmp.events.peer", received_at: DateTime.utc_now()}
      }

      row = CausalSignals.parse_message(message)

      refute is_nil(row)
      assert row.metadata["primary_domain"] == "security"
      assert row.metadata["signal_domains"] == ["routing", "security"]
      assert length(row.metadata["grouped_contexts"]) == 3
      assert row.metadata["explainability"]["primary_domain"] == "security"
      assert row.metadata["explainability"]["source_signal_refs"] == ["ctx-1"]
      assert row.metadata["guardrails"]["contexts_truncated"] == false
    end

    test "enforces grouped context guardrail truncation" do
      zones = Enum.map(1..40, &"zone-#{&1}")

      payload = %{
        "event_id" => "ctx-truncate",
        "timestamp" => "2026-02-16T12:20:00Z",
        "severity" => "medium",
        "signal_domain" => "security",
        "security_zones" => zones
      }

      message = %{
        data: Jason.encode!(payload),
        metadata: %{subject: "siem.events.alert", received_at: DateTime.utc_now()}
      }

      row = CausalSignals.parse_message(message)

      refute is_nil(row)
      assert length(row.metadata["grouped_contexts"]) == 32
      assert row.metadata["guardrails"]["contexts_truncated"] == true
      assert row.metadata["guardrails"]["input_context_count"] == 40
      assert row.metadata["guardrails"]["applied_context_count"] == 32
    end

    test "normalizes routing correlation keys for topology joins" do
      payload = %{
        "event_id" => "join-1",
        "timestamp" => "2026-02-16T12:20:00Z",
        "severity" => "critical",
        "deviceId" => "router-edge-01",
        "peer_ip" => "198.51.100.77",
        "peerAsn" => "64522",
        "localAsn" => 64512,
        "prefix" => "203.0.113.0/24",
        "vrf" => "default"
      }

      message = %{
        data: Jason.encode!(payload),
        metadata: %{subject: "bmp.events.update", received_at: DateTime.utc_now()}
      }

      row = CausalSignals.parse_message(message)

      refute is_nil(row)
      assert row.metadata["source_identity"]["device_uid"] == "router-edge-01"
      assert row.metadata["routing_correlation"]["local_asn"] == 64_512
      assert row.metadata["routing_correlation"]["peer_asn"] == 64_522
      assert row.metadata["routing_correlation"]["vrf"] == "default"
      assert row.metadata["routing_correlation"]["prefix"] == "203.0.113.0/24"
      assert "router-edge-01" in row.metadata["routing_correlation"]["topology_keys"]
      assert "198.51.100.77" in row.metadata["explainability"]["routing_topology_keys"]
    end

    test "uses explicit event_type when provided by collector payload" do
      payload = %{
        "event_id" => "evt-typed-1",
        "event_type" => "route_withdraw",
        "timestamp" => "2026-02-16T12:21:00Z",
        "severity" => "low"
      }

      message = %{
        data: Jason.encode!(payload),
        metadata: %{subject: "bmp.events.peer_down", received_at: DateTime.utc_now()}
      }

      row = CausalSignals.parse_message(message)
      refute is_nil(row)
      assert row.metadata["event_type"] == "route_withdraw"
    end
  end

  describe "replay determinism via Broadway causal routing" do
    test "BMP burst replay yields identical normalized causal overlay inputs" do
      burst = bmp_burst_messages()

      first_projection =
        burst
        |> route_broadway_messages()
        |> parse_causal_rows()
        |> causal_overlay_projection()

      # Replay same logical events in different order to emulate JetStream redelivery.
      replay_projection =
        burst
        |> Enum.reverse()
        |> route_broadway_messages()
        |> parse_causal_rows()
        |> causal_overlay_projection()

      assert first_projection == replay_projection
      assert length(first_projection) == 4
    end

    test "grouped context replay yields deterministic precedence and explainability" do
      now = "2026-02-16T13:10:00Z"

      burst =
        [
          %{
            "event_id" => "ctx-a",
            "timestamp" => now,
            "severity" => "high",
            "signal_domains" => ["routing", "security"],
            "security_zones" => ["zone-a"],
            "bgp_prefix_groups" => ["as64512-core"]
          },
          %{
            "event_id" => "ctx-b",
            "timestamp" => now,
            "severity" => "medium",
            "signal_domain" => "routing",
            "bgp_prefix_group" => "as64512-edge"
          }
        ]
        |> Enum.map(fn payload ->
          %{
            data: Jason.encode!(payload),
            metadata: %{subject: "signals.causal.overlay", received_at: DateTime.utc_now()},
            ack_data: %{}
          }
        end)

      first =
        burst
        |> route_broadway_messages()
        |> parse_causal_rows()
        |> grouped_projection()

      replay =
        burst
        |> Enum.reverse()
        |> route_broadway_messages()
        |> parse_causal_rows()
        |> grouped_projection()

      assert first == replay

      assert Enum.any?(first, fn {_id, primary_domain, _contexts} ->
               primary_domain == "security"
             end)
    end
  end

  defp bmp_burst_messages do
    now = "2026-02-16T13:00:00Z"

    [
      %{
        "event_id" => "bmp-a",
        "timestamp" => now,
        "severity" => "high",
        "device_id" => "router-a",
        "peer_ip" => "192.0.2.1",
        "message" => "peer down"
      },
      %{
        "event_id" => "bmp-b",
        "timestamp" => now,
        "severity" => "critical",
        "device_id" => "router-b",
        "peer_ip" => "192.0.2.2",
        "message" => "withdraw storm"
      },
      %{
        "event_id" => "bmp-c",
        "timestamp" => now,
        "severity" => "medium",
        "device_id" => "router-a",
        "peer_ip" => "192.0.2.1",
        "message" => "path change"
      },
      %{
        "event_id" => "bmp-d",
        "timestamp" => now,
        "severity" => "low",
        "device_id" => "router-c",
        "peer_ip" => "192.0.2.3",
        "message" => "route flap"
      },
      # Duplicate logical event id in same burst to assert deterministic projection contract.
      %{
        "event_id" => "bmp-a",
        "timestamp" => now,
        "severity" => "high",
        "device_id" => "router-a",
        "peer_ip" => "192.0.2.1",
        "message" => "peer down"
      }
    ]
    |> Enum.map(fn payload ->
      %{
        data: Jason.encode!(payload),
        metadata: %{subject: "bmp.events.peer", received_at: DateTime.utc_now()},
        ack_data: %{}
      }
    end)
  end

  defp route_broadway_messages(events) do
    Enum.map(events, fn event ->
      message = Pipeline.transform(event, [])
      routed = Pipeline.handle_message(:default, message, %{})
      assert routed.batcher == :causal_signals
      routed
    end)
  end

  defp parse_causal_rows(messages) do
    messages
    |> Enum.map(fn message ->
      CausalSignals.parse_message(%{data: message.data, metadata: message.metadata})
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Deterministic projection used by topology causal overlays:
  # identity + signal attributes sorted independent of ingest/replay order.
  defp causal_overlay_projection(rows) do
    rows
    |> Enum.map(fn row ->
      {
        row.metadata["event_identity"],
        row.metadata["signal_type"],
        row.severity_id,
        row.device["uid"],
        row.src_endpoint["ip"]
      }
    end)
    |> MapSet.new()
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp grouped_projection(rows) do
    rows
    |> Enum.map(fn row ->
      context_ids =
        row.metadata["grouped_contexts"]
        |> Enum.map(&{"#{&1["type"]}", "#{&1["id"]}"})
        |> Enum.sort()

      {row.metadata["event_identity"], row.metadata["primary_domain"], context_ids}
    end)
    |> Enum.sort()
  end
end
