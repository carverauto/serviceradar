defmodule ServiceRadar.Observability.MtrGraphIntegrationTest do
  @moduledoc """
  Integration tests for MTR graph projection into Apache AGE.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Observability.MtrGraph
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @test_node_ids [
    "mtr:10.0.0.1",
    "mtr:203.0.113.1",
    "mtr:8.8.8.8",
    "mtr:192.0.2.10",
    "mtr:198.51.100.1"
  ]

  setup_all do
    TestSupport.start_core!()

    if age_available?() do
      case ensure_graph(graph_name()) do
        :ok ->
          :ok

        {:error, reason} ->
          {:ok, skip: "Apache AGE graph not available: #{inspect(reason)}"}
      end
    else
      {:ok, skip: "Apache AGE is not available"}
    end
  end

  setup context do
    case context[:skip] do
      nil -> :ok
      reason -> {:skip, reason}
    end
  end

  setup do
    cleanup_graph(@test_node_ids)
    :ok
  end

  test "project_traces creates MtrHop vertices and MTR_PATH edges" do
    results = [
      %{
        "trace" => %{
          "hops" => [
            %{
              "hop_number" => 1,
              "addr" => "10.0.0.1",
              "hostname" => "gw.local",
              "asn" => %{"asn" => 64_512, "org" => "Test-AS"},
              "avg_us" => 480,
              "loss_pct" => 0.0,
              "jitter_us" => 20
            },
            %{
              "hop_number" => 2,
              "addr" => "203.0.113.1",
              "hostname" => "transit.example",
              "avg_us" => 12_000,
              "loss_pct" => 10.0,
              "jitter_us" => 500
            },
            %{
              "hop_number" => 3,
              "addr" => "8.8.8.8",
              "hostname" => "dns.google",
              "avg_us" => 15_000,
              "loss_pct" => 0.0,
              "jitter_us" => 100
            }
          ]
        }
      }
    ]

    status = %{agent_id: "test-agent-mtr"}

    MtrGraph.project_traces(results, status)

    # Verify edge from hop 1 -> hop 2
    [edge_1_2] =
      cypher_rows(
        "MATCH (a:MtrHop {id:'mtr:10.0.0.1'})-[r:MTR_PATH]->(b:MtrHop {id:'mtr:203.0.113.1'}) " <>
          "RETURN {count: count(r), avg_us: r.avg_us, loss_pct: r.loss_pct} AS result"
      )

    assert edge_1_2["count"] == 1
    assert edge_1_2["avg_us"] == 12_000
    assert edge_1_2["loss_pct"] == 10.0

    # Verify edge from hop 2 -> hop 3
    [edge_2_3] =
      cypher_rows(
        "MATCH (a:MtrHop {id:'mtr:203.0.113.1'})-[r:MTR_PATH]->(b:MtrHop {id:'mtr:8.8.8.8'}) " <>
          "RETURN {count: count(r), avg_us: r.avg_us, agent_id: r.agent_id} AS result"
      )

    assert edge_2_3["count"] == 1
    assert edge_2_3["avg_us"] == 15_000
    assert edge_2_3["agent_id"] == "test-agent-mtr"

    # Verify node properties
    [node] =
      cypher_rows(
        "MATCH (n:MtrHop {id:'mtr:10.0.0.1'}) " <>
          "RETURN {addr: n.addr, hostname: n.hostname} AS result"
      )

    assert node["addr"] == "10.0.0.1"
    assert node["hostname"] == "gw.local"
  end

  test "project_traces is idempotent (MERGE semantics)" do
    results = [
      %{
        "trace" => %{
          "hops" => [
            %{"hop_number" => 1, "addr" => "10.0.0.1", "avg_us" => 480, "loss_pct" => 0.0},
            %{"hop_number" => 2, "addr" => "203.0.113.1", "avg_us" => 12_000, "loss_pct" => 5.0}
          ]
        }
      }
    ]

    status = %{agent_id: "test-agent-idem"}

    # Call twice
    MtrGraph.project_traces(results, status)
    MtrGraph.project_traces(results, status)

    # Should still be exactly 1 edge
    [result] =
      cypher_rows(
        "MATCH (a:MtrHop {id:'mtr:10.0.0.1'})-[r:MTR_PATH]->(b:MtrHop {id:'mtr:203.0.113.1'}) " <>
          "RETURN {count: count(r)} AS result"
      )

    assert result["count"] == 1
  end

  test "project_traces skips traces with fewer than 2 responding hops" do
    results = [
      %{
        "trace" => %{
          "hops" => [
            %{"hop_number" => 1, "addr" => "192.0.2.10", "avg_us" => 100}
          ]
        }
      }
    ]

    MtrGraph.project_traces(results, %{agent_id: "test-agent-single"})

    # No edges should exist
    rows =
      cypher_rows(
        "MATCH (a:MtrHop {id:'mtr:192.0.2.10'})-[r:MTR_PATH]->() " <>
          "RETURN {count: count(r)} AS result"
      )

    case rows do
      [] -> assert true
      [result] -> assert result["count"] == 0
    end
  end

  test "project_traces skips non-responding hops (nil/empty addr)" do
    results = [
      %{
        "trace" => %{
          "hops" => [
            %{"hop_number" => 1, "addr" => "10.0.0.1", "avg_us" => 480},
            %{"hop_number" => 2, "addr" => nil, "avg_us" => 0},
            %{"hop_number" => 3, "addr" => "", "avg_us" => 0},
            %{"hop_number" => 4, "addr" => "8.8.8.8", "avg_us" => 15_000}
          ]
        }
      }
    ]

    MtrGraph.project_traces(results, %{agent_id: "test-agent-gaps"})

    # Only responding hops create edges: hop1 -> hop4 (skipping nil/empty)
    [result] =
      cypher_rows(
        "MATCH (a:MtrHop {id:'mtr:10.0.0.1'})-[r:MTR_PATH]->(b:MtrHop {id:'mtr:8.8.8.8'}) " <>
          "RETURN {count: count(r)} AS result"
      )

    assert result["count"] == 1
  end

  test "prune_stale_edges removes MTR_PATH edges older than cutoff" do
    results = [
      %{
        "trace" => %{
          "hops" => [
            %{"hop_number" => 1, "addr" => "198.51.100.1", "avg_us" => 100},
            %{"hop_number" => 2, "addr" => "8.8.8.8", "avg_us" => 200}
          ]
        }
      }
    ]

    MtrGraph.project_traces(results, %{agent_id: "test-agent-prune"})

    # Confirm edge exists
    [before] =
      cypher_rows(
        "MATCH (a:MtrHop {id:'mtr:198.51.100.1'})-[r:MTR_PATH]->(b:MtrHop {id:'mtr:8.8.8.8'}) " <>
          "RETURN {count: count(r)} AS result"
      )

    assert before["count"] == 1

    # Backdate the edge's last_observed_at to 48 hours ago
    old_time =
      DateTime.utc_now()
      |> DateTime.add(-48 * 3600, :second)
      |> DateTime.to_iso8601()

    graph = graph_name() |> String.replace("'", "\\'")

    SQL.query(
      Repo,
      """
      SELECT ag_catalog.agtype_to_text(v)
      FROM ag_catalog.cypher('#{graph}',
        $$MATCH (a:MtrHop {id:'mtr:198.51.100.1'})-[r:MTR_PATH]->(b:MtrHop {id:'mtr:8.8.8.8'})
          SET r.last_observed_at = '#{old_time}'$$
      ) AS (v agtype)
      """,
      []
    )

    # Prune with default 24h cutoff
    MtrGraph.prune_stale_edges()

    # Edge should be gone
    rows =
      cypher_rows(
        "MATCH (a:MtrHop {id:'mtr:198.51.100.1'})-[r:MTR_PATH]->(b:MtrHop {id:'mtr:8.8.8.8'}) " <>
          "RETURN {count: count(r)} AS result"
      )

    case rows do
      [] -> assert true
      [after_prune] -> assert after_prune["count"] == 0
    end
  end

  # -- Helpers --

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

  defp ensure_graph(name) do
    case SQL.query(Repo, "SELECT 1 FROM ag_catalog.ag_graph WHERE name = $1 LIMIT 1", [name]) do
      {:ok, %Postgrex.Result{num_rows: 1}} ->
        :ok

      {:ok, _} ->
        case SQL.query(Repo, "SELECT ag_catalog.create_graph($1)", [name]) do
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
        Enum.map(rows, &decode_cypher_row/1)

      {:error, error} ->
        raise "cypher query failed: #{inspect(error)}"
    end
  end

  defp decode_cypher_row([text_value]) when is_binary(text_value) do
    case Jason.decode(text_value) do
      {:ok, parsed} -> parsed
      {:error, _} -> text_value
    end
  end

  defp decode_cypher_row(row), do: row

  defp graph_name do
    Application.get_env(:serviceradar_core, :age_graph_name, "platform_graph")
  end
end
