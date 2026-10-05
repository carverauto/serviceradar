defmodule ServiceRadar.AgentCommands.StatusHandlerShardingTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.AgentCommands.PubSub
  alias ServiceRadar.AgentCommands.StatusHandler

  @moduletag :db_free
  @command_a "00000000-0000-4000-8000-000000000001"
  @command_b "00000000-0000-4000-8000-000000000002"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    if !Process.whereis(ServiceRadar.PubSub) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    :ok = PubSub.subscribe()
    :ok
  end

  test "interleaved commands preserve persistence, public update and release-consumer order" do
    test_pid = self()
    release = fn kind -> fn data -> send(test_pid, {:release, data.command_id, kind}) end end

    start_handler(test_pid,
      ack_consumer: release.(:ack),
      progress_consumers: [fn _data -> :ok end, fn _data -> :ok end, release.(:progress)],
      result_consumers: [fn _data -> :ok end, fn _data -> :ok end, release.(:result)]
    )

    for command_id <- [@command_a, @command_b], do: PubSub.broadcast_ack(update(command_id))
    for command_id <- [@command_a, @command_b], do: PubSub.broadcast_progress(update(command_id))
    for command_id <- [@command_a, @command_b], do: PubSub.broadcast_result(update(command_id))

    persisted =
      for _message <- 1..6 do
        assert_receive {:persisted, command_id, kind}, 2_000
        {command_id, kind}
      end

    releases =
      for _message <- 1..6 do
        assert_receive {:release, command_id, kind}, 2_000
        {command_id, kind}
      end

    public =
      for _message <- 1..6 do
        assert_receive {kind, %{command_id: command_id}}, 2_000
        {command_id, kind}
      end

    for command_id <- [@command_a, @command_b] do
      assert kinds(persisted, command_id) == [:ack, :progress, :result]
      assert kinds(releases, command_id) == [:ack, :progress, :result]
      assert kinds(public, command_id) == [:command_ack, :command_progress, :command_result]
    end
  end

  test "one blocked result consumer delays neither another consumer nor command persistence" do
    test_pid = self()

    blocked_consumer = fn
      %{command_id: @command_a} ->
        send(test_pid, {:consumer_blocked, self()})

        receive do
          :release_consumer -> send(test_pid, :consumer_finished)
        after
          5_000 -> send(test_pid, :consumer_timed_out)
        end

      _data ->
        :ok
    end

    consumers =
      [blocked_consumer] ++
        for lane <- [:adhoc_scan, :release, :ansible, :northbound] do
          fn data -> send(test_pid, {:consumed, lane, data.command_id}) end
        end

    start_handler(test_pid, result_consumers: consumers)
    PubSub.broadcast_result(update(@command_a))
    assert_receive {:command_result, %{command_id: @command_a}}, 2_000
    assert_receive {:consumer_blocked, consumer_pid}, 2_000

    try do
      PubSub.broadcast_ack(update(@command_b))
      PubSub.broadcast_progress(update(@command_b))
      PubSub.broadcast_result(update(@command_b))

      assert_receive {:command_ack, %{command_id: @command_b}}, 2_000
      assert_receive {:command_progress, %{command_id: @command_b}}, 2_000
      assert_receive {:command_result, %{command_id: @command_b}}, 2_000

      for lane <- [:adhoc_scan, :release, :ansible, :northbound] do
        assert_receive {:consumed, ^lane, @command_a}, 2_000
      end

      refute_received :consumer_finished
      refute_received :consumer_timed_out
    after
      send(consumer_pid, :release_consumer)
    end

    assert_receive :consumer_finished, 2_000
  end

  defp start_handler(test_pid, opts) do
    defaults = [
      ack_persister: persister(test_pid, :ack),
      progress_persister: persister(test_pid, :progress),
      result_persister: persister(test_pid, :result),
      ack_consumer: fn _data -> :ok end,
      progress_consumers: [],
      result_consumers: [],
      cleanup_reconciler: fn _data -> :ok end,
      callback_result_coordinator: fn _data -> :ok end,
      secure_execution_result_coordinator: fn _data -> :ok end,
      result_coordination_dispatcher: fn work ->
        work.()
        :ok
      end
    ]

    start_supervised!({StatusHandler, Keyword.merge(defaults, opts)})
  end

  defp persister(test_pid, kind) do
    fn data, _actor ->
      send(test_pid, {:persisted, data.command_id, kind})
      :ok
    end
  end

  defp kinds(messages, command_id) do
    for {^command_id, kind} <- messages, do: kind
  end

  defp update(command_id) do
    %{
      command_id: command_id,
      command_type: "test.status",
      agent_id: "agent01.example.com",
      partition_id: "default",
      message: "synthetic command update",
      success: true,
      progress_percent: 50,
      payload: %{}
    }
  end
end
