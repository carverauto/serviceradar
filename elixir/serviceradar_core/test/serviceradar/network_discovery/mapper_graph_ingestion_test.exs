defmodule ServiceRadar.NetworkDiscovery.MapperGraphIngestionTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Ecto.Adapters.SQL
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
          {:skip, "Apache AGE graph #{graph_name} not available: #{inspect(reason)}"}
      end
    else
      {:skip, "Apache AGE is not available (ag_catalog.cypher missing)"}
    end
  end

  setup do
    cleanup_graph([
      "dev-1",
      "dev-2",
      "dev-1/eth0",
      "dev-1/unknown-local",
      "dev-2/Gi1/0/1",
      "dev-2/aa:bb:cc:dd:ee:ff"
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
        timestamp: now,
        created_at: now
      }
    ])

    [result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'dev-1\/eth0'})-[r:CONNECTS_TO]->(b:Interface {id:'dev-2\/Gi1\/0\/1'})
      RETURN {source: r.source} AS result/
      )

    assert result["source"] == "lldp"
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
        timestamp: now,
        created_at: now
      }
    ])

    [result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'dev-1\/ifindex:21'})-[r:CONNECTS_TO]->(b:Interface {id:'dev-2\/aa:bb:cc:dd:ee:ff'})
      RETURN {source: r.source} AS result/
      )

    assert result["source"] == "UniFi-API"
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

    cypher = "MATCH (n) WHERE n.id IN [#{quoted_ids}] DETACH DELETE n"

    _ =
      SQL.query(Repo, "SELECT * FROM ag_catalog.cypher($1, $$#{cypher}$$) AS (v agtype)", [
        graph_name()
      ])

    :ok
  end

  defp cypher_rows(cypher) do
    sql =
      "SELECT ag_catalog.agtype_to_text(result) FROM ag_catalog.cypher($1, $$#{cypher}$$) AS (result agtype)"

    case SQL.query(Repo, sql, [graph_name()]) do
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
end
