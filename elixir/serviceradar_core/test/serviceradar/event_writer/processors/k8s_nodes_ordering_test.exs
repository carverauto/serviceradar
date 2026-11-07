defmodule ServiceRadar.EventWriter.Processors.K8sNodesOrderingTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Events.InternalLogPublisher
  alias ServiceRadar.EventWriter.Processors.K8sNodes
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

  test "readiness transition NATS publish fires once after commit and never on rollback", %{
    cluster: cluster
  } do
    test_pid = self()

    on_exit(fn ->
      Process.delete({InternalLogPublisher, :durable_publish})
      Process.delete({InternalLogPublisher, :publisher})
    end)

    Process.put({InternalLogPublisher, :publisher}, {__MODULE__, :publish_live_log, [test_pid]})

    assert {:ok, 2} =
             apply_nodes(cluster, 1, [node_payload(true), node_payload(true, "node2.example.com")])

    Process.put({InternalLogPublisher, :durable_publish}, fn subject, json, _opts ->
      {:ok, decoded} = Jason.decode(json)
      send(test_pid, {:durable_k8s_log, subject, decoded["attributes"]["k8s.node.name"]})
      refute_received {:live_k8s_log, _subject, _node_name, _in_tx?}

      if decoded["attributes"]["k8s.node.name"] == "node2.example.com" do
        {:error, :injected_rollback}
      else
        :ok
      end
    end)

    assert {:error, :batch_failed} =
             apply_nodes(cluster, 2, [
               node_payload(false),
               node_payload(false, "node2.example.com")
             ])

    assert_received {:durable_k8s_log, "logs.internal.k8s", "node1.example.com"}
    assert_received {:durable_k8s_log, "logs.internal.k8s", "node2.example.com"}
    refute_received {:live_k8s_log, _subject, _node_name, _in_tx?}

    assert %{rows: [["node1.example.com", true], ["node2.example.com", true]]} =
             Repo.query!(
               "SELECT name, ready FROM platform.k8s_nodes_current WHERE cluster_id = $1 ORDER BY name",
               [cluster]
             )

    Process.put({InternalLogPublisher, :durable_publish}, fn subject, json, _opts ->
      {:ok, decoded} = Jason.decode(json)
      send(test_pid, {:durable_k8s_log, subject, decoded["attributes"]["k8s.node.name"]})
      refute_received {:live_k8s_log, _subject, _node_name, _in_tx?}
      :ok
    end)

    assert {:ok, 2} =
             apply_nodes(cluster, 2, [
               node_payload(false),
               node_payload(false, "node2.example.com")
             ])

    assert_received {:durable_k8s_log, "logs.internal.k8s", "node1.example.com"}
    assert_received {:durable_k8s_log, "logs.internal.k8s", "node2.example.com"}
    assert_received {:live_k8s_log, "live.logs.internal.k8s", "node1.example.com", false}
    assert_received {:live_k8s_log, "live.logs.internal.k8s", "node2.example.com", false}
    refute_received {:live_k8s_log, _subject, _node_name, _in_tx?}
  end

  def publish_live_log(subject, json, pid) do
    {:ok, decoded} = Jason.decode(json)

    send(
      pid,
      {:live_k8s_log, subject, decoded["attributes"]["k8s.node.name"], Repo.in_transaction?()}
    )

    :ok
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
