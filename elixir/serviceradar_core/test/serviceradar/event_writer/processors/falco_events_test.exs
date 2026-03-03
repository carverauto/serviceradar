defmodule ServiceRadar.EventWriter.Processors.FalcoEventsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Pipeline
  alias ServiceRadar.EventWriter.Processors.FalcoEvents

  describe "table_name/0" do
    test "returns correct table name" do
      assert FalcoEvents.table_name() == "logs"
    end
  end

  describe "promotion thresholds" do
    test "promotes warning and above to events" do
      assert FalcoEvents.promote_to_event?(3)
      assert FalcoEvents.promote_to_event?(6)
      refute FalcoEvents.promote_to_event?(2)
      refute FalcoEvents.promote_to_event?(1)
    end

    test "promotes critical and emergency to alerts" do
      assert FalcoEvents.promote_to_alert?(5)
      assert FalcoEvents.promote_to_alert?(6)
      refute FalcoEvents.promote_to_alert?(4)
      refute FalcoEvents.promote_to_alert?(3)
    end
  end

  describe "parse_message/1" do
    test "maps warning priority to medium severity and failure status" do
      payload = %{
        "uuid" => "6c226df2-9877-4630-b9f4-c419a88599e1",
        "output" => "Unexpected connection to K8s API Server from container",
        "priority" => "Warning",
        "rule" => "Contact K8S API Server From Container",
        "time" => "2026-03-03T05:56:44.079252771Z",
        "output_fields" => %{
          "container.id" => "ec56370f8d11",
          "container.name" => "grafana-sc-datasources",
          "k8s.pod.name" => "kube-prom-grafana-85d59d85f9-gg6zz",
          "proc.name" => "python",
          "user.name" => "<NA>"
        },
        "source" => "syscall",
        "tags" => ["container", "k8s", "network"],
        "hostname" => "k8s-cp2-worker2"
      }

      message = %{data: Jason.encode!(payload), metadata: %{subject: "falco.warning.contact_k8s"}}

      row = FalcoEvents.parse_message(message)

      assert is_binary(row.id)
      assert byte_size(row.id) == 16
      assert row.class_uid == 1008
      assert row.category_uid == 1
      assert row.activity_id == 3
      assert row.type_uid == 100_803
      assert row.activity_name == "Update"
      assert row.severity_id == 3
      assert row.severity == "Medium"
      assert row.status_id == 2
      assert row.status == "Failure"
      assert row.message == payload["output"]
      assert row.log_provider == "falco"
      assert row.log_name == "falco.warning.contact_k8s"
      assert row.log_level == "Warning"
      assert row.metadata["rule"] == payload["rule"]
      assert row.metadata["priority"] == payload["priority"]
      assert row.metadata["hostname"] == payload["hostname"]
      assert row.metadata["output_fields"]["container.id"] == "ec56370f8d11"
      assert row.unmapped["uuid"] == payload["uuid"]
      assert %DateTime{} = row.time
      assert is_binary(row.raw_data)
    end

    test "maps notice priority to low severity and success status" do
      payload = %{
        "output" => "Notice event",
        "priority" => "Notice",
        "rule" => "Some Falco Rule",
        "time" => "2026-03-03T05:56:49.684779242Z"
      }

      message = %{data: Jason.encode!(payload), metadata: %{subject: "falco.notice.some_rule"}}

      row = FalcoEvents.parse_message(message)

      assert row.severity_id == 2
      assert row.severity == "Low"
      assert row.status_id == 1
      assert row.status == "Success"
    end

    test "maps unknown priority to unknown severity and other status" do
      payload = %{
        "output" => "Unknown priority event",
        "priority" => "Weird",
        "time" => "2026-03-03T05:56:49.684779242Z"
      }

      message = %{data: Jason.encode!(payload), metadata: %{subject: "falco.weird.some_rule"}}

      row = FalcoEvents.parse_message(message)

      assert row.severity_id == 0
      assert row.severity == "Unknown"
      assert row.status_id == 99
      assert row.status == "Other"
    end

    test "uses deterministic fallback id when uuid is missing" do
      payload = %{
        "output" => "No UUID payload",
        "priority" => "Error",
        "rule" => "Missing UUID Rule"
      }

      message = %{data: Jason.encode!(payload), metadata: %{subject: "falco.error.missing_uuid"}}

      row1 = FalcoEvents.parse_message(message)
      row2 = FalcoEvents.parse_message(message)

      assert row1.id == row2.id
    end

    test "returns nil for invalid JSON" do
      message = %{data: "not-json", metadata: %{subject: "falco.notice.invalid"}}

      assert FalcoEvents.parse_message(message) == nil
    end
  end

  describe "pipeline routing" do
    test "routes falco subjects to falco batcher" do
      event = %{
        data: Jason.encode!(%{"priority" => "Notice", "output" => "hello"}),
        metadata: %{subject: "falco.notice.contact_k8s_api_server_from_container"},
        ack_data: %{}
      }

      message = Pipeline.transform(event, [])
      routed = Pipeline.handle_message(:default, message, %{})

      assert routed.batcher == :falco
    end
  end
end
