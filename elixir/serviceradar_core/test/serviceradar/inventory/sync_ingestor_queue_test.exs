defmodule ServiceRadar.Inventory.SyncIngestorQueueTest do
  @moduledoc """
  Tests for tenant-scoped sync ingestion queue behavior.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Inventory.SyncIngestorQueue

  defmodule TestIngestor do
    def ingest_updates(updates, tenant_id, _opts) do
      if pid = Application.get_env(:serviceradar_core, :sync_ingestor_test_pid) do
        send(pid, {:ingest_started, tenant_id, updates})
      end

      delay_ms = Application.get_env(:serviceradar_core, :sync_ingestor_test_delay_ms, 0)
      if is_integer(delay_ms) and delay_ms > 0, do: Process.sleep(delay_ms)

      if pid = Application.get_env(:serviceradar_core, :sync_ingestor_test_pid) do
        send(pid, {:ingest_finished, tenant_id})
      end

      :ok
    end
  end

  setup do
    previous = Application.get_env(:serviceradar_core, :sync_ingestor)
    previous_coalesce = Application.get_env(:serviceradar_core, :sync_ingestor_coalesce_ms)
    previous_queue_max = Application.get_env(:serviceradar_core, :sync_ingestor_queue_max_chunks)
    previous_inflight = Application.get_env(:serviceradar_core, :sync_ingestor_max_inflight)
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
      restore_env(:sync_ingestor_max_inflight, previous_inflight)
      restore_env(:sync_ingestor_test_delay_ms, previous_delay)
      restore_env(:sync_ingestor_test_pid, previous_pid)
    end)

    :ok
  end

  test "coalesces bursts per tenant and preserves arrival order" do
    Application.put_env(:serviceradar_core, :sync_ingestor_coalesce_ms, 50)
    Application.put_env(:serviceradar_core, :sync_ingestor_queue_max_chunks, 10)
    Application.put_env(:serviceradar_core, :sync_ingestor_max_inflight, 1)

    tenant_id = "tenant-1"

    update1 = %{"device_id" => "dev-1", "ip" => "10.0.0.1"}
    update2 = %{"device_id" => "dev-2", "ip" => "10.0.0.2"}

    SyncIngestorQueue.enqueue(Jason.encode!([update1]), tenant_id)
    SyncIngestorQueue.enqueue(Jason.encode!([update2]), tenant_id)

    assert_receive {:ingest_started, ^tenant_id, updates}, 500
    assert [^update1, ^update2] = updates
  end

  test "respects inflight limit across tenants" do
    Application.put_env(:serviceradar_core, :sync_ingestor_coalesce_ms, 0)
    Application.put_env(:serviceradar_core, :sync_ingestor_queue_max_chunks, 1)
    Application.put_env(:serviceradar_core, :sync_ingestor_max_inflight, 1)
    Application.put_env(:serviceradar_core, :sync_ingestor_test_delay_ms, 200)

    SyncIngestorQueue.enqueue(Jason.encode!([%{"device_id" => "dev-a"}]), "tenant-a")
    SyncIngestorQueue.enqueue(Jason.encode!([%{"device_id" => "dev-b"}]), "tenant-b")

    assert_receive {:ingest_started, "tenant-a", _updates}, 500
    refute_receive {:ingest_started, "tenant-b", _updates}, 150
    assert_receive {:ingest_finished, "tenant-a"}, 500
    assert_receive {:ingest_started, "tenant-b", _updates}, 500
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
