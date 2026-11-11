defmodule ServiceRadar.AdvisoryLockLeakCheckReleaseGateTest do
  @moduledoc """
  Qualifies the advisory-lock leak check the edge-record release gate relies on
  (`ServiceRadar.TestSupport.AdvisoryLockLeaks`), on the gate's own database:
  a session lock left on an idle connection must fail it, and a transaction
  lock held by a transaction that is still running must not.

  Run via `//elixir/serviceradar_core:large_ingestion_release_gate`.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.DirectSession
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.AdvisoryLockLeaks

  @moduletag :integration
  @moduletag :large_ingestion
  # Unboxed so the check runs outside a transaction, as it does in the gate. Nothing
  # here writes a row: every lock is held by a session that closes with the test.
  @moduletag sandbox: :unboxed

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    # Below 2^32, so pg_locks reports the bigint key as classid 0 and objid = key.
    {:ok, key: 1_947_000_000 + System.unique_integer([:positive])}
  end

  test "a session lock left on an idle connection is reported as leaked", %{key: key} do
    session = start_session!()
    Postgrex.query!(session, "SELECT pg_advisory_lock($1)", [key])

    assert [lock] = held(AdvisoryLockLeaks.leaked(Repo), key)

    assert %{verdict: :leaked, classid: 0, objsubid: 1, mode: "ExclusiveLock", state: "idle"} =
             lock

    assert lock.query =~ "pg_advisory_lock"
    assert AdvisoryLockLeaks.format([lock]) =~ "leaked pid=#{lock.pid} classid=0 objid=#{key}"

    # The same lock, already known, is left out; releasing it clears the report.
    assert [] = held(AdvisoryLockLeaks.leaked(Repo, ignore: [lock]), key)
    Postgrex.query!(session, "SELECT pg_advisory_unlock($1)", [key])
    assert [] = held(AdvisoryLockLeaks.leaked(Repo), key)
  end

  test "a session lock left on the checking connection itself is reported as leaked",
       %{key: key} do
    Repo.query!("SELECT pg_advisory_lock($1)", [key])

    try do
      assert [%{verdict: :leaked, objid: ^key}] = held(AdvisoryLockLeaks.leaked(Repo), key)
    after
      Repo.query!("SELECT pg_advisory_unlock($1)", [key])
    end

    assert [] = held(AdvisoryLockLeaks.leaked(Repo), key)
  end

  test "a transaction lock held by a running transaction is waited out, not reported",
       %{key: key} do
    holder = start_transaction_lock_holder!(key)

    # While the transaction is open the lock is a pg_locks row like any other, which is
    # what a bare count of advisory locks trips over.
    assert %{leaked: leaked, in_flight: in_flight} = AdvisoryLockLeaks.observe(Repo)
    assert [] = held(leaked, key)
    assert [%{verdict: :in_flight, state: "idle in transaction"}] = held(in_flight, key)

    Process.send_after(holder, :commit, 200)

    assert [] = held(AdvisoryLockLeaks.leaked(Repo), key)
    assert_receive {:committed, ^holder}
  end

  test "a lock whose transaction never ends is reported once the settle deadline passes",
       %{key: key} do
    holder = start_transaction_lock_holder!(key)

    assert [%{verdict: :unresolved, state: "idle in transaction"}] =
             held(AdvisoryLockLeaks.leaked(Repo, settle_timeout_ms: 100), key)

    send(holder, :commit)
    assert_receive {:committed, ^holder}
  end

  test "an observation inside a transaction is refused rather than answered from a stale snapshot" do
    assert_raise ArgumentError, ~r/cannot be observed inside a transaction/, fn ->
      Repo.transaction(fn -> AdvisoryLockLeaks.observe(Repo) end)
    end
  end

  defp held(locks, key), do: Enum.filter(locks, &(&1.objid == key))

  # A dedicated session: closing it ends the backend, which releases whatever it holds.
  defp start_session! do
    start_supervised!({Postgrex, DirectSession.connection_opts()}, id: make_ref())
  end

  defp start_transaction_lock_holder!(key) do
    session = start_session!()
    test_pid = self()

    holder =
      start_supervised!(
        {Task,
         fn ->
           Postgrex.transaction(session, fn conn ->
             Postgrex.query!(conn, "SELECT pg_advisory_xact_lock($1)", [key])
             send(test_pid, {:locked, self()})

             receive do
               :commit -> :ok
             end
           end)

           send(test_pid, {:committed, self()})
         end},
        id: make_ref()
      )

    assert_receive {:locked, ^holder}, 15_000
    holder
  end
end
