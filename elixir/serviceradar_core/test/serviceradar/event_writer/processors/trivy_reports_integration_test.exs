defmodule ServiceRadar.EventWriter.Processors.TrivyReportsIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadar.EventWriter.Processors.TrivyReports
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  @scan_activity_flag :trivy_scan_activity_events

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    original = Application.get_env(:serviceradar_core, @scan_activity_flag)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:serviceradar_core, @scan_activity_flag)
        value -> Application.put_env(:serviceradar_core, @scan_activity_flag, value)
      end
    end)

    # Default: routine scan-completed status events are suppressed.
    Application.delete_env(:serviceradar_core, @scan_activity_flag)
    :ok
  end

  test "persists actionable child vulnerability findings and dedupes report replays" do
    event_uuid = Ash.UUID.generate()
    event_uuid_bin = Ecto.UUID.dump!(event_uuid)
    message = trivy_message(event_uuid, "1.24.8")

    with_stateful_rule_loading_disabled(fn ->
      assert {:ok, 1} = TrivyReports.process_batch([message])
      assert {:ok, _count} = TrivyReports.process_batch([trivy_message(event_uuid, "1.24.12")])
    end)

    assert %{rows: [[report_count]]} =
             SQL.query!(
               Repo,
               "SELECT COUNT(*) FROM platform.trivy_reports WHERE event_uuid = $1::uuid",
               [event_uuid_bin]
             )

    assert report_count == 1

    assert %{rows: [[finding_count]]} =
             SQL.query!(
               Repo,
               "SELECT COUNT(*) FROM platform.trivy_findings WHERE event_uuid = $1::uuid",
               [event_uuid_bin]
             )

    assert finding_count == 1

    assert %{rows: [finding]} =
             SQL.query!(
               Repo,
               """
               SELECT
                 finding_id,
                 log_uuid::text,
                 title,
                 severity_text,
                 severity_id,
                 agent_id,
                 device_uid,
                 resource_kind,
                 resource_namespace,
                 pod_namespace,
                 pod_uid,
                 host_ip,
                 node_name,
                 container_name,
                 owner_kind,
                 owner_name,
                 owner_uid,
                 image_repository,
                 image_tag,
                 image_digest,
                 package_name,
                 package_purl,
                 installed_version,
                 fixed_version,
                 target,
                 namespace,
                 resource_name,
                 "references",
                 raw_finding
               FROM platform.trivy_findings
               WHERE event_uuid = $1::uuid
               """,
               [event_uuid_bin]
             )

    assert [
             "CVE-2026-27142",
             log_uuid,
             "html/template: URLs in meta content attribute actions are not escaped",
             "MEDIUM",
             3,
             "agent-k8s-cp3-worker1",
             "sr:trivy-node-1",
             "ReplicaSet",
             "sealed-secrets",
             "sealed-secrets",
             "pod-uid-1",
             "10.0.2.11",
             "agent-k8s-cp3-worker1",
             "controller",
             "ReplicaSet",
             "sealed-secrets-54d6d7dc89",
             "303d4c99-6b82-4d72-b5af-81fa5f8cead2",
             "bitnami/sealed-secrets-controller",
             "0.32.2",
             "sha256:abc123",
             "stdlib",
             "pkg:golang/stdlib@v1.24.6",
             "v1.24.6",
             "1.24.12",
             "bitnami/sealed-secrets-controller:0.32.2",
             "sealed-secrets",
             "sealed-secrets-54d6d7dc89",
             ["https://avd.aquasec.com/nvd/cve-2026-27142"],
             raw_finding
           ] = finding

    assert Ecto.UUID.cast(log_uuid) != :error
    assert raw_finding["vulnerabilityID"] == "CVE-2026-27142"
    assert raw_finding["fixedVersion"] == "1.24.12"
  end

  test "a routine scan-completed report writes no ocsf event by default, findings still persist" do
    event_uuid = Ash.UUID.generate()
    event_uuid_bin = Ecto.UUID.dump!(event_uuid)
    # The base fixture is a MEDIUM-only report: it is not promoted to a finding
    # event, and the scan-completed status event is suppressed by default.
    message = trivy_message(event_uuid, "1.24.8")

    with_stateful_rule_loading_disabled(fn ->
      assert {:ok, 1} = TrivyReports.process_batch([message])
    end)

    # No OCSF event of any kind for this routine scan.
    assert trivy_event_count(event_uuid) == 0

    # But the finding is still fully persisted — the actionable signal is preserved.
    assert %{rows: [[finding_count]]} =
             SQL.query!(
               Repo,
               "SELECT COUNT(*) FROM platform.trivy_findings WHERE event_uuid = $1::uuid",
               [event_uuid_bin]
             )

    assert finding_count == 1
  end

  test "a report with an actionable finding still emits its finding event by default" do
    event_uuid = Ash.UUID.generate()
    message = trivy_high_message(event_uuid)

    with_stateful_rule_loading_disabled(fn ->
      assert {:ok, 1} = TrivyReports.process_batch([message])
    end)

    # The actionable HIGH finding is still promoted into ocsf_events...
    assert trivy_event_count(event_uuid, "trivy_priority_auto") == 1
    # ...while the routine scan-completed status event stays suppressed.
    assert trivy_event_count(event_uuid, "trivy_scan_activity") == 0
  end

  test "enabling :trivy_scan_activity_events re-emits the scan-completed status event" do
    Application.put_env(:serviceradar_core, @scan_activity_flag, true)
    event_uuid = Ash.UUID.generate()
    message = trivy_message(event_uuid, "1.24.8")

    with_stateful_rule_loading_disabled(fn ->
      assert {:ok, 1} = TrivyReports.process_batch([message])
    end)

    assert trivy_event_count(event_uuid, "trivy_scan_activity") == 1
  end

  defp trivy_event_count(event_id) do
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        "SELECT COUNT(*) FROM platform.ocsf_events WHERE metadata->>'event_id' = $1",
        [event_id]
      )

    count
  end

  defp trivy_event_count(event_id, promotion) do
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        """
        SELECT COUNT(*)
        FROM platform.ocsf_events
        WHERE metadata->>'event_id' = $1
          AND metadata->'service_radar'->>'promotion' = $2
        """,
        [event_id, promotion]
      )

    count
  end

  defp trivy_high_message(event_uuid) do
    %{
      data:
        Jason.encode!(%{
          "event_id" => event_uuid,
          "report_kind" => "VulnerabilityReport",
          "cluster_id" => "demo",
          "namespace" => "sealed-secrets",
          "name" => "replicaset-sealed-secrets-54d6d7dc89-controller",
          "uid" => "84e7db6e-633d-4bc4-9bf1-165b02a8a251",
          "resource_version" => "133476401",
          "observed_at" => "2026-06-10T21:01:33.593717Z",
          "owner_ref" => %{
            "kind" => "ReplicaSet",
            "name" => "sealed-secrets-54d6d7dc89",
            "uid" => "303d4c99-6b82-4d72-b5af-81fa5f8cead2"
          },
          "correlation" => %{
            "resource_kind" => "ReplicaSet",
            "resource_name" => "sealed-secrets-54d6d7dc89",
            "resource_namespace" => "sealed-secrets",
            "pod_ip" => "10.42.1.25",
            "host_ip" => "10.0.2.11",
            "device_uid" => "sr:trivy-node-1",
            "node_name" => "agent-k8s-cp3-worker1"
          },
          "summary" => %{
            "criticalCount" => 0,
            "highCount" => 1,
            "mediumCount" => 0,
            "lowCount" => 0
          },
          "report" => %{
            "report" => %{
              "artifact" => %{
                "repository" => "bitnami/sealed-secrets-controller",
                "tag" => "0.32.2",
                "digest" => "sha256:abc123"
              },
              "scanner" => %{"name" => "Trivy", "version" => "0.69.1"},
              "summary" => %{"highCount" => 1},
              "vulnerabilities" => [
                %{
                  "fixedVersion" => "1.24.12",
                  "installedVersion" => "v1.24.6",
                  "severity" => "HIGH",
                  "title" => "example high severity vulnerability",
                  "vulnerabilityID" => "CVE-2026-99999",
                  "pkgName" => "stdlib"
                }
              ]
            }
          }
        }),
      metadata: %{subject: "trivy.report.vulnerability", received_at: DateTime.utc_now()}
    }
  end

  defp with_stateful_rule_loading_disabled(fun) do
    previous = Application.get_env(:serviceradar_core, :repo_enabled, true)

    # This test is about Trivy report/finding persistence. Stateful alert rule
    # loading is exercised elsewhere and can dominate fixture DB runtime.
    Application.put_env(:serviceradar_core, :repo_enabled, false)

    try do
      fun.()
    after
      Application.put_env(:serviceradar_core, :repo_enabled, previous)
    end
  end

  defp trivy_message(event_uuid, fixed_version) do
    %{
      data:
        Jason.encode!(%{
          "event_id" => event_uuid,
          "report_kind" => "VulnerabilityReport",
          "cluster_id" => "demo",
          "namespace" => "sealed-secrets",
          "name" => "replicaset-sealed-secrets-54d6d7dc89-controller",
          "uid" => "84e7db6e-633d-4bc4-9bf1-165b02a8a250",
          "resource_version" => "133476400",
          "observed_at" => "2026-06-10T21:01:33.593717Z",
          "owner_ref" => %{
            "kind" => "ReplicaSet",
            "name" => "sealed-secrets-54d6d7dc89",
            "uid" => "303d4c99-6b82-4d72-b5af-81fa5f8cead2"
          },
          "correlation" => %{
            "container_name" => "controller",
            "owner_kind" => "ReplicaSet",
            "owner_name" => "sealed-secrets-54d6d7dc89",
            "owner_uid" => "303d4c99-6b82-4d72-b5af-81fa5f8cead2",
            "resource_kind" => "ReplicaSet",
            "resource_name" => "sealed-secrets-54d6d7dc89",
            "resource_namespace" => "sealed-secrets",
            "pod_name" => "sealed-secrets-54d6d7dc89-abcde",
            "pod_namespace" => "sealed-secrets",
            "pod_uid" => "pod-uid-1",
            "pod_ip" => "10.42.1.25",
            "host_ip" => "10.0.2.11",
            "device_uid" => "sr:trivy-node-1",
            "node_name" => "agent-k8s-cp3-worker1"
          },
          "summary" => %{
            "criticalCount" => 0,
            "highCount" => 0,
            "mediumCount" => 1,
            "lowCount" => 0
          },
          "report" => %{
            "metadata" => %{
              "creationTimestamp" => "2026-03-20T16:49:51Z",
              "labels" => %{
                "trivy-operator.container.name" => "controller",
                "trivy-operator.resource.kind" => "ReplicaSet",
                "trivy-operator.resource.name" => "sealed-secrets-54d6d7dc89",
                "trivy-operator.resource.namespace" => "sealed-secrets"
              }
            },
            "report" => %{
              "artifact" => %{
                "repository" => "bitnami/sealed-secrets-controller",
                "tag" => "0.32.2",
                "digest" => "sha256:abc123"
              },
              "scanner" => %{"name" => "Trivy", "version" => "0.69.1"},
              "summary" => %{"mediumCount" => 1},
              "vulnerabilities" => [
                %{
                  "fixedVersion" => fixed_version,
                  "installedVersion" => "v1.24.6",
                  "links" => ["https://avd.aquasec.com/nvd/cve-2026-27142"],
                  "severity" => "MEDIUM",
                  "title" =>
                    "html/template: URLs in meta content attribute actions are not escaped",
                  "vulnerabilityID" => "CVE-2026-27142",
                  "pkgName" => "stdlib",
                  "pkgIdentifier" => %{
                    "PURL" => "pkg:golang/stdlib@v1.24.6"
                  }
                }
              ]
            }
          }
        }),
      metadata: %{subject: "trivy.report.vulnerability", received_at: DateTime.utc_now()}
    }
  end
end
