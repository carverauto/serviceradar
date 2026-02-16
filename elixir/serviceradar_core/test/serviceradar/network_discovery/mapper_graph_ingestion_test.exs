defmodule ServiceRadar.NetworkDiscovery.MapperGraphIngestionTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Ecto.Adapters.SQL
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor
  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()

    if age_available?() do
      graph_name = graph_name()

      case ensure_graph(graph_name) do
        :ok ->
          :ok

        {:error, reason} ->
          {:ok, skip: "Apache AGE graph #{graph_name} not available: #{inspect(reason)}"}
      end
    else
      {:ok, skip: "Apache AGE is not available (ag_catalog.cypher missing)"}
    end
  end

  setup do
    Application.put_env(:serviceradar_core, :mapper_topology_edge_stale_minutes, 180)

    cleanup_graph([
      "dev-1",
      "dev-2",
      "dev-3",
      "dev-router",
      "dev-switch-a",
      "dev-switch-b",
      "dev-ap",
      "dev-dist",
      "dev-1/eth0",
      "dev-1/eth2",
      "dev-1/unknown-local",
      "dev-2/Gi1/0/1",
      "dev-2/aa:bb:cc:dd:ee:ff",
      "dev-2/eth1",
      "dev-3/eth5",
      "dev-router/eth0",
      "dev-switch-a/uplink",
      "dev-switch-b/uplink",
      "dev-ap/wifi0",
      "dev-dist/xe-0/0/1"
    ])

    :ok
  end

  test "upsert_interfaces creates interface nodes and HAS_INTERFACE edges" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    TopologyGraph.upsert_interfaces([
      %{
        device_id: "dev-1",
        if_name: "eth0",
        if_index: 10,
        if_descr: "Uplink",
        if_alias: "uplink",
        if_phys_address: "AA:BB:CC:DD:EE:FF",
        ip_addresses: ["192.0.2.10"],
        created_at: now
      }
    ])

    [result] =
      cypher_rows(
        ~s/MATCH (d:Device {id:'dev-1'})-[:HAS_INTERFACE]->(i:Interface {id:'dev-1\/eth0'})
      RETURN {name: i.name, ifindex: i.ifindex, alias: i.alias, ip_addresses: i.ip_addresses} AS result/
      )

    assert result["name"] == "eth0"
    assert result["ifindex"] == 10
    assert result["alias"] == "uplink"
    assert result["ip_addresses"] == ["192.0.2.10"]
  end

  test "upsert_links creates CONNECTS_TO edges between interfaces" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    TopologyGraph.upsert_links([
      %{
        local_device_id: "dev-1",
        neighbor_device_id: "dev-2",
        local_if_name: "eth0",
        local_if_index: 10,
        neighbor_port_id: "Gi1/0/1",
        protocol: "lldp",
        metadata: %{"confidence_tier" => "high", "confidence_score" => 95},
        timestamp: now,
        created_at: now
      }
    ])

    [result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'dev-1\/eth0'})-[r:CONNECTS_TO]->(b:Interface {id:'dev-2\/Gi1\/0\/1'})
      RETURN {source: r.source, tier: r.confidence_tier, score: r.confidence_score} AS result/
      )

    assert result["source"] == "lldp"
    assert result["tier"] == "high"
    assert result["score"] == 95
  end

  test "upsert_links falls back when neighbor port metadata is missing" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    TopologyGraph.upsert_links([
      %{
        local_device_id: "dev-1",
        neighbor_device_id: "dev-2",
        local_if_index: 21,
        neighbor_chassis_id: "aa:bb:cc:dd:ee:ff",
        protocol: "UniFi-API",
        metadata: %{"confidence_tier" => "medium", "confidence_score" => 72},
        timestamp: now,
        created_at: now
      }
    ])

    [result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'dev-1\/ifindex:21'})-[r:CONNECTS_TO]->(b:Interface {id:'dev-2\/aa:bb:cc:dd:ee:ff'})
      RETURN {source: r.source, tier: r.confidence_tier} AS result/
      )

    assert result["source"] == "UniFi-API"
    assert result["tier"] == "medium"
  end

  test "upsert_links skips low-confidence links from AGE projection" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    TopologyGraph.upsert_links([
      %{
        local_device_id: "dev-1",
        neighbor_device_id: "dev-2",
        local_if_name: "eth0",
        neighbor_port_id: "eth1",
        protocol: "unknown",
        metadata: %{"confidence_tier" => "low", "confidence_score" => 20},
        timestamp: now,
        created_at: now
      }
    ])

    [result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'dev-1\/eth0'})-[r:CONNECTS_TO]->(b:Interface {id:'dev-2\/eth1'})
      RETURN {count: count(r)} AS result/
      )

    assert result["count"] == 0
  end

  test "upsert_links drops LLDP edges without a local interface index" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    TopologyGraph.upsert_links([
      %{
        local_device_id: "dev-1",
        neighbor_device_id: "dev-2",
        local_if_name: "eth0",
        local_if_index: nil,
        neighbor_port_id: "eth1",
        protocol: "lldp",
        metadata: %{"confidence_tier" => "high", "confidence_score" => 95},
        timestamp: now,
        created_at: now
      }
    ])

    [result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'dev-1\/eth0'})-[r:CONNECTS_TO]->(b:Interface {id:'dev-2\/eth1'})
      RETURN {count: count(r)} AS result/
      )

    assert result["count"] == 0
  end

  test "upsert_links keeps SNMP-L2 inferred edges without a local interface index" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    TopologyGraph.upsert_links([
      %{
        local_device_id: "dev-1",
        neighbor_device_id: "dev-2",
        local_if_name: "eth0",
        local_if_index: nil,
        neighbor_port_id: "eth1",
        protocol: "snmp-l2",
        metadata: %{"confidence_tier" => "medium", "confidence_score" => 72},
        timestamp: now,
        created_at: now
      }
    ])

    [result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'dev-1\/eth0'})-[r:CONNECTS_TO]->(b:Interface {id:'dev-2\/eth1'})
      RETURN {count: count(r), source: head(collect(r.source))} AS result/
      )

    assert result["count"] == 1
    assert result["source"] == "snmp-l2"
  end

  test "upsert_links keeps multiple resolved SNMP-L2 neighbors for one local device" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    TopologyGraph.upsert_links([
      %{
        local_device_id: "dev-1",
        neighbor_device_id: "dev-2",
        local_if_name: "eth0",
        local_if_index: nil,
        neighbor_port_id: "eth1",
        protocol: "snmp-l2",
        metadata: %{"confidence_tier" => "medium", "confidence_score" => 72},
        timestamp: now,
        created_at: now
      },
      %{
        local_device_id: "dev-1",
        neighbor_device_id: "dev-3",
        local_if_name: "eth0",
        local_if_index: nil,
        neighbor_port_id: "eth9",
        protocol: "snmp-l2",
        metadata: %{"confidence_tier" => "medium", "confidence_score" => 70},
        timestamp: now,
        created_at: now
      }
    ])

    [result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'dev-1\/eth0'})-[r:CONNECTS_TO]->(b:Interface) WHERE b.device_id IN ['dev-2','dev-3']
      RETURN {count: count(r)} AS result/
      )

    assert result["count"] == 2
  end

  test "upsert_links preserves UniFi direct neighbors when SNMP-L2 fallback is also present" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    TopologyGraph.upsert_links([
      %{
        local_device_id: "dev-1",
        neighbor_device_id: "dev-2",
        local_if_name: "eth0",
        local_if_index: 21,
        neighbor_port_id: "Gi1/0/1",
        protocol: "unifi-api",
        metadata: %{"confidence_tier" => "medium", "confidence_score" => 78},
        timestamp: now,
        created_at: now
      },
      %{
        local_device_id: "dev-1",
        neighbor_device_id: "dev-3",
        local_if_name: "eth0",
        local_if_index: 21,
        neighbor_port_id: "Gi1/0/2",
        protocol: "unifi-api",
        metadata: %{"confidence_tier" => "medium", "confidence_score" => 78},
        timestamp: now,
        created_at: now
      },
      %{
        local_device_id: "dev-1",
        neighbor_device_id: "dev-router",
        local_if_name: "eth0",
        local_if_index: 21,
        neighbor_port_id: "eth0",
        protocol: "snmp-l2",
        metadata: %{"confidence_tier" => "medium", "confidence_score" => 70},
        timestamp: now,
        created_at: now
      }
    ])

    [result] =
      cypher_rows(~s/MATCH (a:Interface {id:'dev-1\/eth0'})-[r:CONNECTS_TO]->(b:Interface)
      WHERE b.device_id IN ['dev-2', 'dev-3']
      RETURN {count: count(r), neighbors: collect(distinct b.device_id)} AS result/)

    assert result["count"] == 2
    assert Enum.sort(result["neighbors"]) == ["dev-2", "dev-3"]
  end

  test "upsert_links is idempotent and updates confidence metadata in place" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    later = DateTime.add(now, 30, :second)

    TopologyGraph.upsert_links([
      %{
        local_device_id: "dev-1",
        neighbor_device_id: "dev-2",
        local_if_name: "eth0",
        local_if_index: 10,
        neighbor_port_id: "eth1",
        protocol: "lldp",
        metadata: %{"confidence_tier" => "medium", "confidence_score" => 66},
        timestamp: now,
        created_at: now
      }
    ])

    TopologyGraph.upsert_links([
      %{
        local_device_id: "dev-1",
        neighbor_device_id: "dev-2",
        local_if_name: "eth0",
        local_if_index: 10,
        neighbor_port_id: "eth1",
        protocol: "lldp",
        metadata: %{"confidence_tier" => "high", "confidence_score" => 95},
        timestamp: later,
        created_at: later
      }
    ])

    [count_result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'dev-1\/eth0'})-[r:CONNECTS_TO]->(b:Interface {id:'dev-2\/eth1'})
      RETURN {count: count(r)} AS result/
      )

    [edge_result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'dev-1\/eth0'})-[r:CONNECTS_TO]->(b:Interface {id:'dev-2\/eth1'})
      RETURN {tier: r.confidence_tier, score: r.confidence_score, last: r.last_observed_at} AS result/
      )

    assert count_result["count"] == 1
    assert edge_result["tier"] == "high"
    assert edge_result["score"] == 95
    assert is_binary(edge_result["last"])
  end

  test "upsert_links prunes stale projected edges by observation timestamp" do
    Application.put_env(:serviceradar_core, :mapper_topology_edge_stale_minutes, 1)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    stale = DateTime.add(now, -10 * 60, :second)

    TopologyGraph.upsert_links([
      %{
        local_device_id: "dev-1",
        neighbor_device_id: "dev-2",
        local_if_name: "eth0",
        local_if_index: 10,
        neighbor_port_id: "eth1",
        protocol: "lldp",
        metadata: %{"confidence_tier" => "high", "confidence_score" => 95},
        timestamp: stale,
        created_at: stale
      }
    ])

    TopologyGraph.upsert_links([
      %{
        local_device_id: "dev-1",
        neighbor_device_id: "dev-3",
        local_if_name: "eth2",
        local_if_index: 12,
        neighbor_port_id: "eth5",
        protocol: "lldp",
        metadata: %{"confidence_tier" => "high", "confidence_score" => 95},
        timestamp: now,
        created_at: now
      }
    ])

    [stale_result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'dev-1\/eth0'})-[r:CONNECTS_TO]->(b:Interface {id:'dev-2\/eth1'})
      RETURN {count: count(r)} AS result/
      )

    [fresh_result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'dev-1\/eth2'})-[r:CONNECTS_TO]->(b:Interface {id:'dev-3\/eth5'})
      RETURN {count: count(r)} AS result/
      )

    assert stale_result["count"] == 0
    assert fresh_result["count"] == 1
  end

  test "synthetic topology replay projects expected farm01 and tonka01 connectivity" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    fixture = synthetic_topology_fixture(now)
    payload = Jason.encode!(fixture.links)

    assert :ok = MapperResultsIngestor.ingest_topology(payload, %{})

    [count_result] =
      cypher_rows(
        "MATCH (:Interface)-[r:CONNECTS_TO]->(:Interface) RETURN {count: count(r)} AS result"
      )

    assert count_result["count"] >= length(fixture.expected_edges)

    Enum.each(fixture.expected_edges, fn {from_id, to_id} ->
      [result] =
        cypher_rows(
          "MATCH (a:Interface {id:'#{from_id}'})-[r:CONNECTS_TO]->(b:Interface {id:'#{to_id}'}) RETURN {count: count(r)} AS result"
        )

      assert result["count"] == 1,
             "missing expected edge #{from_id} -> #{to_id}, got #{inspect(result)}"
    end)
  end

  test "router keeps one inferred uplink and prefers LLDP-corroborated switch neighbor" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert_device_type("dev-router", "Router")
    insert_device_type("dev-switch-a", "Switch")
    insert_device_type("dev-switch-b", "Switch")
    insert_device_type("dev-ap", "Access Point")
    insert_device_type("dev-dist", "Switch")

    TopologyGraph.upsert_links([
      %{
        local_device_id: "dev-router",
        neighbor_device_id: "dev-switch-a",
        local_if_name: "eth0",
        local_if_index: 28,
        neighbor_port_id: "uplink",
        protocol: "snmp-l2",
        metadata: %{"confidence_tier" => "low", "confidence_score" => 40},
        timestamp: now,
        created_at: now
      },
      %{
        local_device_id: "dev-router",
        neighbor_device_id: "dev-switch-b",
        local_if_name: "eth0",
        local_if_index: 28,
        neighbor_port_id: "uplink",
        protocol: "snmp-l2",
        metadata: %{"confidence_tier" => "low", "confidence_score" => 40},
        timestamp: now,
        created_at: now
      },
      %{
        local_device_id: "dev-router",
        neighbor_device_id: "dev-ap",
        local_if_name: "eth0",
        local_if_index: 28,
        neighbor_port_id: "wifi0",
        protocol: "snmp-l2",
        metadata: %{"confidence_tier" => "low", "confidence_score" => 40},
        timestamp: now,
        created_at: now
      },
      %{
        local_device_id: "dev-dist",
        neighbor_device_id: "dev-switch-a",
        local_if_name: "xe-0/0/1",
        local_if_index: 10,
        neighbor_port_id: "uplink",
        protocol: "lldp",
        metadata: %{"confidence_tier" => "high", "confidence_score" => 95},
        timestamp: now,
        created_at: now
      }
    ])

    [result] =
      cypher_rows(~s/MATCH (a:Interface)-[r:CONNECTS_TO]->(b:Interface)
      WHERE a.device_id = 'dev-router'
        AND b.device_id IN ['dev-switch-a', 'dev-switch-b', 'dev-ap']
      RETURN {count: count(r), neighbors: collect(distinct b.device_id)} AS result/)

    assert result["count"] == 1
    assert Enum.sort(result["neighbors"]) == ["dev-switch-a"]
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

  defp age_available? do
    with {:ok, %Postgrex.Result{rows: [[_]]}} <-
           SQL.query(Repo, "SELECT 1 FROM pg_namespace WHERE nspname = 'ag_catalog'", []),
         {:ok, %Postgrex.Result{rows: [[_]]}} <-
           SQL.query(
             Repo,
             """
             SELECT 1
             FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'ag_catalog' AND p.proname = 'cypher'
             LIMIT 1
             """,
             []
           ) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp ensure_graph(graph_name) do
    case SQL.query(Repo, "SELECT 1 FROM ag_catalog.ag_graph WHERE name = $1 LIMIT 1", [graph_name]) do
      {:ok, %Postgrex.Result{num_rows: 1}} ->
        :ok

      {:ok, _} ->
        case SQL.query(Repo, "SELECT ag_catalog.create_graph($1)", [graph_name]) do
          {:ok, _} -> :ok
          {:error, err} -> {:error, err}
        end

      {:error, err} ->
        {:error, err}
    end
  rescue
    err -> {:error, err}
  end

  defp cleanup_graph(ids) when is_list(ids) do
    quoted_ids = Enum.map_join(ids, ", ", &("'" <> &1 <> "'"))
    graph = graph_name() |> String.replace("'", "\\'")

    cypher = "MATCH (n) WHERE n.id IN [#{quoted_ids}] DETACH DELETE n"

    _ =
      SQL.query(
        Repo,
        "SELECT ag_catalog.agtype_to_text(v) FROM ag_catalog.cypher('#{graph}', $$#{cypher}$$) AS (v agtype)",
        []
      )

    :ok
  end

  defp cypher_rows(cypher) do
    graph = graph_name() |> String.replace("'", "\\'")

    sql = """
    SELECT ag_catalog.agtype_to_text(result)
    FROM ag_catalog.cypher('#{graph}', $$#{cypher}$$) AS (result agtype)
    """

    case SQL.query(Repo, sql, []) do
      {:ok, %Postgrex.Result{rows: rows}} ->
        Enum.map(rows, fn
          [text_value] when is_binary(text_value) -> decode_agtype(text_value)
          row -> row
        end)

      {:error, error} ->
        raise "cypher query failed: #{inspect(error)}"
    end
  end

  defp decode_agtype(text_value) do
    case Jason.decode(text_value) do
      {:ok, parsed} -> parsed
      {:error, _} -> text_value
    end
  end

  defp graph_name do
    Application.get_env(:serviceradar_core, :age_graph_name, "platform_graph")
  end

  defp synthetic_topology_fixture(now) do
    links = [
      synthetic_link(
        "sr:farm01",
        "sr:uswagg",
        "lan-core",
        "port-1",
        "198.18.1.1",
        "198.18.1.87",
        "USWAggregation",
        now
      ),
      synthetic_link(
        "sr:uswagg",
        "sr:usw16poe",
        "port-10",
        "port-1",
        "198.18.1.87",
        "198.18.1.138",
        "USW16PoE",
        now
      ),
      synthetic_link(
        "sr:uswagg",
        "sr:uswpro24-a",
        "port-31",
        "port-1",
        "198.18.1.87",
        "198.18.1.131",
        "USWPro24-A",
        now
      ),
      synthetic_link(
        "sr:uswagg",
        "sr:uswpro24-b",
        "port-35",
        "port-1",
        "198.18.1.87",
        "198.18.1.195",
        "USWPro24-B",
        now
      ),
      synthetic_link(
        "sr:usw16poe",
        "sr:u6lr",
        "port-5",
        "eth0",
        "198.18.1.138",
        "198.18.1.130",
        "U6LR",
        now
      ),
      synthetic_link(
        "sr:usw16poe",
        "sr:u6mesh-16",
        "port-6",
        "eth0",
        "198.18.1.138",
        "198.18.1.16",
        "U6Mesh-16",
        now
      ),
      synthetic_link(
        "sr:usw16poe",
        "sr:uswlite8",
        "port-7",
        "port-1",
        "198.18.1.138",
        "198.18.1.238",
        "USWLite8PoE",
        now
      ),
      synthetic_link(
        "sr:usw16poe",
        "sr:u6mesh-96",
        "port-8",
        "eth0",
        "198.18.1.138",
        "198.18.1.96",
        "U6Mesh-96",
        now
      ),
      synthetic_link(
        "sr:uswlite8",
        "sr:u6mesh-200",
        "port-2",
        "eth0",
        "198.18.1.238",
        "198.18.1.200",
        "U6Mesh-200",
        now
      ),
      synthetic_link(
        "sr:uswpro24-b",
        "sr:nanohd",
        "port-22",
        "eth0",
        "198.18.1.195",
        "198.18.1.233",
        "NanoHD",
        now
      ),
      synthetic_link(
        "sr:tonka01",
        "sr:aruba-10-154",
        "lan10",
        "uplink",
        "198.18.10.1",
        "198.18.10.154",
        "ArubaSwitch",
        now
      ),
      synthetic_link(
        "sr:aruba-10-154",
        "sr:endpoint-10-96",
        "port-5",
        "eth0",
        "198.18.10.154",
        "198.18.10.96",
        "Endpoint-10-96",
        now
      )
    ]

    expected_edges =
      Enum.map(links, fn link ->
        {"#{link["local_device_id"]}/#{link["local_if_name"]}",
         "#{link["neighbor_device_id"]}/#{link["neighbor_port_id"]}"}
      end)

    %{links: links, expected_edges: expected_edges}
  end

  defp synthetic_link(
         local_id,
         neighbor_id,
         local_if,
         neighbor_port,
         local_ip,
         neighbor_ip,
         neighbor_name,
         now
       ) do
    %{
      "protocol" => "LLDP",
      "agent_id" => "agent-dusk",
      "gateway_id" => "agent-dusk",
      "partition" => "default",
      "local_device_id" => local_id,
      "local_device_ip" => local_ip,
      "local_if_name" => local_if,
      "local_if_index" => synthetic_ifindex(local_if),
      "neighbor_device_id" => neighbor_id,
      "neighbor_port_id" => neighbor_port,
      "neighbor_system_name" => neighbor_name,
      "neighbor_mgmt_addr" => neighbor_ip,
      "metadata" => %{"source" => "synthetic-fixture"},
      "timestamp" => now
    }
  end

  defp synthetic_ifindex(name) when is_binary(name) do
    case Regex.run(~r/(\d+)/, name, capture: :all_but_first) do
      [digits] ->
        case Integer.parse(digits) do
          {value, ""} when value > 0 -> value
          _ -> 1
        end

      _ ->
        :erlang.phash2(name, 4_094) + 1
    end
  end

  defp synthetic_ifindex(_), do: 1
end
