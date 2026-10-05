defmodule ServiceRadar.AdmissionLaneQueueTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Admission.Lane

  test "one key stays ordered while another key uses the free worker" do
    parent = self()

    lane =
      start_lane(held_processor(parent), concurrency: 2, max_items: 4, max_items_per_agent: 2)

    first = admit(lane, status("agent01.example.com", "first"))
    assert_receive {:started, "first", first_worker}
    second = admit(lane, status("agent01.example.com", "second"))
    other = admit(lane, status("agent02.example.com", "other"))

    assert_receive {:started, "other", other_worker}, 1_000
    refute_receive {:started, "second", _}, 50
    send(other_worker, :release)
    assert_receive {^other, :ok}
    send(first_worker, :release)
    assert_receive {^first, :ok}
    assert_receive {:started, "second", second_worker}
    send(second_worker, :release)
    assert_receive {^second, :ok}
    assert_empty(lane)
  end

  test "metadata reservations bound admission before any payload or worker starts" do
    parent = self()
    lane = start_lane(held_processor(parent), max_items_per_agent: 2)
    first_status = status("agent01.example.com", "first")
    second_status = status("agent01.example.com", "second")

    assert {:ok, {^lane, first_id}} =
             Lane.reserve(lane, Lane.descriptor(first_status, 10_000), self(), 1_000)

    assert {:ok, {^lane, second_id}} =
             Lane.reserve(lane, Lane.descriptor(second_status, 10_000), self(), 1_000)

    assert {:error, :count_full} =
             Lane.reserve(
               lane,
               Lane.descriptor(status("agent02.example.com", "rejected"), 10_000),
               self(),
               1_000
             )

    refute_receive {:started, _, _}, 50

    first = make_ref()
    second = make_ref()
    assert :ok = Lane.submit(lane, first_id, first_status, {self(), first})
    assert_receive {:started, "first", first_worker}
    assert :ok = Lane.submit(lane, second_id, second_status, {self(), second})
    refute_receive {:started, "second", _}, 50
    send(first_worker, :release)
    assert_receive {^first, :ok}
    assert_receive {:started, "second", second_worker}
    send(second_worker, :release)
    assert_receive {^second, :ok}
    refute_receive {:started, "rejected", _}, 50
    assert_empty(lane)
  end

  test "a reservation owner exiting releases unused count and byte credits" do
    parent = self()

    lane =
      start_lane(
        fn _ ->
          send(parent, :unexpected_ingestion)
          :ok
        end,
        max_items: 1
      )

    owner = spawn(fn -> Process.sleep(:infinity) end)
    payload = status("agent01.example.com", "unused")

    assert {:ok, {^lane, _id}} =
             Lane.reserve(lane, Lane.descriptor(payload, 10_000), owner, 1_000)

    assert {:error, :count_full} =
             Lane.reserve(lane, Lane.descriptor(payload, 10_000), self(), 1_000)

    Process.exit(owner, :kill)
    assert_empty(lane)
    ref = admit(lane, status("agent02.example.com", "replacement"))
    assert_receive :unexpected_ingestion
    assert_receive {^ref, :ok}
    assert_empty(lane)
  end

  test "payload mismatch and an expired reservation cannot start ingestion" do
    parent = self()

    lane =
      start_lane(
        fn _ ->
          send(parent, :unexpected_ingestion)
          :ok
        end,
        queue_wait_ms: 40,
        worker_timeout_ms: 500,
        gateway_call_timeout_ms: 3_540
      )

    payload = status("agent01.example.com", "reserved")
    assert {:ok, {^lane, id}} = Lane.reserve(lane, Lane.descriptor(payload, 3_540), self(), 1_000)

    assert {:error, :reservation_payload_mismatch} =
             Lane.submit(
               lane,
               id,
               %{payload | agent_id: "agent02.example.com"},
               {self(), make_ref()}
             )

    assert_empty(lane)

    assert {:ok, {^lane, expired}} =
             Lane.reserve(lane, Lane.descriptor(payload, 3_540), self(), 1_000)

    assert_empty(lane)

    assert {:error, :reservation_expired} =
             Lane.submit(lane, expired, payload, {self(), make_ref()})

    refute_receive :unexpected_ingestion, 50
  end

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

  defp start_lane(processor, overrides \\ []) do
    {concurrency, overrides} = Keyword.pop(overrides, :concurrency, 1)

    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    opts = [
      lane: :test,
      concurrency: concurrency,
      task_supervisor: task_supervisor,
      processor: processor,
      source_max_bytes: 1_024,
      gateway_max_ms: 10_000,
      config:
        Keyword.merge(
          [
            max_items: 2,
            max_bytes: 64 * 1_024,
            max_items_per_agent: 1,
            queue_wait_ms: 2_000,
            worker_timeout_ms: 5_000,
            gateway_call_timeout_ms: 10_000
          ],
          overrides
        )
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
