if System.get_env("SRQL_INTEGRATION") != "1" do
  defmodule ServiceRadarWebNG.GraphCypherIntegrationTest do
    use ExUnit.Case, async: true

    @moduletag :skip

    test "set SRQL_INTEGRATION=1 to enable" do
      assert true
    end
  end
else
  defmodule ServiceRadarWebNG.GraphCypherIntegrationTest do
    use ExUnit.Case, async: false

    alias ServiceRadarWebNGWeb.Dashboard.Plugins.Topology

    @graph_name "serviceradar"

    defmodule PostgrexHelpers do
      @moduledoc false

      def connection_opts do
        config = ServiceRadarWebNG.Repo.config()

        ssl =
          case Keyword.get(config, :ssl, false) do
            false -> false
            true -> true
            ssl_opts when is_list(ssl_opts) -> {:opts, ssl_opts}
          end

        base = [
          hostname: Keyword.get(config, :hostname, "localhost"),
          username: Keyword.get(config, :username, "postgres"),
          password: Keyword.get(config, :password),
          database: Keyword.get(config, :database),
          port: Keyword.get(config, :port, 5432)
        ]

        case ssl do
          false -> base
          true -> Keyword.put(base, :ssl, true)
          {:opts, ssl_opts} -> base |> Keyword.put(:ssl, true) |> Keyword.put(:ssl_opts, ssl_opts)
        end
      end

      def age_available?(conn) do
        with {:ok, %Postgrex.Result{rows: [[_]]}} <-
               Postgrex.query(conn, "SELECT 1 FROM pg_namespace WHERE nspname = 'ag_catalog'", []),
             {:ok, %Postgrex.Result{rows: [[_]]}} <-
               Postgrex.query(
                 conn,
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

      def ensure_graph(conn, graph_name) do
        existing =
          Postgrex.query(
            conn,
            "SELECT 1 FROM ag_catalog.ag_graph WHERE name = $1 LIMIT 1",
            [graph_name]
          )

        case existing do
          {:ok, %Postgrex.Result{num_rows: 1}} ->
            :ok

          {:ok, _} ->
            case Postgrex.query(conn, "SELECT ag_catalog.create_graph($1)", [graph_name]) do
              {:ok, _} -> :ok
              {:error, err} -> {:error, err}
            end

          {:error, err} ->
            {:error, err}
        end
      rescue
        err -> {:error, err}
      end
    end

    setup_all do
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(ServiceRadarWebNG.Repo, shared: true)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

      conn = start_supervised!({Postgrex, PostgrexHelpers.connection_opts()})

      if not PostgrexHelpers.age_available?(conn) do
        {:skip, "Apache AGE is not available (ag_catalog.cypher missing)"}
      else
        case PostgrexHelpers.ensure_graph(conn, @graph_name) do
          :ok ->
            :ok

          {:error, err} ->
            {:skip, "Apache AGE graph #{@graph_name} not available: #{inspect(err)}"}
        end
      end
    end

    test "graph_cypher passthrough supports explicit nodes/edges payload" do
      query = ~s(in:graph_cypher cypher:"RETURN {nodes: [], edges: []} AS result" limit:5)
      assert {:ok, %{"results" => [payload]}} = ServiceRadarWebNG.SRQL.query(query)

      assert is_map(payload)
      assert Map.get(payload, "nodes") == []
      assert Map.get(payload, "edges") == []
      assert Topology.supports?(%{"results" => [payload]})
    end

    test "graph_cypher wraps node rows into nodes/edges" do
      query = ~s(in:graph_cypher cypher:"RETURN {id: 'n1', label: 'Node'} AS result" limit:5)
      assert {:ok, %{"results" => [payload]}} = ServiceRadarWebNG.SRQL.query(query)

      assert is_map(payload)
      assert [%{"id" => "n1"} | _] = Map.get(payload, "nodes")
      assert Map.get(payload, "edges") == []
      assert Topology.supports?(%{"results" => [payload]})
    end

    test "graph_cypher wraps edge rows into nodes/edges" do
      query =
        ~s(in:graph_cypher cypher:"RETURN {start_id: 'n1', end_id: 'n2', type: 'links_to'} AS result" limit:5)

      assert {:ok, %{"results" => [payload]}} = ServiceRadarWebNG.SRQL.query(query)

      assert is_map(payload)
      nodes = Map.get(payload, "nodes")
      edges = Map.get(payload, "edges")

      assert is_list(nodes)
      assert is_list(edges)
      assert Enum.any?(nodes, &(&1["id"] == "n1"))
      assert Enum.any?(nodes, &(&1["id"] == "n2"))
      assert [%{"start_id" => "n1", "end_id" => "n2"} | _] = edges
      assert Topology.supports?(%{"results" => [payload]})
    end
  end
end
