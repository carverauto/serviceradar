defmodule ServiceRadar.Observability.StatefulAlertEvaluationQueueTest do
  use ExUnit.Case, async: false

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

  defp unique_queue_name do
    :"stateful_alert_evaluation_queue_#{System.unique_integer([:positive])}"
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
