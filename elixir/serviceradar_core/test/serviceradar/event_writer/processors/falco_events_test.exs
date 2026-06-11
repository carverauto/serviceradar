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
          "container.image.repository" => "grafana/grafana",
          "container.image.tag" => "11.6.0",
          "container.name" => "grafana-sc-datasources",
          "evt.type" => "connect",
          "fd.dip" => "10.42.0.1",
          "fd.dport" => "443",
          "fd.l4proto" => "tcp",
          "fd.name" => "10.42.0.1:443",
          "fd.sip" => "10.42.3.25",
          "fd.sport" => "49200",
          "k8s.pod.name" => "kube-prom-grafana-85d59d85f9-gg6zz",
          "proc.cmdline" => "python /app/sidecar.py",
          "proc.cwd" => "/app",
          "proc.is_exe_upper_layer" => true,
          "proc.name" => "python",
          "user.name" => "<NA>"
        },
        "rule_url" => "https://falco.org/docs/reference/rules/default-rules/",
        "source" => "syscall",
        "tags" => ["container", "k8s", "network"],
        "hostname" => "k8s-cp2-worker2"
      }

      message = %{data: Jason.encode!(payload), metadata: %{subject: "falco.warning.contact_k8s"}}

      row = FalcoEvents.parse_message(message)

      assert is_binary(row.id)
      assert byte_size(row.id) == 16
      assert row.class_uid == 2004
      assert row.category_uid == 2
      assert row.activity_id == 1
      assert row.type_uid == 200_401
      assert row.activity_name == "Create"
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
      assert row.metadata["version"] == "1.9.0-dev"
      assert row.metadata["product"]["name"] == "Falco"
      assert row.metadata["service_radar"]["source_type"] == "falco"
      assert row.metadata["service_radar"]["device_hostname"] == "k8s-cp2-worker2"
      assert row.metadata["service_radar"]["container_id"] == "ec56370f8d11"

      diagnostics = row.metadata["security_signal"]["diagnostics"]
      assert diagnostics["rule"]["name"] == payload["rule"]
      assert diagnostics["rule"]["priority"] == "Warning"
      assert diagnostics["rule"]["source"] == "syscall"
      assert diagnostics["rule"]["tags"] == ["container", "k8s", "network"]

      assert diagnostics["rule"]["references"] == [
               "https://falco.org/docs/reference/rules/default-rules/"
             ]

      assert diagnostics["host"]["name"] == "k8s-cp2-worker2"
      assert diagnostics["process"]["name"] == "python"
      assert diagnostics["process"]["command"] == "python /app/sidecar.py"
      assert diagnostics["process"]["cwd"] == "/app"
      assert diagnostics["process"]["executable_flags"]["upper_layer"] == true
      assert diagnostics["container"]["id"] == "ec56370f8d11"
      assert diagnostics["container"]["name"] == "grafana-sc-datasources"
      assert diagnostics["container"]["image_repository"] == "grafana/grafana"
      assert diagnostics["container"]["image_tag"] == "11.6.0"
      assert diagnostics["file"]["name"] == "10.42.0.1:443"
      assert diagnostics["network"]["source_ip"] == "10.42.3.25"
      assert diagnostics["network"]["source_port"] == "49200"
      assert diagnostics["network"]["destination_ip"] == "10.42.0.1"
      assert diagnostics["network"]["destination_port"] == "443"
      assert diagnostics["network"]["l4_protocol"] == "tcp"
      assert diagnostics["kubernetes"]["pod"] == "kube-prom-grafana-85d59d85f9-gg6zz"
      assert diagnostics["event"]["type"] == "connect"
      assert diagnostics["attribution"]["status"] == "partial"
      assert diagnostics["attribution"]["missing"] == ["kubernetes.namespace"]

      assert row.device[:uid] == "k8s-cp2-worker2"
      assert row.device[:hostname] == "k8s-cp2-worker2"
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

    test "uses Kubernetes node output field as the device host when hostname is absent" do
      payload = %{
        "output" => "Falco event from a workload",
        "priority" => "Warning",
        "rule" => "Workload Rule",
        "time" => "2026-03-03T05:56:49.684779242Z",
        "output_fields" => %{
          "container.id" => "container-1",
          "k8s.node.name" => "agent-k8s-cp3-worker1",
          "k8s.pod.name" => "falco-test-pod"
        }
      }

      message = %{data: Jason.encode!(payload), metadata: %{subject: "falco.logs"}}

      row = FalcoEvents.parse_message(message)

      assert row.metadata["service_radar"]["device_hostname"] == "agent-k8s-cp3-worker1"
      assert row.metadata["service_radar"]["node_name"] == "agent-k8s-cp3-worker1"
      assert row.device[:uid] == "agent-k8s-cp3-worker1"
      assert row.device[:hostname] == "agent-k8s-cp3-worker1"
      assert row.metadata["security_signal"]["diagnostics"]["attribution"]["status"] == "partial"
    end

    test "preserves explicit canonical device uid while keeping Falco host metadata" do
      payload = %{
        "device_uid" => "sr:f19b8510-1419-45d3-8622-9d20fbb9af31",
        "hostname" => "k8s-cp3-worker1",
        "output" => "Falco event with ServiceRadar device correlation",
        "priority" => "Warning",
        "rule" => "Correlated Falco Rule",
        "time" => "2026-03-03T05:56:49.684779242Z",
        "output_fields" => %{
          "serviceradar.agent_id" => "agent-k8s-cp3-worker1",
          "k8s.node.name" => "k8s-cp3-worker1",
          "k8s.pod.name" => "falco-test-pod"
        }
      }

      message = %{data: Jason.encode!(payload), metadata: %{subject: "falco.logs"}}

      row = FalcoEvents.parse_message(message)

      assert row.metadata["service_radar"]["device_uid"] ==
               "sr:f19b8510-1419-45d3-8622-9d20fbb9af31"

      assert row.metadata["service_radar"]["device_hostname"] == "k8s-cp3-worker1"
      assert row.metadata["service_radar"]["agent_id"] == "agent-k8s-cp3-worker1"
      assert row.device[:uid] == "sr:f19b8510-1419-45d3-8622-9d20fbb9af31"
      assert row.device[:hostname] == "k8s-cp3-worker1"
    end

    test "accepts ServiceRadar correlation fields injected by Falcosidekick custom fields" do
      payload = %{
        "custom_fields" => %{
          "serviceradar.agent_id" => "agent-k8s-cp3-worker1",
          "serviceradar.device_uid" => "sr:9a6211a0-46d9-4986-988d-01e14d886e40"
        },
        "hostname" => "k8s-cp3-worker1",
        "output" => "Falco event with Sidekick custom fields",
        "priority" => "Warning",
        "rule" => "Sidekick Correlated Rule",
        "time" => "2026-03-03T05:56:49.684779242Z",
        "output_fields" => %{
          "k8s.node.name" => "k8s-cp3-worker1"
        }
      }

      message = %{data: Jason.encode!(payload), metadata: %{subject: "falco.logs"}}

      row = FalcoEvents.parse_message(message)

      assert row.metadata["service_radar"]["agent_id"] == "agent-k8s-cp3-worker1"

      assert row.metadata["service_radar"]["device_uid"] ==
               "sr:9a6211a0-46d9-4986-988d-01e14d886e40"

      assert row.metadata["output_fields"]["serviceradar.device_uid"] ==
               "sr:9a6211a0-46d9-4986-988d-01e14d886e40"

      assert row.device[:uid] == "sr:9a6211a0-46d9-4986-988d-01e14d886e40"
      assert row.device[:hostname] == "k8s-cp3-worker1"
    end

    test "uses normalized body when Zen-compacted payload omits output" do
      payload = %{
        "body" => "Compacted Falco event",
        "priority" => "Critical",
        "rule" => "Compacted Falco Rule",
        "time" => "2026-03-03T05:56:49.684779242Z"
      }

      message = %{data: Jason.encode!(payload), metadata: %{subject: "falco.logs"}}

      row = FalcoEvents.parse_message(message)

      assert row.message == "Compacted Falco event"
      assert row.unmapped["body"] == "Compacted Falco event"
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
