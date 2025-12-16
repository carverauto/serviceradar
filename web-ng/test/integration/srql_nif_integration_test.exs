if System.get_env("SRQL_INTEGRATION") != "1" do
  defmodule ServiceRadarWebNG.SRQLNifIntegrationTest do
    use ExUnit.Case, async: true

    @moduletag :skip

    test "set SRQL_INTEGRATION=1 to enable" do
      assert true
    end
  end
else
  defmodule ServiceRadarWebNG.SRQLNifIntegrationTest do
    use ExUnit.Case, async: false

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

      def create_pollers_table(conn) do
        sql = """
        CREATE TABLE IF NOT EXISTS pollers (
          poller_id text PRIMARY KEY,
          component_id text NULL,
          registration_source text NULL,
          status text NULL,
          spiffe_identity text NULL,
          first_registered timestamptz NULL,
          first_seen timestamptz NULL,
          last_seen timestamptz NULL,
          metadata jsonb NULL,
          created_by text NULL,
          is_healthy boolean NULL,
          agent_count int4 NULL,
          checker_count int4 NULL,
          updated_at timestamptz NULL
        )
        """

        Postgrex.query!(conn, sql, [])
      end

      def insert_poller(conn, poller_id) do
        now = DateTime.utc_now()

        sql = """
        INSERT INTO pollers (
          poller_id,
          component_id,
          registration_source,
          status,
          spiffe_identity,
          first_registered,
          first_seen,
          last_seen,
          metadata,
          created_by,
          is_healthy,
          agent_count,
          checker_count,
          updated_at
        ) VALUES (
          $1,
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
          $14
        )
        ON CONFLICT (poller_id) DO UPDATE SET
          component_id = excluded.component_id,
          registration_source = excluded.registration_source,
          status = excluded.status,
          spiffe_identity = excluded.spiffe_identity,
          first_registered = excluded.first_registered,
          first_seen = excluded.first_seen,
          last_seen = excluded.last_seen,
          metadata = excluded.metadata,
          created_by = excluded.created_by,
          is_healthy = excluded.is_healthy,
          agent_count = excluded.agent_count,
          checker_count = excluded.checker_count,
          updated_at = excluded.updated_at
        """

        Postgrex.query!(conn, sql, [
          poller_id,
          "srql-itest",
          "integration",
          "ready",
          "spiffe://example.test/poller",
          now,
          now,
          now,
          %{"integration" => true},
          "srql-nif-test",
          true,
          7,
          3,
          now
        ])
      end

      def delete_poller(conn, poller_id) do
        Postgrex.query!(conn, "DELETE FROM pollers WHERE poller_id = $1", [poller_id])
      end
    end

    setup_all do
      owner =
        Ecto.Adapters.SQL.Sandbox.start_owner!(ServiceRadarWebNG.Repo, shared: true)

      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

      conn = start_supervised!({Postgrex, PostgrexHelpers.connection_opts()})
      PostgrexHelpers.create_pollers_table(conn)

      poller_id = "srql-itest-" <> Ecto.UUID.generate()
      PostgrexHelpers.insert_poller(conn, poller_id)

      on_exit(fn ->
        if Process.alive?(conn) do
          try do
            PostgrexHelpers.delete_poller(conn, poller_id)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      {:ok, poller_id: poller_id}
    end

    test "translates SRQL pollers query via NIF", %{poller_id: poller_id} do
      query = "in:pollers poller_id:#{poller_id} is_healthy:true limit:5"

      assert {:ok, json} =
               ServiceRadarWebNG.SRQL.Native.translate(query, nil, nil, nil, nil)

      assert {:ok, %{"sql" => sql, "params" => params}} = Jason.decode(json)
      assert is_binary(sql)
      assert is_list(params)
    end

    test "executes SRQL pollers query via NIF", %{poller_id: poller_id} do
      query = "in:pollers poller_id:#{poller_id} is_healthy:true limit:5"

      assert {:ok, response} = ServiceRadarWebNG.SRQL.query(query)
      assert is_map(response)

      results = Map.get(response, "results")
      assert is_list(results)
      assert length(results) == 1

      poller = hd(results)
      assert poller["poller_id"] == poller_id
      assert poller["is_healthy"] == true
      assert poller["agent_count"] == 7
      assert poller["checker_count"] == 3
    end
  end
end
