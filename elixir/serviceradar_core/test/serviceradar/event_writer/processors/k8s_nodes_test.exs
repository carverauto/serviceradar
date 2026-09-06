defmodule ServiceRadar.EventWriter.Processors.K8sNodesTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.K8sNodes

  defp message(payload) do
    %{
      data: Jason.encode!(payload),
      metadata: %{subject: "inventory.k8s.nodes"}
    }
  end

  defp worker_previous(ready) do
    %{ready: ready, role: "worker", cluster_id: "cluster-a"}
  end

  defp snapshot(nodes) do
    %{
      "cluster_id" => "cluster-a",
      "generated_at" => "2026-09-05T12:00:00Z",
      "nodes" => nodes
    }
  end

  test "parse_message builds node rows from inventory snapshot" do
    payload =
      snapshot([
        %{
          "name" => "node-worker-1.example.com",
          "uid" => "uid-worker-1",
          "role" => "worker",
          "ready" => true,
          "internal_ip" => "192.0.2.11",
          "observed_at" => "2026-09-05T11:59:00Z"
        },
        %{
          "name" => "node-control-1.example.com",
          "role" => "control-plane",
          "ready" => false,
          "ready_reason" => "KubeletNotReady",
          "internal_ip" => "192.0.2.2"
        }
      ])

    assert %{cluster_id: "cluster-a", snapshot_at: snapshot_at, nodes: rows} =
             K8sNodes.parse_message(message(payload))

    assert snapshot_at == ~U[2026-09-05 12:00:00Z]
    assert length(rows) == 2

    worker = Enum.find(rows, &(&1.name == "node-worker-1.example.com"))
    assert worker.ready
    assert worker.role == "worker"
    assert worker.internal_ip == "192.0.2.11"
    assert worker.observed_at == ~U[2026-09-05 11:59:00Z]
    assert is_binary(worker.node_key)

    control = Enum.find(rows, &(&1.name == "node-control-1.example.com"))
    refute control.ready
    assert control.role == "control-plane"
    assert control.ready_reason == "KubeletNotReady"
  end

  test "parse_message drops a malformed snapshot" do
    assert K8sNodes.parse_message(%{data: "{not-json", metadata: %{}}) == nil
  end

  test "snapshot timestamps retain subsecond ordering and must be present" do
    payload = [] |> snapshot() |> Map.put("generated_at", "2026-09-05T12:00:00.123456Z")

    assert %{snapshot_at: ~U[2026-09-05 12:00:00.123456Z]} =
             K8sNodes.parse_message(message(payload))

    assert nil == K8sNodes.parse_message(message(Map.delete(payload, "generated_at")))
  end

  test "readiness_transitions emits only Ready flips of a persisted node" do
    worker = %{
      name: "node-worker-1.example.com",
      cluster_id: "cluster-a",
      role: "worker",
      ready: false,
      ready_reason: "KubeletNotReady"
    }

    control = %{
      name: "node-control-1.example.com",
      cluster_id: "cluster-a",
      role: "control-plane",
      ready: true,
      ready_reason: "KubeletReady"
    }

    previous = %{
      "node-worker-1.example.com" => %{ready: true, role: "worker", cluster_id: "cluster-a"},
      "node-control-1.example.com" => %{
        ready: true,
        role: "control-plane",
        cluster_id: "cluster-a"
      }
    }

    assert [{:not_ready, ^worker}] =
             K8sNodes.readiness_transitions(previous, [worker, control])

    recovered = %{worker | ready: true}

    assert [{:ready, ^recovered}] =
             K8sNodes.readiness_transitions(
               %{"node-worker-1.example.com" => worker_previous(false)},
               [recovered]
             )

    assert [] = K8sNodes.readiness_transitions(%{}, [worker])

    assert [] =
             K8sNodes.readiness_transitions(
               %{"node-worker-1.example.com" => worker_previous(false)},
               [worker]
             )
  end

  test "disappeared_not_ready emits a ready/clear for a NotReady node that left the snapshot" do
    previous = %{
      "node-worker-1.example.com" => %{
        ready: false,
        role: "worker",
        cluster_id: "cluster-a"
      },
      "node-control-1.example.com" => %{
        ready: true,
        role: "control-plane",
        cluster_id: "cluster-a"
      }
    }

    remaining = [
      %{
        name: "node-control-1.example.com",
        cluster_id: "cluster-a",
        role: "control-plane",
        ready: true
      }
    ]

    assert [{:ready, recovered}] = K8sNodes.disappeared_not_ready(previous, remaining)
    assert recovered.name == "node-worker-1.example.com"
    assert recovered.role == "worker"
    assert recovered.ready_reason == "NodeDeleted"
  end
end
