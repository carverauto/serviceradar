defmodule ServiceRadar.FlowAttributionTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.FlowAttribution
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

      query!("DELETE FROM platform.flow_process_attributions WHERE partition = $1", [partition])
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

    event = %Netprobepb.FlowAttributionEvent{
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

    %{rows: [[history_count, history_cmdline]]} =
      query!(
        """
        SELECT count(*), max(cmdline)
        FROM platform.flow_process_attributions
        WHERE partition = $1
        """,
        [partition]
      )

    assert history_count == 1
    assert history_cmdline == "redis-server --protected-mode yes"
  end

  test "correlates delayed TCP flow from historical attribution only", %{
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

    seed_legacy_attribution(%{
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
      src_ip: "10.0.2.12",
      src_port: 38_573,
      dst_ip: "152.117.116.178",
      dst_port: 161
    })

    seed_attribution(%{
      partition: partition,
      agent_id: agent_id,
      observed_at: DateTime.add(now, -2, :second),
      proto: 17,
      local_ip: "10.0.2.12",
      local_port: 20_509,
      remote_ip: "152.117.116.178",
      remote_port: 161,
      pid: 72_101,
      comm: "serviceradar-agent"
    })

    assert {:ok, 1} = FlowAttribution.correlate()

    payload = attributed_payload(partition)
    assert payload["event_type"] == "attributed_flow"
    assert payload["attribution"]["pid"] == 72_101
    assert payload["attribution"]["comm"] == "serviceradar-agent"
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
      VALUES ($1, $2, $3, $4, $5, $6, $7, 2048, 8, '{}'::jsonb, $8)
      """,
      [
        params.time,
        params.src_ip,
        params.src_port,
        params.dst_ip,
        params.dst_port,
        Map.get(params, :proto, 6),
        Map.get(params, :protocol_name, "tcp"),
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
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, 'curl https://example.com', 1000, NULL, ($12::text)::jsonb)
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
        json_param(Map.get(params, :workload_identity))
      ]
    )
  end

  defp seed_legacy_attribution(params) do
    query!(
      """
      INSERT INTO platform.flow_process_attributions (
        observed_at,
        partition,
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
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'curl https://example.com', 1000, NULL, ($11::text)::jsonb)
      """,
      [
        params.observed_at,
        params.partition,
        params.agent_id,
        Map.get(params, :proto, 6),
        params.local_ip,
        params.local_port,
        params.remote_ip,
        params.remote_port,
        params.pid,
        params.comm,
        json_param(Map.get(params, :workload_identity))
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
      params.remote_port,
      params.pid,
      Map.get(params, :uid, 1000),
      Map.get(params, :container_id),
      params.comm
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
