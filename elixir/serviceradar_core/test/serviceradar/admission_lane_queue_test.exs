defmodule ServiceRadar.AdmissionLaneQueueTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Admission.Lane

  test "queued caller churn compacts the FIFO while preserving capacity accounting" do
    parent = self()
    lane = start_lane(held_processor(parent))

    held_ref = admit(lane, status("agent-held", "held"))
    assert_receive {:started, "held", held_worker}

    assert %{
             queue: initial_queue,
             jobs: initial_jobs,
             running: initial_running,
             admitted_bytes: held_bytes,
             admitted_per_agent: %{"agent-held" => 1}
           } = :sys.get_state(lane)

    assert :queue.is_empty(initial_queue)
    assert map_size(initial_jobs) == 1
    assert map_size(initial_running) == 1

    for iteration <- 1..100 do
      caller =
        spawn(fn ->
          result =
            Lane.admit(
              lane,
              status("agent-churn", "queued-#{iteration}"),
              {self(), make_ref()}
            )

          send(parent, {:churn_admitted, iteration, result})
          Process.sleep(:infinity)
        end)

      assert_receive {:churn_admitted, ^iteration, :ok}
      Process.exit(caller, :kill)

      assert_eventually(fn ->
        %{jobs: jobs, admitted_per_agent: admitted_per_agent} = :sys.get_state(lane)
        map_size(jobs) == 1 and admitted_per_agent == %{"agent-held" => 1}
      end)
    end

    assert %{
             queue: queue,
             jobs: jobs,
             running: running,
             admitted_bytes: ^held_bytes,
             admitted_per_agent: %{"agent-held" => 1}
           } = :sys.get_state(lane)

    assert :queue.is_empty(queue)
    assert map_size(jobs) == 1
    assert map_size(running) == 1

    send(held_worker, :release)
    assert_receive {^held_ref, :ok}
    assert_empty(lane)

    replacement_ref = admit(lane, status("agent-churn", "replacement"))
    assert_receive {:started, "replacement", replacement_worker}
    send(replacement_worker, :release)
    assert_receive {^replacement_ref, :ok}
    assert_empty(lane)
  end

  defp start_lane(processor) do
    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    opts = [
      lane: :test,
      concurrency: 1,
      task_supervisor: task_supervisor,
      processor: processor,
      source_max_bytes: 1_024,
      gateway_max_ms: 10_000,
      config: [
        max_items: 2,
        max_bytes: 64 * 1_024,
        max_items_per_agent: 1,
        queue_wait_ms: 2_000,
        worker_timeout_ms: 5_000,
        gateway_call_timeout_ms: 10_000
      ]
    ]

    start_supervised!(Supervisor.child_spec({Lane, opts}, id: make_ref()))
  end

  defp admit(lane, status) do
    reply_ref = make_ref()
    assert :ok = Lane.admit(lane, status, {self(), reply_ref})
    reply_ref
  end

  defp status(agent_id, message), do: %{agent_id: agent_id, message: message}

  defp held_processor(parent) do
    fn status ->
      send(parent, {:started, status.message, self()})

      receive do
        :release -> :ok
      end
    end
  end

  defp assert_eventually(fun, attempts \\ 30)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_empty(lane) do
    assert_eventually(fn ->
      state = :sys.get_state(lane)

      match?(
        %{jobs: jobs, running: running, admitted_bytes: 0}
        when jobs == %{} and running == %{},
        state
      ) and :queue.is_empty(state.queue)
    end)
  end
end
