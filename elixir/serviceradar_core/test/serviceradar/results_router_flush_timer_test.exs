defmodule ServiceRadar.ResultsRouterFlushTimerTest do
  @moduledoc """
  The service-state batching timer in ResultsRouter: armed only while statuses
  are buffered, and never multiplied by a tick that fired before a cancel.

  The callbacks are driven from the test process, so the router's timers send
  their ticks here and can be counted.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.ResultsRouter

  @interval_ms 30

  setup do
    keys = [
      :results_router_batching,
      :results_router_flush_interval_ms,
      :results_router_max_buffer
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:serviceradar_core, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:serviceradar_core, key, value)
        {key, :error} -> Application.delete_env(:serviceradar_core, key)
      end)
    end)

    Application.put_env(:serviceradar_core, :results_router_batching, true)
    Application.put_env(:serviceradar_core, :results_router_flush_interval_ms, @interval_ms)
    Application.put_env(:serviceradar_core, :results_router_max_buffer, 2)
    :ok
  end

  test "an idle router arms no flush timer" do
    {:ok, _state} = ResultsRouter.init(%{})

    assert flush_ticks(@interval_ms * 3) == 0
  end

  test "a tick that fired just before a size-triggered flush does not start a second timer" do
    {:ok, state} = ResultsRouter.init(%{})
    {:noreply, state} = ResultsRouter.handle_cast({:results_update, status()}, state)

    # Let the armed timer fire; its tick is now waiting in the mailbox.
    Process.sleep(@interval_ms * 2)

    # The second status reaches max_buffer and flushes, cancelling a timer that
    # has already fired.
    {:noreply, state} = ResultsRouter.handle_cast({:results_update, status()}, state)

    stale = next_tick(100)
    assert stale
    {:noreply, _state} = ResultsRouter.handle_info(stale, state)

    assert flush_ticks(@interval_ms * 4) <= 1
  end

  # Not a queued class, and nothing to ingest: the router only buffers it.
  defp status, do: %{source: "results", service_type: "unrouted-test-type", message: "{}"}

  defp next_tick(timeout) do
    receive do
      :flush_results -> :flush_results
      {:flush_results, _token} = tick -> tick
    after
      timeout -> nil
    end
  end

  defp flush_ticks(window_ms) do
    Process.sleep(window_ms)
    count_ticks(0)
  end

  defp count_ticks(count) do
    case next_tick(0) do
      nil -> count
      _tick -> count_ticks(count + 1)
    end
  end
end
