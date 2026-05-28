defmodule ServiceRadar.StatusHandlerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.StatusHandler

  defmodule TestIngestor do
    @moduledoc false
    def ingest_updates(updates, opts) do
      send(self(), {:ingest, updates, opts})
      :ok
    end
  end

  setup do
    existing = Process.whereis(ServiceRadar.ResultsRouter)
    previous_sync_ingestor = Application.get_env(:serviceradar_core, :sync_ingestor)
    previous_sync_ingestor_async = Application.get_env(:serviceradar_core, :sync_ingestor_async)

    if is_pid(existing) do
      Process.unregister(ServiceRadar.ResultsRouter)
    end

    on_exit(fn ->
      restore_env(:sync_ingestor, previous_sync_ingestor)
      restore_env(:sync_ingestor_async, previous_sync_ingestor_async)

      if is_pid(existing) do
        Process.register(existing, ServiceRadar.ResultsRouter)
      else
        if Process.whereis(ServiceRadar.ResultsRouter) do
          Process.unregister(ServiceRadar.ResultsRouter)
        end
      end
    end)

    :ok
  end

  test "routes sync results through ResultsRouter when available" do
    parent = self()

    router_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:results_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(router_pid, ServiceRadar.ResultsRouter)

    status = %{
      source: "results",
      service_type: "sync",
      message: Jason.encode!([%{"device_id" => "dev-1"}])
    }

    assert {:noreply, %{}} = StatusHandler.handle_cast({:status_update, status}, %{})
    assert_receive {:forwarded, ^status}
  end

  test "ingests passive netprobe results directly when ResultsRouter is registered" do
    Application.put_env(:serviceradar_core, :sync_ingestor, TestIngestor)
    Application.put_env(:serviceradar_core, :sync_ingestor_async, false)

    parent = self()

    router_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:results_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(router_pid, ServiceRadar.ResultsRouter)

    status = %{
      source: "results",
      service_type: "passive-netprobe",
      message:
        Jason.encode!([
          %{
            "device_id" => "sr:test-device",
            "ip" => "192.168.2.22",
            "source" => "passive-netprobe",
            "metadata" => %{
              "passive_fingerprint.source" => "passive-netprobe",
              "passive_fingerprint.tcp.source" => "passive-netprobe"
            }
          }
        ])
    }

    assert {:noreply, %{}} = StatusHandler.handle_cast({:status_update, status}, %{})

    assert_receive {:ingest, updates, opts}
    assert [%{"ip" => "192.168.2.22", "source" => "passive-netprobe"}] = updates
    assert Keyword.keyword?(opts)
    refute_received {:forwarded, ^status}
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
