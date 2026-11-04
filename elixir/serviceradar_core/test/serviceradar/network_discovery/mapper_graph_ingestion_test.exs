defmodule ServiceRadar.NetworkDiscovery.MapperGraphIngestionTest do
  use ServiceRadar.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Ingestion.LaneSupervisor
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor
  alias ServiceRadar.NetworkDiscovery.TopologyProjectionWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    Application.put_env(:serviceradar_core, :mapper_topology_edge_stale_minutes, 180)

    :ok
  end

  # Regression coverage for the 2026-06-25 evidence-pipeline outage: records
  # that legitimately lack logical-key fields (SNMP-L2 ARP+FDB attachments,
  # UniFi wireless clients / uplinks, wireguard-derived links) were rejected by
  # Required validation because Ash's :string defaults cast the ingestor's ""
  # sentinel back to nil, and one rejected record aborted the whole payload.
  # These payload shapes mirror what go/pkg/mapper actually emits
  # (snmp_l2_query.go, ubnt_topology.go, and the core wireguard deriver).
  test "ingest_topology persists SNMP-L2 ARP+FDB attachment records without a neighbor port id" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    purge_topology_rows(["sr:it-fdb-switch"])

    payload = [
      %{
        "timestamp" => now,
        "protocol" => "SNMP-L2",
        "agent_id" => "agent-it-fdb",
        "gateway_id" => "agent-it-fdb",
        "partition" => "default",
        "local_device_id" => "sr:it-fdb-switch",
        "local_device_ip" => "192.0.2.10",
        "local_if_index" => 4,
        "neighbor_chassis_id" => "aa:bb:cc:dd:fd:11",
        "neighbor_mgmt_addr" => "192.0.2.77",
        "metadata" => %{
          "protocol" => "SNMP-L2",
          "source" => "snmp-arp-fdb",
          "evidence" => "ipNetToMedia+dot1dTpFdb",
          "fdb_port_mapped" => "true",
          "evidence_class" => "inferred-segment",
          "relation_family" => "ATTACHED_TO",
          "confidence_tier" => "medium",
          "confidence_reason" => "arp_fdb_port_mapping"
        }
      }
    ]

    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!(payload), %{})

    rows = topology_rows("sr:it-fdb-switch")
    assert [row] = rows
    assert row["protocol"] == "SNMP-L2"
    assert row["neighbor_chassis_id"] == "aa:bb:cc:dd:fd:11"
    assert row["neighbor_port_id"] == ""
  end

  test "ingest_topology persists UniFi wireless client association records" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    purge_topology_rows(["sr:it-unifi-ap"])

    payload = [
      %{
        "timestamp" => now,
        "protocol" => "UniFi-API",
        "agent_id" => "agent-it-unifi",
        "gateway_id" => "agent-it-unifi",
        "partition" => "default",
        "local_device_id" => "sr:it-unifi-ap",
        "local_device_ip" => "192.0.2.20",
        "local_if_name" => "wireless",
        "neighbor_chassis_id" => "aa:bb:cc:dd:fd:22",
        "neighbor_system_name" => "laptop-01",
        "neighbor_mgmt_addr" => "192.0.2.88",
        "metadata" => %{
          "source" => "unifi-api-wireless-client",
          "evidence_class" => "endpoint-attachment",
          "relation_type" => "ATTACHED_TO",
          "relation_family" => "ATTACHED_TO",
          "confidence_tier" => "high",
          "confidence_reason" => "controller_client_association",
          "client_type" => "wireless",
          "uplink_device_id" => "unifi-sr:dev-1"
        }
      }
    ]

    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!(payload), %{})

    assert [row] = topology_rows("sr:it-unifi-ap")
    assert row["protocol"] == "UniFi-API"
    assert row["neighbor_port_id"] == ""
    assert row["neighbor_system_name"] == "laptop-01"
  end

  test "ingest_topology persists UniFi uplink records without a neighbor port id" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    purge_topology_rows(["sr:it-unifi-switch"])

    payload = [
      %{
        "timestamp" => now,
        "protocol" => "UniFi-API",
        "agent_id" => "agent-it-unifi",
        "gateway_id" => "agent-it-unifi",
        "partition" => "default",
        "local_device_id" => "sr:it-unifi-switch",
        "local_device_ip" => "192.0.2.30",
        "local_if_index" => 24,
        "local_if_name" => "Port 24",
        "neighbor_chassis_id" => "aa:bb:cc:dd:fd:33",
        "neighbor_system_name" => "office-ap",
        "neighbor_mgmt_addr" => "192.0.2.31",
        "metadata" => %{
          "source" => "unifi-api-uplink",
          "evidence_class" => "direct-physical",
          "relation_family" => "CONNECTS_TO",
          "uplink_device_id" => "unifi-sr:dev-2",
          "uplink_device_name" => "office-switch"
        }
      }
    ]

    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!(payload), %{})

    assert [row] = topology_rows("sr:it-unifi-switch")
    assert row["protocol"] == "UniFi-API"
    assert row["neighbor_port_id"] == ""
    assert row["local_if_index"] == 24
  end

  test "ingest_topology persists wireguard-derived records without a neighbor chassis id" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    purge_topology_rows(["sr:it-wg-router-a"])

    payload = [
      %{
        "timestamp" => now,
        "protocol" => "wireguard-derived",
        "agent_id" => "agent-it-wg",
        "gateway_id" => "agent-it-wg",
        "partition" => "default",
        "local_device_id" => "sr:it-wg-router-a",
        "local_device_ip" => "203.0.113.1",
        "local_if_name" => "wg0",
        "neighbor_device_id" => "sr:it-wg-router-b",
        "neighbor_port_id" => "wg0",
        "neighbor_port_descr" => "wireguard",
        "neighbor_system_name" => "wg-router-b",
        "neighbor_mgmt_addr" => "203.0.113.2",
        "metadata" => %{
          "source" => "wireguard-derived",
          "evidence_class" => "direct-logical",
          "relation_family" => "LOGICAL_PEER",
          "rule" => "exact_wg_interface_name_two_router_endpoints",
          "tunnel_name" => "wg0",
          "confidence_tier" => "high",
          "confidence_score" => 95,
          "confidence_reason" => "deterministic_wireguard_tunnel_match"
        }
      }
    ]

    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!(payload), %{})

    assert [row] = topology_rows("sr:it-wg-router-a")
    assert row["protocol"] == "wireguard-derived"
    assert row["neighbor_chassis_id"] == ""
    assert row["neighbor_port_id"] == "wg0"
  end

  # Pre-fix, this exact mix froze the whole pipeline: the sparse FDB/wireless
  # records failed Required validation, handle_bulk_result mapped the partial
  # success to {:error, _}, and even the fully-valid LLDP record never reached
  # TopologyGraph.upsert_links/1. Post-fix every record in the mix persists.
  test "ingest_topology with mixed sparse and rich records persists all of them" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    purge_topology_rows(["sr:it-mix-a", "sr:it-mix-sw"])

    payload = [
      %{
        "timestamp" => now,
        "protocol" => "LLDP",
        "agent_id" => "agent-it-mix",
        "gateway_id" => "agent-it-mix",
        "partition" => "default",
        "local_device_id" => "sr:it-mix-a",
        "local_device_ip" => "198.51.100.1",
        "local_if_index" => 10,
        "local_if_name" => "eth0",
        "neighbor_device_id" => "sr:it-mix-b",
        "neighbor_port_id" => "Gi0/1",
        "neighbor_system_name" => "mix-b",
        "neighbor_mgmt_addr" => "198.51.100.2",
        "metadata" => %{"source" => "lldp"}
      },
      %{
        "timestamp" => now,
        "protocol" => "SNMP-L2",
        "agent_id" => "agent-it-mix",
        "gateway_id" => "agent-it-mix",
        "partition" => "default",
        "local_device_id" => "sr:it-mix-sw",
        "local_device_ip" => "198.51.100.3",
        "local_if_index" => 7,
        "neighbor_chassis_id" => "aa:bb:cc:dd:fd:44",
        "neighbor_mgmt_addr" => "198.51.100.99",
        "metadata" => %{
          "source" => "snmp-arp-fdb",
          "evidence" => "ipNetToMedia+dot1dTpFdb",
          "fdb_port_mapped" => "true",
          "evidence_class" => "inferred-segment",
          "relation_family" => "ATTACHED_TO",
          "confidence_tier" => "medium",
          "confidence_reason" => "arp_fdb_port_mapping"
        }
      },
      %{
        "timestamp" => now,
        "protocol" => "UniFi-API",
        "agent_id" => "agent-it-mix",
        "gateway_id" => "agent-it-mix",
        "partition" => "default",
        "local_device_id" => "sr:it-mix-a",
        "local_device_ip" => "198.51.100.1",
        "local_if_name" => "wireless",
        "neighbor_chassis_id" => "aa:bb:cc:dd:fd:55",
        "neighbor_system_name" => "phone-01",
        "neighbor_mgmt_addr" => "198.51.100.88",
        "metadata" => %{
          "source" => "unifi-api-wireless-client",
          "evidence_class" => "endpoint-attachment",
          "relation_family" => "ATTACHED_TO",
          "confidence_tier" => "high",
          "confidence_reason" => "controller_client_association"
        }
      }
    ]

    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!(payload), %{})

    lldp_rows = topology_rows("sr:it-mix-a")
    assert Enum.any?(lldp_rows, &(&1["protocol"] == "LLDP" and &1["neighbor_port_id"] == "Gi0/1"))
    assert Enum.any?(lldp_rows, &(&1["protocol"] == "UniFi-API" and &1["neighbor_port_id"] == ""))

    assert [fdb_row] = topology_rows("sr:it-mix-sw")
    assert fdb_row["neighbor_port_id"] == ""
  end

  test "a large mapper interface result commits within the lane worker budget while Dgraph does not answer" do
    # Accepts connections from its backlog and never answers: a wedged Dgraph.
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, backlog: 1024])
    {:ok, port} = :inet.port(listener)
    with_dgraph_url("dgraph://127.0.0.1:#{port}?sslmode=disable")
    on_exit(fn -> :gen_tcp.close(listener) end)

    device_ip = "192.0.2.#{rem(System.unique_integer([:positive]), 200) + 20}"
    ts = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    payload =
      Jason.encode!(
        for index <- 1..200 do
          %{
            "device_id" => "default:#{device_ip}",
            "partition" => "default",
            "device_ip" => device_ip,
            "if_index" => index,
            "if_name" => "eth#{index}",
            "if_alias" => "port #{index}",
            "timestamp" => ts
          }
        end
      )

    budget = Keyword.fetch!(LaneSupervisor.limits(:mapper), :worker_timeout_ms)
    ingest = Task.async(fn -> MapperResultsIngestor.ingest_interfaces(payload, %{}) end)

    assert {:ok, :ok} = Task.yield(ingest, budget) || Task.shutdown(ingest, :brutal_kill),
           "mapper interface ingestion must not wait on the graph backend"

    assert %Postgrex.Result{rows: [[200]]} =
             SQL.query!(
               Repo,
               "SELECT count(DISTINCT if_index) FROM platform.discovered_interfaces WHERE device_ip = $1",
               [device_ip]
             )

    assert [%{"device_id" => device_id}] = pending_projection_args()
    assert is_binary(device_id) and device_id != ""
  end

  test "a write that lands during a projection causes exactly one follow-up projection" do
    device = "sr:it-follow"
    on_exit(fn -> delete_interface(device) end)
    on_exit(fn -> purge_topology_rows([device]) end)

    upsert_interface_alias(device, "first-alias")
    insert_unresolved_link(device)

    assert :ok = TopologyProjectionWorker.enqueue(:interfaces, [%{device_id: device}])
    [job] = pending_projection_jobs()
    mark_executing(job)

    test = self()
    handler = "mapper-graph-ingestion-follow-up-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:serviceradar, :mapper_topology, :neighbor_dropped],
        fn _event, _measurements, _metadata, _config ->
          if Process.get(:follow_up_write) == nil do
            Process.put(:follow_up_write, :done)
            upsert_interface_alias(device, "latest-alias")
            send(test, :write_landed)
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok = TopologyProjectionWorker.perform(reload_job(job.id))
    assert_received :write_landed

    assert [follow_up] = pending_projection_jobs()
    assert follow_up.id != job.id
    assert follow_up.args["device_id"] == device

    assert :ok = TopologyProjectionWorker.enqueue(:interfaces, [%{device_id: device}])
    assert [coalesced] = pending_projection_jobs()
    assert coalesced.id == follow_up.id

    mark_executing(follow_up)
    assert :ok = TopologyProjectionWorker.perform(reload_job(follow_up.id))
    assert [] = pending_projection_jobs()
  end

  test "device projections in one burst schedule one run of the global passes" do
    devices = ["sr:it-burst-a", "sr:it-burst-b", "sr:it-burst-c"]
    Enum.each(devices, fn device -> on_exit(fn -> delete_interface(device) end) end)
    Enum.each(devices, &upsert_interface_alias(&1, "burst-alias"))

    assert :ok =
             TopologyProjectionWorker.enqueue(:interfaces, Enum.map(devices, &%{device_id: &1}))

    jobs = pending_projection_jobs()
    assert length(jobs) == length(devices)
    Enum.each(jobs, &assert(:ok = TopologyProjectionWorker.perform(&1)))

    now = DateTime.utc_now()
    assert [global] = pending_global_pass_jobs()
    assert global.state == "scheduled"
    assert DateTime.after?(global.scheduled_at, now)
  end

  defp purge_topology_rows(local_device_ids) when is_list(local_device_ids) do
    SQL.query!(
      Repo,
      "DELETE FROM platform.mapper_topology_links WHERE local_device_id = ANY($1)",
      [local_device_ids]
    )

    :ok
  end

  defp topology_rows(local_device_id) do
    %Postgrex.Result{rows: rows, columns: columns} =
      SQL.query!(
        Repo,
        """
        SELECT protocol, local_device_id, local_if_index, neighbor_device_id,
               neighbor_chassis_id, neighbor_port_id, neighbor_system_name
        FROM platform.mapper_topology_links
        WHERE local_device_id = $1
        """,
        [local_device_id]
      )

    Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)
  end

  defp pending_projection_args, do: Enum.map(pending_projection_jobs(), & &1.args)

  defp pending_projection_jobs do
    Repo.all(
      from(j in Oban.Job,
        where:
          j.worker == "ServiceRadar.NetworkDiscovery.TopologyProjectionWorker" and
            j.state in ["available", "scheduled", "retryable"],
        order_by: j.id
      ),
      prefix: "platform"
    )
  end

  defp pending_global_pass_jobs do
    Repo.all(
      from(j in Oban.Job,
        where:
          j.worker == "ServiceRadar.NetworkDiscovery.TopologyGlobalPassWorker" and
            j.state in ["available", "scheduled"]
      ),
      prefix: "platform"
    )
  end

  defp mark_executing(%Oban.Job{id: id}) do
    Repo.update_all(
      from(j in Oban.Job, where: j.id == ^id),
      [set: [state: "executing", attempted_at: DateTime.utc_now(), attempt: 1]],
      prefix: "platform"
    )
  end

  defp reload_job(id), do: Repo.get!(Oban.Job, id, prefix: "platform")

  defp upsert_interface_alias(device_id, if_alias) do
    # discovered_interfaces.device_id references ocsf_devices. The projection
    # reads the interface row; the parent device is what makes that row legal.
    insert_device_type(device_id, "Switch")

    SQL.query!(
      Repo,
      """
      INSERT INTO platform.discovered_interfaces
        (timestamp, device_id, interface_uid, if_index, if_name, if_alias,
         classifications, classification_meta, classification_source)
      VALUES ($1, $2, 'eth0', 1, 'eth0', $3, '{}', '{}', 'rules')
      ON CONFLICT (device_id, interface_uid)
      DO UPDATE SET if_alias = EXCLUDED.if_alias, timestamp = EXCLUDED.timestamp, if_name = EXCLUDED.if_name
      """,
      [DateTime.utc_now(), device_id, if_alias]
    )
  end

  defp delete_interface(device_id) do
    SQL.query!(
      Repo,
      "DELETE FROM platform.discovered_interfaces WHERE device_id = $1",
      [device_id]
    )
  end

  # A committed link whose neighbor never resolved to an `sr:` identity: the
  # projection reads it and drops it.
  defp insert_unresolved_link(local_device_id) do
    SQL.query!(
      Repo,
      """
      INSERT INTO platform.mapper_topology_links (
        id, timestamp, created_at, local_device_id, neighbor_device_id,
        local_if_index, neighbor_port_id, protocol, neighbor_chassis_id, metadata
      )
      VALUES (gen_random_uuid(), $1, $1, $2, 'host01.example.com', 1, 'Gi0/1', 'LLDP',
              'aa:bb:cc:dd:ee:01', '{}')
      """,
      [DateTime.utc_now(), local_device_id]
    )
  end

  defp insert_device_type(uid, type) do
    SQL.query!(
      Repo,
      """
      INSERT INTO ocsf_devices (uid, type, name, hostname, created_time, modified_time)
      VALUES ($1, $2, $1, $1, NOW(), NOW())
      ON CONFLICT (uid) DO UPDATE SET type = EXCLUDED.type, modified_time = NOW()
      """,
      [uid, type]
    )
  end

  defp with_dgraph_url(dgraph_url) do
    previous_url = System.get_env("DGRAPH_URL")
    System.put_env("DGRAPH_URL", dgraph_url)

    on_exit(fn ->
      if previous_url,
        do: System.put_env("DGRAPH_URL", previous_url),
        else: System.delete_env("DGRAPH_URL")
    end)
  end
end
