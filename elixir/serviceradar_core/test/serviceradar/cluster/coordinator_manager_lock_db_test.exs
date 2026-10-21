defmodule ServiceRadar.Cluster.CoordinatorManagerLockDbTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Cluster.CoordinatorManager
  alias ServiceRadar.Repo

  @moduletag :integration

  # The coordinator's advisory lock key. Every core replica contends for this
  # one value, so it is a cross-replica contract rather than an implementation
  # detail.
  @lock_key 42_600_101

  # A dropped socket is reconnected inside the same connection process, and the
  # new session holds no lock. The leader heartbeat has to notice that, or the
  # old leader keeps running coordinator children next to the replica that took
  # the lock.
  test "a leader keeps its role only while its own session holds the lock" do
    holder = connect!()
    leader = leader_state(holder)

    assert [[true]] =
             Postgrex.query!(holder, "SELECT pg_try_advisory_lock($1)", [@lock_key]).rows

    assert {:noreply, %{leader?: true, conn: ^holder}} =
             CoordinatorManager.handle_info(:ensure_coordinator, leader)

    # A replica whose session lost the lock while another one took it.
    lost = connect!()

    assert {:noreply, demoted} =
             CoordinatorManager.handle_info(:ensure_coordinator, leader_state(lost))

    refute demoted.leader?
    assert demoted.conn == nil

    # The real holder is untouched by the other replica's demotion.
    assert [[true]] =
             Postgrex.query!(holder, "SELECT pg_advisory_unlock($1)", [@lock_key]).rows
  end

  test "a heartbeat whose query exceeds the old 5000 ms checkout bound once does not drop leadership" do
    holder = connect!()
    leader = leader_state(holder)

    assert [[true]] =
             Postgrex.query!(holder, "SELECT pg_try_advisory_lock($1)", [@lock_key]).rows

    Postgrex.query!(holder, "SET search_path = pg_temp, pg_catalog", [])
    Postgrex.query!(holder, "CREATE TEMP SEQUENCE heartbeat_call", [])

    Postgrex.query!(
      holder,
      """
      CREATE OR REPLACE FUNCTION pg_temp.heartbeat_gate()
      RETURNS boolean
      LANGUAGE plpgsql
      VOLATILE
      AS $$
      BEGIN
        IF nextval('pg_temp.heartbeat_call') = 1 THEN
          PERFORM pg_sleep(5.2);
        END IF;
        RETURN true;
      END;
      $$
      """,
      []
    )

    Postgrex.query!(
      holder,
      """
      CREATE TEMP VIEW pg_temp.pg_locks AS
        WITH gate AS MATERIALIZED (
          SELECT pg_temp.heartbeat_gate() AS ok
        )
        SELECT l.*
        FROM gate
        CROSS JOIN pg_catalog.pg_locks l
        WHERE gate.ok
      """,
      []
    )

    assert {:noreply, %{leader?: true, conn: ^holder}} =
             CoordinatorManager.handle_info(:ensure_coordinator, leader)

    assert [[1]] =
             Postgrex.query!(holder, "SELECT last_value FROM pg_temp.heartbeat_call", []).rows

    assert [[true]] =
             Postgrex.query!(holder, "SELECT pg_advisory_unlock($1)", [@lock_key]).rows
  end

  test "a heartbeat that fails once with a transient query error logs at warning and retries before demoting" do
    holder = connect!()
    leader = leader_state(holder)

    assert [[true]] =
             Postgrex.query!(holder, "SELECT pg_try_advisory_lock($1)", [@lock_key]).rows

    Postgrex.query!(holder, "SET search_path = pg_temp, pg_catalog", [])
    Postgrex.query!(holder, "CREATE TEMP SEQUENCE heartbeat_call", [])

    Postgrex.query!(
      holder,
      """
      CREATE OR REPLACE FUNCTION pg_temp.heartbeat_gate()
      RETURNS boolean
      LANGUAGE plpgsql
      VOLATILE
      AS $$
      BEGIN
        IF nextval('pg_temp.heartbeat_call') = 1 THEN
          RAISE EXCEPTION 'simulated transient heartbeat failure' USING ERRCODE = '57014';
        END IF;
        RETURN true;
      END;
      $$
      """,
      []
    )

    Postgrex.query!(
      holder,
      """
      CREATE TEMP VIEW pg_temp.pg_locks AS
        WITH gate AS MATERIALIZED (
          SELECT pg_temp.heartbeat_gate() AS ok
        )
        SELECT l.*
        FROM gate
        CROSS JOIN pg_catalog.pg_locks l
        WHERE gate.ok
      """,
      []
    )

    log =
      capture_log([level: :warning], fn ->
        assert {:noreply, %{leader?: true, conn: ^holder}} =
                 CoordinatorManager.handle_info(:ensure_coordinator, leader)
      end)

    assert log =~ "Coordinator lock heartbeat failed; retrying before demoting"

    assert [[2]] =
             Postgrex.query!(holder, "SELECT last_value FROM pg_temp.heartbeat_call", []).rows

    assert [[true]] =
             Postgrex.query!(holder, "SELECT pg_advisory_unlock($1)", [@lock_key]).rows
  end

  test "a heartbeat that fails on both the initial check and the retry demotes the leader" do
    holder = connect!()
    leader = leader_state(holder)

    assert [[true]] =
             Postgrex.query!(holder, "SELECT pg_try_advisory_lock($1)", [@lock_key]).rows

    Postgrex.query!(holder, "SET search_path = pg_temp, pg_catalog", [])

    Postgrex.query!(
      holder,
      """
      CREATE OR REPLACE FUNCTION pg_temp.heartbeat_gate()
      RETURNS boolean
      LANGUAGE plpgsql
      VOLATILE
      AS $$
      BEGIN
        RAISE EXCEPTION 'persistent heartbeat failure' USING ERRCODE = '57014';
      END;
      $$
      """,
      []
    )

    Postgrex.query!(
      holder,
      """
      CREATE TEMP VIEW pg_temp.pg_locks AS
        WITH gate AS MATERIALIZED (
          SELECT pg_temp.heartbeat_gate() AS ok
        )
        SELECT l.*
        FROM gate
        CROSS JOIN pg_catalog.pg_locks l
        WHERE gate.ok
      """,
      []
    )

    log =
      capture_log([level: :warning], fn ->
        assert {:noreply, demoted} =
                 CoordinatorManager.handle_info(:ensure_coordinator, leader)

        refute demoted.leader?
        assert demoted.conn == nil
      end)

    assert log =~ "Coordinator lock heartbeat failed; retrying before demoting"
    assert log =~ "Coordinator lock heartbeat failed"
  end

  defp leader_state(conn) do
    %{
      conn: conn,
      conn_mon: Process.monitor(conn),
      leader?: true,
      coordinator_child: nil,
      coordinator_child_mon: nil
    }
  end

  defp connect! do
    config =
      Repo.config()
      |> Keyword.drop([:pool, :pool_size, :name])
      |> CoordinatorManager.coordinator_connection_opts(nil)

    start_supervised!(
      {Postgrex, config},
      id: System.unique_integer([:positive]),
      restart: :temporary
    )
  end
end
