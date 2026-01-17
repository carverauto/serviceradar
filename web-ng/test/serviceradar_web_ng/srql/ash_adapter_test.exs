defmodule ServiceRadarWebNG.SRQL.AshAdapterTest do
  @moduledoc """
  Tests for the SRQL Ash Adapter.

  Verifies that SRQL queries are correctly translated to Ash queries
  and that policy enforcement works through the adapter.
  """
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadarWebNG.SRQL.AshAdapter

  describe "ash_entity?/1" do
    test "returns true for devices" do
      assert AshAdapter.ash_entity?("devices")
    end

    test "returns true for gateways" do
      assert AshAdapter.ash_entity?("gateways")
    end

    test "returns true for agents" do
      assert AshAdapter.ash_entity?("agents")
    end

    test "returns false for metrics entities" do
      refute AshAdapter.ash_entity?("timeseries_metrics")
      refute AshAdapter.ash_entity?("snmp_metrics")
      refute AshAdapter.ash_entity?("cpu_metrics")
    end

    test "returns false for unknown entities" do
      refute AshAdapter.ash_entity?("unknown")
      refute AshAdapter.ash_entity?(nil)
      refute AshAdapter.ash_entity?(123)
    end
  end

  describe "get_resource/1" do
    test "returns Device resource for devices entity" do
      assert {:ok, ServiceRadar.Inventory.Device} = AshAdapter.get_resource("devices")
    end

    test "returns Gateway resource for gateways entity" do
      assert {:ok, ServiceRadar.Infrastructure.Gateway} = AshAdapter.get_resource("gateways")
    end

    test "returns Agent resource for agents entity" do
      assert {:ok, ServiceRadar.Infrastructure.Agent} = AshAdapter.get_resource("agents")
    end

    test "returns error for unknown entity" do
      assert {:error, {:unknown_entity, "unknown"}} = AshAdapter.get_resource("unknown")
    end
  end

  describe "get_domain/1" do
    test "returns Inventory domain for devices entity" do
      assert {:ok, ServiceRadar.Inventory} = AshAdapter.get_domain("devices")
    end

    test "returns Infrastructure domain for gateways entity" do
      assert {:ok, ServiceRadar.Infrastructure} = AshAdapter.get_domain("gateways")
    end

    test "returns Infrastructure domain for agents entity" do
      assert {:ok, ServiceRadar.Infrastructure} = AshAdapter.get_domain("agents")
    end

    test "returns error for unknown entity" do
      assert {:error, {:unknown_entity, "flows"}} = AshAdapter.get_domain("flows")
    end
  end

  describe "query/3 - devices" do
    setup do
      device1 =
        device_fixture(%{
          uid: "device-001",
          hostname: "server1.local",
          ip: "192.168.1.1",
          is_available: true,
          # Server
          type_id: 1
        })

      device2 =
        device_fixture(%{
          uid: "device-002",
          hostname: "server2.local",
          ip: "192.168.1.2",
          is_available: true,
          # Desktop
          type_id: 2
        })

      device3 =
        device_fixture(%{
          uid: "device-003",
          hostname: "server3.local",
          ip: "192.168.1.3",
          is_available: false,
          # Server
          type_id: 1
        })

      {:ok, device1: device1, device2: device2, device3: device3}
    end

    test "returns all devices with no filters", %{} do
      actor = viewer_actor()
      {:ok, response} = AshAdapter.query("devices", %{}, actor)

      assert is_list(response["results"])
      assert length(response["results"]) >= 3
      assert response["pagination"]["limit"] == 100
    end

    test "filters by eq operator", %{device1: device1} do
      actor = viewer_actor()

      params = %{
        filters: [%{field: "uid", op: "eq", value: device1.uid}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      assert length(response["results"]) == 1
      assert hd(response["results"])["uid"] == device1.uid
    end

    test "filters by neq operator", %{device1: device1} do
      actor = viewer_actor()

      params = %{
        filters: [%{field: "uid", op: "neq", value: device1.uid}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      refute device1.uid in uids
    end

    test "filters by gt operator on type_id", %{device2: device2} do
      actor = viewer_actor()

      # type_id 2 (Desktop) > type_id 1 (Server)
      params = %{
        filters: [%{field: "type_id", op: "gt", value: 1}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      # Should include device2 (type_id: 2)
      uids = Enum.map(response["results"], & &1["uid"])
      assert device2.uid in uids
    end

    test "filters by gte operator", %{device1: device1, device2: device2} do
      actor = viewer_actor()

      params = %{
        filters: [%{field: "type_id", op: "gte", value: 1}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      # type_id: 1
      assert device1.uid in uids
      # type_id: 2
      assert device2.uid in uids
    end

    test "filters by lt operator", %{device1: device1, device2: device2} do
      actor = viewer_actor()

      params = %{
        filters: [%{field: "type_id", op: "lt", value: 2}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      # type_id: 1
      assert device1.uid in uids
      # type_id: 2
      refute device2.uid in uids
    end

    test "filters by lte operator", %{device1: device1, device3: device3} do
      actor = viewer_actor()

      params = %{
        filters: [%{field: "type_id", op: "lte", value: 1}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      # type_id: 1
      assert device1.uid in uids
      # type_id: 1
      assert device3.uid in uids
    end

    test "filters by contains operator on hostname", %{device1: device1} do
      actor = viewer_actor()

      params = %{
        filters: [%{field: "hostname", op: "contains", value: "server1"}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert device1.uid in uids
    end

    test "filters by in operator", %{device1: device1, device2: device2} do
      actor = viewer_actor()

      params = %{
        filters: [%{field: "uid", op: "in", value: [device1.uid, device2.uid]}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert device1.uid in uids
      assert device2.uid in uids
      assert length(uids) == 2
    end

    test "filters by boolean field", %{device1: device1, device2: device2, device3: device3} do
      actor = viewer_actor()

      params = %{
        filters: [%{field: "is_available", op: "eq", value: true}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert device1.uid in uids
      assert device2.uid in uids
      refute device3.uid in uids
    end

    test "combines multiple filters", %{device1: device1} do
      actor = viewer_actor()

      params = %{
        filters: [
          %{field: "is_available", op: "eq", value: true},
          %{field: "type_id", op: "eq", value: 1}
        ]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      # Only device1 is available AND type_id: 1
      uids = Enum.map(response["results"], & &1["uid"])
      assert device1.uid in uids
    end

    test "sorts by field ascending", %{} do
      actor = viewer_actor()

      params = %{
        sort: %{field: "uid", dir: "asc"}
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert uids == Enum.sort(uids)
    end

    test "sorts by field descending", %{} do
      actor = viewer_actor()

      params = %{
        sort: %{field: "uid", dir: "desc"}
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert uids == Enum.sort(uids, :desc)
    end

    test "limits results", %{} do
      actor = viewer_actor()

      params = %{limit: 2}

      {:ok, response} = AshAdapter.query("devices", params, actor)

      assert length(response["results"]) == 2
      assert response["pagination"]["limit"] == 2
    end

    test "handles string keyed filter params", %{device1: device1} do
      actor = viewer_actor()

      params = %{
        filters: [%{"field" => "uid", "op" => "eq", "value" => device1.uid}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      assert length(response["results"]) == 1
      assert hd(response["results"])["uid"] == device1.uid
    end

    test "handles string keyed sort params", %{} do
      actor = viewer_actor()

      params = %{
        sort: %{"field" => "uid", "dir" => "desc"}
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert uids == Enum.sort(uids, :desc)
    end
  end

  describe "query/3 - gateways" do
    setup do
      gateway1 = gateway_fixture(%{id: "gateway-001"})
      gateway2 = gateway_fixture(%{id: "gateway-002"})

      {:ok, gateway1: gateway1, gateway2: gateway2}
    end

    test "returns all gateways", %{} do
      actor = viewer_actor()
      {:ok, response} = AshAdapter.query("gateways", %{}, actor)

      assert is_list(response["results"])
      assert length(response["results"]) >= 2
    end

    test "filters gateways by id", %{gateway1: gateway1} do
      actor = viewer_actor()

      params = %{
        filters: [%{field: "id", op: "eq", value: gateway1.id}]
      }

      {:ok, response} = AshAdapter.query("gateways", params, actor)

      assert length(response["results"]) == 1
      assert hd(response["results"])["id"] == gateway1.id
    end
  end

  describe "query/3 - agents" do
    setup do
      gateway = gateway_fixture()
      agent1 = agent_fixture(gateway, %{uid: "agent-001", name: "Agent One"})
      agent2 = agent_fixture(gateway, %{uid: "agent-002", name: "Agent Two"})

      {:ok, gateway: gateway, agent1: agent1, agent2: agent2}
    end

    test "returns all agents", %{} do
      actor = viewer_actor()
      {:ok, response} = AshAdapter.query("agents", %{}, actor)

      assert is_list(response["results"])
      assert length(response["results"]) >= 2
    end

    test "filters agents by uid", %{agent1: agent1} do
      actor = viewer_actor()

      params = %{
        filters: [%{field: "uid", op: "eq", value: agent1.uid}]
      }

      {:ok, response} = AshAdapter.query("agents", params, actor)

      assert length(response["results"]) == 1
      assert hd(response["results"])["uid"] == agent1.uid
    end

    test "filters agents by name contains", %{agent1: agent1} do
      actor = viewer_actor()

      params = %{
        filters: [%{field: "name", op: "contains", value: "One"}]
      }

      {:ok, response} = AshAdapter.query("agents", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert agent1.uid in uids
    end
  end

  describe "query/3 - policy enforcement" do
    setup do
      device = device_fixture()

      {:ok, device: device}
    end

    test "viewer can read devices", %{device: device} do
      actor = viewer_actor()
      {:ok, response} = AshAdapter.query("devices", %{}, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert device.uid in uids
    end

    test "admin can read devices", %{device: device} do
      actor = admin_actor()
      {:ok, response} = AshAdapter.query("devices", %{}, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert device.uid in uids
    end

    test "operator can read devices", %{device: device} do
      actor = operator_actor()
      {:ok, response} = AshAdapter.query("devices", %{}, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert device.uid in uids
    end
  end

  describe "query/3 - response format" do
    setup do
      device =
        device_fixture(%{
          uid: "format-test",
          hostname: "format.local",
          first_seen_time: DateTime.utc_now(),
          last_seen_time: DateTime.utc_now()
        })

      {:ok, device: device}
    end

    test "response has correct structure", %{} do
      actor = viewer_actor()
      {:ok, response} = AshAdapter.query("devices", %{}, actor)

      assert Map.has_key?(response, "results")
      assert Map.has_key?(response, "pagination")
      assert Map.has_key?(response, "viz")
      assert Map.has_key?(response, "error")

      assert is_list(response["results"])
      assert is_map(response["pagination"])
      assert is_nil(response["viz"])
      assert is_nil(response["error"])
    end

    test "pagination has expected fields", %{} do
      actor = viewer_actor()
      {:ok, response} = AshAdapter.query("devices", %{limit: 10}, actor)

      pagination = response["pagination"]
      assert Map.has_key?(pagination, "limit")
      assert Map.has_key?(pagination, "next_cursor")
      assert Map.has_key?(pagination, "prev_cursor")
      assert pagination["limit"] == 10
    end

    test "datetime fields are ISO8601 formatted", %{device: device} do
      actor = viewer_actor()

      params = %{
        filters: [%{field: "uid", op: "eq", value: device.uid}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      result = hd(response["results"])

      # Check that datetime fields are strings in ISO8601 format
      if result["first_seen_time"] do
        assert is_binary(result["first_seen_time"])
        assert {:ok, _, _} = DateTime.from_iso8601(result["first_seen_time"])
      end

      if result["last_seen_time"] do
        assert is_binary(result["last_seen_time"])
        assert {:ok, _, _} = DateTime.from_iso8601(result["last_seen_time"])
      end
    end

    test "result fields are string keyed", %{} do
      actor = viewer_actor()
      {:ok, response} = AshAdapter.query("devices", %{}, actor)

      result = hd(response["results"])
      keys = Map.keys(result)

      # All keys should be strings
      assert Enum.all?(keys, &is_binary/1)
      assert "uid" in keys or "id" in keys
    end
  end

  describe "query/3 - error handling" do
    test "query with no actor raises Forbidden error" do
      # Without actor, should raise Forbidden error due to domain require_actor? true
      assert_raise Ash.Error.Forbidden, fn ->
        AshAdapter.query("devices", %{}, nil)
      end
    end

    test "returns error for unknown entity" do
      result = AshAdapter.query("unknown_entity", %{}, system_actor())
      assert {:error, {:unknown_entity, "unknown_entity"}} = result
    end

    test "handles invalid filter field gracefully" do
      actor = viewer_actor()

      # This should not crash, just skip the invalid filter
      params = %{
        filters: [%{field: "nonexistent_field_xyz", op: "eq", value: "test"}]
      }

      result = AshAdapter.query("devices", params, actor)

      # Should succeed, just ignoring the invalid filter
      assert {:ok, _response} = result
    end

    test "handles invalid sort field gracefully" do
      actor = viewer_actor()

      params = %{
        sort: %{field: "nonexistent_sort_field", dir: "asc"}
      }

      result = AshAdapter.query("devices", params, actor)

      # Should succeed, just ignoring the invalid sort
      assert {:ok, _response} = result
    end

    test "handles malformed filter gracefully" do
      actor = viewer_actor()

      # Missing required keys
      params = %{
        # Missing op and value
        filters: [%{field: "uid"}]
      }

      result = AshAdapter.query("devices", params, actor)

      # Should succeed, skipping malformed filter
      assert {:ok, _response} = result
    end
  end
end
