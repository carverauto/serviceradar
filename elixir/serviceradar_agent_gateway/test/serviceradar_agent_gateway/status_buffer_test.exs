defmodule ServiceRadarAgentGateway.StatusBufferTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.Config
  alias ServiceRadarAgentGateway.StatusBuffer
  alias ServiceRadarAgentGateway.StatusHandlerTestHelpers

  setup do
    previous_config =
      try do
        {:ok, Config.get()}
      rescue
        ArgumentError -> :missing
      end

    Config.setup(gateway_id: "gateway-test", domain: "test", capabilities: [])
    on_exit(fn -> restore_config(previous_config) end)
  end

  test "overflow reports the evicted entry and retains the incoming entry" do
    handler_id = "status-buffer-overflow-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:serviceradar, :agent_gateway, :results, :buffer, :dropped],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, buffer} = StatusBuffer.start_link(name: nil, max_entries: 1, flush_interval_ms: 60_000)

    old_status = %{
      gateway_id: "gateway-old",
      partition: "partition-old",
      source: "results",
      service_type: "sync",
      message: "old"
    }

    new_status = %{
      gateway_id: "gateway-new",
      partition: "partition-new",
      source: "status",
      service_type: "agent",
      message: "new-and-larger"
    }

    assert :ok = GenServer.call(buffer, {:enqueue, old_status})
    assert :ok = GenServer.call(buffer, {:enqueue, new_status})

    assert_receive {:telemetry, [:serviceradar, :agent_gateway, :results, :buffer, :dropped],
                    %{count: 1, bytes: dropped_bytes}, metadata}

    assert dropped_bytes == :erlang.external_size(old_status)
    assert metadata.reason == :overflow
    assert metadata.gateway_id == "gateway-old"
    assert metadata.partition == "partition-old"
    assert metadata.source == "results"
    assert metadata.service_type == "sync"
    assert 1 == GenServer.call(buffer, :size)

    assert %{queue: queue, retained_bytes: retained_bytes} = :sys.get_state(buffer)
    assert :queue.to_list(queue) == [new_status]
    assert retained_bytes == :erlang.external_size(new_status)
  end

  # A core whose StatusHandler is slow to answer a reservation must not stall
  # the buffer's mailbox: PushStatus enqueues best-effort statuses with a short
  # call timeout, and a delivery running inside the buffer process made those
  # enqueues time out and count as drops whenever one core call was slow.
  test "accepts a status while a delivery waits on a slow core, then delivers both" do
    previous_admission = Application.fetch_env(:serviceradar_agent_gateway, :reserved_core_admission)
    Application.put_env(:serviceradar_agent_gateway, :reserved_core_admission, true)
    existing_handler = Process.whereis(ServiceRadar.StatusHandler)
    StatusHandlerTestHelpers.unregister_quietly(ServiceRadar.StatusHandler)

    parent = self()
    core = spawn(fn -> slow_core_loop(parent, :hold_next_reserve) end)
    Process.register(core, ServiceRadar.StatusHandler)

    on_exit(fn ->
      StatusHandlerTestHelpers.kill_and_await(core)
      StatusHandlerTestHelpers.restore(ServiceRadar.StatusHandler, existing_handler)

      case previous_admission do
        {:ok, value} -> Application.put_env(:serviceradar_agent_gateway, :reserved_core_admission, value)
        :error -> Application.delete_env(:serviceradar_agent_gateway, :reserved_core_admission)
      end
    end)

    start_supervised!({StatusBuffer, flush_interval_ms: 60_000})

    assert :ok = StatusBuffer.enqueue(best_effort_status("first"))
    StatusBuffer.request_flush()
    assert_receive {:reserve_held, ^core}, 1_000

    assert :ok = StatusBuffer.enqueue(best_effort_status("second"))
    assert 2 == StatusBuffer.size()

    send(core, :release)
    StatusBuffer.request_flush()

    assert_receive {:delivered, "first"}, 2_000
    assert_receive {:delivered, "second"}, 2_000
    refute_receive {:delivered, _service_name}, 100
    assert 0 == StatusBuffer.size()
  end

  # A failed delivery must not be retried at once into the core that just failed
  # to answer: the periodic tick that fires while the reservation waits is not a
  # flush request, so the retry waits a full flush interval after the failure.
  test "a failed delivery waits a full flush interval before the next attempt" do
    previous_admission = Application.fetch_env(:serviceradar_agent_gateway, :reserved_core_admission)
    Application.put_env(:serviceradar_agent_gateway, :reserved_core_admission, true)
    existing_handler = Process.whereis(ServiceRadar.StatusHandler)
    StatusHandlerTestHelpers.unregister_quietly(ServiceRadar.StatusHandler)

    parent = self()
    core = spawn(fn -> unanswered_reserve_core_loop(parent, :ignore_next_reserve) end)
    Process.register(core, ServiceRadar.StatusHandler)

    on_exit(fn ->
      StatusHandlerTestHelpers.kill_and_await(core)
      StatusHandlerTestHelpers.restore(ServiceRadar.StatusHandler, existing_handler)

      case previous_admission do
        {:ok, value} -> Application.put_env(:serviceradar_agent_gateway, :reserved_core_admission, value)
        :error -> Application.delete_env(:serviceradar_agent_gateway, :reserved_core_admission)
      end
    end)

    # 1_000 ms is the flush floor, shorter than the 1_100 ms reservation wait,
    # so a periodic tick fires while the first delivery is in flight.
    start_supervised!({StatusBuffer, flush_interval_ms: 1_000})

    assert :ok = StatusBuffer.enqueue(best_effort_status("first"))
    StatusBuffer.request_flush()
    assert_receive {:reserve, :ignored, first_at}, 1_000

    assert_receive {:reserve, :answered, retry_at}, 4_000
    assert_receive {:delivered, "first"}, 1_000

    # The reservation fails at about first_at + 1_100; the retry must not come
    # before one more flush interval has passed (about first_at + 2_100).
    assert retry_at - first_at >= 2_000
  end

  # Never answers the first reservation, so its caller times out; answers every
  # later one at once.
  defp unanswered_reserve_core_loop(parent, mode) do
    receive do
      {:"$gen_call", from, {:reserve_status, _descriptor}} ->
        now = System.monotonic_time(:millisecond)

        if mode == :ignore_next_reserve do
          send(parent, {:reserve, :ignored, now})
        else
          send(parent, {:reserve, :answered, now})
          GenServer.reply(from, {:ok, {self(), make_ref()}})
        end

        unanswered_reserve_core_loop(parent, :answer)

      {:"$gen_call", from, {:submit, _id, status, :best_effort}} ->
        send(parent, {:delivered, status.service_name})
        GenServer.reply(from, :ok)
        unanswered_reserve_core_loop(parent, mode)
    end
  end

  # Answers the first reservation only after the test releases it, and every
  # later one at once. Submitted payloads are reported to the test.
  defp slow_core_loop(parent, mode) do
    receive do
      {:"$gen_call", from, {:reserve_status, _descriptor}} ->
        if mode == :hold_next_reserve do
          send(parent, {:reserve_held, self()})
          receive(do: (:release -> :ok))
        end

        GenServer.reply(from, {:ok, {self(), make_ref()}})
        slow_core_loop(parent, :answer)

      {:"$gen_call", from, {:submit, _id, status, :best_effort}} ->
        send(parent, {:delivered, status.service_name})
        GenServer.reply(from, :ok)
        slow_core_loop(parent, mode)
    end
  end

  defp best_effort_status(service_name) do
    %{
      service_name: service_name,
      service_type: "agent",
      source: "status",
      available: true,
      message: "",
      agent_id: "agent-buffer-test",
      gateway_id: "gateway-test",
      partition: "default"
    }
  end

  defp restore_config({:ok, config}) do
    Config.setup(
      gateway_id: config.gateway_id,
      domain: config.domain,
      capabilities: config.capabilities
    )
  end

  defp restore_config(:missing), do: :persistent_term.erase(Config)
end
