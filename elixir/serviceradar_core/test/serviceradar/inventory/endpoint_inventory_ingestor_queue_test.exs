defmodule ServiceRadar.Inventory.EndpointInventoryIngestorQueueTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Inventory.EndpointInventoryIngestorQueue

  defmodule TestIngestor do
    @moduledoc false

    def ingest_report(payload, opts) do
      if pid = Application.get_env(:serviceradar_core, :endpoint_inventory_queue_test_pid) do
        send(pid, {:endpoint_inventory_ingest_started, payload, opts})
      end

      delay_ms =
        Map.get(payload, "delay_ms") ||
          endpoint_inventory_queue_test_delay_ms(payload, opts)

      if is_integer(delay_ms) and delay_ms > 0, do: Process.sleep(delay_ms)

      if pid = Application.get_env(:serviceradar_core, :endpoint_inventory_queue_test_pid) do
        send(pid, {:endpoint_inventory_ingest_finished, payload})
      end

      {:ok,
       %{
         agent_id: payload["agent_id"],
         scan_id: payload["scan_id"],
         directives: %{"endpoint_inventory" => %{"accepted" => true}}
       }}
    end

    defp endpoint_inventory_queue_test_delay_ms(payload, opts) do
      case Application.get_env(:serviceradar_core, :endpoint_inventory_queue_test_delay_ms, 0) do
        fun when is_function(fun, 2) -> fun.(payload, opts)
        delays when is_map(delays) -> Map.get(delays, payload["scan_id"], 0)
        delay_ms -> delay_ms
      end
    end
  end

  setup do
    previous_ingestor = Application.get_env(:serviceradar_core, :endpoint_inventory_ingestor)

    previous_callback =
      Application.get_env(:serviceradar_core, :endpoint_inventory_after_ingest_callback)

    previous_pid = Application.get_env(:serviceradar_core, :endpoint_inventory_queue_test_pid)

    previous_delay =
      Application.get_env(:serviceradar_core, :endpoint_inventory_queue_test_delay_ms)

    previous_max_concurrency =
      Application.get_env(:serviceradar_core, :endpoint_inventory_ingestor_max_concurrency)

    previous_max_pending =
      Application.get_env(:serviceradar_core, :endpoint_inventory_ingestor_queue_max_pending)

    previous_max_pending_per_agent =
      Application.get_env(
        :serviceradar_core,
        :endpoint_inventory_ingestor_queue_max_pending_per_agent
      )

    previous_ingest_timeout =
      Application.get_env(:serviceradar_core, :endpoint_inventory_ingestor_timeout_ms)

    Application.put_env(:serviceradar_core, :endpoint_inventory_ingestor, TestIngestor)
    Application.put_env(:serviceradar_core, :endpoint_inventory_queue_test_pid, self())
    Application.put_env(:serviceradar_core, :endpoint_inventory_ingestor_max_concurrency, 1)
    Application.put_env(:serviceradar_core, :endpoint_inventory_ingestor_queue_max_pending, 10)

    Application.put_env(
      :serviceradar_core,
      :endpoint_inventory_ingestor_queue_max_pending_per_agent,
      10
    )

    restart_task_supervisor(ServiceRadar.EndpointInventoryIngestor.TaskSupervisor)
    restart_queue()
    flush_mailbox()

    on_exit(fn ->
      restore_env(:endpoint_inventory_ingestor, previous_ingestor)
      restore_env(:endpoint_inventory_after_ingest_callback, previous_callback)
      restore_env(:endpoint_inventory_queue_test_pid, previous_pid)
      restore_env(:endpoint_inventory_queue_test_delay_ms, previous_delay)
      restore_env(:endpoint_inventory_ingestor_max_concurrency, previous_max_concurrency)
      restore_env(:endpoint_inventory_ingestor_queue_max_pending, previous_max_pending)

      restore_env(
        :endpoint_inventory_ingestor_queue_max_pending_per_agent,
        previous_max_pending_per_agent
      )

      restore_env(:endpoint_inventory_ingestor_timeout_ms, previous_ingest_timeout)
    end)

    :ok
  end

  test "enqueues async reports and processes them outside the caller" do
    payload = %{"agent_id" => "agent-queue-1", "scan_id" => "scan-queue-1"}

    assert :ok = EndpointInventoryIngestorQueue.enqueue(payload, actor: :test_actor)

    assert_receive {:endpoint_inventory_ingest_started, ^payload, opts}, 500
    assert opts[:actor] == :test_actor
    assert_receive {:endpoint_inventory_ingest_finished, ^payload}, 500
  end

  test "after-ingest callback runs only after ingest returns" do
    payload = %{"agent_id" => "agent-queue-callback", "scan_id" => "scan-queue-callback"}
    test_pid = self()

    Application.put_env(
      :serviceradar_core,
      :endpoint_inventory_after_ingest_callback,
      fn callback_payload, result, callback_opts ->
        send(
          test_pid,
          {:endpoint_inventory_after_ingest, callback_payload, result, callback_opts}
        )
      end
    )

    assert {:ok, result} =
             EndpointInventoryIngestorQueue.enqueue_and_wait(
               payload,
               [source: :callback_test],
               1_000
             )

    assert_receive {:endpoint_inventory_ingest_started, ^payload, _opts}, 500
    assert_receive {:endpoint_inventory_ingest_finished, ^payload}, 500

    assert_receive {:endpoint_inventory_after_ingest, ^payload, {:ok, callback_result},
                    callback_opts},
                   500

    assert result == callback_result
    assert callback_opts[:source] == :callback_test
  end

  test "synchronous callers wait for queued acknowledgement directives" do
    payload = %{"agent_id" => "agent-queue-sync", "scan_id" => "scan-queue-sync"}

    assert {:ok, result} = EndpointInventoryIngestorQueue.enqueue_and_wait(payload, [], 1_000)
    assert result.agent_id == "agent-queue-sync"
    assert result.directives["endpoint_inventory"]["accepted"] == true
  end

  test "configured synchronous timeout is below the outer status call budget" do
    configured_timeout =
      Application.fetch_env!(:serviceradar_core, :endpoint_inventory_ingestor_timeout_ms)

    assert configured_timeout == 20_000
    assert configured_timeout < 30_000
  end

  test "synchronous timeout terminates the in-flight ingestion task" do
    Application.put_env(:serviceradar_core, :endpoint_inventory_queue_test_delay_ms, 100)
    Application.put_env(:serviceradar_core, :endpoint_inventory_ingestor_timeout_ms, 10)

    payload = %{"agent_id" => "agent-queue-timeout", "scan_id" => "scan-queue-timeout"}

    assert {:error, :endpoint_inventory_ingest_queue_timeout} =
             EndpointInventoryIngestorQueue.enqueue_and_wait(payload)

    assert_receive {:endpoint_inventory_ingest_started, ^payload, _opts}, 500
    refute_receive {:endpoint_inventory_ingest_finished, ^payload}, 200
  end

  test "timed-out async ingestion frees the slot for the next queued job" do
    Application.put_env(:serviceradar_core, :endpoint_inventory_ingestor_timeout_ms, 20)

    slow = %{"agent_id" => "agent-queue-slow", "scan_id" => "scan-queue-slow", "delay_ms" => 200}
    fast = %{"agent_id" => "agent-queue-fast", "scan_id" => "scan-queue-fast", "delay_ms" => 0}

    assert :ok = EndpointInventoryIngestorQueue.enqueue(slow)
    assert_receive {:endpoint_inventory_ingest_started, ^slow, _opts}, 500

    assert {:ok, result} = EndpointInventoryIngestorQueue.enqueue_and_wait(fast, [], 1_000)

    assert result.agent_id == "agent-queue-fast"
    assert_receive {:endpoint_inventory_ingest_started, ^fast, _opts}, 500
    assert_receive {:endpoint_inventory_ingest_finished, ^fast}, 500
    refute_receive {:endpoint_inventory_ingest_finished, ^slow}, 100
  end

  test "bounded admission rejects when pending and inflight jobs fill capacity" do
    Application.put_env(:serviceradar_core, :endpoint_inventory_queue_test_delay_ms, 200)
    Application.put_env(:serviceradar_core, :endpoint_inventory_ingestor_queue_max_pending, 2)
    restart_queue()
    flush_mailbox()

    first = %{"agent_id" => "agent-queue-a", "scan_id" => "scan-queue-a"}
    second = %{"agent_id" => "agent-queue-b", "scan_id" => "scan-queue-b"}
    third = %{"agent_id" => "agent-queue-c", "scan_id" => "scan-queue-c"}

    assert :ok = EndpointInventoryIngestorQueue.enqueue(first)
    assert_receive {:endpoint_inventory_ingest_started, ^first, _opts}, 500

    assert :ok = EndpointInventoryIngestorQueue.enqueue(second)

    assert {:error, :endpoint_inventory_ingest_queue_full} =
             EndpointInventoryIngestorQueue.enqueue(third)

    assert_receive {:endpoint_inventory_ingest_started, ^second, _opts}, 1_000
  end

  test "per-agent admission rejects a noisy agent without filling global capacity" do
    Application.put_env(:serviceradar_core, :endpoint_inventory_queue_test_delay_ms, 200)
    Application.put_env(:serviceradar_core, :endpoint_inventory_ingestor_queue_max_pending, 10)

    Application.put_env(
      :serviceradar_core,
      :endpoint_inventory_ingestor_queue_max_pending_per_agent,
      2
    )

    restart_queue()
    flush_mailbox()

    first = %{"agent_id" => "agent-noisy", "scan_id" => "scan-noisy-a"}
    second = %{"agent_id" => "agent-noisy", "scan_id" => "scan-noisy-b"}
    third = %{"agent_id" => "agent-noisy", "scan_id" => "scan-noisy-c"}
    other_agent = %{"agent_id" => "agent-other", "scan_id" => "scan-other-a"}

    assert :ok = EndpointInventoryIngestorQueue.enqueue(first)
    assert_receive {:endpoint_inventory_ingest_started, ^first, _opts}, 500

    assert :ok = EndpointInventoryIngestorQueue.enqueue(second)

    assert {:error, :endpoint_inventory_ingest_queue_full} =
             EndpointInventoryIngestorQueue.enqueue(third)

    assert :ok = EndpointInventoryIngestorQueue.enqueue(other_agent)
  end

  test "fair dequeue prefers an agent without an in-flight ingest when a slot opens" do
    Application.put_env(:serviceradar_core, :endpoint_inventory_ingestor_max_concurrency, 2)
    Application.put_env(:serviceradar_core, :endpoint_inventory_ingestor_queue_max_pending, 10)
    Application.put_env(:serviceradar_core, :endpoint_inventory_ingestor_timeout_ms, 2_000)

    Application.put_env(
      :serviceradar_core,
      :endpoint_inventory_ingestor_queue_max_pending_per_agent,
      10
    )

    Application.put_env(:serviceradar_core, :endpoint_inventory_queue_test_delay_ms, %{
      "scan-fair-a1" => 80,
      "scan-fair-a2" => 500,
      "scan-fair-a3" => 0,
      "scan-fair-b1" => 300
    })

    restart_queue()
    flush_mailbox()

    first = %{"agent_id" => "agent-fair-a", "scan_id" => "scan-fair-a1"}
    second = %{"agent_id" => "agent-fair-a", "scan_id" => "scan-fair-a2"}
    third = %{"agent_id" => "agent-fair-a", "scan_id" => "scan-fair-a3"}
    other_agent = %{"agent_id" => "agent-fair-b", "scan_id" => "scan-fair-b1"}

    assert :ok = EndpointInventoryIngestorQueue.enqueue(first)
    assert :ok = EndpointInventoryIngestorQueue.enqueue(second)
    assert :ok = EndpointInventoryIngestorQueue.enqueue(third)
    assert :ok = EndpointInventoryIngestorQueue.enqueue(other_agent)

    assert_receive {:endpoint_inventory_ingest_started, ^first, _opts}, 500
    assert_receive {:endpoint_inventory_ingest_started, ^second, _opts}, 500
    assert_receive {:endpoint_inventory_ingest_finished, ^first}, 1_000

    assert_receive {:endpoint_inventory_ingest_started, ^other_agent, _opts}, 500
    refute_receive {:endpoint_inventory_ingest_started, ^third, _opts}, 50
  end

  test "returns unavailable when queue is not running instead of ingesting inline" do
    queue_pid = Process.whereis(EndpointInventoryIngestorQueue)

    if is_pid(queue_pid) do
      Process.unregister(EndpointInventoryIngestorQueue)
    end

    on_exit(fn ->
      if is_pid(queue_pid) and Process.alive?(queue_pid) and
           is_nil(Process.whereis(EndpointInventoryIngestorQueue)) do
        Process.register(queue_pid, EndpointInventoryIngestorQueue)
      end
    end)

    payload = %{"agent_id" => "agent-queue-down", "scan_id" => "scan-queue-down"}

    assert {:error, :endpoint_inventory_ingest_queue_unavailable} =
             EndpointInventoryIngestorQueue.enqueue(payload)

    refute_receive {:endpoint_inventory_ingest_started, ^payload, _opts}, 200
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)

  defp restart_task_supervisor(name) do
    stop_process(name)

    case start_supervised({Task.Supervisor, name: name}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp restart_queue do
    stop_supervised_child(EndpointInventoryIngestorQueue)

    case start_supervised(EndpointInventoryIngestorQueue) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp stop_supervised_child(child_id) do
    case stop_supervised(child_id) do
      :ok -> :ok
      {:error, :not_found} -> stop_process(child_id)
    end
  end

  defp stop_process(name) do
    if pid = Process.whereis(name) do
      ref = Process.monitor(pid)
      Process.exit(pid, :shutdown)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        1_000 -> :ok
      end
    end

    :ok
  end

  defp flush_mailbox do
    receive do
      _message -> flush_mailbox()
    after
      0 -> :ok
    end
  end
end
