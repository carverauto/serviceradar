defmodule ServiceRadar.ResultsRouterTest do
  @moduledoc """
  Tests for results ingestion routing in ResultsRouter.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.ResultsRouter

  defmodule TestIngestor do
    def ingest_updates(updates, tenant_id, opts) do
      send(self(), {:ingest, updates, tenant_id, opts})
      :ok
    end
  end

  defmodule TestSweepIngestor do
    def ingest_results(results, execution_id, tenant_id, opts) do
      send(self(), {:sweep_ingest, results, execution_id, tenant_id, opts})
      {:ok, %{hosts_total: length(results)}}
    end
  end

  setup do
    previous = Application.get_env(:serviceradar_core, :sync_ingestor)
    previous_async = Application.get_env(:serviceradar_core, :sync_ingestor_async)
    previous_sweep = Application.get_env(:serviceradar_core, :sweep_ingestor)
    Application.put_env(:serviceradar_core, :sync_ingestor, TestIngestor)
    Application.put_env(:serviceradar_core, :sync_ingestor_async, false)
    Application.put_env(:serviceradar_core, :sweep_ingestor, TestSweepIngestor)

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

      if is_nil(previous_sweep) do
        Application.delete_env(:serviceradar_core, :sweep_ingestor)
      else
        Application.put_env(:serviceradar_core, :sweep_ingestor, previous_sweep)
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

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})

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

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})
    refute_receive {:ingest, _updates, _tenant, _opts}
  end

  test "does not ingest when payload is invalid" do
    status = %{
      source: "results",
      service_type: "sync",
      message: Jason.encode!(%{"device_id" => "dev-1"}),
      tenant_id: "tenant-1"
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})
    refute_receive {:ingest, _updates, _tenant, _opts}
  end

  test "ingests sweep results from summary payload" do
    execution_id = Ash.UUID.generate()
    sweep_group_id = Ash.UUID.generate()
    last_sweep = 1_700_000_000

    payload = %{
      "execution_id" => execution_id,
      "sweep_group_id" => sweep_group_id,
      "last_sweep" => last_sweep,
      "hosts" => [
        %{
          "host" => "192.168.1.10",
          "available" => true,
          "icmp_status" => %{"available" => true, "round_trip" => "1ms"}
        },
        %{
          "host" => "192.168.1.11",
          "available" => false,
          "icmp_status" => %{"available" => false}
        }
      ]
    }

    status = %{
      source: "results",
      service_type: "sweep",
      message: Jason.encode!(payload),
      tenant_id: "tenant-1",
      agent_id: "agent-1"
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})

    assert_receive {:sweep_ingest, results, ^execution_id, "tenant-1", opts}
    assert length(results) == 2
    assert Enum.any?(results, &(&1["host_ip"] == "192.168.1.10"))
    assert Enum.any?(results, &(&1["host_ip"] == "192.168.1.11"))
    assert Enum.all?(results, &(&1["last_sweep_time"] == DateTime.to_iso8601(DateTime.from_unix!(last_sweep))))
    assert opts[:sweep_group_id] == sweep_group_id
    assert opts[:agent_id] == "agent-1"
    assert %{tenant_id: "tenant-1"} = opts[:actor]
  end
end
