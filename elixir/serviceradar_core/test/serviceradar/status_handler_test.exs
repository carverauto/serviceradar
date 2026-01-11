defmodule ServiceRadar.StatusHandlerTest do
  @moduledoc """
  Tests for sync result ingestion routing in StatusHandler.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.StatusHandler

  defmodule TestIngestor do
    def ingest_updates(updates, tenant_id, opts) do
      send(self(), {:ingest, updates, tenant_id, opts})
      :ok
    end
  end

  setup do
    previous = Application.get_env(:serviceradar_core, :sync_ingestor)
    previous_async = Application.get_env(:serviceradar_core, :sync_ingestor_async)
    Application.put_env(:serviceradar_core, :sync_ingestor, TestIngestor)
    Application.put_env(:serviceradar_core, :sync_ingestor_async, false)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:serviceradar_core, :sync_ingestor)
      else
        Application.put_env(:serviceradar_core, :sync_ingestor, previous)
      end

      if is_nil(previous_async) do
        Application.delete_env(:serviceradar_core, :sync_ingestor_async)
      else
        Application.put_env(:serviceradar_core, :sync_ingestor_async, previous_async)
      end
    end)

    :ok
  end

  test "ingests sync updates when tenant_id is present" do
    status = %{
      source: "results",
      service_type: "sync",
      message: Jason.encode!([%{"device_id" => "dev-1", "ip" => "10.0.0.1"}]),
      tenant_id: "tenant-1"
    }

    assert {:noreply, %{}} = StatusHandler.handle_cast({:status_update, status}, %{})

    assert_receive {:ingest, updates, "tenant-1", opts}
    assert [%{"device_id" => "dev-1", "ip" => "10.0.0.1"}] = updates
    assert Keyword.keyword?(opts)
    assert %{tenant_id: "tenant-1"} = opts[:actor]
  end

  test "does not ingest when tenant_id is missing" do
    status = %{
      source: "results",
      service_type: "sync",
      message: Jason.encode!([%{"device_id" => "dev-1"}])
    }

    assert {:noreply, %{}} = StatusHandler.handle_cast({:status_update, status}, %{})
    refute_receive {:ingest, _updates, _tenant, _opts}
  end

  test "does not ingest when payload is invalid" do
    status = %{
      source: "results",
      service_type: "sync",
      message: Jason.encode!(%{"device_id" => "dev-1"}),
      tenant_id: "tenant-1"
    }

    assert {:noreply, %{}} = StatusHandler.handle_cast({:status_update, status}, %{})
    refute_receive {:ingest, _updates, _tenant, _opts}
  end
end
