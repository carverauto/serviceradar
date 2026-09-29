defmodule ServiceRadar.SweepJobs.Ingestion.DispatcherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.Ingestion.Dispatcher

  @group :sweep_ingestion_test_workers

  setup do
    scope = :"sweep_ingestion_test_scope_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: scope, start: {:pg, :start_link, [scope]}})
    test_pid = self()

    dispatcher =
      start_supervised!(
        {Dispatcher,
         name: nil,
         scope: scope,
         group: @group,
         fallback: {__MODULE__, :record_fallback, [test_pid]}}
      )

    %{scope: scope, dispatcher: dispatcher}
  end

  def record_fallback(status, test_pid), do: send(test_pid, {:fallback, status})

  # A stand-in worker: joins the group and reports every chunk it receives.
  # It acknowledges only when told to, so a test controls what is in flight.
  defp start_worker(scope, name) do
    test_pid = self()

    pid =
      spawn_link(fn ->
        :ok = :pg.join(scope, @group, self())
        send(test_pid, {:joined, name})
        worker_loop(test_pid, name)
      end)

    assert_receive {:joined, ^name}
    pid
  end

  defp worker_loop(test_pid, name) do
    receive do
      {:sweep_ingest, dispatcher, key, status} ->
        send(test_pid, {:received, name, key, status.seq, dispatcher})
        worker_loop(test_pid, name)

      {:ack, dispatcher, key} ->
        send(dispatcher, {:sweep_ingested, key, self()})
        worker_loop(test_pid, name)

      :stop ->
        :ok
    end
  end

  defp status(agent_id, group_id, seq) do
    %{
      source: "results",
      service_type: "sweep",
      agent_id: agent_id,
      seq: seq,
      message: Jason.encode!(%{"sweep_group_id" => group_id, "hosts" => []})
    }
  end

  # Waits until the dispatcher has seen `count` workers, so a test never
  # dispatches before membership has propagated.
  defp await_workers(dispatcher, count) do
    Enum.reduce_while(1..100, nil, fn _, _ ->
      if map_size(Dispatcher.state(dispatcher).workers) == count do
        {:halt, :ok}
      else
        Process.sleep(10)
        {:cont, nil}
      end
    end) || flunk("dispatcher never saw #{count} workers")
  end

  test "derives the partition key from the reporter and the payload's sweep group" do
    assert Dispatcher.partition_key(status("agent-a", "group-1", 1)) == {"agent-a", "group-1"}

    assert Dispatcher.partition_key(%{agent_id: "agent-a", message: "not json"}) ==
             {"agent-a", nil}

    assert Dispatcher.partition_key(%{agent_id: "agent-a"}) == {"agent-a", nil}
  end

  test "keeps a partition on its worker while it has chunks in flight", ctx do
    start_worker(ctx.scope, :w1)
    start_worker(ctx.scope, :w2)
    await_workers(ctx.dispatcher, 2)

    for seq <- 1..3, do: Dispatcher.dispatch(ctx.dispatcher, status("agent-a", "group-1", seq))

    assert_receive {:received, first, {"agent-a", "group-1"}, 1, _}
    assert_receive {:received, ^first, {"agent-a", "group-1"}, 2, _}
    assert_receive {:received, ^first, {"agent-a", "group-1"}, 3, _}
    refute_received {:received, _, _, _, _}
  end

  test "spreads partitions across the least-loaded workers", ctx do
    start_worker(ctx.scope, :w1)
    start_worker(ctx.scope, :w2)
    await_workers(ctx.dispatcher, 2)

    Dispatcher.dispatch(ctx.dispatcher, status("agent-a", "large", 1))
    Dispatcher.dispatch(ctx.dispatcher, status("agent-a", "small", 1))

    assert_receive {:received, large_worker, {"agent-a", "large"}, 1, _}
    assert_receive {:received, small_worker, {"agent-a", "small"}, 1, _}
    assert large_worker != small_worker
  end

  test "moves an idle partition to a less-loaded worker", ctx do
    workers = %{w1: start_worker(ctx.scope, :w1), w2: start_worker(ctx.scope, :w2)}
    await_workers(ctx.dispatcher, 2)

    # group-1 lands on worker x.
    Dispatcher.dispatch(ctx.dispatcher, status("agent-a", "group-1", 1))
    assert_receive {:received, x, {"agent-a", "group-1"} = group_1, 1, dispatcher}
    y = if x == :w1, do: :w2, else: :w1

    # Two chunks of another partition go to the idle worker y ...
    Dispatcher.dispatch(ctx.dispatcher, status("agent-b", "other", 1))
    Dispatcher.dispatch(ctx.dispatcher, status("agent-b", "other", 2))
    assert_receive {:received, ^y, {"agent-b", "other"} = other, 1, _}
    assert_receive {:received, ^y, ^other, 2, _}

    # ... and two chunks of a third partition then go to the less-loaded x.
    Dispatcher.dispatch(ctx.dispatcher, status("agent-c", "third", 1))
    Dispatcher.dispatch(ctx.dispatcher, status("agent-c", "third", 2))
    assert_receive {:received, ^x, {"agent-c", "third"}, 1, _}
    assert_receive {:received, ^x, {"agent-c", "third"}, 2, _}

    # group-1 finishes on x, and y works off one chunk: x now holds 2, y holds 1.
    send(workers[x], {:ack, dispatcher, group_1})
    send(workers[y], {:ack, dispatcher, other})
    await_loads(ctx.dispatcher, %{workers[x] => 2, workers[y] => 1})

    # With nothing in flight, group-1 is free to move to the less-loaded y.
    Dispatcher.dispatch(ctx.dispatcher, status("agent-a", "group-1", 2))
    assert_receive {:received, ^y, ^group_1, 2, _}
  end

  defp await_loads(dispatcher, expected) do
    Enum.reduce_while(1..100, nil, fn _, _ ->
      if Dispatcher.state(dispatcher).workers == expected do
        {:halt, :ok}
      else
        Process.sleep(10)
        {:cont, nil}
      end
    end) || flunk("dispatcher loads never reached #{inspect(expected)}")
  end

  test "releases a departed worker's partitions and reports its lost chunks", ctx do
    ref =
      :telemetry_test.attach_event_handlers(self(), [[:serviceradar, :sweep_ingestion, :lost]])

    w1 = start_worker(ctx.scope, :w1)
    await_workers(ctx.dispatcher, 1)

    Dispatcher.dispatch(ctx.dispatcher, status("agent-a", "group-1", 1))
    assert_receive {:received, :w1, _, 1, _}

    unlink_and_stop(w1)
    await_workers(ctx.dispatcher, 0)

    assert_receive {[:serviceradar, :sweep_ingestion, :lost], ^ref, %{count: 1}, _}
    assert Dispatcher.state(ctx.dispatcher).partitions == %{}

    start_worker(ctx.scope, :w2)
    await_workers(ctx.dispatcher, 1)
    Dispatcher.dispatch(ctx.dispatcher, status("agent-a", "group-1", 2))
    assert_receive {:received, :w2, _, 2, _}
  end

  test "falls back to the results router path when no worker is registered", ctx do
    chunk = status("agent-a", "group-1", 1)
    Dispatcher.dispatch(ctx.dispatcher, chunk)

    assert_receive {:fallback, ^chunk}
  end

  test "re-subscribes to a restarted scope and dispatches to new workers", ctx do
    start_worker(ctx.scope, :w1)
    await_workers(ctx.dispatcher, 1)

    scope_pid = Process.whereis(ctx.scope)
    scope_mon = Process.monitor(scope_pid)
    Process.exit(scope_pid, :kill)
    assert_receive {:DOWN, ^scope_mon, :process, ^scope_pid, _}

    await_workers(ctx.dispatcher, 0)

    wait_for_scope(ctx.scope)
    start_worker(ctx.scope, :w2)
    await_workers(ctx.dispatcher, 1)

    Dispatcher.dispatch(ctx.dispatcher, status("agent-a", "group-1", 1))
    assert_receive {:received, :w2, _, 1, _}
  end

  test "releases a worker killed without a :leave and emits lost telemetry", ctx do
    ref =
      :telemetry_test.attach_event_handlers(self(), [[:serviceradar, :sweep_ingestion, :lost]])

    w1 = start_worker(ctx.scope, :w1)
    await_workers(ctx.dispatcher, 1)

    Dispatcher.dispatch(ctx.dispatcher, status("agent-a", "group-1", 1))
    assert_receive {:received, :w1, _, 1, _}

    kill_worker(w1)
    await_workers(ctx.dispatcher, 0)

    assert_receive {[:serviceradar, :sweep_ingestion, :lost], ^ref, %{count: 1}, _}
    assert Dispatcher.state(ctx.dispatcher).partitions == %{}

    start_worker(ctx.scope, :w2)
    await_workers(ctx.dispatcher, 1)
    Dispatcher.dispatch(ctx.dispatcher, status("agent-a", "group-1", 2))
    assert_receive {:received, :w2, _, 2, _}
  end

  defp unlink_and_stop(pid) do
    Process.unlink(pid)
    monitor = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}
  end

  defp kill_worker(pid) do
    Process.unlink(pid)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}
  end

  defp wait_for_scope(scope) do
    Enum.reduce_while(1..100, nil, fn _, _ ->
      if is_pid(Process.whereis(scope)) do
        {:halt, :ok}
      else
        Process.sleep(10)
        {:cont, nil}
      end
    end) || flunk("scope #{inspect(scope)} did not restart")
  end
end
