defmodule ServiceRadar.Inventory.SyncIngestorQueueTest do
  @moduledoc """
  Tests for sync ingestion queue behavior.

  In schema-agnostic mode, operates as a single queue since the DB schema
  is set by CNPG search_path credentials.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Inventory.SyncIngestorQueue

  defmodule TestIngestor do
    @moduledoc false
    def ingest_updates(updates, _opts) do
      if pid = Application.get_env(:serviceradar_core, :sync_ingestor_test_pid) do
        send(pid, {:ingest_started, updates})
      end

      delay_ms = Application.get_env(:serviceradar_core, :sync_ingestor_test_delay_ms, 0)
      if is_integer(delay_ms) and delay_ms > 0, do: Process.sleep(delay_ms)

      if pid = Application.get_env(:serviceradar_core, :sync_ingestor_test_pid) do
        send(pid, :ingest_finished)
      end

      :ok
    end
  end

  setup do
    previous = Application.get_env(:serviceradar_core, :sync_ingestor)
    previous_coalesce = Application.get_env(:serviceradar_core, :sync_ingestor_coalesce_ms)
    previous_queue_max = Application.get_env(:serviceradar_core, :sync_ingestor_queue_max_chunks)
    previous_delay = Application.get_env(:serviceradar_core, :sync_ingestor_test_delay_ms)
    previous_pid = Application.get_env(:serviceradar_core, :sync_ingestor_test_pid)
    previous_queue_server = Application.get_env(:serviceradar_core, :sync_ingestor_queue_server)

    previous_max_pending =
      Application.get_env(:serviceradar_core, :sync_ingestor_queue_max_pending_chunks)

    Application.put_env(:serviceradar_core, :sync_ingestor, TestIngestor)
    Application.put_env(:serviceradar_core, :sync_ingestor_test_pid, self())

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
      restore_env(:sync_ingestor_test_pid, previous_pid)
      restore_env(:sync_ingestor_queue_server, previous_queue_server)
      restore_env(:sync_ingestor_queue_max_pending_chunks, previous_max_pending)
    end)

    :ok
  end

  test "coalesces bursts and preserves arrival order" do
    Application.put_env(:serviceradar_core, :sync_ingestor_coalesce_ms, 50)
    Application.put_env(:serviceradar_core, :sync_ingestor_queue_max_chunks, 10)

    update1 = %{"device_id" => "dev-1", "ip" => "10.0.0.1"}
    update2 = %{"device_id" => "dev-2", "ip" => "10.0.0.2"}

    SyncIngestorQueue.enqueue(Jason.encode!([update1]))
    SyncIngestorQueue.enqueue(Jason.encode!([update2]))

    assert_receive {:ingest_started, updates}, 500
    assert [^update1, ^update2] = updates
  end

  test "processes batches sequentially" do
    Application.put_env(:serviceradar_core, :sync_ingestor_coalesce_ms, 10)
    Application.put_env(:serviceradar_core, :sync_ingestor_queue_max_chunks, 10)
    Application.put_env(:serviceradar_core, :sync_ingestor_test_delay_ms, 200)

    SyncIngestorQueue.enqueue(Jason.encode!([%{"device_id" => "dev-a"}]))

    # Let the first batch become inflight before adding the second.
    assert_receive {:ingest_started, _updates}, 2_000

    SyncIngestorQueue.enqueue(Jason.encode!([%{"device_id" => "dev-b"}]))

    # Second batch should wait until first finishes
    refute_receive {:ingest_started, _updates}, 150
    assert_receive :ingest_finished, 2_000
    assert_receive {:ingest_started, _updates}, 2_000
  end

  test "a full queue rejects while a task is in flight and keeps its size" do
    Application.put_env(:serviceradar_core, :sync_ingestor_coalesce_ms, 0)
    Application.put_env(:serviceradar_core, :sync_ingestor_queue_max_chunks, 10)
    Application.put_env(:serviceradar_core, :sync_ingestor_queue_max_pending_chunks, 2)
    Application.put_env(:serviceradar_core, :sync_ingestor_test_delay_ms, 500)

    assert :ok = SyncIngestorQueue.enqueue(Jason.encode!([%{"device_id" => "dev-1"}]))
    assert_receive {:ingest_started, _updates}, 1_000

    assert :ok = SyncIngestorQueue.enqueue(Jason.encode!([%{"device_id" => "dev-2"}]))
    assert :ok = SyncIngestorQueue.enqueue(Jason.encode!([%{"device_id" => "dev-3"}]))

    assert {:error, :sync_ingest_queue_full} =
             SyncIngestorQueue.enqueue(Jason.encode!([%{"device_id" => "dev-4"}]))

    assert_receive :ingest_finished, 2_000
    assert_receive {:ingest_started, updates}, 2_000
    assert Enum.map(updates, & &1["device_id"]) == ["dev-2", "dev-3"]
  end

  test "a malformed payload is rejected by the ingestion task, not at admission" do
    Application.put_env(:serviceradar_core, :sync_ingestor_coalesce_ms, 0)

    assert :ok = SyncIngestorQueue.enqueue("not json")
    assert :ok = SyncIngestorQueue.enqueue(Jason.encode!([%{"device_id" => "dev-ok"}]))

    assert_receive {:ingest_started, [%{"device_id" => "dev-ok"}]}, 1_000
  end

  test "a sync run that lost a chunk is reported incomplete; a whole run is not" do
    Application.put_env(:serviceradar_core, :sync_ingestor_coalesce_ms, 0)
    test_pid = self()
    handler = "sync-incomplete-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:serviceradar, :sync_ingestion, :incomplete_run],
      fn _event, measurements, metadata, _ ->
        send(test_pid, {:incomplete_run, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    chunk = fn run_id, index, final? ->
      Jason.encode!([
        %{
          "device_id" => "#{run_id}-#{index}",
          "sync_meta" => %{
            "sync_service_id" => "source-test",
            "sync_run_id" => run_id,
            "chunk_index" => index,
            "total_chunks" => 3,
            "is_final" => final?
          }
        }
      ])
    end

    # Chunk 1 of the lossy run never arrives.
    for {run, index, final?} <- [{"lossy", 0, false}, {"lossy", 2, true}] do
      assert :ok = SyncIngestorQueue.enqueue(chunk.(run, index, final?))
      assert_receive :ingest_finished, 1_000
    end

    assert_receive {:incomplete_run, %{missing_chunks: 1}, %{sync_run_id: "lossy"}}, 1_000

    for {run, index, final?} <- [{"whole", 0, false}, {"whole", 1, false}, {"whole", 2, true}] do
      assert :ok = SyncIngestorQueue.enqueue(chunk.(run, index, final?))
      assert_receive :ingest_finished, 1_000
    end

    refute_receive {:incomplete_run, _measurements, %{sync_run_id: "whole"}}, 200
  end

  test "keeps different sync run envelopes in separate arrival-ordered groups" do
    batch = fn source_id, run_id, device_id ->
      [
        %{
          "device_id" => device_id,
          "sync_meta" => %{
            "sync_service_id" => source_id,
            "sync_run_id" => run_id,
            "chunk_index" => 1,
            "total_chunks" => 3,
            "is_final" => false
          }
        }
      ]
    end

    a1 = batch.("source-a", "run-a", "a-1")
    a2 = batch.("source-a", "run-a", "a-2")
    b1 = batch.("source-b", "run-b", "b-1")
    a3 = batch.("source-a", "run-a", "a-3")

    assert SyncIngestorQueue.group_batches_for_ingestion([a1, a2, b1, a3]) == [
             List.flatten([a1, a2]),
             b1,
             a3
           ]
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
