defmodule ServiceRadar.ResultsRouterDispatchTest do
  @moduledoc """
  ResultsRouter admits database-bound result classes to per-class queues instead
  of ingesting them in its own process.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.ResultIngestion
  alias ServiceRadar.ResultsRouter

  defmodule HeldSweepIngestor do
    @moduledoc false
    def ingest_results(_results, _execution_id, opts) do
      test_pid = Application.fetch_env!(:serviceradar_core, :router_dispatch_test_pid)
      send(test_pid, {:sweep_started, opts[:agent_id], self()})

      receive do
        :release -> {:ok, %{}}
      end
    end
  end

  defmodule RecordingPluginIngestor do
    @moduledoc false
    def ingest(_payload, status) do
      test_pid = Application.fetch_env!(:serviceradar_core, :router_dispatch_test_pid)
      send(test_pid, {:plugin_ingested, status[:agent_id], self()})

      if Application.get_env(:serviceradar_core, :router_dispatch_hold_plugin) do
        receive do
          :release -> :ok
        end
      else
        :ok
      end
    end
  end

  setup do
    keys = [
      :sweep_ingestor,
      :plugin_result_ingestor,
      :router_dispatch_test_pid,
      :router_dispatch_hold_plugin,
      :results_router_batching,
      ResultIngestion
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:serviceradar_core, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:serviceradar_core, key, value)
        {key, :error} -> Application.delete_env(:serviceradar_core, key)
      end)
    end)

    Application.put_env(:serviceradar_core, :sweep_ingestor, HeldSweepIngestor)
    Application.put_env(:serviceradar_core, :plugin_result_ingestor, RecordingPluginIngestor)
    Application.put_env(:serviceradar_core, :router_dispatch_test_pid, self())
    Application.put_env(:serviceradar_core, :results_router_batching, false)
    :ok
  end

  test "a held sweep ingest does not delay another agent's result" do
    router = start_router!()

    GenServer.cast(router, {:results_update, sweep_status("agent-a")})
    assert_receive {:sweep_started, "agent-a", sweep}, 1_000

    GenServer.cast(router, {:results_update, plugin_status("agent-b")})
    assert_receive {:plugin_ingested, "agent-b", plugin_worker}, 1_000

    refute plugin_worker == router
    send(sweep, :release)
  end

  test "an agent's later result of the same class waits for its earlier one" do
    router = start_router!()

    GenServer.cast(router, {:results_update, sweep_status("agent-a")})
    assert_receive {:sweep_started, "agent-a", first}, 1_000

    GenServer.cast(router, {:results_update, sweep_status("agent-a")})
    refute_receive {:sweep_started, "agent-a", _second}, 200

    send(first, :release)
    assert_receive {:sweep_started, "agent-a", second}, 1_000
    send(second, :release)
  end

  test "a result sent by call is answered after its ingest, without blocking the router" do
    Application.put_env(:serviceradar_core, :router_dispatch_hold_plugin, true)
    router = start_router!()

    call =
      Task.async(fn ->
        GenServer.call(router, {:results_update, plugin_status("agent-a")}, 5_000)
      end)

    assert_receive {:plugin_ingested, "agent-a", plugin_worker}, 1_000

    # The router keeps routing while that ingest is held.
    GenServer.cast(router, {:results_update, sweep_status("agent-b")})
    assert_receive {:sweep_started, "agent-b", sweep}, 1_000

    refute Task.yield(call, 0)
    send(plugin_worker, :release)
    assert {:ok, :ok} = Task.yield(call, 1_000)
    send(sweep, :release)
  end

  test "a full class queue rejects a call with its reason" do
    Application.put_env(:serviceradar_core, :router_dispatch_hold_plugin, true)

    Application.put_env(:serviceradar_core, ResultIngestion,
      plugin_result: [max_items_per_key: 1]
    )

    router = start_router!()

    held =
      Task.async(fn ->
        GenServer.call(router, {:results_update, plugin_status("agent-a")}, 5_000)
      end)

    assert_receive {:plugin_ingested, "agent-a", plugin_worker}, 1_000

    assert {:error, :result_ingestion_key_full} =
             GenServer.call(router, {:results_update, plugin_status("agent-a")}, 1_000)

    send(plugin_worker, :release)
    assert {:ok, :ok} = Task.yield(held, 1_000)
  end

  defp start_router! do
    if !Process.whereis(ResultIngestion), do: start_supervised!(ResultIngestion)
    {:ok, router} = GenServer.start_link(ResultsRouter, %{})
    router
  end

  defp sweep_status(agent_id) do
    %{
      source: "results",
      service_type: "sweep",
      agent_id: agent_id,
      message:
        Jason.encode!(%{
          "execution_id" => Ecto.UUID.generate(),
          "sweep_group_id" => Ecto.UUID.generate(),
          "last_sweep" => 1_700_000_000,
          "hosts" => [
            %{
              "host" => "192.0.2.10",
              "available" => true,
              "icmp_status" => %{"available" => true}
            }
          ]
        })
    }
  end

  defp plugin_status(agent_id) do
    %{
      source: "plugin-result",
      service_type: "plugin",
      service_name: "example",
      agent_id: agent_id,
      message: Jason.encode!(%{"status" => "OK", "summary" => "plugin result"})
    }
  end
end
