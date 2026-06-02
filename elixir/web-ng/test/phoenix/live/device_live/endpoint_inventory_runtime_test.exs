defmodule ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryRuntimeTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryRuntime

  defmodule StubCommandBus do
    @moduledoc false
    def dispatch_endpoint_inventory_cache_query(agent_id, payload, opts) do
      send(self(), {:cache_query, agent_id, payload, opts})
      {:ok, "cache-command-1"}
    end

    def dispatch_endpoint_inventory_force_fresh_scan(agent_id, payload, opts) do
      send(self(), {:force_fresh, agent_id, payload, opts})
      {:ok, "fresh-command-1"}
    end

    def dispatch_endpoint_inventory_cohort_cache_query(payload, opts) do
      send(self(), {:cohort_query, payload, opts})

      {:ok,
       %{
         query_id: "cohort-query-1",
         coverage: %{targeted: 2, answered: 1, offline: 1, expired: 0, pending: 0},
         results: [
           %{
             "agent_id" => "agent-1",
             "device_uid" => "sr:test-device",
             "matched" => true,
             "freshness" => %{"verdict" => "fresh"}
           }
         ],
         dispatches: []
       }}
    end
  end

  test "dispatches a device cache query with bounded predicate payload" do
    socket =
      socket()
      |> EndpointInventoryRuntime.assign_defaults()
      |> EndpointInventoryRuntime.dispatch_device_query(
        %{"name" => "nginx", "package_manager" => "dpkg", "mode" => "detail"},
        command_bus: StubCommandBus
      )

    assert_receive {:cache_query, "agent-1", payload, opts}
    assert payload.predicate == %{name: "nginx", package_manager: "dpkg"}
    assert payload.mode == "detail"
    assert payload.limit == 25
    assert opts[:context].device_uid == "sr:test-device"
    assert socket.assigns.endpoint_inventory_query_running == true
    assert MapSet.member?(socket.assigns.endpoint_inventory_pending_command_ids, "cache-command-1")
  end

  test "dispatches force fresh scan through guarded command path" do
    socket =
      socket()
      |> EndpointInventoryRuntime.assign_defaults()
      |> EndpointInventoryRuntime.dispatch_force_refresh(
        %{"name" => "nginx", "package_manager" => "dpkg"},
        command_bus: StubCommandBus
      )

    assert_receive {:force_fresh, "agent-1", payload, opts}
    assert payload.sources == ["os_packages"]
    assert payload.query.predicate == %{name: "nginx", package_manager: "dpkg"}
    assert opts[:context].device_uid == "sr:test-device"
    assert socket.assigns.endpoint_inventory_force_refresh_running == true
  end

  test "dispatches cohort query and stores coverage envelope" do
    socket =
      socket()
      |> EndpointInventoryRuntime.assign_defaults()
      |> EndpointInventoryRuntime.dispatch_cohort_query(
        %{"name" => "nginx", "cohort" => "custom", "agent_ids" => "agent-1, agent-2"},
        command_bus: StubCommandBus
      )

    assert_receive {:cohort_query, payload, opts}
    assert payload.predicate == %{name: "nginx"}
    assert payload.mode == "count"
    assert opts[:agent_ids] == ["agent-1", "agent-2"]
    assert socket.assigns.endpoint_inventory_cohort_query_result.coverage.answered == 1
    assert socket.assigns.endpoint_inventory_cohort_query_result.coverage.offline == 1
  end

  test "applies relevant command result with freshness payload" do
    socket =
      socket()
      |> EndpointInventoryRuntime.assign_defaults()
      |> Map.update!(:assigns, &Map.put(&1, :endpoint_inventory_pending_command_ids, MapSet.new(["cmd-1"])))
      |> EndpointInventoryRuntime.apply_command_update(:result, %{
        command_id: "cmd-1",
        command_type: "endpoint_inventory.cache_query",
        success: true,
        payload: %{
          "matched" => true,
          "match_count" => 1,
          "freshness" => %{"verdict" => "fresh"}
        }
      })

    assert socket.assigns.endpoint_inventory_live_query_result["matched"] == true
    assert socket.assigns.endpoint_inventory_live_query_result["freshness"]["verdict"] == "fresh"
    refute MapSet.member?(socket.assigns.endpoint_inventory_pending_command_ids, "cmd-1")
  end

  defp socket do
    %Phoenix.LiveView.Socket{
      assigns: %{
        current_scope: %{user: %{id: "user-1"}},
        device_uid: "sr:test-device",
        device_row: %{"partition_id" => "default", "agent_id" => "agent-1"},
        endpoint_inventory_scan: %{agent_id: "agent-1"},
        results: [%{"agent_id" => "agent-1"}]
      }
    }
  end
end
