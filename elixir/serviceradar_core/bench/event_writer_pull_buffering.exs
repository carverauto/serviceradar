defmodule ServiceRadar.Bench.EventWriterPullBuffering do
  @moduledoc false

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Producer

  @reply_to "$JS.ACK.metrics.serviceradar-event-writer.1.1.1.0.0"

  def run do
    mode = env("EVENT_WRITER_BUFFER_BENCH_MODE", "buffer_drain")
    messages = env_int("EVENT_WRITER_BUFFER_BENCH_MESSAGES", 100_000)
    payload_bytes = env_int("EVENT_WRITER_BUFFER_BENCH_PAYLOAD_BYTES", 1024)
    pull_batch_size = env_int("EVENT_WRITER_BUFFER_BENCH_PULL_BATCH_SIZE", 16)
    max_ack_pending = env_int("EVENT_WRITER_BUFFER_BENCH_MAX_ACK_PENDING", messages)

    config =
      build_config(
        consumer_pull_batch_size: pull_batch_size,
        max_ack_pending: max_ack_pending
      )

    payload = :binary.copy("x", payload_bytes)

    IO.puts("""
    EventWriter pull/buffering benchmark
    mode=#{mode}
    messages=#{messages}
    payload_bytes=#{payload_bytes}
    pull_batch_size=#{pull_batch_size}
    max_ack_pending=#{max_ack_pending}
    """)

    :erlang.garbage_collect()
    memory_before = :erlang.memory(:total)
    started_at = System.monotonic_time()

    result = run_mode(mode, config, payload, messages)

    elapsed = System.monotonic_time() - started_at
    :erlang.garbage_collect()
    memory_after = :erlang.memory(:total)

    elapsed_s = System.convert_time_unit(elapsed, :native, :microsecond) / 1_000_000
    messages_per_second = result.messages / max(elapsed_s, 0.001)
    payload_mib = result.messages * payload_bytes / 1_048_576
    payload_mib_per_second = payload_mib / max(elapsed_s, 0.001)

    IO.puts("""
    Results
    elapsed_seconds=#{fmt(elapsed_s)}
    messages=#{result.messages}
    messages_per_second=#{round(messages_per_second)}
    payload_mib=#{fmt(payload_mib)}
    payload_mib_per_second=#{fmt(payload_mib_per_second)}
    emitted=#{result.emitted}
    pending_count=#{result.pending_count}
    dropped_overflow=#{result.dropped_overflow}
    max_buffered=#{result.max_buffered}
    memory_delta_mb=#{fmt((memory_after - memory_before) / 1_048_576)}
    """)
  end

  defp run_mode("buffer_drain", config, payload, messages) do
    state = init_state(config)

    {enqueued, state} =
      timed_count(messages, state, fn index, acc_state ->
        push_msg(acc_state, payload, index)
      end)

    {:noreply, emitted, state} = Producer.handle_demand(enqueued, state)

    %{
      messages: enqueued,
      emitted: length(emitted),
      pending_count: state.pending_count,
      dropped_overflow: state.dropped_overflow,
      max_buffered: state.max_buffered
    }
  end

  defp run_mode("standing_demand", config, payload, messages) do
    state = init_state(config)
    {:noreply, [], state} = Producer.handle_demand(messages, state)

    {emitted, state} =
      Enum.reduce(1..messages, {0, state}, fn index, {count, acc_state} ->
        {:noreply, emitted, next_state} =
          Producer.handle_info({:msg, message(payload, index)}, acc_state)

        {count + length(emitted), next_state}
      end)

    %{
      messages: messages,
      emitted: emitted,
      pending_count: state.pending_count,
      dropped_overflow: state.dropped_overflow,
      max_buffered: state.max_buffered
    }
  end

  defp run_mode(mode, _config, _payload, _messages) do
    raise "unsupported EVENT_WRITER_BUFFER_BENCH_MODE=#{inspect(mode)}; expected buffer_drain or standing_demand"
  end

  defp timed_count(messages, state, fun) do
    Enum.reduce(1..messages, {0, state}, fn index, {count, acc_state} ->
      case fun.(index, acc_state) do
        {:ok, next_state} -> {count + 1, next_state}
        {:overflow, next_state} -> {count, next_state}
      end
    end)
  end

  defp push_msg(state, payload, index) do
    {:noreply, emitted, next_state} = Producer.handle_info({:msg, message(payload, index)}, state)

    case emitted do
      [] -> {:ok, next_state}
      _ -> {:ok, next_state}
    end
  end

  defp message(payload, index) do
    %{
      body: payload,
      topic: "metrics.sysmon.bench",
      reply_to: "#{@reply_to}.#{index}",
      headers: %{}
    }
  end

  defp init_state(config) do
    {:producer, state} = Producer.init(config)
    flush_mailbox()
    %{state | connected: true, conn: nil}
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp build_config(overrides) do
    base = %Config{
      enabled: false,
      nats: %{host: "localhost", port: 4222, tls: false},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "bench-consumer",
      producer_name: nil,
      streams: [],
      consumer_pull_batch_size: 16,
      max_ack_pending: 100_000,
      processor_concurrency: 4,
      ack_wait_ns: 120_000_000_000,
      max_deliver: 5
    }

    struct(base, overrides)
  end

  defp env(name, default), do: System.get_env(name) || default

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> parse_int(value, default)
    end
  end

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value), do: to_string(value)
end

ServiceRadar.Bench.EventWriterPullBuffering.run()
