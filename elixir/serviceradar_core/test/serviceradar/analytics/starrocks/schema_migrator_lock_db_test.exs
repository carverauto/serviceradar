defmodule ServiceRadar.Analytics.StarRocks.SchemaMigratorLockDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Analytics.StarRocks.SchemaMigrator
  alias ServiceRadar.Repo

  @moduletag :integration

  # The migrator's advisory lock key. Every replica contends for this one value,
  # so it is a cross-replica contract rather than an implementation detail.
  @lock_key 7_203_950_114

  test "waiting for the migration lock outlasts the session's statement_timeout" do
    release = hold_migration_lock_elsewhere!()

    # A role or database statement_timeout, as a deployment may set one. Without
    # the migrator lifting it, the lock wait is cancelled as query_canceled.
    Repo.query!("SET statement_timeout = '300ms'")

    parent = self()

    spawn(fn ->
      Process.sleep(1_500)
      release.()
      send(parent, :released)
    end)

    started = System.monotonic_time(:millisecond)

    result =
      SchemaMigrator.migrate(
        database: "serviceradar",
        migrations: [],
        retention_days: [],
        sleep: fn _ms -> :ok end,
        query: fn
          "SHOW BACKENDS" ->
            {:ok, %{columns: ["BackendId", "Alive"], rows: [[1, "true"]]}}

          "SHOW COMPUTE NODES" ->
            {:ok, %{columns: ["ComputeNodeId", "Alive"], rows: []}}

          sql ->
            send(parent, {:under_lock, sql})
            {:error, :stop_after_lock}
        end
      )

    waited = System.monotonic_time(:millisecond) - started

    refute match?({:error, %Postgrex.Error{}}, result)
    assert {:error, :stop_after_lock} = result
    assert_received {:under_lock, _sql}
    assert_receive :released, 5_000
    # It really waited for the holder, well past the 300ms timeout.
    assert waited >= 1_000
  end

  # Holds the lock the way another replica's rebuild does, on a connection
  # outside this test's sandbox. Returns the function that releases it.
  defp hold_migration_lock_elsewhere! do
    config = Keyword.drop(Repo.config(), [:pool, :pool_size, :name])
    {:ok, conn} = Postgrex.start_link(Keyword.put(config, :pool_size, 1))
    parent = self()

    holder =
      spawn(fn ->
        Postgrex.transaction(conn, fn tx ->
          Postgrex.query!(tx, "SELECT pg_advisory_xact_lock($1)", [@lock_key])
          send(parent, {:lock_held, self()})

          receive do
            :release -> :ok
          after
            30_000 -> :ok
          end
        end)

        GenServer.stop(conn)
      end)

    assert_receive {:lock_held, ^holder}, 10_000
    on_exit(fn -> if Process.alive?(holder), do: send(holder, :release) end)

    fn -> send(holder, :release) end
  end
end
