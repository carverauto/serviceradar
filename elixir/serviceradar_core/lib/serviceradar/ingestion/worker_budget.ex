defmodule ServiceRadar.Ingestion.WorkerBudget do
  @moduledoc "Limits database-active workers while reserving capacity for each acknowledged lane."
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def run(server, lane, fun) do
    :ok = GenServer.call(server, {:acquire, group(lane)}, :infinity)
    try do
      fun.()
    after
      GenServer.call(server, :release, :infinity)
    end
  end

  @impl true
  def init(opts) do
    pool_size = Keyword.get(opts, :pool_size,
      Application.get_env(:serviceradar_core, ServiceRadar.Repo, [])[:pool_size] || 10)
    reserve = Keyword.get(opts, :repo_reserve, 3)
    workers = Keyword.get(opts, :general_workers, 4)
    unless is_integer(pool_size) and pool_size > 0 and is_integer(reserve) and reserve >= 3 and
             is_integer(workers) and workers > 0 do
      raise ArgumentError, "invalid ingestion Repo budget"
    end
    general = min(workers, pool_size - reserve - 3)

    if general < 1 do
      {:stop, {:insufficient_ingestion_repo_budget, pool_size, reserve}}
    else
      {:ok, %{limits: %{flow: 1, plugin: 1, endpoint: 1, general: general},
              active: %{}, waiting: :queue.new(), monitors: %{}}}
    end
  end

  @impl true
  def handle_call({:acquire, group}, {pid, _} = from, state) do
    ref = Process.monitor(pid)
    state = %{state | monitors: Map.put(state.monitors, ref, pid)}
    {:noreply, dispatch(%{state | waiting: :queue.in({pid, group, from}, state.waiting)})}
  end

  def handle_call(:release, {pid, _}, state), do: {:reply, :ok, release(state, pid)}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    if state.monitors[ref] == pid, do: {:noreply, release(state, pid)}, else: {:noreply, state}
  end

  defp release(state, pid) do
    refs = for {ref, owner} <- state.monitors, owner == pid, do: ref
    Enum.each(refs, &Process.demonitor(&1, [:flush]))
    waiting = state.waiting |> :queue.to_list() |> Enum.reject(fn {owner, _, _} -> owner == pid end)
    dispatch(%{state | active: Map.delete(state.active, pid), waiting: :queue.from_list(waiting),
                        monitors: Map.drop(state.monitors, refs)})
  end

  defp dispatch(state) do
    {waiting, active} = Enum.reduce(:queue.to_list(state.waiting), {[], state.active},
      fn {pid, group, from} = item, {waiting, active} ->
        used = Enum.count(active, fn {_pid, active_group} -> active_group == group end)
        if used < state.limits[group] do
          GenServer.reply(from, :ok)
          {waiting, Map.put(active, pid, group)}
        else
          {[item | waiting], active}
        end
      end)
    %{state | waiting: :queue.from_list(Enum.reverse(waiting)), active: active}
  end

  defp group(:flow_attribution), do: :flow
  defp group(:retained_plugin_result), do: :plugin
  defp group(:endpoint), do: :endpoint
  defp group(_), do: :general
end
