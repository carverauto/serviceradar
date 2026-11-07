defmodule ServiceRadar.EventWriter.Processors.K8sNodesOrderingTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.EventWriter.Processors.K8sNodes
  alias ServiceRadar.NATS.DurablePublishWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    %{cluster: "cluster-#{Ash.UUID.generate()}"}
  end

  test "late NotReady snapshots cannot overwrite Ready or delete newer nodes", %{cluster: cluster} do
    assert {:ok, 1} = apply_nodes(cluster, 1, [node_payload(true)])

    assert {:ok, 2} =
             apply_nodes(cluster, 3, [node_payload(true), node_payload(true, "node2.example.com")])

    assert {:ok, 0} = apply_nodes(cluster, 2, [node_payload(false)])
    assert {:ok, 0} = apply_nodes(cluster, 3, [node_payload(false)])

    assert %{rows: [["node1.example.com", true, nil], ["node2.example.com", true, nil]]} =
             Repo.query!(
               "SELECT name, ready, deleted_at FROM platform.k8s_nodes_current WHERE cluster_id = $1 ORDER BY name",
               [cluster]
             )
  end

  test "empty snapshots retain ordering even before the first node", %{cluster: cluster} do
    assert {:ok, 0} = apply_nodes(cluster, 3, [])
    assert {:ok, 0} = apply_nodes(cluster, 2, [node_payload(false)])

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM platform.k8s_nodes_current WHERE cluster_id = $1",
               [cluster]
             )
  end

  test "late snapshots cannot revive deleted nodes", %{cluster: cluster} do
    assert {:ok, 1} = apply_nodes(cluster, 1, [node_payload(true)])
    assert {:ok, 0} = apply_nodes(cluster, 3, [])
    assert {:ok, 0} = apply_nodes(cluster, 2, [node_payload(false)])

    assert %{rows: [[true, deleted_at]]} =
             Repo.query!(
               "SELECT ready, deleted_at FROM platform.k8s_nodes_current WHERE cluster_id = $1",
               [cluster]
             )

    assert deleted_at == ~U[2026-09-05 12:00:00.000003Z]
    assert {:ok, 1} = apply_nodes(cluster, 4, [node_payload(true)])
  end

  test "readiness transitions are queued for JetStream with the snapshot and dropped with its rollback",
       %{cluster: cluster} do
    assert {:ok, 2} =
             apply_nodes(cluster, 1, [node_payload(true), node_payload(true, "node2.example.com")])

    baseline = readiness_job_ids(cluster)

    assert {:error, :rolled_back} =
             Repo.transaction(fn ->
               assert {:ok, 2} =
                        apply_nodes(cluster, 2, [
                          node_payload(false),
                          node_payload(false, "node2.example.com")
                        ])

               assert length(readiness_job_ids(cluster) -- baseline) == 2
               Repo.rollback(:rolled_back)
             end)

    assert readiness_job_ids(cluster) == baseline

    assert %{rows: [["node1.example.com", true], ["node2.example.com", true]]} =
             Repo.query!(
               "SELECT name, ready FROM platform.k8s_nodes_current WHERE cluster_id = $1 ORDER BY name",
               [cluster]
             )

    assert {:ok, 2} =
             apply_nodes(cluster, 2, [
               node_payload(false),
               node_payload(false, "node2.example.com")
             ])

    assert ["node1.example.com", "node2.example.com"] =
             cluster
             |> readiness_jobs()
             |> Enum.reject(&(&1.id in baseline))
             |> Enum.map(& &1.node)
             |> Enum.sort()

    assert {:ok, 0} = apply_nodes(cluster, 1, [node_payload(true)])
    assert length(readiness_job_ids(cluster) -- baseline) == 2
  end

  defp readiness_job_ids(cluster), do: cluster |> readiness_jobs() |> Enum.map(& &1.id)

  defp readiness_jobs(cluster) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT id, args->>'body'
        FROM platform.oban_jobs
        WHERE worker = $1 AND args->>'subject' = $2
        ORDER BY id
        """,
        [inspect(DurablePublishWorker), "logs.internal.k8s"]
      )

    Enum.flat_map(rows, fn [id, body] ->
      attributes = Jason.decode!(body)["attributes"]

      if attributes["cluster_id"] == cluster do
        [%{id: id, node: attributes["node"]}]
      else
        []
      end
    end)
  end

  defp node_payload(ready, name \\ "node1.example.com"), do: %{"name" => name, "ready" => ready}

  defp apply_nodes(cluster, offset, nodes) do
    K8sNodes.process_batch([
      %{
        data: %{
          "cluster_id" => cluster,
          "generated_at" => DateTime.add(~U[2026-09-05 12:00:00.000000Z], offset, :microsecond),
          "nodes" => nodes
        }
      }
    ])
  end
end
