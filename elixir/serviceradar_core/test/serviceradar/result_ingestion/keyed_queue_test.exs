defmodule ServiceRadar.ResultIngestion.KeyedQueueTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.ResultIngestion.KeyedQueue

  setup do
    supervisor = start_supervised!(Task.Supervisor)
    %{supervisor: supervisor}
  end

  test "one key's jobs run one at a time in arrival order", ctx do
    queue = start_queue!(ctx, workers: 4)

    :ok = admit(queue, :agent_a, held(:first))
    :ok = admit(queue, :agent_a, held(:second))

    assert_receive {:started, :first, first}
    refute_receive {:started, :second, _pid}, 100

    send(first, :release)
    assert_receive {:started, :second, second}
    send(second, :release)
  end

  test "different keys run concurrently up to the worker bound", ctx do
    queue = start_queue!(ctx, workers: 2)

    :ok = admit(queue, :agent_a, held(:a))
    :ok = admit(queue, :agent_b, held(:b))
    :ok = admit(queue, :agent_c, held(:c))

    assert_receive {:started, :a, a}
    assert_receive {:started, :b, b}
    refute_receive {:started, :c, _pid}, 100

    send(a, :release)
    assert_receive {:started, :c, c}
    Enum.each([b, c], &send(&1, :release))
  end

  test "a busy key does not hold back an idle one queued behind it", ctx do
    queue = start_queue!(ctx, workers: 2)

    :ok = admit(queue, :agent_a, held(:a1))
    :ok = admit(queue, :agent_a, held(:a2))
    :ok = admit(queue, :agent_b, held(:b1))

    assert_receive {:started, :a1, a1}
    assert_receive {:started, :b1, b1}
    refute_receive {:started, :a2, _pid}, 100
    Enum.each([a1, b1], &send(&1, :release))
    assert_receive {:started, :a2, a2}
    send(a2, :release)
  end

  test "each bound rejects with its own reason", ctx do
    items = start_queue!(ctx, workers: 1, max_items: 1)
    :ok = admit(items, :agent_a, held(:held_items))
    assert {:error, :result_ingestion_queue_full} = admit(items, :agent_b, fn -> :ok end)

    bytes = start_queue!(ctx, workers: 1, max_bytes: 10)

    assert {:error, :result_ingestion_bytes_full} =
             KeyedQueue.admit(bytes, :agent_a, 11, fn -> :ok end)

    per_key = start_queue!(ctx, workers: 1, max_items_per_key: 1)
    :ok = admit(per_key, :agent_a, held(:held_key))
    assert {:error, :result_ingestion_key_full} = admit(per_key, :agent_a, fn -> :ok end)
    assert :ok = admit(per_key, :agent_b, fn -> :ok end)

    for name <- [:held_items, :held_key] do
      assert_receive {:started, ^name, pid}
      send(pid, :release)
    end
  end

  test "a caller waiting on a job gets its result", ctx do
    queue = start_queue!(ctx, workers: 1)
    caller = self()
    ref = make_ref()

    :ok =
      KeyedQueue.admit(queue, :agent_a, 0, fn -> {:ok, :done} end, reply_to: {caller, ref})

    assert_receive {^ref, {:ok, :done}}
  end

  test "a job past its timeout is killed and its caller told", ctx do
    queue = start_queue!(ctx, workers: 1, job_timeout_ms: 50)
    ref = make_ref()

    :ok =
      KeyedQueue.admit(queue, :agent_a, 0, fn -> Process.sleep(:infinity) end,
        reply_to: {self(), ref}
      )

    assert_receive {^ref, {:error, :result_ingestion_timeout}}, 1_000
    assert :ok = admit(queue, :agent_a, fn -> :ok end)
  end

  test "a job that crashes is reported and the queue continues", ctx do
    queue = start_queue!(ctx, workers: 1)
    ref = make_ref()

    :ok = KeyedQueue.admit(queue, :agent_a, 0, fn -> exit(:boom) end, reply_to: {self(), ref})

    assert_receive {^ref, {:error, {:result_ingestion_task_exit, :boom}}}, 1_000
    assert_eventually(fn -> {:ok, %{items: 0}} = KeyedQueue.stats(queue) end)
  end

  test "coalescing replaces a key's pending job with the newer one", ctx do
    queue = start_queue!(ctx, workers: 1, coalesce: true)
    ref = make_ref()
    test_pid = self()

    :ok = admit(queue, :agent_a, held(:running))

    :ok =
      KeyedQueue.admit(queue, :agent_a, 0, fn -> send(test_pid, {:started, :stale, self()}) end,
        reply_to: {self(), ref}
      )

    :ok = admit(queue, :agent_a, fn -> send(test_pid, {:started, :newest, self()}) end)

    assert_receive {^ref, {:error, :result_ingestion_superseded}}
    assert_receive {:started, :running, running}
    send(running, :release)
    assert_receive {:started, :newest, _pid}
    refute_received {:started, :stale, _pid}
  end

  test "depth returns to zero after work drains", ctx do
    queue = start_queue!(ctx, workers: 2)
    handler = "keyed-queue-state-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:serviceradar, :result_ingestion, :state],
      fn _event, measurements, %{class: :test_class}, _ ->
        send(test_pid, {:state, measurements})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    :ok = admit(queue, :agent_a, fn -> :ok end)
    :ok = admit(queue, :agent_b, fn -> {:error, :nope} end)

    assert_eventually(fn ->
      {:ok, %{items: 0, bytes: 0, in_flight_count: 0}} = KeyedQueue.stats(queue)
    end)

    assert_receive {:state,
                    %{pending_count: 0, in_flight_count: 0, in_flight_bytes: 0, pending_bytes: 0}}
  end

  defp start_queue!(ctx, overrides) do
    opts =
      Keyword.merge(
        [
          name: Module.concat(__MODULE__, "q#{System.unique_integer([:positive])}"),
          class: :test_class,
          task_supervisor: ctx.supervisor,
          workers: 1,
          max_items: 100,
          max_bytes: 1_000_000,
          max_items_per_key: 10,
          job_timeout_ms: 5_000
        ],
        overrides
      )

    start_supervised!({KeyedQueue, opts}, id: opts[:name])
  end

  defp admit(queue, key, fun), do: KeyedQueue.admit(queue, key, 0, fun)

  defp held(name) do
    test_pid = self()

    fn ->
      send(test_pid, {:started, name, self()})

      receive do
        :release -> :ok
      end
    end
  end

  defp assert_eventually(check, attempts \\ 40) do
    check.()
  rescue
    error in [MatchError] ->
      if attempts > 1 do
        Process.sleep(25)
        assert_eventually(check, attempts - 1)
      else
        reraise error, __STACKTRACE__
      end
  end
end
