defmodule ServiceRadar.EventWriter.Processors.CausalSignalsTest do
  use ExUnit.Case, async: true

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
      assert row.metadata["schema_version"] == "1.0"
      assert row.device["uid"] == "mac-aabbccddeeff"
      assert row.src_endpoint["ip"] == "192.0.2.10"
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
  end
end
