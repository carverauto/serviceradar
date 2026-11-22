defmodule ServiceRadarCoreElx.CameraStorage.ReadLongshorePool do
  @moduledoc """
  Bounded Longshore session owner for per-request archive reads.

  Longshore enforces at most two live clients per BEAM VM (including draining
  clients). This pool keeps at most one active `ObjectStorageSession` keyed by
  `{destination_sha256, credential_fingerprint}` and at most one draining
  session being retired after a credential or destination rotation. Raw
  credentials are never retained in process state.
  """

  use GenServer, shutdown: 40_000

  alias ServiceRadarObjectStorage.Session, as: ObjectStorageSession

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def acquire(pool \\ __MODULE__, key, ls_config, timeout \\ 5_000) do
    GenServer.call(pool, {:acquire, key, ls_config}, timeout)
  end

  def release(pool \\ __MODULE__, lease_ref) do
    GenServer.cast(pool, {:release, lease_ref})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    session_starter = Keyword.get(opts, :session_starter, &ObjectStorageSession.start_link/1)

    {:ok,
     %{
       session_starter: session_starter,
       active: nil,
       draining: nil,
       by_caller: %{},
       by_session: %{}
     }}
  end

  @impl true
  def handle_call({:acquire, key, _ls_config}, {caller_pid, _}, %{active: %{key: key} = active} = state) do
    lease_ref = Process.monitor(caller_pid)
    active = %{active | callers: Map.put(active.callers, lease_ref, true)}
    by_caller = Map.put(state.by_caller, lease_ref, :active)
    {:reply, {:ok, active.pid, lease_ref}, %{state | active: active, by_caller: by_caller}}
  end

  def handle_call({:acquire, key, ls_config}, {caller_pid, _}, %{active: nil} = state) do
    start_active_session(key, ls_config, caller_pid, state)
  end

  def handle_call({:acquire, key, ls_config}, {caller_pid, _}, %{active: active, draining: nil} = state) do
    state = rotate_active_to_draining(active, state)
    start_active_session(key, ls_config, caller_pid, state)
  end

  def handle_call({:acquire, _key, _ls_config}, _from, state) do
    {:reply, {:error, :archive_read_busy}, state}
  end

  @impl true
  def handle_cast({:release, lease_ref}, state) do
    Process.demonitor(lease_ref, [:flush])
    {:noreply, release_lease(lease_ref, state)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    cond do
      Map.has_key?(state.by_caller, ref) ->
        {:noreply, release_lease(ref, state)}

      Map.has_key?(state.by_session, ref) ->
        {:noreply, handle_session_down(ref, state)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(_other, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    stop_session_sync(state.active)
    stop_session_sync(state.draining)
    :ok
  end

  @impl true
  def format_status(_), do: %{state: :redacted}

  defp start_active_session(key, ls_config, caller_pid, state) do
    case state.session_starter.(config: ls_config) do
      {:ok, pid} ->
        session_mon = Process.monitor(pid)
        lease_ref = Process.monitor(caller_pid)

        active = %{
          key: key,
          pid: pid,
          monitor: session_mon,
          callers: %{lease_ref => true}
        }

        state = %{
          state
          | active: active,
            by_caller: Map.put(state.by_caller, lease_ref, :active),
            by_session: Map.put(state.by_session, session_mon, :active)
        }

        {:reply, {:ok, pid, lease_ref}, state}

      {:error, _reason} ->
        {:reply, {:error, :archive_read_unavailable}, state}
    end
  end

  defp rotate_active_to_draining(active, state) do
    by_caller =
      Map.new(state.by_caller, fn
        {ref, :active} -> {ref, :draining}
        other -> other
      end)

    by_session = Map.put(state.by_session, active.monitor, :draining)

    draining = %{
      pid: active.pid,
      monitor: active.monitor,
      callers: active.callers,
      stopping: false
    }

    draining = maybe_stop_draining(draining)

    %{state | active: nil, draining: draining, by_caller: by_caller, by_session: by_session}
  end

  defp release_lease(lease_ref, state) do
    case Map.pop(state.by_caller, lease_ref) do
      {nil, _} ->
        state

      {:active, by_caller} ->
        active =
          case state.active do
            nil -> nil
            slot -> %{slot | callers: Map.delete(slot.callers, lease_ref)}
          end

        %{state | active: active, by_caller: by_caller}

      {:draining, by_caller} ->
        draining =
          case state.draining do
            nil ->
              nil

            slot ->
              slot
              |> Map.update!(:callers, &Map.delete(&1, lease_ref))
              |> maybe_stop_draining()
          end

        %{state | draining: draining, by_caller: by_caller}
    end
  end

  defp maybe_stop_draining(%{stopping: false, callers: callers, pid: pid} = draining) when map_size(callers) == 0 do
    Process.exit(pid, :shutdown)
    %{draining | stopping: true}
  end

  defp maybe_stop_draining(draining), do: draining

  defp handle_session_down(session_mon, state) do
    case Map.pop(state.by_session, session_mon) do
      {:active, by_session} ->
        by_caller = drop_callers_for_role(state.by_caller, :active)
        %{state | active: nil, by_caller: by_caller, by_session: by_session}

      {:draining, by_session} ->
        by_caller = drop_callers_for_role(state.by_caller, :draining)
        %{state | draining: nil, by_caller: by_caller, by_session: by_session}

      {nil, _} ->
        state
    end
  end

  defp drop_callers_for_role(by_caller, role) do
    Enum.reduce(by_caller, %{}, fn
      {ref, ^role}, acc ->
        Process.demonitor(ref, [:flush])
        acc

      {ref, other}, acc ->
        Map.put(acc, ref, other)
    end)
  end

  defp stop_session_sync(nil), do: :ok

  defp stop_session_sync(%{pid: pid}) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :shutdown, 5_000)
    end

    :ok
  catch
    :exit, _ -> :ok
  end
end
