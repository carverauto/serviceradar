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
