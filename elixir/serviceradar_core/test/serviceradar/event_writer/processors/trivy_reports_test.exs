defmodule ServiceRadar.EventWriter.Processors.TrivyReportsTest do
  use ExUnit.Case, async: true

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
      assert row.severity_id == 5
      assert row.severity == "Critical"
      assert row.status_id == 2
      assert row.status == "Failure"
      assert row.log_provider == "trivy"
      assert row.log_name == "trivy.report.vulnerability"
      assert row.metadata["report_kind"] == "VulnerabilityReport"
      assert row.metadata["resource"] == "Pod/demo/nginx-123"
      assert row.src_endpoint[:ip] == "10.42.0.25"
      assert row.device[:ip] == "10.42.0.25"
      assert row.device[:uid] == "pod-uid-1"
      assert row.unmapped["cluster_id"] == "demo-cluster"
      assert %DateTime{} = row.time
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
