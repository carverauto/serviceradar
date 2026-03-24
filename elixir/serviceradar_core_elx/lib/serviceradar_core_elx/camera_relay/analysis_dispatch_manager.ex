defmodule ServiceRadarCoreElx.CameraRelay.AnalysisDispatchManager do
  @moduledoc """
  Starts and tracks relay-scoped external analysis dispatch workers.
  """

  use GenServer

  alias ServiceRadarCoreElx.CameraRelay.AnalysisHTTPDispatchWorker

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def open_http_branch(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:open_http_branch, attrs})
  end

  def close_http_branch(relay_session_id, branch_id) when is_binary(relay_session_id) and is_binary(branch_id) do
    GenServer.call(__MODULE__, {:close_http_branch, relay_session_id, branch_id})
  end

  def list_branches(relay_session_id) when is_binary(relay_session_id) do
    GenServer.call(__MODULE__, {:list_branches, relay_session_id})
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       branches: %{},
       dispatch_supervisor:
         Keyword.get(
           opts,
           :dispatch_supervisor,
           ServiceRadarCoreElx.CameraRelay.AnalysisDispatchSupervisor
         ),
       task_supervisor:
         Keyword.get(
           opts,
           :task_supervisor,
           ServiceRadarCoreElx.CameraRelay.AnalysisDispatchTaskSupervisor
         ),
       adapter: Keyword.get(opts, :adapter),
       adapter_opts: Keyword.get(opts, :adapter_opts, []),
       result_ingestor: Keyword.get(opts, :result_ingestor),
       telemetry_module: Keyword.get(opts, :telemetry_module)
     }}
  end

  @impl true
  def handle_call({:open_http_branch, attrs}, _from, state) do
    relay_session_id = required_string!(attrs, :relay_session_id)
    branch_id = required_string!(attrs, :branch_id)

    if get_in(state.branches, [relay_session_id, branch_id]) do
      {:reply, {:error, :already_exists}, state}
    else
      worker_opts =
        attrs
        |> Map.put(:task_supervisor, state.task_supervisor)
        |> maybe_put(:adapter, state.adapter)
        |> maybe_put(:adapter_opts, state.adapter_opts)
        |> maybe_put(:result_ingestor, state.result_ingestor)
        |> maybe_put(:telemetry_module, state.telemetry_module)

      case DynamicSupervisor.start_child(
             state.dispatch_supervisor,
             {AnalysisHTTPDispatchWorker, worker_opts}
           ) do
        {:ok, pid} ->
          ref = Process.monitor(pid)

          branch = %{
            relay_session_id: relay_session_id,
            branch_id: branch_id,
            pid: pid,
            monitor_ref: ref,
            worker_id: Map.get(attrs, :worker_id),
            endpoint_url: Map.get(attrs, :endpoint_url)
          }

          next_state =
            update_in(state.branches, fn branches ->
              Map.update(branches, relay_session_id, %{branch_id => branch}, &Map.put(&1, branch_id, branch))
            end)

          {:reply, {:ok, branch}, next_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:close_http_branch, relay_session_id, branch_id}, _from, state) do
    case get_in(state.branches, [relay_session_id, branch_id]) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{pid: pid, monitor_ref: ref} ->
        Process.demonitor(ref, [:flush])
        reply = AnalysisHTTPDispatchWorker.close(pid)
        {:reply, reply, delete_branch(state, relay_session_id, branch_id)}
    end
  end

  def handle_call({:list_branches, relay_session_id}, _from, state) do
    branches =
      state.branches
      |> Map.get(relay_session_id, %{})
      |> Map.values()
      |> Enum.sort_by(& &1.branch_id)

    {:reply, branches, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    branches =
      Enum.reduce(state.branches, state.branches, fn {relay_session_id, relay_branches}, acc ->
        case Enum.find(relay_branches, fn {_branch_id, branch} -> branch.monitor_ref == ref end) do
          {branch_id, _branch} ->
            updated_relay_branches = Map.delete(relay_branches, branch_id)

            if map_size(updated_relay_branches) == 0 do
              Map.delete(acc, relay_session_id)
            else
              Map.put(acc, relay_session_id, updated_relay_branches)
            end

          nil ->
            acc
        end
      end)

    {:noreply, %{state | branches: branches}}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp delete_branch(state, relay_session_id, branch_id) do
    updated_relay_branches =
      state.branches
      |> Map.get(relay_session_id, %{})
      |> Map.delete(branch_id)

    branches =
      if map_size(updated_relay_branches) == 0 do
        Map.delete(state.branches, relay_session_id)
      else
        Map.put(state.branches, relay_session_id, updated_relay_branches)
      end

    %{state | branches: branches}
  end

  defp required_string!(attrs, key) do
    case attrs |> Map.get(key, "") |> to_string() |> String.trim() do
      "" -> raise ArgumentError, "#{key} is required"
      value -> value
    end
  end
end
