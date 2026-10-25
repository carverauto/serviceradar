defmodule ServiceRadar.Cluster.CoordinatorManager do
  @moduledoc """
  Maintains single-owner coordinator duties for replicated core nodes.

  The active coordinator is chosen via a Postgres advisory lock held on a
  dedicated connection. While the lock is held, coordinator-only children run
  under `ServiceRadar.Cluster.CoordinatorRuntimeSupervisor`. Leader heartbeats
  verify that the current backend session still owns the advisory lock using a
  15-second query timeout. A statement-level query error leaves the session and
  its lock intact, so it is retried once before demoting; any error that ends
  the session (a disconnect or a fatal server error) demotes immediately,
  because the lock was released with the session.
  """

  use GenServer

  alias ServiceRadar.Cluster.CoordinatorChildren
  alias ServiceRadar.Cluster.CoordinatorRuntimeSupervisor
  alias ServiceRadar.Repo.DirectSession

  require Logger

  @lock_key 42_600_101
  @retry_interval_ms 5_000
  @connection_timeout_ms 5_000
  @heartbeat_timeout_ms 15_000
  @lock_sql "SELECT pg_try_advisory_lock($1)"
  @unlock_sql "SELECT pg_advisory_unlock($1)"

  # The lock belongs to the database session, not to this connection process.
  # DBConnection reconnects a dropped socket inside the same process, so after a
  # disconnect the process is alive and answers queries while the new session
  # holds nothing, and another core can already have taken the lock. A leader
  # heartbeat therefore asks whether this session still holds it; `SELECT 1`
  # would succeed and leave two coordinators running. A bigint advisory key is
  # recorded in pg_locks as classid (high 32 bits), objid (low 32 bits) and
  # objsubid 1.
  @lock_held_sql """
  SELECT EXISTS (
    SELECT 1 FROM pg_locks
    WHERE locktype = 'advisory' AND granted AND pid = pg_backend_pid()
      AND classid::bigint = $1 AND objid::bigint = $2 AND objsubid = 1
  )
  """
  @lock_classid div(@lock_key, 4_294_967_296)
  @lock_objid rem(@lock_key, 4_294_967_296)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    state = %{
      conn: nil,
      conn_mon: nil,
      leader?: false,
      coordinator_child: nil,
      coordinator_child_mon: nil
    }

    send(self(), :ensure_coordinator)
    {:ok, state}
  end

  @impl true
  def handle_info(:ensure_coordinator, state) do
    new_state =
      state
      |> ensure_connection()
      |> ensure_lock()

    schedule_retry()
    {:noreply, new_state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{conn_mon: ref} = state) do
    Logger.warning("Coordinator DB lock connection exited", reason: inspect(reason))
    {:noreply, demote_after_connection_exit(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{coordinator_child_mon: ref} = state) do
    Logger.warning("Coordinator child tree exited", reason: inspect(reason))

    {:noreply,
     demote(%{
       state
       | coordinator_child: nil,
         coordinator_child_mon: nil
     })}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    maybe_unlock(state.conn)
    :ok
  end

  defp ensure_connection(%{conn: conn} = state) when is_pid(conn), do: state

  defp ensure_connection(state) do
    case Postgrex.start_link(repo_connection_opts()) do
      {:ok, conn} ->
        mon = Process.monitor(conn)
        %{state | conn: conn, conn_mon: mon}

      {:error, reason} ->
        Logger.warning("Coordinator DB connection unavailable", reason: inspect(reason))
        state
    end
  end

  defp ensure_lock(%{conn: conn, leader?: false} = state) when is_pid(conn) do
    case Postgrex.query(conn, @lock_sql, [@lock_key], timeout: @connection_timeout_ms) do
      {:ok, %Postgrex.Result{rows: [[true]]}} ->
        Logger.info("Core coordinator lock acquired", node: Node.self())
        promote(state)

      {:ok, %Postgrex.Result{rows: [[false]]}} ->
        state

      {:error, reason} ->
        Logger.warning("Coordinator lock attempt failed", reason: inspect(reason))
        demote_after_connection_error(state)
    end
  end

  defp ensure_lock(%{conn: conn, leader?: true} = state) when is_pid(conn) do
    case query_lock_held(conn) do
      {:ok, %Postgrex.Result{rows: [[true]]}} ->
        state

      {:ok, _result} ->
        demote_after_lock_lost(state)

      {:error, %Postgrex.Error{postgres: %{severity: "ERROR"}} = reason} ->
        Logger.warning("Coordinator lock heartbeat failed; retrying before demoting",
          reason: inspect(reason)
        )

        retry_lock_heartbeat(state)

      {:error, reason} ->
        Logger.warning("Coordinator lock heartbeat lost its database session; demoting",
          reason: inspect(reason)
        )

        demote_after_connection_error(state)
    end
  end

  defp ensure_lock(state), do: state

  defp retry_lock_heartbeat(%{conn: conn} = state) do
    case query_lock_held(conn) do
      {:ok, %Postgrex.Result{rows: [[true]]}} ->
        state

      {:ok, _result} ->
        demote_after_lock_lost(state)

      {:error, reason} ->
        Logger.warning("Coordinator lock heartbeat failed", reason: inspect(reason))
        demote_after_connection_error(state)
    end
  end

  defp query_lock_held(conn) do
    Postgrex.query(conn, @lock_held_sql, [@lock_classid, @lock_objid],
      timeout: @heartbeat_timeout_ms
    )
  end

  defp demote_after_lock_lost(state) do
    Logger.error("Core coordinator lock lost by this database session; demoting",
      node: Node.self()
    )

    demote_after_connection_error(state)
  end

  defp promote(state) do
    case DynamicSupervisor.start_child(CoordinatorRuntimeSupervisor, coordinator_child_spec()) do
      {:ok, pid} ->
        child_mon = Process.monitor(pid)
        %{state | leader?: true, coordinator_child: pid, coordinator_child_mon: child_mon}

      {:error, {:already_started, pid}} ->
        child_mon = Process.monitor(pid)
        %{state | leader?: true, coordinator_child: pid, coordinator_child_mon: child_mon}

      {:error, reason} ->
        Logger.error("Failed to start coordinator children", reason: inspect(reason))
        demote(state)
    end
  end

  defp demote(%{leader?: false} = state), do: state

  defp demote(state) do
    maybe_stop_child(state.coordinator_child)
    maybe_unlock(state.conn)
    Logger.warning("Core coordinator lock released", node: Node.self())
    %{state | leader?: false, coordinator_child: nil, coordinator_child_mon: nil}
  end

  defp maybe_stop_child(nil), do: :ok

  defp maybe_stop_child(pid) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(CoordinatorRuntimeSupervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, :noproc} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp demote_after_connection_exit(state) do
    state
    |> demote()
    |> Map.merge(%{conn: nil, conn_mon: nil})
  end

  defp demote_after_connection_error(%{leader?: true} = state) do
    state
    |> demote()
    |> Map.merge(%{conn: nil, conn_mon: nil})
  end

  defp demote_after_connection_error(state) do
    # Postgrex.start_link/1 starts a linked DBConnection pool process. If the
    # lock query fails before this node becomes leader, demote/1 is otherwise a
    # no-op and the pool remains alive until it exhausts Postgres connections.
    maybe_stop_connection(state.conn)

    %{state | conn: nil, conn_mon: nil}
  end

  defp maybe_unlock(nil), do: :ok

  defp maybe_unlock(conn) when is_pid(conn) do
    _ = Postgrex.query(conn, @unlock_sql, [@lock_key], timeout: @connection_timeout_ms)
    maybe_stop_connection(conn)
    :ok
  rescue
    _ -> :ok
  end

  defp maybe_stop_connection(nil), do: :ok

  defp maybe_stop_connection(conn) when is_pid(conn) do
    if Process.alive?(conn) do
      GenServer.stop(conn, :normal)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp schedule_retry do
    Process.send_after(self(), :ensure_coordinator, @retry_interval_ms)
  end

  defp coordinator_child_spec do
    %{
      id: CoordinatorChildren,
      start: {CoordinatorChildren, :start_link, [[]]},
      restart: :transient
    }
  end

  defp repo_connection_opts do
    coordinator_connection_opts(DirectSession.repo_opts(), DirectSession.direct_host())
  end

  @doc false
  def coordinator_connection_opts(opts, host) when is_list(opts) do
    opts
    |> DirectSession.put_host(host)
    |> Keyword.put(:pool_size, 1)
    |> Keyword.put(:timeout, normalize_heartbeat_timeout(Keyword.get(opts, :timeout)))
  end

  defp normalize_heartbeat_timeout(timeout)
       when is_integer(timeout) and timeout > @heartbeat_timeout_ms, do: timeout

  defp normalize_heartbeat_timeout(_timeout), do: @heartbeat_timeout_ms
end
