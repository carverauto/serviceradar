defmodule ServiceRadar.Cluster.CoordinatorManager do
  @moduledoc """
  Maintains single-owner coordinator duties for replicated core nodes.

  The active coordinator is chosen via a Postgres advisory lock held on a
  dedicated connection. While the lock is held, coordinator-only children run
  under `ServiceRadar.Cluster.CoordinatorRuntimeSupervisor`.
  """

  use GenServer

  alias ServiceRadar.Cluster.CoordinatorChildren
  alias ServiceRadar.Cluster.CoordinatorRuntimeSupervisor

  require Logger

  @lock_key 42_600_101
  @retry_interval_ms 5_000
  @connection_timeout_ms 5_000
  @lock_sql "SELECT pg_try_advisory_lock($1)"
  @unlock_sql "SELECT pg_advisory_unlock($1)"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    state = %{
      conn: nil,
      conn_mon: nil,
      leader?: false,
      coordinator_child: nil
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
    {:noreply, demote(%{state | conn: nil, conn_mon: nil})}
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
        demote(%{state | conn: nil, conn_mon: nil})
    end
  end

  defp ensure_lock(%{conn: conn, leader?: true} = state) when is_pid(conn) do
    case Postgrex.query(conn, "SELECT 1", [], timeout: @connection_timeout_ms) do
      {:ok, _result} ->
        state

      {:error, reason} ->
        Logger.warning("Coordinator lock heartbeat failed", reason: inspect(reason))
        demote(%{state | conn: nil, conn_mon: nil})
    end
  end

  defp ensure_lock(state), do: state

  defp promote(state) do
    case DynamicSupervisor.start_child(CoordinatorRuntimeSupervisor, coordinator_child_spec()) do
      {:ok, pid} ->
        %{state | leader?: true, coordinator_child: pid}

      {:error, {:already_started, pid}} ->
        %{state | leader?: true, coordinator_child: pid}

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
    %{state | leader?: false, coordinator_child: nil}
  end

  defp maybe_stop_child(nil), do: :ok

  defp maybe_stop_child(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(CoordinatorRuntimeSupervisor, pid)
  end

  defp maybe_unlock(nil), do: :ok

  defp maybe_unlock(conn) when is_pid(conn) do
    _ = Postgrex.query(conn, @unlock_sql, [@lock_key], timeout: @connection_timeout_ms)
    GenServer.stop(conn, :normal)
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
    Keyword.take(ServiceRadar.Repo.config(), [
      :hostname,
      :port,
      :username,
      :password,
      :database,
      :socket_dir,
      :socket,
      :parameters,
      :ssl,
      :ssl_opts,
      :connect_timeout,
      :timeout,
      :ipv6,
      :url
    ])
  end
end
