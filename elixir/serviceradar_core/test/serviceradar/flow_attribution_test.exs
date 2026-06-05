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
      query!("DELETE FROM platform.flow_process_attributions WHERE partition = $1", [partition])
      query!("DELETE FROM platform.ocsf_agents WHERE uid = $1", [agent_id])
    end)

    %{partition: partition, agent_id: agent_id}
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
      VALUES ($1, $2, $3, $4, $5, 6, 'tcp', 2048, 8, '{}'::jsonb, $6)
      """,
      [
        params.time,
        params.src_ip,
        params.src_port,
        params.dst_ip,
        params.dst_port,
        params.partition
      ]
    )
  end

  defp seed_attribution(params) do
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
        container_id
      )
      VALUES ($1, $2, $3, 6, $4, $5, $6, $7, $8, $9, 'curl https://example.com', 1000, NULL)
      """,
      [
        params.observed_at,
        params.partition,
        params.agent_id,
        params.local_ip,
        params.local_port,
        params.remote_ip,
        params.remote_port,
        params.pid,
        params.comm
      ]
    )
  end

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
