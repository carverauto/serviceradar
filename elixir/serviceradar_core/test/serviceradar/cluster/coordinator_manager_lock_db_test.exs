defmodule ServiceRadar.Cluster.CoordinatorManagerLockDbTest do
  use ExUnit.Case, async: false

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
    config = Keyword.drop(Repo.config(), [:pool, :pool_size, :name])

    start_supervised!(
      {Postgrex, Keyword.put(config, :pool_size, 1)},
      id: System.unique_integer([:positive]),
      restart: :temporary
    )
  end
end
