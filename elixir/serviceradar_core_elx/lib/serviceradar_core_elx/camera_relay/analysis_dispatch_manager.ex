defmodule ServiceRadarCoreElx.CameraRelay.AnalysisDispatchManager do
  @moduledoc """
  Starts and tracks relay-scoped external analysis dispatch workers.
  """

  use GenServer

  alias ServiceRadar.Camera.AnalysisWorkerAlertRouter
  alias ServiceRadarCoreElx.CameraRelay.AnalysisHTTPDispatchWorker
  alias ServiceRadarCoreElx.CameraRelay.AnalysisWorkerResolver

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

  def worker_assignment_snapshot do
    GenServer.call(__MODULE__, :worker_assignment_snapshot)
  end

  def report_branch_assignment(relay_session_id, branch_id, attrs)
      when is_binary(relay_session_id) and is_binary(branch_id) and is_map(attrs) do
    GenServer.call(__MODULE__, {:report_branch_assignment, relay_session_id, branch_id, attrs})
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
       telemetry_module: Keyword.get(opts, :telemetry_module),
       worker_resolver: Keyword.get(opts, :worker_resolver, AnalysisWorkerResolver),
       alert_router: Keyword.get(opts, :alert_router, AnalysisWorkerAlertRouter),
       assignment_detail_limit: Keyword.get(opts, :assignment_detail_limit, 5)
     }}
  end

  @impl true
  def handle_call({:open_http_branch, attrs}, _from, state) do
    relay_session_id = required_string!(attrs, :relay_session_id)
    branch_id = required_string!(attrs, :branch_id)

    if get_in(state.branches, [relay_session_id, branch_id]) do
      {:reply, {:error, :already_exists}, state}
    else
      case resolve_worker(attrs, state) do
        {:ok, resolved_worker} ->
          emit_worker_selection_event(
            state,
            :worker_selected,
            attrs,
            resolved_worker,
            nil
          )

          worker_opts =
            attrs
            |> Map.merge(
              Map.take(resolved_worker, [
                :worker_id,
                :display_name,
                :adapter,
                :endpoint_url,
                :capabilities,
                :headers,
                :selection_mode,
                :requested_capability,
                :registry_managed?
              ])
            )
            |> Map.put(:worker_adapter, resolved_worker.adapter)
            |> Map.put(:task_supervisor, state.task_supervisor)
            |> Map.put(:worker_resolver, state.worker_resolver)
            |> Map.put(:alert_router, state.alert_router)
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
                worker_id: resolved_worker.worker_id,
                display_name: resolved_worker.display_name,
                endpoint_url: resolved_worker.endpoint_url,
                adapter: resolved_worker.adapter,
                capabilities: resolved_worker.capabilities,
                selection_mode: resolved_worker.selection_mode,
                requested_capability: resolved_worker.requested_capability,
                registry_managed?: resolved_worker.registry_managed?
              }

              next_state =
                update_in(state.branches, fn branches ->
                  Map.update(
                    branches,
                    relay_session_id,
                    %{branch_id => branch},
                    &Map.put(&1, branch_id, branch)
                  )
                end)

              {:reply, {:ok, branch}, next_state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end

        {:error, reason} ->
          emit_worker_selection_event(state, :worker_selection_failed, attrs, nil, reason)
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

  def handle_call(:worker_assignment_snapshot, _from, state) do
    {:reply, assignment_snapshot(state), state}
  end

  def handle_call({:report_branch_assignment, relay_session_id, branch_id, attrs}, _from, state) do
    next_state =
      update_in(state.branches, fn branches ->
        update_in(branches, [relay_session_id, branch_id], fn
          nil ->
            nil

          branch ->
            branch
            |> Map.put(:worker_id, required_string!(attrs, :worker_id))
            |> maybe_put(:display_name, Map.get(attrs, :display_name))
            |> maybe_put(:endpoint_url, Map.get(attrs, :endpoint_url))
            |> maybe_put(:adapter, Map.get(attrs, :adapter))
            |> maybe_put(:capabilities, Map.get(attrs, :capabilities))
            |> maybe_put(:selection_mode, Map.get(attrs, :selection_mode))
            |> maybe_put(:requested_capability, Map.get(attrs, :requested_capability))
            |> maybe_put(:registry_managed?, Map.get(attrs, :registry_managed?))
        end)
      end)

    {:reply, :ok, next_state}
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

  defp resolve_worker(attrs, state) do
    state.worker_resolver.resolve_http_worker(attrs)
  end

  defp emit_worker_selection_event(state, event, attrs, resolved_worker, reason) do
    telemetry_module = state.telemetry_module || ServiceRadar.Telemetry
    requested_capability = requested_capability(attrs)

    telemetry_module.emit_camera_relay_analysis_event(
      event,
      %{
        relay_boundary: "core_elx",
        relay_session_id: required_string!(attrs, :relay_session_id),
        branch_id: required_string!(attrs, :branch_id),
        worker_id: resolved_worker && resolved_worker.worker_id,
        selection_mode: resolved_worker && resolved_worker.selection_mode,
        requested_worker_id: requested_worker_id(attrs),
        requested_capability: requested_capability,
        reason: format_reason(reason)
      },
      %{}
    )
  end

  defp assignment_snapshot(state) do
    state.branches
    |> Map.values()
    |> Enum.flat_map(&Map.values/1)
    |> Enum.group_by(& &1.worker_id)
    |> Map.new(fn {worker_id, branches} ->
      ordered_branches =
        Enum.sort_by(branches, fn branch ->
          {branch.relay_session_id, branch.branch_id}
        end)

      active_assignments =
        ordered_branches
        |> Enum.take(state.assignment_detail_limit)
        |> Enum.map(&assignment_details/1)

      {worker_id,
       %{
         active_assignment_count: length(ordered_branches),
         active_assignments: active_assignments
       }}
    end)
  end

  defp assignment_details(branch) do
    %{
      relay_session_id: branch.relay_session_id,
      branch_id: branch.branch_id,
      worker_id: branch.worker_id,
      display_name: branch.display_name,
      adapter: branch.adapter,
      capabilities: List.wrap(branch.capabilities),
      selection_mode: branch.selection_mode,
      requested_capability: branch.requested_capability,
      registry_managed?: branch.registry_managed?
    }
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

  defp required_string!(attrs, key) do
    case attrs |> Map.get(key, "") |> to_string() |> String.trim() do
      "" -> raise ArgumentError, "#{key} is required"
      value -> value
    end
  end

  defp requested_worker_id(attrs) do
    case attrs
         |> Map.get(
           :registered_worker_id,
           Map.get(
             attrs,
             "registered_worker_id",
             Map.get(attrs, :worker_id, Map.get(attrs, "worker_id"))
           )
         )
         |> to_string()
         |> String.trim() do
      "" -> nil
      value -> value
    end
  end

  defp requested_capability(attrs) do
    case attrs
         |> Map.get(
           :required_capability,
           Map.get(
             attrs,
             "required_capability",
             Map.get(attrs, :capability, Map.get(attrs, "capability"))
           )
         )
         |> to_string()
         |> String.trim() do
      "" -> nil
      value -> value
    end
  end

  defp format_reason(nil), do: nil

  defp format_reason({:unsupported_worker_adapter, adapter}), do: "unsupported_worker_adapter:#{adapter}"

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
