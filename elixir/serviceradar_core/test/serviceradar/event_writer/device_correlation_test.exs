defmodule ServiceRadar.EventWriter.DeviceCorrelationTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.DeviceCorrelation
  alias ServiceRadar.EventWriter.Processors.FalcoEvents
  alias ServiceRadar.EventWriter.Processors.TrivyReports
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    unique = System.unique_integer([:positive])
    actor = SystemActor.system(:event_writer_device_correlation_test)
    partition = "device-correlation-test-#{unique}"
    device = create_device!(actor, "sr:security-correlation-device-#{unique}")
    agent_id = "agent-security-correlation-#{unique}"
    create_agent!(actor, agent_id, device.uid)

    %{actor: actor, partition: partition, device: device, agent_id: agent_id, unique: unique}
  end

  test "resolves pod UID through workload identity to the reporting agent device", %{
    partition: partition,
    device: device,
    agent_id: agent_id,
    unique: unique
  } do
    pod_uid = "pod-uid-#{unique}"

    insert_workload_identity!(partition,
      agent_id: agent_id,
      container_id: "container-#{unique}",
      pod_uid: pod_uid,
      pod_namespace: "demo",
      pod_name: "api-#{unique}"
    )

    assert DeviceCorrelation.resolve(%{partition: partition, pod_uid: pod_uid}) == device.uid
  end

  test "Trivy finding normalization uses workload identity when no agent id is present", %{
    partition: partition,
    device: device,
    agent_id: agent_id,
    unique: unique
  } do
    pod_uid = "trivy-pod-uid-#{unique}"
    pod_name = "trivy-api-#{unique}"

    insert_workload_identity!(partition,
      agent_id: agent_id,
      container_id: "trivy-container-#{unique}",
      pod_uid: pod_uid,
      pod_namespace: "demo",
      pod_name: pod_name
    )

    row =
      TrivyReports.parse_message(%{
        data:
          Jason.encode!(%{
            "event_id" => "trivy-event-#{unique}",
            "report_kind" => "VulnerabilityReport",
            "cluster_id" => "demo-cluster",
            "namespace" => "demo",
            "name" => "trivy-report-#{unique}",
            "uid" => "trivy-report-uid-#{unique}",
            "observed_at" => "2026-03-03T18:40:00Z",
            "summary" => %{"highCount" => 1},
            "correlation" => %{
              "partition" => partition,
              "resource_kind" => "Pod",
              "resource_name" => pod_name,
              "resource_namespace" => "demo",
              "pod_name" => pod_name,
              "pod_namespace" => "demo",
              "pod_uid" => pod_uid
            },
            "report" => %{
              "report" => %{
                "scanner" => %{"name" => "Trivy", "version" => "0.60.0"},
                "summary" => %{"highCount" => 1}
              }
            }
          }),
        metadata: %{subject: "trivy.report.vulnerability"}
      })

    assert row.metadata["service_radar"]["device_uid"] == device.uid
    assert row.metadata["service_radar"]["pod_uid"] == pod_uid
    assert row.device[:uid] == device.uid
  end

  test "Falco finding normalization uses workload identity by namespace and pod name", %{
    partition: partition,
    device: device,
    agent_id: agent_id,
    unique: unique
  } do
    pod_name = "falco-api-#{unique}"

    insert_workload_identity!(partition,
      agent_id: agent_id,
      container_id: "falco-container-#{unique}",
      pod_namespace: "demo",
      pod_name: pod_name
    )

    row =
      FalcoEvents.parse_message(%{
        data:
          Jason.encode!(%{
            "output" => "Falco event from workload identity",
            "priority" => "Warning",
            "rule" => "Workload Identity Correlation",
            "time" => "2026-03-03T05:56:49.684779242Z",
            "output_fields" => %{
              "container.id" => "falco-container-#{unique}",
              "k8s.ns.name" => "demo",
              "k8s.pod.name" => pod_name,
              "service_radar.partition" => partition
            }
          }),
        metadata: %{subject: "falco.logs"}
      })

    assert row.metadata["service_radar"]["device_uid"] == device.uid
    assert row.device[:uid] == device.uid
  end

  defp insert_workload_identity!(partition, attrs) do
    Repo.query!(
      """
      INSERT INTO platform.workload_identity_current (
        observed_at,
        inserted_at,
        updated_at,
        partition,
        agent_id,
        gateway_id,
        container_id,
        pod_uid,
        pod_namespace,
        pod_name,
        container_name,
        image,
        runtime_source,
        confidence,
        identity
      )
      VALUES (
        now(),
        now(),
        now(),
        $1,
        $2,
        'gateway-test',
        $3,
        $4,
        $5,
        $6,
        $7,
        'registry.example/app:latest',
        'Containerd',
        'High',
        '{}'::jsonb
      )
      """,
      [
        partition,
        Keyword.fetch!(attrs, :agent_id),
        Keyword.fetch!(attrs, :container_id),
        Keyword.get(attrs, :pod_uid),
        Keyword.get(attrs, :pod_namespace),
        Keyword.get(attrs, :pod_name),
        Keyword.get(attrs, :container_name, "app")
      ]
    )
  end

  defp create_device!(actor, uid) do
    now = DateTime.utc_now()

    Device
    |> Ash.Changeset.for_create(
      :create,
      %{
        uid: uid,
        hostname: "#{uid}.local",
        type_id: 0,
        is_available: true,
        first_seen_time: now,
        last_seen_time: now
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_agent!(actor, agent_id, device_uid) do
    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      %{
        uid: agent_id,
        name: agent_id,
        type_id: 0,
        device_uid: device_uid,
        capabilities: ["trivy", "falco"]
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
