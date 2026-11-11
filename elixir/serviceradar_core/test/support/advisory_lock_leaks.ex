defmodule ServiceRadar.TestSupport.AdvisoryLockLeaks do
  @poll_interval_ms 20

  @moduledoc """
  Finds advisory locks that client sessions of the current database left behind.

  A leaked advisory lock is a session-level lock still held by a session that
  has no transaction open. That is what a session lock taken through a pooled
  connection looks like once the caller has moved on: the backend sits idle in
  the pool and keeps the lock until it disconnects.

  Counting the rows of `pg_locks` does not test that. A transaction-level
  advisory lock is a row there too for as long as its transaction runs, so a
  count taken while any other process is inside such a transaction reports a
  lock that is released a few milliseconds later.

  `pg_locks` does not say whether a lock is session-level or
  transaction-level, so each observation reads `pg_stat_activity`, then
  `pg_locks`, then `pg_stat_activity` again, and classifies every granted
  advisory lock in the current database by its holder across the three reads:

  | Observation                                                              | Verdict                  |
  | ------------------------------------------------------------------------ | ------------------------ |
  | client backend, state exactly `idle` in both reads, `state_change` same  | `:leaked`                |
  | the checking session itself                                              | `:leaked`                |
  | client backend in any other state, or changed, started or was replaced   | `:in_flight`             |
  | holder has no activity row, or the lock has no pid (prepared xact)       | `:in_flight`             |
  | holder is not a client backend (TimescaleDB workers, scheduler)          | not reported             |
  | a later read of `pg_locks` no longer lists the lock                      | gone, not reported       |
  | `:in_flight` at the deadline, still listed by a final `pg_locks` read    | `:unresolved`, a failure |

  A holder's backend type is taken from the second activity read, or from the
  first when the second has no row for it; a holder with no row in either read
  is `:in_flight`.

  "Any other state" includes `idle in transaction`, `idle in transaction
  (aborted)`, `active`, `fastpath function call` and `disabled`.
  A session in `idle in transaction (aborted)` has already released its
  transaction-level locks, so a lock it still holds is session-level, but it
  cannot be told apart until the transaction ends.

  An idle holder had no transaction open at any point between the reads, so
  its lock cannot be transaction-level. The checking session's lock is leaked
  for the same reason: each statement runs in a transaction of its own, so a
  lock that session already holds was not taken by any of them. A missing
  activity row never makes a lock `:leaked`.

  `leaked/2` repeats the observation every #{@poll_interval_ms} ms while any
  lock is `:in_flight`. Each repeat re-reads `pg_locks`, so a lock that is no
  longer granted is gone and not reported. Once the settle deadline passes,
  one final `pg_locks` read drops the in-flight locks released meanwhile; the
  rest are returned as `:unresolved`, a failure, and each diagnostic line shows
  the holder's state or that it had no activity row.

  Call it outside a transaction, from a test tagged `sandbox: :unboxed`. Inside
  one, PostgreSQL answers both activity reads from a single cached snapshot and
  nothing can be classified, so the observation raises instead.
  """

  @default_settle_timeout_ms 30_000

  @activity_sql """
  SELECT pid, pid = pg_backend_pid(), backend_start, backend_type, state, state_change,
         xact_start, application_name, left(query, 300)
  FROM pg_stat_activity
  WHERE datname = current_database()
  """

  # The columns of @activity_sql after pid, in order.
  @activity_fields [
    :self?,
    :backend_start,
    :backend_type,
    :state,
    :state_change,
    :xact_start,
    :application_name,
    :query
  ]

  @locks_sql """
  SELECT pid, classid::bigint, objid::bigint, objsubid::integer, mode
  FROM pg_locks
  WHERE locktype = 'advisory'
    AND granted
    AND database = (SELECT oid FROM pg_database WHERE datname = current_database())
  ORDER BY pid, classid, objid, objsubid, mode
  """

  @type lock :: %{
          verdict: :leaked | :in_flight | :unresolved,
          pid: integer() | nil,
          activity_row?: boolean(),
          classid: integer(),
          objid: integer(),
          objsubid: integer(),
          mode: String.t(),
          backend_start: DateTime.t() | nil,
          state: String.t() | nil,
          state_change: DateTime.t() | nil,
          xact_start: DateTime.t() | nil,
          application_name: String.t() | nil,
          query: String.t() | nil
        }

  @doc """
  Returns the advisory locks left behind in the current database, waiting for
  in-flight transactions to finish first. An empty list means none.

  Options:

    * `:ignore` - locks returned by an earlier call, to leave out. A lock is
      the same lock when the same session still holds the same key in the same
      mode.
    * `:settle_timeout_ms` - how long to wait for in-flight locks to resolve
      before reporting them as `:unresolved`. Defaults to
      #{@default_settle_timeout_ms} ms.
    * `:before_final_read` - a zero-arity function called once the deadline
      has passed with locks still in flight, before the final `pg_locks` read
      that decides which of them are `:unresolved`. Not called otherwise.
      Defaults to a no-op; tests use it to change the database at that point.
  """
  @spec leaked(module(), keyword()) :: [lock()]
  def leaked(repo, opts \\ []) do
    ignore = Keyword.get(opts, :ignore, [])
    timeout = Keyword.get(opts, :settle_timeout_ms, @default_settle_timeout_ms)
    before_final_read = Keyword.get(opts, :before_final_read, fn -> :ok end)
    deadline = System.monotonic_time(:millisecond) + timeout
    settle(repo, ignore, deadline, before_final_read)
  end

  @doc """
  Classifies the advisory locks held at one instant, without waiting.

  Options: `:ignore`, as for `leaked/2`.
  """
  @spec observe(module(), keyword()) :: %{leaked: [lock()], in_flight: [lock()]}
  def observe(repo, opts \\ []) do
    ignored = opts |> Keyword.get(:ignore, []) |> MapSet.new(&identity/1)

    before = activity(repo)
    lock_rows = lock_rows(repo)
    later = activity(repo)
    reject_enclosing_transaction!(before, later)

    locks =
      lock_rows
      |> Enum.map(&classify(&1, before, later))
      |> Enum.reject(&(is_nil(&1) or MapSet.member?(ignored, identity(&1))))

    %{
      leaked: Enum.filter(locks, &(&1.verdict == :leaked)),
      in_flight: Enum.filter(locks, &(&1.verdict == :in_flight))
    }
  end

  @doc "Renders locks for an assertion message, one line per lock."
  @spec format([lock()]) :: String.t()
  def format(locks) do
    Enum.join(
      ["advisory locks left behind (#{length(locks)}):" | Enum.map(locks, &format_lock/1)],
      "\n"
    )
  end

  defp settle(repo, ignore, deadline, before_final_read) do
    %{leaked: leaked, in_flight: in_flight} = observe(repo, ignore: ignore)

    cond do
      in_flight == [] ->
        leaked

      System.monotonic_time(:millisecond) >= deadline ->
        before_final_read.()
        leaked ++ Enum.map(still_granted(repo, in_flight), &%{&1 | verdict: :unresolved})

      true ->
        Process.sleep(@poll_interval_ms)
        settle(repo, ignore, deadline, before_final_read)
    end
  end

  defp still_granted(repo, locks) do
    granted = repo |> lock_rows() |> MapSet.new(&List.to_tuple/1)
    Enum.filter(locks, &MapSet.member?(granted, granted_key(&1)))
  end

  defp granted_key(lock), do: {lock.pid, lock.classid, lock.objid, lock.objsubid, lock.mode}

  defp lock_rows(repo) do
    %Postgrex.Result{rows: rows} = repo.query!(@locks_sql, [])
    rows
  end

  # Each statement of an observation must run in a transaction of its own. Inside one
  # transaction PostgreSQL serves both activity reads from the same cached snapshot, so
  # they would agree whatever the other sessions did in between.
  defp reject_enclosing_transaction!(before, later) do
    if own_transaction(before) == own_transaction(later) do
      raise ArgumentError,
            "advisory lock leaks cannot be observed inside a transaction; " <>
              "call from a test tagged `sandbox: :unboxed`, outside Repo.transaction/2"
    end
  end

  defp own_transaction(activity) do
    Enum.find_value(activity, fn {_pid, session} -> session.self? && session.xact_start end)
  end

  defp activity(repo) do
    %Postgrex.Result{rows: rows} = repo.query!(@activity_sql, [])

    Map.new(rows, fn [pid | values] ->
      {pid, Map.new(Enum.zip(@activity_fields, values))}
    end)
  end

  defp classify([pid, classid, objid, objsubid, mode], before, later) do
    earlier = Map.get(before, pid)
    holder = Map.get(later, pid)

    case verdict(pid, earlier, holder) do
      :not_applicable ->
        nil

      verdict ->
        described = holder || earlier || %{}

        %{
          verdict: verdict,
          pid: pid,
          activity_row?: holder != nil,
          classid: classid,
          objid: objid,
          objsubid: objsubid,
          mode: mode,
          backend_start: described[:backend_start],
          state: described[:state],
          state_change: described[:state_change],
          xact_start: described[:xact_start],
          application_name: described[:application_name],
          query: described[:query]
        }
    end
  end

  # A lock with no backend belongs to a prepared transaction, which never becomes idle.
  defp verdict(nil, _earlier, _holder), do: :in_flight

  defp verdict(_pid, %{backend_type: type}, nil) when type != "client backend",
    do: :not_applicable

  # No activity row: the session is exiting, and the next pg_locks read shows whether
  # its lock went with it.
  defp verdict(_pid, _earlier, nil), do: :in_flight

  defp verdict(_pid, _earlier, %{backend_type: type}) when type != "client backend",
    do: :not_applicable

  # A session that appeared, or was replaced under a reused pid, during the observation.
  defp verdict(_pid, nil, _holder), do: :in_flight

  defp verdict(_pid, %{backend_start: started}, %{backend_start: restarted})
       when started != restarted, do: :in_flight

  # The observing session. `observe/2` has established that no transaction of its own
  # spans the lock read, so a lock it holds was taken by an earlier statement.
  defp verdict(_pid, %{self?: true}, _holder), do: :leaked

  defp verdict(_pid, %{state: "idle", state_change: changed}, %{
         state: "idle",
         state_change: changed
       }), do: :leaked

  defp verdict(_pid, _earlier, _holder), do: :in_flight

  defp identity(lock) do
    {lock.pid, lock.backend_start, lock.classid, lock.objid, lock.objsubid, lock.mode}
  end

  defp format_lock(lock) do
    "  #{lock.verdict} pid=#{inspect(lock.pid)}#{activity_note(lock)} " <>
      "classid=#{lock.classid} objid=#{lock.objid} objsubid=#{lock.objsubid} " <>
      "mode=#{lock.mode} state=#{inspect(lock.state)} " <>
      "state_change=#{inspect(lock.state_change)} xact_start=#{inspect(lock.xact_start)} " <>
      "backend_start=#{inspect(lock.backend_start)} " <>
      "application_name=#{inspect(lock.application_name)} query=#{inspect(lock.query)}"
  end

  defp activity_note(%{activity_row?: true}), do: ""
  defp activity_note(_lock), do: " (holder had no pg_stat_activity row)"
end
