defmodule ServiceRadar.WorkloadIdentityTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport
  alias ServiceRadar.WorkloadIdentity

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    partition = "workload-identity-test-#{System.unique_integer([:positive])}"
    agent_id = "agent-#{partition}"

    on_exit(fn ->
      Repo.query!(
        "DELETE FROM platform.workload_identity_current WHERE partition = $1",
        [partition]
      )

      Repo.query!(
        "DELETE FROM platform.flow_process_attribution_current WHERE partition = $1",
        [partition]
      )
    end)

    %{partition: partition, agent_id: agent_id}
  end

  test "persists forwarded workload identity snapshots", %{
    partition: partition,
    agent_id: agent_id
  } do
    container_id = "container-#{System.unique_integer([:positive])}"

    snapshot =
      Jason.encode!(%{
        "observed_at_unix_nano" => System.system_time(:nanosecond),
        "enabled" => true,
        "context_name" => "demo-context",
        "cluster_id" => "cluster-demo-1",
        "cluster_name" => "nil",
        "identities" => [
          %{
            "container_id" => container_id,
            "identity" => %{
              "container_id" => container_id,
              "pod_uid" => "pod-uid-1",
              "pod_namespace" => "demo",
              "pod_name" => "redis-0",
              "container_name" => "redis",
              "image" => "redis:7",
              "runtime_source" => "Containerd",
              "confidence" => "High",
              "labels" => %{"app" => "redis"}
            }
          }
        ]
      })

    assert :ok =
             WorkloadIdentity.persist_snapshot(%{
               message: snapshot,
               partition: partition,
               agent_id: agent_id,
               gateway_id: "gateway-test"
             })

    %{rows: rows} =
      Repo.query!(
        """
        SELECT agent_id, container_id, pod_namespace, pod_name, container_name, image, identity
        FROM platform.workload_identity_current
        WHERE partition = $1 AND agent_id = $2 AND container_id = $3
        """,
        [partition, agent_id, container_id]
      )

    assert [
             [
               ^agent_id,
               ^container_id,
               "demo",
               "redis-0",
               "redis",
               "redis:7",
               %{
                 "context_name" => "demo-context",
                 "labels" => %{"app" => "redis"}
               }
             ]
           ] = rows
  end

  test "backfills matching flow attribution rows after snapshot ingest", %{
    partition: partition,
    agent_id: agent_id
  } do
    container_id = "container-#{System.unique_integer([:positive])}"

    Repo.query!(
      """
      INSERT INTO platform.flow_process_attribution_current (
        observed_at,
        partition,
        attribution_key,
        agent_id,
        proto,
        local_ip,
        local_port,
        remote_ip,
        remote_port,
        pid,
        comm,
        container_id
      )
      VALUES (
        now(),
        $1,
        md5($1 || $2 || $3),
        $2,
        6,
        '10.0.2.11',
        179,
        '192.168.10.96',
        34491,
        45246,
        'gobgpd',
        $3
      )
      """,
      [partition, agent_id, container_id]
    )

    snapshot =
      Jason.encode!(%{
        "observed_at_unix_nano" => System.system_time(:nanosecond),
        "enabled" => true,
        "identities" => [
          %{
            "container_id" => container_id,
            "identity" => %{
              "container_id" => container_id,
              "pod_uid" => "pod-uid-2",
              "pod_namespace" => "demo",
              "pod_name" => "gobgp-0",
              "container_name" => "gobgpd",
              "image" => "gobgp:latest",
              "runtime_source" => "Containerd",
              "confidence" => "High"
            }
          }
        ]
      })

    assert :ok =
             WorkloadIdentity.persist_snapshot(%{
               message: snapshot,
               partition: partition,
               agent_id: agent_id,
               gateway_id: "gateway-test"
             })

    %{rows: [[workload]]} =
      Repo.query!(
        """
        SELECT workload_identity
        FROM platform.flow_process_attribution_current
        WHERE partition = $1 AND agent_id = $2 AND container_id = $3
        """,
        [partition, agent_id, container_id]
      )

    assert workload["pod_namespace"] == "demo"
    assert workload["pod_name"] == "gobgp-0"
    assert workload["container_name"] == "gobgpd"
  end
end
