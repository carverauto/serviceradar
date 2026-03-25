defmodule ServiceRadarCoreElx.CameraRelay.BoomboxSidecarManager do
  @moduledoc """
  Starts and tracks relay-scoped Boombox-backed reference sidecar workers.
  """

  use GenServer

  alias ServiceRadarCoreElx.CameraRelay.BoomboxSidecarWorker

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def open_sidecar(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:open_sidecar, attrs})
  end

  def close_sidecar(relay_session_id, branch_id) when is_binary(relay_session_id) and is_binary(branch_id) do
    GenServer.call(__MODULE__, {:close_sidecar, relay_session_id, branch_id}, 20_000)
  end

  def list_sidecars(relay_session_id) when is_binary(relay_session_id) do
    GenServer.call(__MODULE__, {:list_sidecars, relay_session_id})
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       branches: %{},
       supervisor: Keyword.get(opts, :supervisor, ServiceRadarCoreElx.CameraRelay.BoomboxSidecarSupervisor),
       result_ingestor: Keyword.get(opts, :result_ingestor),
       telemetry_module: Keyword.get(opts, :telemetry_module)
     }}
  end

  @impl true
  def handle_call({:open_sidecar, attrs}, _from, state) do
    relay_session_id = required_string!(attrs, :relay_session_id)
    branch_id = required_string!(attrs, :branch_id)

    if get_in(state.branches, [relay_session_id, branch_id]) do
      {:reply, {:error, :already_exists}, state}
    else
      worker_opts =
        attrs
        |> maybe_put(:result_ingestor, state.result_ingestor)
        |> maybe_put(:telemetry_module, state.telemetry_module)

      case DynamicSupervisor.start_child(state.supervisor, {BoomboxSidecarWorker, worker_opts}) do
        {:ok, pid} ->
          ref = Process.monitor(pid)
          branch = build_branch(worker_opts, pid, ref)
          next_state = put_branch(state, relay_session_id, branch_id, branch)
          {:reply, {:ok, branch}, next_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:close_sidecar, relay_session_id, branch_id}, _from, state) do
    case get_in(state.branches, [relay_session_id, branch_id]) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{pid: pid, monitor_ref: ref} ->
        Process.demonitor(ref, [:flush])
        reply = BoomboxSidecarWorker.close(pid)
        {:reply, reply, delete_branch(state, relay_session_id, branch_id)}
    end
  end

  def handle_call({:list_sidecars, relay_session_id}, _from, state) do
    branches =
      state.branches
      |> Map.get(relay_session_id, %{})
      |> Map.values()
      |> Enum.sort_by(& &1.branch_id)

    {:reply, branches, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, delete_branch_by_ref(state, ref)}
  end

  defp build_branch(attrs, pid, ref) do
    %{
      relay_session_id: required_string!(attrs, :relay_session_id),
      branch_id: required_string!(attrs, :branch_id),
      worker_id: optional_string(attrs, :worker_id) || "boombox-sidecar-worker",
      output_path: Map.get(attrs, :output_path),
      capture_ms: Map.get(attrs, :capture_ms),
      pid: pid,
      monitor_ref: ref
    }
  end

  defp put_branch(state, relay_session_id, branch_id, branch) do
    update_in(state.branches, fn branches ->
      Map.update(branches, relay_session_id, %{branch_id => branch}, &Map.put(&1, branch_id, branch))
    end)
  end

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

  defp delete_branch_by_ref(state, ref) do
    case find_branch_key_by_ref(state.branches, ref) do
      {relay_session_id, branch_id} -> delete_branch(state, relay_session_id, branch_id)
      nil -> state
    end
  end

  defp find_branch_key_by_ref(branches_by_session, ref) do
    Enum.find_value(branches_by_session, fn {relay_session_id, relay_branches} ->
      branch_key_for_ref(relay_session_id, relay_branches, ref)
    end)
  end

  defp branch_key_for_ref(relay_session_id, relay_branches, ref) do
    case Enum.find(relay_branches, fn {_branch_id, branch} -> branch.monitor_ref == ref end) do
      {branch_id, _branch} -> {relay_session_id, branch_id}
      nil -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp required_string!(attrs, key) do
    case attrs |> Map.get(key, Map.get(attrs, to_string(key), "")) |> to_string() |> String.trim() do
      "" -> raise ArgumentError, "#{key} is required"
      value -> value
    end
  end

  defp optional_string(attrs, key) do
    case attrs |> Map.get(key, Map.get(attrs, to_string(key), "")) |> to_string() |> String.trim() do
      "" -> nil
      value -> value
    end
  end
end
