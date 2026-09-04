defmodule ServiceRadar.FlowAttributionTest do
  use ServiceRadar.DataCase, async: false

  alias Serviceradar.Agent.Netprobe.V1.FlowAttributionEvent
  alias ServiceRadar.FlowAttribution
  alias ServiceRadar.FlowAttribution.Persistence
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    partition = "flow-attribution-test-#{System.unique_integer([:positive])}"
    agent_id = "agent-#{partition}"

    on_exit(fn ->
      query!("DELETE FROM platform.ocsf_network_activity WHERE partition = $1", [partition])

      query!("DELETE FROM platform.flow_process_attribution_current WHERE partition = $1", [
        partition
      ])

      query!("DELETE FROM platform.workload_identity_current WHERE partition = $1", [partition])
      query!("DELETE FROM platform.ocsf_agents WHERE uid = $1", [agent_id])
    end)

    %{partition: partition, agent_id: agent_id}
  end

  test "clamps configured raw attribution retention to the correlation skew" do
    old_config = Application.get_env(:serviceradar_core, FlowAttribution)

    on_exit(fn ->
      if is_nil(old_config) do
        Application.delete_env(:serviceradar_core, FlowAttribution)
      else
        Application.put_env(:serviceradar_core, FlowAttribution, old_config)
      end
    end)

    Application.put_env(:serviceradar_core, FlowAttribution, retention_minutes: 1)

    assert FlowAttribution.retention_minutes() == 15
  end

  test "prunes raw attribution rows using configured retention", %{
    partition: partition,
    agent_id: agent_id
  } do
    old_config = Application.get_env(:serviceradar_core, FlowAttribution)

    on_exit(fn ->
      if is_nil(old_config) do
        Application.delete_env(:serviceradar_core, FlowAttribution)
      else
        Application.put_env(:serviceradar_core, FlowAttribution, old_config)
      end
    end)

    Application.put_env(:serviceradar_core, FlowAttribution, retention_minutes: 20)

    seed_attribution(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(DateTime.utc_now(), -25, :minute),
      local_ip: "10.0.2.12",
      local_port: 20_509,
      remote_ip: "152.117.116.178",
      remote_port: 161,
      pid: 72_101,
      comm: "old-row"
    })

    seed_attribution(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(DateTime.utc_now(), -5, :minute),
      local_ip: "10.0.2.12",
      local_port: 20_510,
      remote_ip: "152.117.116.178",
      remote_port: 161,
      pid: 72_102,
      comm: "fresh-row"
    })

    assert {:ok, 1} = FlowAttribution.prune()

    %{rows: [[count]]} =
      query!(
        "SELECT count(*) FROM platform.flow_process_attribution_current WHERE partition = $1",
        [partition]
      )

    assert count == 1
  end

  test "upserts duplicate attribution observations into current state", %{
    partition: partition,
    agent_id: agent_id
  } do
    now =
      DateTime.utc_now()
      |> DateTime.to_unix()
      |> div(60)
      |> Kernel.*(60)
      |> DateTime.from_unix!()

    event = %FlowAttributionEvent{
      transport_protocol: "tcp",
      local_ip: "10.42.221.147",
      local_port: 6379,
      remote_ip: "0.0.0.0",
      remote_port: 0,
      pid: 63_790,
      uid: 1000,
      comm: "redis-server",
      redacted_cmdline: ["redis-server", "*:6379"],
      observed_at_unix_nano: DateTime.to_unix(now, :nanosecond)
    }

    later = %{
      event
      | redacted_cmdline: ["redis-server", "--protected-mode", "yes"],
        observed_at_unix_nano: now |> DateTime.add(5, :second) |> DateTime.to_unix(:nanosecond)
    }

    FlowAttribution.persist([event, later], partition, agent_id)

    %{rows: [[count, observed_at, cmdline]]} =
      query!(
        """
        SELECT count(*), max(observed_at), max(cmdline)
        FROM platform.flow_process_attribution_current
        WHERE partition = $1
        """,
        [partition]
      )

    assert count == 1
    assert DateTime.compare(observed_at, DateTime.add(now, 5, :second)) in [:eq, :gt]
    assert cmdline == "redis-server --protected-mode yes"
  end

  test "current attribution upsert is idempotent for repeated rows", %{
    partition: partition,
    agent_id: agent_id
  } do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    row = %{
      observed_at: now,
      partition: partition,
      attribution_key: "attr-key-#{System.unique_integer([:positive])}",
      agent_id: agent_id,
      proto: 6,
      local_ip: "10.42.221.147",
      local_port: 6379,
      remote_ip: "0.0.0.0",
      remote_port: 0,
      pid: 63_790,
      comm: "redis-server",
      cmdline: "redis-server *:6379",
      uid: 1000,
      container_id: nil,
      workload_identity: nil
    }

    assert {:ok, %Postgrex.Result{num_rows: 1}} = Persistence.insert_current_rows([row, row])
    assert {:ok, %Postgrex.Result{num_rows: 0}} = Persistence.insert_current_rows([row, row])

    older = %{
      row
      | observed_at: DateTime.add(now, -5, :second),
        cmdline: "redis-server older",
        uid: 2000
    }

    assert {:ok, %Postgrex.Result{num_rows: 0}} = Persistence.insert_current_rows([older])

    %{rows: [[count, observed_at, cmdline, uid]]} =
      query!(
        """
        SELECT count(*), max(observed_at), max(cmdline), max(uid)
        FROM platform.flow_process_attribution_current
        WHERE partition = $1
        """,
        [partition]
      )

    assert count == 1
    assert DateTime.compare(observed_at, now) == :eq
    assert cmdline == "redis-server *:6379"
    assert uid == 1000
  end

  test "enriches current attribution rows from existing workload identity", %{
    partition: partition,
    agent_id: agent_id
  } do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    container_id = "container-existing-#{System.unique_integer([:positive])}"

    seed_workload_identity(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -1, :second),
      container_id: container_id,
      identity: %{
        "container_id" => container_id,
        "pod_namespace" => "demo",
        "pod_name" => "speaker-x6qvg",
        "container_name" => "speaker",
        "image" => "metallb/speaker:v0.14.9",
        "runtime_source" => "containerd",
        "confidence" => "high"
      }
    })

    event = %FlowAttributionEvent{
      transport_protocol: "udp",
      local_ip: "10.0.2.9",
      local_port: 7946,
      remote_ip: "192.168.10.96",
      remote_port: 7946,
      pid: 112_633,
      uid: 1000,
      comm: "speaker",
      container_id: container_id,
      observed_at_unix_nano: DateTime.to_unix(now, :nanosecond)
    }

    FlowAttribution.persist([event], partition, agent_id)

    %{rows: [[workload]]} =
      query!(
        """
        SELECT workload_identity
        FROM platform.flow_process_attribution_current
        WHERE partition = $1 AND agent_id = $2 AND container_id = $3
        """,
        [partition, agent_id, container_id]
      )

    assert workload["pod_namespace"] == "demo"
    assert workload["pod_name"] == "speaker-x6qvg"
    assert workload["container_name"] == "speaker"
  end

  test "merges current workload context into partial event workload identity", %{
    partition: partition,
    agent_id: agent_id
  } do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    container_id = "container-partial-#{System.unique_integer([:positive])}"

    seed_workload_identity(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -1, :second),
      container_id: container_id,
      identity: %{
        "context_name" => "default-cp3",
        "container_id" => container_id,
        "pod_namespace" => "metallb-system",
        "pod_name" => "speaker-r7zlz",
        "container_name" => "speaker",
        "image" => "quay.io/metallb/speaker:v0.15.2",
        "runtime_source" => "containerd",
        "confidence" => "high"
      }
    })

    event = %FlowAttributionEvent{
      transport_protocol: "udp",
      local_ip: "10.0.2.13",
      local_port: 7946,
      remote_ip: "192.168.10.31",
      remote_port: 7946,
      pid: 963_214,
      uid: 1000,
      comm: "speaker",
      container_id: container_id,
      workload_identity: %Serviceradar.Agent.Netprobe.V1.WorkloadIdentity{
        container_id: container_id,
        pod_namespace: "metallb-system",
        pod_name: "speaker-r7zlz",
        container_name: "speaker"
      },
      observed_at_unix_nano: DateTime.to_unix(now, :nanosecond)
    }

    FlowAttribution.persist([event], partition, agent_id)

    %{rows: [[workload]]} =
      query!(
        """
        SELECT workload_identity
        FROM platform.flow_process_attribution_current
        WHERE partition = $1 AND agent_id = $2 AND container_id = $3
        """,
        [partition, agent_id, container_id]
      )

    assert workload["context_name"] == "default-cp3"
    assert workload["pod_namespace"] == "metallb-system"
    assert workload["pod_name"] == "speaker-r7zlz"
    assert workload["container_name"] == "speaker"
    assert workload["image"] == "quay.io/metallb/speaker:v0.15.2"
  end

  test "backfills current attribution rows when workload identity arrives late", %{
    partition: partition,
    agent_id: agent_id
  } do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    container_id = "container-late-#{System.unique_integer([:positive])}"

    seed_attribution(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -2, :second),
      local_ip: "10.0.2.11",
      local_port: 179,
      remote_ip: "192.168.10.96",
      remote_port: 34_491,
      pid: 45_246,
      comm: "gobgpd",
      container_id: container_id
    })

    seed_workload_identity(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -1, :second),
      container_id: container_id,
      identity: %{
        "container_id" => container_id,
        "pod_namespace" => "demo",
        "pod_name" => "gobgp-0",
        "container_name" => "gobgpd",
        "image" => "gobgp:latest",
        "runtime_source" => "containerd",
        "confidence" => "high"
      }
    })

    assert {:ok, 1} =
             FlowAttribution.backfill_current_workload_identity([
               %{
                 partition: partition,
                 agent_id: agent_id,
                 container_id: container_id
               }
             ])

    %{rows: [[workload]]} =
      query!(
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

  test "backfills missing context on partial current workload identity", %{
    partition: partition,
    agent_id: agent_id
  } do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    container_id = "container-partial-late-#{System.unique_integer([:positive])}"

    seed_attribution(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -2, :second),
      local_ip: "10.0.2.12",
      local_port: 7946,
      remote_ip: "192.168.10.96",
      remote_port: 7946,
      pid: 963_214,
      comm: "speaker",
      container_id: container_id,
      workload_identity: %{
        "container_id" => container_id,
        "pod_namespace" => "metallb-system",
        "pod_name" => "speaker-dhj7j",
        "container_name" => "speaker"
      }
    })

    seed_workload_identity(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -1, :second),
      container_id: container_id,
      identity: %{
        "context_name" => "default-cp3",
        "container_id" => container_id,
        "pod_namespace" => "metallb-system",
        "pod_name" => "speaker-dhj7j",
        "container_name" => "speaker",
        "image" => "quay.io/metallb/speaker:v0.15.2",
        "runtime_source" => "containerd",
        "confidence" => "high"
      }
    })

    assert {:ok, 1} =
             FlowAttribution.backfill_current_workload_identity([
               %{
                 partition: partition,
                 agent_id: agent_id,
                 container_id: container_id
               }
             ])

    %{rows: [[workload]]} =
      query!(
        """
        SELECT workload_identity
        FROM platform.flow_process_attribution_current
        WHERE partition = $1 AND agent_id = $2 AND container_id = $3
        """,
        [partition, agent_id, container_id]
      )

    assert workload["context_name"] == "default-cp3"
    assert workload["pod_namespace"] == "metallb-system"
    assert workload["pod_name"] == "speaker-dhj7j"
    assert workload["image"] == "quay.io/metallb/speaker:v0.15.2"
  end

  test "correlates delayed TCP flow from current-state attribution", %{
    partition: partition,
    agent_id: agent_id
  } do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    flow_time = DateTime.add(now, -10, :minute)

    seed_flow(%{
      partition: partition,
      time: flow_time,
      src_ip: "192.168.1.62",
      src_port: 54_710,
      dst_ip: "192.168.1.1",
      dst_port: 443
    })

    seed_attribution(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(flow_time, -2, :second),
      local_ip: "192.168.1.62",
      local_port: 54_710,
      remote_ip: "192.168.1.1",
      remote_port: 443,
      pid: 61_707,
      comm: "serviceradar-agent"
    })

    assert {:ok, 1} = FlowAttribution.correlate()

    payload = attributed_payload(partition)
    assert payload["event_type"] == "attributed_flow"
    assert payload["agent_id"] == agent_id
    assert payload["attribution"]["pid"] == 61_707
    assert payload["attribution"]["comm"] == "serviceradar-agent"
  end

  test "correlates pod-local attribution to node-SNATed NetFlow", %{
    partition: partition,
    agent_id: agent_id
  } do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    seed_agent(agent_id, "10.0.2.9")

    seed_flow(%{
      partition: partition,
      time: now,
      src_ip: "10.0.2.9",
      src_port: 55_000,
      dst_ip: "104.20.23.154",
      dst_port: 443
    })

    seed_attribution(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -10, :second),
      local_ip: "10.42.202.17",
      local_port: 42_276,
      remote_ip: "104.20.23.154",
      remote_port: 443,
      pid: 12_345,
      comm: "curl"
    })

    assert {:ok, 1} = FlowAttribution.correlate()

    assert %{"event_type" => "attributed_flow", "agent_id" => ^agent_id} =
             payload = attributed_payload(partition)

    assert payload["attribution"]["pid"] == 12_345
    assert payload["attribution"]["comm"] == "curl"
  end

  test "keeps exact 5-tuple attribution ahead of SNAT fallback candidates", %{
    partition: partition,
    agent_id: agent_id
  } do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    seed_agent(agent_id, "10.0.2.9")

    seed_flow(%{
      partition: partition,
      time: now,
      src_ip: "10.0.2.9",
      src_port: 42_276,
      dst_ip: "104.20.23.154",
      dst_port: 443
    })

    seed_attribution(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -8, :second),
      local_ip: "10.42.202.17",
      local_port: 51_515,
      remote_ip: "104.20.23.154",
      remote_port: 443,
      pid: 22_222,
      comm: "pod-curl"
    })

    seed_attribution(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -12, :second),
      local_ip: "10.0.2.9",
      local_port: 42_276,
      remote_ip: "104.20.23.154",
      remote_port: 443,
      pid: 11_111,
      comm: "host-curl"
    })

    assert {:ok, 1} = FlowAttribution.correlate()

    payload = attributed_payload(partition)
    assert payload["attribution"]["pid"] == 11_111
    assert payload["attribution"]["comm"] == "host-curl"
  end

  test "correlates exact UDP attribution", %{partition: partition, agent_id: agent_id} do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    seed_flow(%{
      partition: partition,
      time: now,
      proto: 17,
      protocol_name: "udp",
      src_ip: "10.42.68.167",
      src_port: 57_279,
      dst_ip: "10.43.0.10",
      dst_port: 53
    })

    seed_attribution(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -2, :second),
      proto: 17,
      local_ip: "10.42.68.167",
      local_port: 57_279,
      remote_ip: "10.43.0.10",
      remote_port: 53,
      pid: 44_024,
      comm: "redis-server"
    })

    assert {:ok, 1} = FlowAttribution.correlate()

    payload = attributed_payload(partition)
    assert payload["event_type"] == "attributed_flow"
    assert payload["attribution"]["pid"] == 44_024
    assert payload["attribution"]["comm"] == "redis-server"
  end

  test "correlates wildcard service attribution for server-side fan-in", %{
    partition: partition,
    agent_id: agent_id
  } do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    seed_flow(%{
      partition: partition,
      time: now,
      proto: 17,
      protocol_name: "udp",
      src_ip: "10.42.221.147",
      src_port: 53,
      dst_ip: "10.42.199.32",
      dst_port: 57_216
    })

    seed_attribution(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -2, :second),
      proto: 17,
      local_ip: "10.42.221.147",
      local_port: 53,
      remote_ip: "0.0.0.0",
      remote_port: 0,
      pid: 55_053,
      comm: "coredns"
    })

    assert {:ok, 1} = FlowAttribution.correlate()

    payload = attributed_payload(partition)
    assert payload["event_type"] == "attributed_flow"
    assert payload["attribution"]["pid"] == 55_053
    assert payload["attribution"]["comm"] == "coredns"
  end

  test "keeps exact attribution ahead of wildcard service attribution", %{
    partition: partition,
    agent_id: agent_id
  } do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    seed_flow(%{
      partition: partition,
      time: now,
      src_ip: "10.42.221.147",
      src_port: 6379,
      dst_ip: "10.42.199.32",
      dst_port: 57_216
    })

    seed_attribution(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -2, :second),
      local_ip: "10.42.221.147",
      local_port: 6379,
      remote_ip: "0.0.0.0",
      remote_port: 0,
      pid: 63_790,
      comm: "wildcard-redis"
    })

    seed_attribution(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -5, :second),
      local_ip: "10.42.221.147",
      local_port: 6379,
      remote_ip: "10.42.199.32",
      remote_port: 57_216,
      pid: 63_791,
      comm: "exact-redis"
    })

    assert {:ok, 1} = FlowAttribution.correlate()

    payload = attributed_payload(partition)
    assert payload["attribution"]["pid"] == 63_791
    assert payload["attribution"]["comm"] == "exact-redis"
  end

  test "carries workload identity into attributed flow payload", %{
    partition: partition,
    agent_id: agent_id
  } do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    seed_flow(%{
      partition: partition,
      time: now,
      src_ip: "10.42.68.167",
      src_port: 57_279,
      dst_ip: "10.43.0.10",
      dst_port: 6379
    })

    seed_attribution(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -2, :second),
      local_ip: "10.42.68.167",
      local_port: 57_279,
      remote_ip: "10.43.0.10",
      remote_port: 6379,
      pid: 44_024,
      comm: "redis-server",
      workload_identity: %{
        "pod_namespace" => "demo",
        "pod_name" => "redis-0",
        "pod_uid" => "57e67067-89e4-4001-bdd4-8632d39ea02b",
        "container_name" => "redis",
        "image" => "redis:7",
        "runtime_source" => "containerd",
        "confidence" => "high",
        "labels" => %{"app.kubernetes.io/name" => "redis"}
      }
    })

    assert {:ok, 1} = FlowAttribution.correlate()

    workload = attributed_payload(partition)["attribution"]["workload_identity"]
    assert workload["pod_namespace"] == "demo"
    assert workload["pod_name"] == "redis-0"
    assert workload["container_name"] == "redis"
    assert workload["labels"]["app.kubernetes.io/name"] == "redis"
  end

  test "joins standalone workload identity by agent and container during correlation", %{
    partition: partition,
    agent_id: agent_id
  } do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    container_id = "containerd://6c6ad30c2ff8796e0c016634eb069cb54eb5539c"

    seed_flow(%{
      partition: partition,
      time: now,
      src_ip: "10.42.68.167",
      src_port: 57_279,
      dst_ip: "10.43.0.10",
      dst_port: 6379
    })

    seed_attribution(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -2, :second),
      local_ip: "10.42.68.167",
      local_port: 57_279,
      remote_ip: "10.43.0.10",
      remote_port: 6379,
      pid: 44_024,
      comm: "redis-server",
      container_id: container_id
    })

    seed_workload_identity(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -1, :second),
      container_id: container_id,
      identity: %{
        "container_id" => container_id,
        "pod_namespace" => "demo",
        "pod_name" => "redis-0",
        "pod_uid" => "57e67067-89e4-4001-bdd4-8632d39ea02b",
        "container_name" => "redis",
        "image" => "redis:7",
        "runtime_source" => "containerd",
        "confidence" => "high"
      }
    })

    assert {:ok, 1} = FlowAttribution.correlate()

    payload = attributed_payload(partition)
    assert payload["attribution"]["container_id"] == container_id

    workload = payload["attribution"]["workload_identity"]
    assert workload["pod_namespace"] == "demo"
    assert workload["pod_name"] == "redis-0"
    assert workload["container_name"] == "redis"
    assert workload["runtime_source"] == "containerd"
  end

  test "correlation merges standalone context into partial attributed flow workload", %{
    partition: partition,
    agent_id: agent_id
  } do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    container_id = "containerd://partial-flow-context"

    seed_flow(%{
      partition: partition,
      time: now,
      src_ip: "10.0.2.12",
      src_port: 7946,
      dst_ip: "192.168.10.96",
      dst_port: 7946,
      proto: 17,
      protocol_name: "udp"
    })

    seed_attribution(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -2, :second),
      local_ip: "10.0.2.12",
      local_port: 7946,
      remote_ip: "192.168.10.96",
      remote_port: 7946,
      proto: 17,
      pid: 963_214,
      comm: "speaker",
      container_id: container_id,
      workload_identity: %{
        "container_id" => container_id,
        "pod_namespace" => "metallb-system",
        "pod_name" => "speaker-dhj7j",
        "container_name" => "speaker"
      }
    })

    seed_workload_identity(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -1, :second),
      container_id: container_id,
      identity: %{
        "context_name" => "default-cp3",
        "container_id" => container_id,
        "pod_namespace" => "metallb-system",
        "pod_name" => "speaker-dhj7j",
        "container_name" => "speaker",
        "image" => "quay.io/metallb/speaker:v0.15.2",
        "runtime_source" => "containerd"
      }
    })

    assert {:ok, 1} = FlowAttribution.correlate()

    workload = attributed_payload(partition)["attribution"]["workload_identity"]
    assert workload["context_name"] == "default-cp3"
    assert workload["pod_namespace"] == "metallb-system"
    assert workload["pod_name"] == "speaker-dhj7j"
    assert workload["container_name"] == "speaker"
    assert workload["image"] == "quay.io/metallb/speaker:v0.15.2"
  end

  test "backfills recent attributed flows when standalone workload identity arrives late", %{
    partition: partition,
    agent_id: agent_id
  } do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    container_id = "containerd://late-identity-container"

    seed_flow(%{
      partition: partition,
      time: now,
      src_ip: "10.42.68.167",
      src_port: 57_279,
      dst_ip: "10.43.0.10",
      dst_port: 6379,
      payload: %{
        "event_type" => "attributed_flow",
        "agent_id" => agent_id,
        "attribution" => %{
          "pid" => 44_024,
          "comm" => "redis-server",
          "container_id" => container_id
        }
      }
    })

    seed_workload_identity(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, 1, :second),
      container_id: container_id,
      identity: %{
        "container_id" => container_id,
        "pod_namespace" => "demo",
        "pod_name" => "redis-late-0",
        "container_name" => "redis",
        "image" => "redis:7",
        "runtime_source" => "containerd",
        "confidence" => "high"
      }
    })

    assert {:ok, 1} = FlowAttribution.correlate()

    workload = attributed_payload(partition)["attribution"]["workload_identity"]
    assert workload["pod_namespace"] == "demo"
    assert workload["pod_name"] == "redis-late-0"
  end

  test "correlates UDP attribution when exporter local ephemeral port differs", %{
    partition: partition,
    agent_id: agent_id
  } do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    seed_flow(%{
      partition: partition,
      time: now,
      proto: 17,
      protocol_name: "udp",
      src_ip: "203.0.113.17",
      src_port: 61_001,
      dst_ip: "198.51.100.123",
      dst_port: 4_321
    })

    seed_attribution(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -2, :second),
      proto: 17,
      local_ip: "203.0.113.17",
      local_port: 61_002,
      remote_ip: "198.51.100.123",
      remote_port: 4_321,
      pid: 42_002,
      comm: "udp-port-client"
    })

    assert {:ok, 1} = FlowAttribution.correlate()

    payload = attributed_payload(partition)
    assert payload["event_type"] == "attributed_flow"
    assert payload["agent_id"] == agent_id
    assert payload["attribution"]["pid"] == 42_002
    assert payload["attribution"]["comm"] == "udp-port-client"
  end

  test "correlates coalesced UDP attribution with a zero local port", %{
    partition: partition,
    agent_id: agent_id
  } do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    seed_flow(%{
      partition: partition,
      time: now,
      proto: 17,
      protocol_name: "udp",
      src_ip: "192.0.2.44",
      src_port: 49_152,
      dst_ip: "198.51.100.53",
      dst_port: 8_125
    })

    seed_attribution(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -2, :second),
      proto: 17,
      local_ip: "192.0.2.44",
      local_port: 0,
      remote_ip: "198.51.100.53",
      remote_port: 8_125,
      pid: 42_001,
      comm: "udp-zero-client"
    })

    assert {:ok, 1} = FlowAttribution.correlate()

    payload = attributed_payload(partition)
    assert payload["event_type"] == "attributed_flow"
    assert payload["agent_id"] == agent_id
    assert payload["attribution"]["pid"] == 42_001
    assert payload["attribution"]["comm"] == "udp-zero-client"
  end

  test "keeps exact UDP attribution ahead of relaxed service-port candidates", %{
    partition: partition,
    agent_id: agent_id
  } do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    seed_flow(%{
      partition: partition,
      time: now,
      proto: 17,
      protocol_name: "udp",
      src_ip: "10.0.2.12",
      src_port: 38_573,
      dst_ip: "152.117.116.178",
      dst_port: 161
    })

    seed_attribution(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -1, :second),
      proto: 17,
      local_ip: "10.0.2.12",
      local_port: 20_509,
      remote_ip: "152.117.116.178",
      remote_port: 161,
      pid: 72_101,
      comm: "relaxed"
    })

    seed_attribution(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -5, :second),
      proto: 17,
      local_ip: "10.0.2.12",
      local_port: 38_573,
      remote_ip: "152.117.116.178",
      remote_port: 161,
      pid: 72_102,
      comm: "exact"
    })

    assert {:ok, 1} = FlowAttribution.correlate()

    payload = attributed_payload(partition)
    assert payload["attribution"]["pid"] == 72_102
    assert payload["attribution"]["comm"] == "exact"
  end

  test "correlates ICMP pseudo-port exporter data through node fallback", %{
    partition: partition,
    agent_id: agent_id
  } do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    seed_agent(agent_id, "10.0.2.11")

    seed_flow(%{
      partition: partition,
      time: now,
      proto: 1,
      protocol_name: "icmp",
      src_ip: "1.1.1.1",
      src_port: 8,
      dst_ip: "10.0.2.11",
      dst_port: 0
    })

    seed_attribution(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -2, :second),
      proto: 1,
      local_ip: "10.42.68.112",
      local_port: 0,
      remote_ip: "1.1.1.1",
      remote_port: 0,
      pid: 55_555,
      comm: "ping"
    })

    assert {:ok, 1} = FlowAttribution.correlate()

    payload = attributed_payload(partition)
    assert payload["event_type"] == "attributed_flow"
    assert payload["attribution"]["pid"] == 55_555
    assert payload["attribution"]["comm"] == "ping"
  end

  defp seed_agent(agent_id, ip) do
    query!(
      """
      INSERT INTO platform.ocsf_agents (uid, ip, status)
      VALUES ($1, $2, 'healthy')
      ON CONFLICT (uid) DO UPDATE SET ip = EXCLUDED.ip
      """,
      [agent_id, ip]
    )
  end

  defp seed_flow(params) do
    query!(
      """
      INSERT INTO platform.ocsf_network_activity (
        time,
        src_endpoint_ip,
        src_endpoint_port,
        dst_endpoint_ip,
        dst_endpoint_port,
        protocol_num,
        protocol_name,
        bytes_total,
        packets_total,
        ocsf_payload,
        partition
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, 2048, 8, ($8::text)::jsonb, $9)
      """,
      [
        params.time,
        params.src_ip,
        params.src_port,
        params.dst_ip,
        params.dst_port,
        Map.get(params, :proto, 6),
        Map.get(params, :protocol_name, "tcp"),
        json_param(Map.get(params, :payload, %{})),
        params.partition
      ]
    )
  end

  defp seed_attribution(params) do
    query!(
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
        cmdline,
        uid,
        container_id,
        workload_identity
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, 'curl https://example.com', 1000, $12, ($13::text)::jsonb)
      """,
      [
        params.observed_at,
        params.partition,
        attribution_key(params),
        params.agent_id,
        Map.get(params, :proto, 6),
        params.local_ip,
        params.local_port,
        params.remote_ip,
        params.remote_port,
        params.pid,
        params.comm,
        Map.get(params, :container_id),
        json_param(Map.get(params, :workload_identity))
      ]
    )
  end

  defp seed_workload_identity(params) do
    identity = Map.fetch!(params, :identity)

    query!(
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
        degradation_reason,
        identity
      )
      VALUES (
        $1,
        now(),
        now(),
        $2,
        $3,
        $4,
        $5,
        $6,
        $7,
        $8,
        $9,
        $10,
        $11,
        $12,
        $13,
        ($14::text)::jsonb
      )
      """,
      [
        params.observed_at,
        params.partition,
        params.agent_id,
        Map.get(params, :gateway_id),
        params.container_id,
        Map.get(identity, "pod_uid"),
        Map.get(identity, "pod_namespace"),
        Map.get(identity, "pod_name"),
        Map.get(identity, "container_name"),
        Map.get(identity, "image"),
        Map.get(identity, "runtime_source"),
        Map.get(identity, "confidence"),
        Map.get(identity, "degradation_reason"),
        Jason.encode!(identity)
      ]
    )
  end

  defp attribution_key(params) do
    [
      params.agent_id,
      Map.get(params, :proto, 6),
      params.local_ip,
      params.local_port,
      params.remote_ip,
      params.remote_port
    ]
    |> Enum.map_join(<<31>>, &key_part/1)
    |> then(&:crypto.hash(:md5, &1))
    |> Base.encode16(case: :lower)
  end

  defp key_part(nil), do: ""
  defp key_part(value), do: to_string(value)

  defp json_param(nil), do: nil
  defp json_param(value), do: Jason.encode!(value)

  defp attributed_payload(partition) do
    %{rows: [[payload]]} =
      query!(
        """
        SELECT ocsf_payload
        FROM platform.ocsf_network_activity
        WHERE partition = $1
        LIMIT 1
        """,
        [partition]
      )

    payload
  end

  defp query!(sql, params) do
    Repo.query!(sql, params)
  end
end
