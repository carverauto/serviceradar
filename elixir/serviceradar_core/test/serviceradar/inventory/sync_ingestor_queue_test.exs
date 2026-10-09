defmodule ServiceRadar.Inventory.SyncIngestorQueueTest do
  @moduledoc """
  Tests for sync ingestion queue behavior.

  In schema-agnostic mode, operates as a single queue since the DB schema
  is set by CNPG search_path credentials.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Ingestion.WorkerBudget
  alias ServiceRadar.Inventory.SyncIngestorQueue

  defmodule TestIngestor do
    @moduledoc false
    def ingest_updates(updates, _opts) do
      if pid = Application.get_env(:serviceradar_core, :sync_ingestor_test_pid) do
        send(pid, {:ingest_started, updates})
      end

      delay_ms = next_delay_ms()
      if is_integer(delay_ms) and delay_ms > 0, do: Process.sleep(delay_ms)

      if pid = Application.get_env(:serviceradar_core, :sync_ingestor_test_pid) do
        send(pid, :ingest_finished)
      end

      :ok
    end

    # :sync_ingestor_test_delays scripts one delay per ingest call, in order;
    # once it is used up, every call takes :sync_ingestor_test_delay_ms.
    defp next_delay_ms do
      case Application.get_env(:serviceradar_core, :sync_ingestor_test_delays, []) do
        [delay_ms | rest] ->
          Application.put_env(:serviceradar_core, :sync_ingestor_test_delays, rest)
          delay_ms

        [] ->
          Application.get_env(:serviceradar_core, :sync_ingestor_test_delay_ms, 0)
      end
    end
  end

  setup do
    previous = Application.get_env(:serviceradar_core, :sync_ingestor)
    previous_coalesce = Application.get_env(:serviceradar_core, :sync_ingestor_coalesce_ms)
    previous_queue_max = Application.get_env(:serviceradar_core, :sync_ingestor_queue_max_chunks)
    previous_delay = Application.get_env(:serviceradar_core, :sync_ingestor_test_delay_ms)
    previous_delays = Application.get_env(:serviceradar_core, :sync_ingestor_test_delays)
    previous_timeout = Application.get_env(:serviceradar_core, :sync_ingestor_worker_timeout_ms)
    previous_pid = Application.get_env(:serviceradar_core, :sync_ingestor_test_pid)
    previous_queue_server = Application.get_env(:serviceradar_core, :sync_ingestor_queue_server)

    Application.put_env(:serviceradar_core, :sync_ingestor, TestIngestor)
    Application.put_env(:serviceradar_core, :sync_ingestor_test_pid, self())

    if !Process.whereis(WorkerBudget) do
      start_supervised!({WorkerBudget, pool_size: 10})
    end

    {:ok, sync_task_supervisor} = start_supervised(Task.Supervisor)

    {:ok, sync_queue} =
      start_supervised({SyncIngestorQueue, name: nil, task_supervisor: sync_task_supervisor})

    Application.put_env(:serviceradar_core, :sync_ingestor_queue_server, sync_queue)
    flush_mailbox()

    on_exit(fn ->
      restore_env(:sync_ingestor, previous)
      restore_env(:sync_ingestor_coalesce_ms, previous_coalesce)
      restore_env(:sync_ingestor_queue_max_chunks, previous_queue_max)
      restore_env(:sync_ingestor_test_delay_ms, previous_delay)
      restore_env(:sync_ingestor_test_delays, previous_delays)
      restore_env(:sync_ingestor_worker_timeout_ms, previous_timeout)
      restore_env(:sync_ingestor_test_pid, previous_pid)
      restore_env(:sync_ingestor_queue_server, previous_queue_server)
    end)

    :ok
  end

  test "coalesces bursts and preserves arrival order" do
    Application.put_env(:serviceradar_core, :sync_ingestor_coalesce_ms, 50)
    Application.put_env(:serviceradar_core, :sync_ingestor_queue_max_chunks, 10)

    update1 = %{"device_id" => "dev-1", "ip" => "10.0.0.1"}
    update2 = %{"device_id" => "dev-2", "ip" => "10.0.0.2"}

    assert :ok = SyncIngestorQueue.enqueue(Jason.encode!([update1]))
    assert :ok = SyncIngestorQueue.enqueue(Jason.encode!([update2]))

    assert_receive {:ingest_started, updates}, 500
    assert [^update1, ^update2] = updates
  end

  test "processes batches sequentially" do
    Application.put_env(:serviceradar_core, :sync_ingestor_coalesce_ms, 10)
    Application.put_env(:serviceradar_core, :sync_ingestor_queue_max_chunks, 10)
    Application.put_env(:serviceradar_core, :sync_ingestor_test_delay_ms, 200)

    assert :ok = SyncIngestorQueue.enqueue(Jason.encode!([%{"device_id" => "dev-a"}]))

    # Let the first batch become inflight before adding the second.
    assert_receive {:ingest_started, _updates}, 2_000

    assert :ok = SyncIngestorQueue.enqueue(Jason.encode!([%{"device_id" => "dev-b"}]))

    # Second batch should wait until first finishes
    refute_receive {:ingest_started, _updates}, 150
    assert_receive :ingest_finished, 2_000
    assert_receive {:ingest_started, _updates}, 2_000
  end

  test "a batch takes at most queue_max_chunks chunks" do
    Application.put_env(:serviceradar_core, :sync_ingestor_coalesce_ms, 50)
    Application.put_env(:serviceradar_core, :sync_ingestor_queue_max_chunks, 2)
    # The first batch runs long enough for the other three chunks to queue up.
    Application.put_env(:serviceradar_core, :sync_ingestor_test_delays, [300])

    devices = for n <- 1..5, do: %{"device_id" => "dev-#{n}"}
    Enum.each(devices, &assert(:ok = SyncIngestorQueue.enqueue(Jason.encode!([&1]))))

    batches = receive_batches(length(devices))

    assert List.flatten(batches) == devices

    assert Enum.all?(batches, &(length(&1) <= 2)),
           "batch sizes: #{inspect(Enum.map(batches, &length/1))}"
  end

  test "a timed-out batch is retried with its own chunks, not with later arrivals" do
    Application.put_env(:serviceradar_core, :sync_ingestor_coalesce_ms, 50)
    Application.put_env(:serviceradar_core, :sync_ingestor_queue_max_chunks, 2)
    Application.put_env(:serviceradar_core, :sync_ingestor_worker_timeout_ms, 100)
    # Only the first attempt hangs; the timeout kills it.
    Application.put_env(:serviceradar_core, :sync_ingestor_test_delays, [10_000])

    a = %{"device_id" => "dev-a"}
    b = %{"device_id" => "dev-b"}
    c = %{"device_id" => "dev-c"}

    assert :ok = SyncIngestorQueue.enqueue(Jason.encode!([a]))
    assert :ok = SyncIngestorQueue.enqueue(Jason.encode!([b]))
    assert_receive {:ingest_started, [^a, ^b]}, 1_000

    assert :ok = SyncIngestorQueue.enqueue(Jason.encode!([c]))

    assert_receive {:ingest_started, retry}, 2_000
    assert retry == [a, b]
    assert_receive {:ingest_started, [^c]}, 2_000
  end

  test "a batch's deadline grows with the chunks it carries" do
    Application.put_env(:serviceradar_core, :sync_ingestor_coalesce_ms, 50)
    Application.put_env(:serviceradar_core, :sync_ingestor_queue_max_chunks, 3)
    Application.put_env(:serviceradar_core, :sync_ingestor_worker_timeout_ms, 500)
    # Longer than one chunk's budget, well inside three chunks' budget.
    Application.put_env(:serviceradar_core, :sync_ingestor_test_delays, [800])

    devices = for n <- 1..3, do: %{"device_id" => "dev-#{n}"}
    Enum.each(devices, &assert(:ok = SyncIngestorQueue.enqueue(Jason.encode!([&1]))))

    assert_receive {:ingest_started, ^devices}, 1_000
    assert_receive :ingest_finished, 3_000
    refute_receive {:ingest_started, _updates}, 300
  end

  test "keeps different sync run envelopes in separate arrival-ordered groups" do
    batch = fn source_id, run_id, chunk_index, device_id ->
      [
        %{
          "device_id" => device_id,
          "sync_meta" => %{
            "sync_service_id" => source_id,
            "sync_run_id" => run_id,
            "chunk_index" => chunk_index,
            "total_chunks" => 3,
            "is_final" => false
          }
        }
      ]
    end

    a1 = batch.("source-a", "run-a", 0, "a-1")
    a2 = batch.("source-a", "run-a", 1, "a-2")
    b1 = batch.("source-b", "run-b", 0, "b-1")
    a3 = batch.("source-a", "run-a", 2, "a-3")

    assert SyncIngestorQueue.group_batches_for_ingestion([a1, a2, b1, a3]) == [
             List.flatten([a1, a2]),
             b1,
             a3
           ]
  end

  test "deduplicates repeated deliveries of the same chunk by run_id and chunk_index" do
    chunk = fn chunk_index, device_id ->
      [
        %{
          "device_id" => device_id,
          "sync_meta" => %{
            "sync_service_id" => "source-a",
            "sync_run_id" => "run-dup",
            "chunk_index" => chunk_index,
            "total_chunks" => 2,
            "is_final" => false
          }
        }
      ]
    end

    c0_a = chunk.(0, "device-a")
    c0_b = chunk.(0, "device-b")
    c0_c = chunk.(0, "device-c")
    c1 = chunk.(1, "device-x")

    result = SyncIngestorQueue.group_batches_for_ingestion([c0_a, c0_b, c0_c, c1])

    assert result == [List.flatten([c0_a, c1])]
  end

  test "strips an accounting-only collection final marker from device ingestion" do
    control = %{
      "_sync_control" => "collection_final",
      "timestamp" => "2026-09-01T08:00:00Z",
      "sync_meta" => %{"is_final" => true}
    }

    device = %{"device_id" => "device-a"}

    assert SyncIngestorQueue.strip_sync_control_updates([control, device]) == [device]
  end

  defp receive_batches(expected_updates, batches \\ []) do
    if batches |> List.flatten() |> length() >= expected_updates do
      Enum.reverse(batches)
    else
      assert_receive {:ingest_started, updates}, 2_000
      receive_batches(expected_updates, [updates | batches])
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)

  defp flush_mailbox do
    receive do
      _message -> flush_mailbox()
    after
      0 -> :ok
    end
  end
end
