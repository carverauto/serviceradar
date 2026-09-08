defmodule ServiceRadar.EventWriter.Processors.TrivyReportsTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.EventWriter.Pipeline
  alias ServiceRadar.EventWriter.Processors.TrivyReports

  describe "table_name/0" do
    test "returns logs table" do
      assert TrivyReports.table_name() == "logs"
    end
  end

  describe "promotion thresholds" do
    test "promotes high and above to events" do
      assert TrivyReports.promote_to_event?(4)
      assert TrivyReports.promote_to_event?(5)
      assert TrivyReports.promote_to_event?(6)
      refute TrivyReports.promote_to_event?(3)
    end

    test "promotes critical and fatal to alerts" do
      assert TrivyReports.promote_to_alert?(5)
      assert TrivyReports.promote_to_alert?(6)
      refute TrivyReports.promote_to_alert?(4)
    end
  end

  describe "parse_message/1" do
    test "maps summary severity and correlation into OCSF event row" do
      payload = %{
        "event_id" => "8aa6cadf-7244-49ff-ac99-7108e2921423",
        "report_kind" => "VulnerabilityReport",
        "cluster_id" => "demo-cluster",
        "namespace" => "demo",
        "name" => "nginx-123",
        "uid" => "uid-1",
        "resource_version" => "88",
        "observed_at" => "2026-03-03T18:40:00Z",
        "summary" => %{"criticalCount" => 1, "highCount" => 2},
        "correlation" => %{
          "resource_kind" => "Pod",
          "resource_name" => "nginx-123",
          "resource_namespace" => "demo",
          "pod_name" => "nginx-123",
          "pod_namespace" => "demo",
          "pod_uid" => "pod-uid-1",
          "pod_ip" => "10.42.0.25",
          "node_name" => "worker-1",
          "container_name" => "nginx"
        },
        "owner_ref" => %{"kind" => "ReplicaSet", "name" => "nginx-rs"},
        "report" => %{
          "metadata" => %{
            "labels" => %{
              "trivy-operator.resource.kind" => "Pod",
              "trivy-operator.resource.name" => "nginx-123",
              "trivy-operator.resource.namespace" => "demo"
            }
          },
          "report" => %{
            "scanner" => %{"name" => "Trivy", "version" => "0.60.0"},
            "summary" => %{"criticalCount" => 1, "highCount" => 2}
          }
        }
      }

      message = %{
        data: Jason.encode!(payload),
        metadata: %{subject: "trivy.report.vulnerability"}
      }

      row = TrivyReports.parse_message(message)

      assert is_binary(row.id)
      assert byte_size(row.id) == 16
      assert row.class_uid == 2002
      assert row.category_uid == 2
      assert row.activity_id == 1
      assert row.type_uid == 200_201
      assert row.activity_name == "Create"
      assert row.severity_id == 5
      assert row.severity == "Critical"
      assert row.status_id == 2
      assert row.status == "Failure"
      assert row.log_provider == "trivy"
      assert row.log_name == "trivy.report.vulnerability"
      assert row.metadata["report_kind"] == "VulnerabilityReport"
      assert row.metadata["version"] == "1.9.0-dev"
      assert row.metadata["product"]["name"] == "Trivy"
      assert row.metadata["resource"] == "Pod/demo/nginx-123"
      assert row.metadata["finding_info"]["uid"] == "8aa6cadf-7244-49ff-ac99-7108e2921423"
      assert row.metadata["finding_info"]["group_uid"] == row.metadata["finding_info"]["uid"]
      assert row.metadata["finding_info"]["title"] == row.message
      assert row.metadata["finding_info"]["source"] == "trivy"
      assert row.metadata["finding_info"]["dimensions"]["resource_kind"] == "Pod"
      assert row.metadata["finding_info"]["dimensions"]["resource_name"] == "nginx-123"
      assert row.metadata["security_signal"]["finding_uid"] == row.metadata["finding_info"]["uid"]
      assert row.metadata["service_radar"]["source_type"] == "trivy"
      assert row.metadata["service_radar"]["finding_uid"] == row.metadata["finding_info"]["uid"]
      assert row.metadata["service_radar"]["device_hostname"] == "worker-1"
      assert row.metadata["service_radar"]["pod_uid"] == "pod-uid-1"
      assert row.src_endpoint[:ip] == "10.42.0.25"
      assert row.device[:uid] == "worker-1"
      assert row.device[:name] == "worker-1"
      assert row.device[:hostname] == "worker-1"
      assert row.unmapped["cluster_id"] == "demo-cluster"
      assert %DateTime{} = row.time
    end

    test "preserves explicit canonical device uid from correlation metadata" do
      payload = %{
        "event_id" => "9aa6cadf-7244-49ff-ac99-7108e2921423",
        "report_kind" => "VulnerabilityReport",
        "cluster_id" => "demo-cluster",
        "namespace" => "demo",
        "name" => "nginx-123",
        "uid" => "uid-2",
        "observed_at" => "2026-03-03T18:40:00Z",
        "summary" => %{"highCount" => 1},
        "correlation" => %{
          "agent_id" => "agent-k8s-cp3-worker1",
          "device_uid" => "sr:7cf3224f-273e-4ef3-94b2-53145589a3bc",
          "resource_kind" => "Pod",
          "resource_name" => "nginx-123",
          "resource_namespace" => "demo",
          "pod_name" => "nginx-123",
          "pod_namespace" => "demo",
          "pod_uid" => "pod-uid-2",
          "pod_ip" => "10.42.0.25",
          "node_name" => "worker-1",
          "container_name" => "nginx"
        },
        "report" => %{
          "report" => %{
            "scanner" => %{"name" => "Trivy", "version" => "0.60.0"},
            "summary" => %{"highCount" => 1}
          }
        }
      }

      message = %{
        data: Jason.encode!(payload),
        metadata: %{subject: "trivy.report.vulnerability"}
      }

      row = TrivyReports.parse_message(message)

      assert row.metadata["service_radar"]["device_uid"] ==
               "sr:7cf3224f-273e-4ef3-94b2-53145589a3bc"

      assert row.metadata["service_radar"]["device_hostname"] == "worker-1"
      assert row.metadata["service_radar"]["agent_id"] == "agent-k8s-cp3-worker1"
      assert row.device[:uid] == "sr:7cf3224f-273e-4ef3-94b2-53145589a3bc"
      assert row.device[:hostname] == "worker-1"
    end

    test "does not treat unknown Kubernetes resource uid as canonical device uid" do
      payload = %{
        "event_id" => "4aa6cadf-7244-49ff-ac99-7108e2921423",
        "report_kind" => "VulnerabilityReport",
        "cluster_id" => "demo-cluster",
        "namespace" => "demo",
        "name" => "nginx-123",
        "uid" => "trivy-report-uid",
        "observed_at" => "2026-03-03T18:40:00Z",
        "summary" => %{"highCount" => 1},
        "correlation" => %{
          "device_uid" => "kubernetes-resource-uid",
          "resource_kind" => "ReplicaSet",
          "resource_name" => "nginx-rs",
          "resource_namespace" => "demo",
          "node_name" => "worker-1"
        },
        "report" => %{
          "report" => %{
            "scanner" => %{"name" => "Trivy", "version" => "0.60.0"},
            "summary" => %{"highCount" => 1}
          }
        }
      }

      message = %{
        data: Jason.encode!(payload),
        metadata: %{subject: "trivy.report.vulnerability"}
      }

      row = TrivyReports.parse_message(message)

      assert row.metadata["service_radar"]["device_hostname"] == "worker-1"
      assert row.device[:uid] == "worker-1"
      assert row.device[:hostname] == "worker-1"
      refute row.metadata["service_radar"]["device_uid"] == "kubernetes-resource-uid"
    end

    test "emits scan activity separately from finding outcomes" do
      payload = %{
        "event_id" => "7aa6cadf-7244-49ff-ac99-7108e2921423",
        "report_kind" => "VulnerabilityReport",
        "cluster_id" => "demo-cluster",
        "namespace" => "demo",
        "name" => "nginx-123",
        "uid" => "uid-3",
        "observed_at" => "2026-03-03T18:40:00Z",
        "summary" => %{"criticalCount" => 1},
        "correlation" => %{
          "agent_id" => "agent-k8s-cp3-worker1",
          "device_uid" => "sr:7cf3224f-273e-4ef3-94b2-53145589a3bc",
          "resource_kind" => "Pod",
          "resource_name" => "nginx-123",
          "resource_namespace" => "demo",
          "pod_name" => "nginx-123",
          "pod_namespace" => "demo",
          "pod_uid" => "pod-uid-3",
          "pod_ip" => "10.42.0.25",
          "node_name" => "worker-1"
        },
        "report" => %{
          "report" => %{
            "scanner" => %{"name" => "Trivy", "version" => "0.60.0"},
            "summary" => %{"criticalCount" => 1}
          }
        }
      }

      message = %{
        data: Jason.encode!(payload),
        metadata: %{subject: "trivy.report.vulnerability"}
      }

      [scan_row, finding_row] = TrivyReports.parse_event_rows(message)

      assert scan_row.class_uid == 6007
      assert scan_row.category_uid == 6
      assert scan_row.activity_id == 2
      assert scan_row.activity_name == "Completed"
      assert scan_row.status == "Success"
      assert scan_row.severity == "Informational"
      assert scan_row.metadata["service_radar"]["source_type"] == "trivy"

      assert scan_row.metadata["service_radar"]["device_uid"] ==
               "sr:7cf3224f-273e-4ef3-94b2-53145589a3bc"

      assert scan_row.metadata["service_radar"]["ocsf_class"] == "scan_activity"
      assert scan_row.device[:uid] == "sr:7cf3224f-273e-4ef3-94b2-53145589a3bc"

      assert finding_row.class_uid == 2002
      assert finding_row.category_uid == 2
      assert finding_row.status == "Failure"
    end
  end

  describe "pipeline routing" do
    test "routes trivy subjects to trivy batcher" do
      event = %{
        data:
          Jason.encode!(%{
            "report_kind" => "VulnerabilityReport",
            "summary" => %{"highCount" => 1}
          }),
        metadata: %{subject: "trivy.report.vulnerability"},
        ack_data: %{}
      }

      message = Pipeline.transform(event, [])
      routed = Pipeline.handle_message(:default, message, %{})

      assert routed.batcher == :trivy
    end
  end
end
