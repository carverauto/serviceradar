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
        "id" => Ecto.UUID.generate(),
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

      assert is_binary(row.id)
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

    test "rejects a metric payload mis-routed to the OCSF events stream" do
      payload = %{
        "schema" => "serviceradar.metric.v1",
        "metric_name" => "cpu",
        "value" => 1.0,
        "temporality" => "cumulative"
      }

      message = %{data: Jason.encode!(payload), metadata: %{subject: "events.ocsf.processed"}}

      assert Events.parse_message(message) == nil
    end
  end

  describe "fields a producer leaves to EventWriter" do
    @event %{
      "id" => "0b7f6a2e-3f7d-4c55-9f1d-1f4b5f7c2a10",
      "class_uid" => 1008,
      "category_uid" => 1,
      "type_uid" => 100_801,
      "activity_id" => 1
    }

    test "an absent log_name and raw_data take the subject and the raw payload" do
      data = Jason.encode!(@event)
      row = Events.parse_message(%{data: data, metadata: %{subject: "events.ocsf.processed"}})

      assert row.log_name == "events.ocsf.processed"
      assert row.raw_data == data
    end

    # Core's publisher sends every field; a null it sends is a null it means.
    test "an explicit null log_name and raw_data are stored as null" do
      data = Jason.encode!(Map.merge(@event, %{"log_name" => nil, "raw_data" => nil}))
      row = Events.parse_message(%{data: data, metadata: %{subject: "events.internal.jobs"}})

      assert row.log_name == nil
      assert row.raw_data == nil
    end
  end
end
