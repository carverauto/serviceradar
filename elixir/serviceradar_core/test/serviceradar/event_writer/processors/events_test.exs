defmodule ServiceRadar.EventWriter.Processors.EventsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.Events

  describe "table_name/0" do
    test "returns correct table name" do
      assert Events.table_name() == "ocsf_events"
    end
  end

  describe "parse_message/1" do
    test "parses OCSF event payloads" do
      payload = %{
        "id" => "event-123",
        "time" => "2024-01-01T00:00:00Z",
        "class_uid" => 1008,
        "category_uid" => 1,
        "type_uid" => 100_801,
        "activity_id" => 1,
        "severity_id" => 5,
        "message" => "gateway offline",
        "metadata" => %{"version" => "1.7.0"}
      }

      message = %{data: Jason.encode!(payload), metadata: %{subject: "events.ocsf.processed"}}

      row = Events.parse_message(message)

      assert row.id == "event-123"
      assert row.class_uid == 1008
      assert row.category_uid == 1
      assert row.activity_id == 1
      assert row.type_uid == 100_801
      assert row.message == "gateway offline"
      assert row.severity_id == 5
      assert row.severity == "Critical"
      assert row.log_name == "events.ocsf.processed"
      assert row.metadata["version"] == "1.7.0"
      assert %DateTime{} = row.time
      assert is_binary(row.raw_data)
    end

    test "returns nil when required fields are missing" do
      payload = %{
        "time" => "2024-01-01T00:00:00Z",
        "class_uid" => 1008
      }

      message = %{data: Jason.encode!(payload), metadata: %{subject: "events.ocsf.processed"}}

      row = Events.parse_message(message)

      assert row == nil
    end
  end
end
