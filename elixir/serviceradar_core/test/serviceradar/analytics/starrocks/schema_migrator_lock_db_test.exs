defmodule ServiceRadar.Analytics.StarRocks.SchemaMigratorLockDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Analytics.StarRocks.SchemaMigrator
  alias ServiceRadar.Repo

  @moduletag :integration

  # The migrator's advisory lock key. Every replica contends for this one value,
  # so it is a cross-replica contract rather than an implementation detail.
  @lock_key 7_203_950_114

  test "a replica waiting for the lock never queues on it, and takes it once the holder is done" do
    holder = hold_migration_lock_elsewhere!()
    sampler = sample_lock_waiters(1_200)

    spawn(fn ->
      Process.sleep(1_500)
      send(holder, :release)
    end)

    assert {:error, :stop_after_lock} = migrate_until_locked()
    assert_received {:under_lock, _sql}

    # While the holder had it, no session sat in the lock's wait queue: a
    # queued wait is a connection held idle for the holder's whole run.
    assert_receive {:waiters, ^sampler, samples}, 5_000
    assert samples != []
    assert Enum.all?(samples, &(&1 == 0))
  end

  test "a holder whose session dies releases the lock to the waiting replica" do
    holder = hold_migration_lock_elsewhere!()

    spawn(fn ->
      Process.sleep(1_500)
      send(holder, :crash)
    end)

    assert {:error, :stop_after_lock} = migrate_until_locked()
    assert_received {:under_lock, _sql}
  end

  # Runs the migrator against a warehouse that stops it at the first statement
  # it sends under the lock, which is enough to prove it got the lock.
  defp migrate_until_locked do
    parent = self()

    SchemaMigrator.migrate(
      database: "serviceradar",
      migrations: [],
      retention_days: [],
      sleep: &Process.sleep/1,
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
  end

  # Holds the lock the way another replica's migration does, on a connection
  # outside this test's sandbox. The returned process releases it on
  # `:release`, and on `:crash` kills the connection with the transaction open.
  defp hold_migration_lock_elsewhere! do
    conn = start_outside_sandbox!()
    parent = self()

    holder =
      spawn(fn ->
        Postgrex.transaction(conn, fn tx ->
          Postgrex.query!(tx, "SELECT pg_advisory_xact_lock($1)", [@lock_key])
          send(parent, {:lock_held, self()})

          receive do
            :release -> :ok
            :crash -> Process.exit(conn, :kill)
          after
            30_000 -> :ok
          end
        end)
      end)

    assert_receive {:lock_held, ^holder}, 10_000
    on_exit(fn -> if Process.alive?(holder), do: send(holder, :release) end)
    holder
  end

  # Counts, every 100ms for `window` ms, the sessions waiting in the lock's
  # queue. A bigint advisory key is recorded as its high and low 32 bits.
  defp sample_lock_waiters(window) do
    conn = start_outside_sandbox!()
    parent = self()

    spawn(fn ->
      samples =
        for _ <- 1..div(window, 100) do
          Process.sleep(100)

          %{rows: [[count]]} =
            Postgrex.query!(
              conn,
              "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted " <>
                "AND classid = $1 AND objid = $2 AND objsubid = 1",
              [div(@lock_key, 4_294_967_296), rem(@lock_key, 4_294_967_296)]
            )

          count
        end

      send(parent, {:waiters, self(), samples})
    end)
  end

  defp start_outside_sandbox! do
    config = Keyword.drop(Repo.config(), [:pool, :pool_size, :name])
    {:ok, conn} = Postgrex.start_link(Keyword.put(config, :pool_size, 1))
    Process.unlink(conn)
    on_exit(fn -> if Process.alive?(conn), do: GenServer.stop(conn) end)
    conn
  end
end
