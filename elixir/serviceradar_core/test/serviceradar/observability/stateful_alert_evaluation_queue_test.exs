defmodule ServiceRadar.Observability.StatefulAlertEvaluationQueueTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.StatefulAlertEvaluationQueue

  setup do
    previous = Application.get_env(:serviceradar_core, :stateful_alert_event_evaluator)

    on_exit(fn ->
      restore_env(:stateful_alert_event_evaluator, previous)
    end)

    :ok
  end

  test "dispatches event evaluation asynchronously" do
    parent = self()
    queue_name = unique_queue_name()

    Application.put_env(:serviceradar_core, :stateful_alert_event_evaluator, fn events ->
      send(parent, {:evaluated, events})
      :ok
    end)

    start_supervised!(
      {StatefulAlertEvaluationQueue, name: queue_name, max_concurrency: 1, max_pending: 2}
    )

    event = %{id: "event-1", metadata: %{"signal_type" => "inventory"}}

    assert :ok = StatefulAlertEvaluationQueue.enqueue_events([event], queue_name)
    assert_receive {:evaluated, [^event]}, 1_000
  end

  test "rejects new jobs when the bounded queue is full" do
    parent = self()
    queue_name = unique_queue_name()

    Application.put_env(:serviceradar_core, :stateful_alert_event_evaluator, fn events ->
      send(parent, {:started, self(), events})

      receive do
        :release -> :ok
      after
        5_000 -> :ok
      end
    end)

    start_supervised!(
      {StatefulAlertEvaluationQueue, name: queue_name, max_concurrency: 1, max_pending: 1}
    )

    event = %{id: "event-1", metadata: %{"signal_type" => "inventory"}}

    assert :ok = StatefulAlertEvaluationQueue.enqueue_events([event], queue_name)
    assert_receive {:started, task_pid, [^event]}, 1_000

    assert {:error, :stateful_alert_evaluation_queue_full} =
             StatefulAlertEvaluationQueue.enqueue_events([%{id: "event-2"}], queue_name)

    send(task_pid, :release)
  end

  test "logs evaluator error returns" do
    parent = self()
    queue_name = unique_queue_name()

    Application.put_env(:serviceradar_core, :stateful_alert_event_evaluator, fn events ->
      send(parent, {:evaluation_failed, events})
      {:error, :database_unavailable}
    end)

    start_supervised!(
      {StatefulAlertEvaluationQueue, name: queue_name, max_concurrency: 1, max_pending: 1}
    )

    event = %{id: "event-error", metadata: %{}}

    log =
      capture_log(fn ->
        assert :ok = StatefulAlertEvaluationQueue.enqueue_events([event], queue_name)
        assert_receive {:evaluation_failed, [^event]}, 1_000
        assert_queue_idle(queue_name)
        Logger.flush()
      end)

    assert log =~ "Stateful alert event evaluation failed"
    assert log =~ "database_unavailable"
  end

  defp unique_queue_name do
    :"stateful_alert_evaluation_queue_#{System.unique_integer([:positive])}"
  end

  defp assert_queue_idle(queue_name, attempts \\ 100)

  defp assert_queue_idle(_queue_name, 0) do
    flunk("stateful alert evaluation queue did not become idle")
  end

  defp assert_queue_idle(queue_name, attempts) do
    if map_size(:sys.get_state(queue_name).inflight) == 0 do
      :ok
    else
      receive do
      after
        10 -> assert_queue_idle(queue_name, attempts - 1)
      end
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
