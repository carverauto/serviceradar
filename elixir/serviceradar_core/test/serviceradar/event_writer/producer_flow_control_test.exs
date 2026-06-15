defmodule ServiceRadar.EventWriter.ProducerFlowControlTest do
  @moduledoc """
  Pure unit tests for the EventWriter producer's demand-based flow control.

  These exercise the GenStage callbacks directly (no NATS connection) to assert
  that the in-process buffer is bounded -- the regression that previously let the
  producer mailbox grow to 273k messages / 9.6GB refc binary and OOM-killed core.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Producer

  # A consumer reply_to subject so the producer treats it as a JetStream message
  # (the overflow NAK / drain paths are keyed on a non-empty reply_to).
  @reply_to "$JS.ACK.events.consumer.1.1.1.0.0"

  defp build_config(overrides) do
    base = %Config{
      enabled: false,
      nats: %{host: "localhost", port: 4222, tls: false},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "test-consumer",
      producer_name: nil,
      streams: [],
      max_ack_pending: 8,
      processor_concurrency: 4,
      ack_wait_ns: 120_000_000_000,
      max_deliver: 5
    }

    struct(base, overrides)
  end

  defp init_state(config) do
    # init/1 sends itself :connect; drain it so it does not leak into later asserts.
    {:producer, state} = Producer.init(config)
    flush_mailbox()
    # Pretend we are connected without a real socket; conn=nil makes ack/nak a no-op.
    %{state | connected: true, conn: nil}
  end

  defp push_msg(state, body) do
    msg = %{body: body, topic: "events.test", reply_to: @reply_to, headers: %{}}

    {:noreply, emitted, new_state} =
      Producer.handle_info({:msg, msg}, state)

    {emitted, new_state}
  end

  defp push_n(state, n) do
    Enum.reduce(1..n, {[], state}, fn i, {_emitted, acc_state} ->
      push_msg(acc_state, "payload-#{i}")
    end)
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  describe "max_buffered/1" do
    test "derives the producer buffer ceiling from per-consumer max_ack_pending" do
      assert Producer.max_buffered(build_config(max_ack_pending: 256)) == 512
    end

    test "never drops below the floor" do
      assert Producer.max_buffered(build_config(max_ack_pending: 1)) == 64
    end

    test "falls back to the config default when max_ack_pending is nil" do
      assert Producer.max_buffered(build_config(max_ack_pending: nil)) ==
               max(64, Config.default_max_ack_pending())
    end
  end

  describe "in-flight buffer is capped at the configured bound" do
    test "buffer never exceeds max_buffered no matter how many messages are pushed" do
      # max_ack_pending: 8 -> max_buffered = max(64, 16) = 64
      config = build_config(max_ack_pending: 8)
      state = init_state(config)
      bound = state.max_buffered

      # Push 10x the bound with zero downstream demand: a broken pipeline would
      # buffer all of them. The fix caps the buffer at `bound`.
      {emitted, state} = push_n(state, bound * 10)

      assert emitted == []
      assert state.pending_count == bound
      assert length(state.pending_messages) == bound
      # Everything beyond the bound was NAK'd back to the server, not retained.
      assert state.dropped_overflow == bound * 10 - bound
    end

    test "demand drains the buffer and re-opens capacity for new pushes" do
      config = build_config(max_ack_pending: 8)
      state = init_state(config)
      bound = state.max_buffered

      {[], state} = push_n(state, bound)
      assert state.pending_count == bound

      # Broadway asks for half the buffer.
      take = div(bound, 2)
      {:noreply, drained, state} = Producer.handle_demand(take, state)

      assert length(drained) == take
      assert state.pending_count == bound - take

      # New pushes are accepted again up to the bound (no overflow yet).
      {[], state} = push_n(state, take)
      assert state.pending_count == bound
    end

    test "preserves FIFO arrival order when draining" do
      config = build_config(max_ack_pending: 8)
      state = init_state(config)

      {[], state} = push_n(state, 5)
      {:noreply, drained, _state} = Producer.handle_demand(5, state)

      bodies = Enum.map(drained, & &1.data)
      assert bodies == ["payload-1", "payload-2", "payload-3", "payload-4", "payload-5"]
    end

    test "messages arriving under standing demand are emitted immediately, not buffered" do
      config = build_config(max_ack_pending: 8)
      state = init_state(config)

      # Standing demand of 3.
      {:noreply, [], state} = Producer.handle_demand(3, state)
      assert state.demand == 3

      {emitted, state} = push_msg(state, "live")
      assert Enum.map(emitted, & &1.data) == ["live"]
      assert state.pending_count == 0
      assert state.demand == 2
    end
  end
end
