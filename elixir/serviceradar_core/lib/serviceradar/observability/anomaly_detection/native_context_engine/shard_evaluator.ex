defmodule ServiceRadar.Observability.AnomalyDetection.NativeContextEngine.ShardEvaluator do
  @moduledoc false

  alias ServiceRadar.Observability.CausalReasoner

  @spec start_workers(tuple()) :: tuple()
  def start_workers(resources) when is_tuple(resources) do
    resources
    |> Tuple.to_list()
    |> Enum.map(&start_worker/1)
    |> List.to_tuple()
  end

  @spec start_worker(reference()) :: pid()
  def start_worker(resource), do: spawn_link(fn -> worker_loop(resource) end)

  @spec stop_workers(tuple() | nil) :: :ok
  def stop_workers(nil), do: :ok

  def stop_workers(workers) when is_tuple(workers) do
    workers
    |> Tuple.to_list()
    |> Enum.each(&send(&1, :stop))
  end

  @spec worker_index(tuple(), pid()) :: non_neg_integer() | nil
  def worker_index(workers, pid) do
    Enum.find_value(0..(tuple_size(workers) - 1), fn index ->
      if elem(workers, index) == pid, do: index
    end)
  end

  @spec evaluate_groups(tuple(), tuple(), non_neg_integer()) :: [
          CausalReasoner.indexed_event_result()
        ]
  def evaluate_groups(groups, workers, timeout_ms) do
    0..(tuple_size(groups) - 1)
    |> Enum.reduce([], fn shard_index, requests ->
      case elem(groups, shard_index) do
        [] ->
          requests

        inputs ->
          worker = elem(workers, shard_index)
          ref = make_ref()
          monitor = Process.monitor(worker)
          send(worker, {:evaluate, self(), ref, inputs})
          [{ref, monitor, indexes_of(inputs)} | requests]
      end
    end)
    |> Enum.reverse()
    |> Enum.flat_map(&receive_result(&1, timeout_ms))
  end

  defp receive_result({ref, monitor, indexes}, timeout_ms) do
    receive do
      {^ref, results} ->
        Process.demonitor(monitor, [:flush])
        results

      {:DOWN, ^monitor, :process, _pid, reason} ->
        shard_error_results(indexes, {:shard_exit, reason})
    after
      timeout_ms ->
        Process.demonitor(monitor, [:flush])
        shard_error_results(indexes, {:shard_exit, :timeout})
    end
  end

  defp indexes_of(inputs) do
    Enum.map(inputs, fn {index, _key, _context, _value, _observed_at} -> index end)
  end

  defp shard_error_results([], reason), do: [{-1, {:error, reason}}]

  defp shard_error_results(indexes, reason) do
    Enum.map(indexes, fn index -> {index, {:error, reason}} end)
  end

  defp worker_loop(resource) do
    receive do
      {:evaluate, caller, ref, inputs} ->
        send(caller, {ref, evaluate_group(resource, inputs)})
        worker_loop(resource)

      :stop ->
        :ok
    end
  end

  defp evaluate_group(resource, inputs) do
    CausalReasoner.reason_state_value_tuples_changes(resource, inputs)
  rescue
    reason -> [{-1, {:error, {:shard_exit, reason}}}]
  catch
    kind, reason -> [{-1, {:error, {:shard_exit, {kind, reason}}}}]
  end
end
