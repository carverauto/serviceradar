defmodule ServiceRadar.AgentConfig.ConfigInvalidatorTest do
  @moduledoc """
  Bounded invalidation contract (#5341): a click storm of interface toggles
  must coalesce into at most a few supervised rebuilds, never run the
  fleet-wide push in the caller's process, and a runaway rebuild must die
  alone instead of taking the node down.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.AgentConfig.ConfigInvalidator

  @moduletag :db_free
  @debounce_ms 30

  setup do
    start_supervised!({Task.Supervisor, name: ConfigInvalidatorTest.TaskSupervisor})
    test_pid = self()

    {:ok, pushes} = Agent.start_link(fn -> [] end)

    # Holds the FIRST push open until the test releases it, so storms can
    # arrive mid-flight; every later push completes immediately.
    push = fn config_type ->
      worker = self()
      first? = Agent.get(pushes, &(&1 == []))

      Agent.update(pushes, fn list ->
        send(test_pid, {:push_started, config_type, worker})
        [config_type | list]
      end)

      if first? do
        receive do
          :release_first_push -> :ok
        after
          5_000 -> :ok
        end
      end

      :ok
    end

    Application.put_env(:serviceradar_core, :config_invalidator_debounce_ms, @debounce_ms)

    on_exit(fn ->
      Application.delete_env(:serviceradar_core, :config_invalidator_debounce_ms)
    end)

    {:ok, push: push, pushes: pushes}
  end

  defp start_invalidator!(ctx, opts \\ []) do
    start_supervised!(
      {ConfigInvalidator,
       Keyword.merge(
         [
           task_supervisor: ConfigInvalidatorTest.TaskSupervisor,
           push: ctx.push
         ],
         opts
       )}
    )
  end

  test "a storm of invalidates coalesces into one rebuild", ctx do
    invalidator = start_invalidator!(ctx, name: :storm_test_invalidator)

    for _i <- 1..60, do: GenServer.cast(invalidator, {:invalidate, :snmp})

    assert_receive {:push_started, :snmp, worker_pid}, 1_000
    send(worker_pid, :release_first_push)

    refute_receive {:push_started, :snmp, _second}, ceil(@debounce_ms * 4)

    assert Agent.get(ctx.pushes, &length/1) == 1
  end

  test "invalidates arriving mid-rebuild produce exactly one follow-up", ctx do
    invalidator = start_invalidator!(ctx, name: :midflight_test_invalidator)

    GenServer.cast(invalidator, {:invalidate, :snmp})

    assert_receive {:push_started, :snmp, worker_pid}, 1_000

    # The storm arrives while the first rebuild is held open.
    for _i <- 1..50, do: GenServer.cast(invalidator, {:invalidate, :snmp})

    send(worker_pid, :release_first_push)

    assert_receive {:push_started, :snmp, _second}, 1_000
    refute_receive {:push_started, :snmp, _third}, ceil(@debounce_ms * 4)

    assert Agent.get(ctx.pushes, &length/1) == 2
  end

  test "the rebuild never runs in the caller's or the invalidator's process", ctx do
    invalidator = start_invalidator!(ctx, name: :caller_test_invalidator)

    GenServer.cast(invalidator, {:invalidate, :visibility})

    assert_receive {:push_started, :visibility, worker_pid}, 1_000
    send(worker_pid, :release_first_push)

    refute worker_pid == self()
    refute worker_pid == invalidator
  end

  @tag :capture_log
  test "a rebuild exceeding max_heap_size is killed and the invalidator survives", ctx do
    test_pid = self()

    # The default push cannot balloon deterministically, so this worker
    # allocates past a tiny limit instead: the accumulator stays live across
    # the reduce, so the heap grows past 10_000 words and the flag kills the
    # worker before it returns.
    bloater = fn config_type ->
      list = Enum.reduce(1..500_000, [], fn i, acc -> [i | acc] end)
      {config_type, length(list)}
    end

    invalidator =
      start_invalidator!(ctx,
        name: :heap_test_invalidator,
        push: bloater,
        max_heap_words: 10_000
      )

    handler_id = {:heap_kill_test, make_ref()}

    :telemetry.attach(
      handler_id,
      [:serviceradar, :agent_config, :config_push],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:push_telemetry, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    GenServer.cast(invalidator, {:invalidate, :sysmon})

    assert_receive {:push_telemetry, %{reason: :max_heap_size_killed, config_type: :sysmon}},
                   5_000

    # The GenServer survived the kill and still accepts work.
    assert Process.alive?(invalidator)
    GenServer.cast(invalidator, {:invalidate, :sysmon})
    assert Process.alive?(invalidator)
  end

  test "telemetry reports duration and the coalesced count", ctx do
    test_pid = self()
    invalidator = start_invalidator!(ctx, name: :telemetry_test_invalidator)

    handler_id = {:telemetry_test, make_ref()}

    :telemetry.attach(
      handler_id,
      [:serviceradar, :agent_config, :config_push],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    for _i <- 1..7, do: GenServer.cast(invalidator, {:invalidate, :sweep})

    assert_receive {:push_started, :sweep, worker_pid}, 1_000
    send(worker_pid, :release_first_push)

    assert_receive {:telemetry, %{duration_ms: ms, coalesced: 7},
                    %{config_type: :sweep, reason: :normal}},
                   1_000

    assert is_integer(ms)
  end

  test "ConfigServer.invalidate casts to the invalidator and stays cheap for the caller", ctx do
    # The production wiring: the invalidator registered under its own name
    # (what ConfigServer.invalidate/1 casts to) runs with a stubbed push; the
    # cache side guards a missing ETS table itself, so no app start is needed.
    start_invalidator!(ctx, name: ConfigInvalidator)

    assert :ok = ServiceRadar.AgentConfig.ConfigServer.invalidate(:snmp)

    assert_receive {:push_started, :snmp, worker_pid}, 1_000
    send(worker_pid, :release_first_push)
  end
end
