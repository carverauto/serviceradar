defmodule ServiceRadar.Inventory.SyncIngestorQueueTest do
  @moduledoc """
  Tests for sync ingestion queue behavior.

  In schema-agnostic mode, operates as a single queue since the DB schema
  is set by CNPG search_path credentials.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Inventory.SyncIngestorQueue

  defmodule TestIngestor do
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

    Application.put_env(:serviceradar_core, :sync_ingestor, TestIngestor)
    Application.put_env(:serviceradar_core, :sync_ingestor_test_pid, self())

    ensure_supervised({Task.Supervisor, name: ServiceRadar.SyncIngestor.TaskSupervisor})
    ensure_supervised(SyncIngestorQueue)

    on_exit(fn ->
      restore_env(:sync_ingestor, previous)
      restore_env(:sync_ingestor_coalesce_ms, previous_coalesce)
      restore_env(:sync_ingestor_queue_max_chunks, previous_queue_max)
      restore_env(:sync_ingestor_test_delay_ms, previous_delay)
      restore_env(:sync_ingestor_test_pid, previous_pid)
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
    Application.put_env(:serviceradar_core, :sync_ingestor_coalesce_ms, 0)
    Application.put_env(:serviceradar_core, :sync_ingestor_queue_max_chunks, 1)
    Application.put_env(:serviceradar_core, :sync_ingestor_test_delay_ms, 200)

    SyncIngestorQueue.enqueue(Jason.encode!([%{"device_id" => "dev-a"}]))
    SyncIngestorQueue.enqueue(Jason.encode!([%{"device_id" => "dev-b"}]))

    # First batch should start immediately
    assert_receive {:ingest_started, _updates}, 500

    # Second batch should wait until first finishes
    refute_receive {:ingest_started, _updates}, 150
    assert_receive :ingest_finished, 500
    assert_receive {:ingest_started, _updates}, 500
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)

  defp ensure_supervised({Task.Supervisor, opts}) do
    name = Keyword.get(opts, :name)

    if name && Process.whereis(name) do
      :ok
    else
      start_supervised!({Task.Supervisor, opts})
    end
  end

  defp ensure_supervised(module) when is_atom(module) do
    if Process.whereis(module) do
      :ok
    else
      start_supervised!(module)
    end
  end
end
