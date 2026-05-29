defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceTaskData do
  @moduledoc false

  require Logger

  def timed(slow_task_ms, key, fun) when is_integer(slow_task_ms) and is_atom(key) and is_function(fun, 0) do
    {key,
     Task.async(fn ->
       started_at = System.monotonic_time(:millisecond)
       value = fun.()
       elapsed_ms = System.monotonic_time(:millisecond) - started_at

       if elapsed_ms >= slow_task_ms do
         Logger.warning("Device details task #{key} took #{elapsed_ms}ms")
       end

       {key, value}
     end)}
  end

  # Returns a map of results; timed-out or crashed tasks are silently omitted.
  def yield_many(tasks, timeout) do
    keyed_tasks = Enum.map(tasks, &normalize_timed_task/1)
    key_by_ref = Map.new(keyed_tasks, fn {key, task} -> {task.ref, key} end)

    keyed_tasks
    |> Enum.map(fn {_key, task} -> task end)
    |> Task.yield_many(timeout)
    |> Enum.map(fn {task, result} ->
      key = Map.get(key_by_ref, task.ref)

      case result do
        {:ok, {key, value}} when is_atom(key) ->
          {key, value}

        {:ok, _unexpected} ->
          nil

        _ ->
          if not is_nil(key) do
            Logger.warning("Device details task #{key} timed out after #{timeout}ms")
          end

          Task.shutdown(task, :brutal_kill)
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp normalize_timed_task({key, %Task{} = task}) when is_atom(key), do: {key, task}
  defp normalize_timed_task(%Task{} = task), do: {nil, task}
end
