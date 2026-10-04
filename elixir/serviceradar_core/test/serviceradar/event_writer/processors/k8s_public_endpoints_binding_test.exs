defmodule ServiceRadar.EventWriter.Processors.K8sPublicEndpointsBindingTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.EventWriter.Processors.K8sPublicEndpoints
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    suffix = Ash.UUID.generate()
    agent_a = "agent-example-a-#{suffix}"
    agent_b = "agent-example-b-#{suffix}"
    cluster = "cluster-example-#{suffix}"

    Enum.each([agent_a, agent_b], fn agent_id ->
      Repo.query!("INSERT INTO platform.ocsf_agents (uid) VALUES ($1)", [agent_id])
    end)

    Repo.query!(
      """
      INSERT INTO platform.k8s_inventory_cluster_bindings
        (cluster_id, agent_id, partition_id, changed_by, inserted_at, updated_at)
      VALUES ($1, $2, 'SITE01', 'test-operator', now(), now())
      """,
      [cluster, agent_a]
    )

    %{cluster: cluster, agent_a: agent_a, agent_b: agent_b}
  end

  test "only the bound authenticated agent can mutate a cluster", context do
    agent_a = context.agent_a

    assert {:ok, 1} = process(context.cluster, context.agent_a, 1)

    assert {:error, :k8s_inventory_cluster_binding_mismatch} =
             process(context.cluster, context.agent_b, 2, [endpoint("service-replacement")])

    assert %{rows: [[1]]} = endpoint_count(context.cluster)
    assert %{rows: [["service-example"]]} = active_services(context.cluster)

    assert {:error, :k8s_inventory_cluster_binding_mismatch} =
             process(context.cluster, context.agent_b, 3, [])

    assert %{rows: [[1]]} = endpoint_count(context.cluster)

    assert %{rows: [[^agent_a, "SITE01"]]} =
             Repo.query!(
               "SELECT agent_id, partition_id FROM platform.k8s_public_endpoint_snapshots WHERE cluster_id = $1",
               [context.cluster]
             )
  end

  test "an unbound cluster cannot be mutated by an authenticated agent", context do
    unbound_cluster = "cluster-unbound-#{Ash.UUID.generate()}"

    assert {:error, :k8s_inventory_cluster_binding_mismatch} =
             process(unbound_cluster, context.agent_a, 1)

    assert %{rows: [[0]]} = endpoint_count(unbound_cluster)
  end

  test "a nested foreign cluster id rejects the whole snapshot", context do
    foreign_cluster = "cluster-foreign-#{Ash.UUID.generate()}"

    assert {:ok, 1} = process(context.cluster, context.agent_a, 1)

    assert {:ok, 0} =
             process(context.cluster, context.agent_a, 2, [
               endpoint("service-replacement", foreign_cluster)
             ])

    assert %{rows: [[1]]} = endpoint_count(context.cluster)
    assert %{rows: [["service-example"]]} = active_services(context.cluster)
    assert %{rows: [[0]]} = endpoint_count(foreign_cluster)
  end

  test "ownership transfer revokes the previous agent atomically", context do
    assert {:ok, 1} = process(context.cluster, context.agent_a, 1)

    Repo.query!(
      "UPDATE platform.k8s_inventory_cluster_bindings SET agent_id = $2, updated_at = now() WHERE cluster_id = $1",
      [context.cluster, context.agent_b]
    )

    assert {:error, :k8s_inventory_cluster_binding_mismatch} =
             process(context.cluster, context.agent_a, 2)

    assert {:ok, 1} = process(context.cluster, context.agent_b, 3)
  end

  defp process(cluster, agent_id, offset, endpoints \\ [endpoint("service-example")]) do
    K8sPublicEndpoints.process_batch([
      %{
        data: %{
          "cluster_id" => cluster,
          "generated_at" => DateTime.add(~U[2026-10-04 12:00:00Z], offset, :second),
          "endpoints" => endpoints
        },
        metadata: %{
          headers: [
            {"Sr-Ingest-Identity", "agent:#{agent_id}"},
            {"Sr-Agent-Id", agent_id},
            {"Sr-Partition", "SITE01"}
          ]
        }
      }
    ])
  end

  defp endpoint(service_name, cluster_id \\ nil) do
    %{
      "ip" => "192.0.2.10",
      "port" => 443,
      "protocol" => "TCP",
      "namespace" => "namespace-example",
      "service_name" => service_name,
      "cluster_id" => cluster_id
    }
  end

  defp endpoint_count(cluster) do
    Repo.query!(
      "SELECT count(*) FROM platform.public_endpoints_current WHERE cluster_id = $1 AND deleted_at IS NULL",
      [cluster]
    )
  end

  defp active_services(cluster) do
    Repo.query!(
      "SELECT service_name FROM platform.public_endpoints_current WHERE cluster_id = $1 AND deleted_at IS NULL ORDER BY service_name",
      [cluster]
    )
  end
end
