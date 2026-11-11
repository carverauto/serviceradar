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
    %{task: holder} = start_transaction_lock_holder!(key)

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
    %{task: holder} = start_transaction_lock_holder!(key)

    assert [%{verdict: :unresolved, state: "idle in transaction"}] =
             held(AdvisoryLockLeaks.leaked(Repo, settle_timeout_ms: 100), key)

    send(holder, :commit)
    assert_receive {:committed, ^holder}
  end

  for {label, abort?, state} <- [
        {"idle in transaction", false, "idle in transaction"},
        {"idle in an aborted transaction", true, "idle in transaction (aborted)"}
      ] do
    test "a transaction lock on a client already #{label} is unresolved, never leaked, and gone once it ends",
         %{key: key} do
      %{task: task, backend: backend} =
        start_transaction_lock_holder!(key, abort: unquote(abort?))

      await_state!(backend, unquote(state))

      %{leaked: observed_leaked, in_flight: observed_in_flight} = AdvisoryLockLeaks.observe(Repo)
      while_open = held(AdvisoryLockLeaks.leaked(Repo, settle_timeout_ms: 100), key)

      assert [%{verdict: :unresolved, state: unquote(state)}] = while_open

      send(task, :commit)
      assert_receive {:committed, ^task}
      after_commit = held(AdvisoryLockLeaks.leaked(Repo), key)

      assert [] = after_commit

      verdicts =
        Enum.map(held(observed_leaked ++ observed_in_flight ++ while_open, key), & &1.verdict)

      refute :leaked in verdicts
    end
  end

  test "a lock released just before the settle deadline is not reported", %{key: key} do
    %{task: task} = start_transaction_lock_holder!(key)
    settle_timeout_ms = 1_000
    deadline = System.monotonic_time(:millisecond) + settle_timeout_ms

    check =
      Task.async(fn ->
        AdvisoryLockLeaks.leaked(Repo, settle_timeout_ms: settle_timeout_ms)
      end)

    Process.sleep(settle_timeout_ms - 100)
    send(task, :commit)
    assert_receive {:committed, ^task}
    assert System.monotonic_time(:millisecond) < deadline

    assert [] = held(Task.await(check, 30_000), key)
  end

  test "a lock whose holder disconnects between observations is not reported", %{key: key} do
    holder = start_transaction_lock_holder!(key)

    assert %{in_flight: in_flight} = AdvisoryLockLeaks.observe(Repo)
    assert [%{pid: backend}] = held(in_flight, key)
    assert backend == holder.backend

    Repo.query!("SELECT pg_terminate_backend($1)", [backend])

    assert [] = held(AdvisoryLockLeaks.leaked(Repo), key)
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

  defp start_transaction_lock_holder!(key, opts \\ []) do
    session = start_session!()
    test_pid = self()

    task =
      start_supervised!(
        {Task,
         fn ->
           Postgrex.transaction(session, fn conn ->
             %Postgrex.Result{rows: [[backend]]} =
               Postgrex.query!(conn, "SELECT pg_backend_pid()", [])

             Postgrex.query!(conn, "SELECT pg_advisory_xact_lock($1)", [key])

             if Keyword.get(opts, :abort, false) do
               {:error, %Postgrex.Error{}} = Postgrex.query(conn, "SELECT 1 / 0", [])
             end

             send(test_pid, {:locked, self(), backend})

             receive do
               :commit -> :ok
             end
           end)

           send(test_pid, {:committed, self()})
         end},
        id: make_ref()
      )

    assert_receive {:locked, ^task, backend}, 15_000
    %{task: task, backend: backend}
  end

  defp await_state!(backend, state, attempts \\ 250) do
    %Postgrex.Result{rows: rows} =
      Repo.query!("SELECT state FROM pg_stat_activity WHERE pid = $1", [backend])

    cond do
      rows == [[state]] ->
        :ok

      attempts == 0 ->
        flunk("backend #{backend} never reached #{inspect(state)}: #{inspect(rows)}")

      true ->
        Process.sleep(20)
        await_state!(backend, state, attempts - 1)
    end
  end
end
