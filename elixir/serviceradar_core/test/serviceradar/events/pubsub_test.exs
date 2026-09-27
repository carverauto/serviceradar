defmodule ServiceRadar.Events.PubSubTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.Events
  alias ServiceRadar.Events.PubSub, as: EventsPubSub

  @row %{
    id: "3f1b8a52-6c1e-4f5d-9d3b-2b8e4d7a9c10",
    time: ~U[2026-09-26 12:00:00.000000Z],
    class_uid: 1008,
    category_uid: 1,
    type_uid: 100_801,
    activity_id: 1,
    activity_name: "Fault Opened",
    severity_id: 4,
    severity: "High",
    message: "Conveyor jam on belt 7",
    status_id: 1,
    status: "Success",
    status_code: nil,
    log_name: "demo.faults",
    log_provider: "plugin:demo-ot-plc",
    device: %{
      "uid" => "sr:device:plc-07",
      "hostname" => "plc07.example.test",
      "os" => %{"name" => "fw"}
    },
    metadata: %{"plugin_id" => "demo-ot-plc", "fault_kind" => "jam"},
    observables: [%{"name" => "ip", "value" => "192.0.2.7"}],
    raw_data: "{...}",
    unmapped: %{"x" => 1}
  }

  test "summaries keep the fields subscribers filter on and drop bulky ones" do
    summary = EventsPubSub.event_summary(@row)

    assert summary["id"] == @row.id
    assert summary["time"] == "2026-09-26T12:00:00.000000Z"
    assert summary["log_provider"] == "plugin:demo-ot-plc"
    assert summary["severity_id"] == 4
    assert summary["metadata"] == %{"plugin_id" => "demo-ot-plc", "fault_kind" => "jam"}
    assert summary["device"] == %{"uid" => "sr:device:plc-07", "hostname" => "plc07.example.test"}

    refute Map.has_key?(summary, "raw_data")
    refute Map.has_key?(summary, "observables")
    refute Map.has_key?(summary, "unmapped")
  end

  test "summaries tolerate rows without device or metadata maps" do
    summary = EventsPubSub.event_summary(%{id: "e-1", time: nil, device: nil, metadata: nil})

    assert summary["device"] == %{}
    assert summary["metadata"] == %{}
    assert summary["time"] == nil
  end

  test "summaries of parsed EventWriter rows carry a JSON-safe UUID string id" do
    uuid = "3f1b8a52-6c1e-4f5d-9d3b-2b8e4d7a9c10"

    for id <- [uuid, "plugin-1700000000-1"] do
      payload =
        Jason.encode!(%{
          "id" => id,
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "message" => "Conveyor jam on belt 7"
        })

      row = Events.parse_message(%{data: payload, metadata: %{subject: "events.demo"}})
      summary = EventsPubSub.event_summary(row)

      assert {:ok, _uuid} = Ecto.UUID.cast(summary["id"])
      assert {:ok, json} = Jason.encode(summary)
      assert %{"id" => decoded_id} = Jason.decode!(json)
      assert decoded_id == summary["id"]

      if id == uuid, do: assert(decoded_id == uuid)
    end
  end

  test "an empty row list broadcasts nothing" do
    assert EventsPubSub.broadcast_event_rows([]) == :ok
  end
end
