defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceTaskData do
  @moduledoc """
  Bounded, crash-isolated fan-out for the device-detail loaders.

  Two properties matter here, and both are load-bearing:

    * **Nothing a loader does can kill the caller.** These batches run inside
      `Phoenix.LiveView.start_async/3`, and LiveView spawns that worker with
      `Task.start_link/1`, unlinking only inside a `try/after` (see
      `phoenix_live_view/async.ex`). A plain `Task.async/1` child that crashes
      therefore delivers an exit signal that skips that `after`, skips
      `report_async_result`, and kills the LiveView itself — so the
      `handle_async(..., {:exit, _}, socket)` clauses never run. Running the
      batch through `Task.Supervisor.async_stream_nolink/4` breaks the link, so
      a crash (including one raised in a *nested* task a loader spawns) comes
      back as a dropped result instead of a dead page.

    * **The batch cannot demand more connections than the Repo pool has.**
      Every loader here checks out a `ServiceRadar.Repo` connection, and a
      device page runs several of these batches at once. Unbounded fan-out let
      one page ask for ~16 simultaneous checkouts against a pool of 8; the
      overflow was dropped by `DBConnection` after `queue_target`, which raised,
      which is what started the crash cascade above. `max_concurrency` caps it.

  Failed and timed-out tasks are omitted from the result map, which is the shape
  every caller already handles via `Map.get(results, key, default)`.

  The tradeoff `nolink` brings, which LiveView's own docs call out: these tasks
  no longer die with the caller, so a page abandoned mid-load can leave a few
  queries running. That is bounded twice over — by the batch deadline below and
  by SRQL's `statement_timeout` — and it is a much better failure than the one
  it replaces, where an abandoned load took the LiveView down with it.
  """

  require Logger

  # Returned by a guarded task body that raised or exited. `run/3` drops these.
  @failed :__device_task_failed__

  # Sized just under the smallest deployed Repo pool (demo runs POOL_SIZE=8), so
  # a single batch leaves headroom rather than claiming every connection.
  #
  # Deliberately not lower: before this bound existed the pool WAS the limiter,
  # so these batches already ran at an effective concurrency of ~8. Dropping to
  # 3 or 4 would roughly double the wall time of the supplemental batch, which
  # runs against a 3s budget on the details tab (@details_supplemental_timeout_ms)
  # and would start shedding results that used to load. The catastrophic case
  # was never "slightly over the pool" -- it was ~16 simultaneous multi-second
  # 24h aggregates, which this comfortably prevents.
  @default_max_concurrency 6

  @doc """
  Builds a runnable spec. The fun is deliberately NOT started here — `run/3`
  starts it under a concurrency bound.
  """
  def spec(slow_task_ms, key, fun) when is_integer(slow_task_ms) and is_atom(key) and is_function(fun, 0) do
    {key, fn -> guarded_call(slow_task_ms, key, fun) end}
  end

  @doc """
  Runs specs concurrently (bounded) and returns a map of successful results.

  Crashed and timed-out tasks are logged and omitted.
  """
  def run(specs, timeout, opts \\ []) when is_list(specs) and is_integer(timeout) do
    max_concurrency = Keyword.get(opts, :max_concurrency, default_max_concurrency())

    # `timeout` is the budget for the WHOLE batch, as it was when this ran on
    # `Task.yield_many/2`. `async_stream`'s own :timeout is per element, so the
    # batch deadline is enforced here by halting the stream, which shuts down
    # anything still in flight.
    deadline = System.monotonic_time(:millisecond) + timeout

    ServiceRadarWebNG.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      specs,
      fn {_key, fun} -> fun.() end,
      max_concurrency: max_concurrency,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    # Stream.zip, not Enum.zip: Enum.zip is eager and would drain the whole
    # stream before the reduce below ever ran, so the deadline halt could never
    # fire and the batch budget would be unenforced.
    |> Stream.zip(specs)
    |> Enum.reduce_while(%{}, fn {result, {key, _fun}}, acc ->
      acc = merge_result(acc, key, result)

      if System.monotonic_time(:millisecond) >= deadline do
        {:halt, acc}
      else
        {:cont, acc}
      end
    end)
  end

  defp merge_result(acc, _key, {:ok, @failed}), do: acc
  defp merge_result(acc, key, {:ok, value}), do: Map.put(acc, key, value)

  defp merge_result(acc, key, {:exit, reason}) do
    Logger.warning("Device details task #{key} did not complete: #{inspect(reason)}")
    acc
  end

  defp guarded_call(slow_task_ms, key, fun) do
    started_at = System.monotonic_time(:millisecond)
    value = fun.()
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    if elapsed_ms >= slow_task_ms do
      Logger.warning("Device details task #{key} took #{elapsed_ms}ms")
    end

    value
  rescue
    error ->
      Logger.warning("Device details task #{key} failed: #{Exception.message(error)}")
      @failed
  catch
    :exit, reason ->
      Logger.warning("Device details task #{key} exited: #{inspect(reason)}")
      @failed
  end

  defp default_max_concurrency do
    Application.get_env(:serviceradar_web_ng, :device_task_max_concurrency, @default_max_concurrency)
  end
end
