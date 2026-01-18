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

    test "returns true for metrics entities" do
      assert AshAdapter.ash_entity?("timeseries_metrics")
      assert AshAdapter.ash_entity?("snmp_metrics")
      assert AshAdapter.ash_entity?("cpu_metrics")
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

  describe "query/3 - LIKE operator" do
    setup do
      device1 =
        device_fixture(%{
          uid: "like-test-001",
          hostname: "faker-server-01.local",
          ip: "172.16.80.10"
        })

      device2 =
        device_fixture(%{
          uid: "like-test-002",
          hostname: "faker-server-02.local",
          ip: "172.16.80.20"
        })

      device3 =
        device_fixture(%{
          uid: "like-test-003",
          hostname: "production-server.local",
          ip: "10.0.0.1"
        })

      {:ok, device1: device1, device2: device2, device3: device3}
    end

    test "filters by hostname with LIKE operator and wildcards", %{device1: device1, device2: device2, device3: device3} do
      actor = viewer_actor()

      # Simulates query: hostname:%faker%
      params = %{
        filters: [%{field: "hostname", op: "like", value: "%faker%"}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert device1.uid in uids
      assert device2.uid in uids
      refute device3.uid in uids
    end

    test "filters by IP with LIKE operator", %{device1: device1, device2: device2, device3: device3} do
      actor = viewer_actor()

      # Simulates query: ip:%172.16%
      params = %{
        filters: [%{field: "ip", op: "like", value: "%172.16%"}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert device1.uid in uids
      assert device2.uid in uids
      refute device3.uid in uids
    end

    test "LIKE without wildcards still works", %{device1: device1} do
      actor = viewer_actor()

      params = %{
        filters: [%{field: "hostname", op: "like", value: "faker"}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert device1.uid in uids
    end

    test "not_like excludes matching records", %{device1: device1, device3: device3} do
      actor = viewer_actor()

      params = %{
        filters: [%{field: "hostname", op: "not_like", value: "%faker%"}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      refute device1.uid in uids
      assert device3.uid in uids
    end
  end

  describe "query/3 - boolean field handling" do
    setup do
      available_device =
        device_fixture(%{
          uid: "bool-test-available",
          hostname: "available.local",
          is_available: true
        })

      unavailable_device =
        device_fixture(%{
          uid: "bool-test-unavailable",
          hostname: "unavailable.local",
          is_available: false
        })

      {:ok, available: available_device, unavailable: unavailable_device}
    end

    test "filters boolean field with eq and true value", %{available: available, unavailable: unavailable} do
      actor = viewer_actor()

      params = %{
        filters: [%{field: "is_available", op: "eq", value: true}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert available.uid in uids
      refute unavailable.uid in uids
    end

    test "filters boolean field with eq and string 'true'", %{available: available, unavailable: unavailable} do
      actor = viewer_actor()

      # User might pass string "true" instead of boolean
      params = %{
        filters: [%{field: "is_available", op: "eq", value: "true"}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert available.uid in uids
      refute unavailable.uid in uids
    end

    test "filters boolean field with like operator (should not error)", %{available: available, unavailable: unavailable} do
      actor = viewer_actor()

      # This should NOT throw "boolean ~~ unknown" error
      # It should treat like as eq for boolean fields
      params = %{
        filters: [%{field: "is_available", op: "like", value: "true"}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert available.uid in uids
      refute unavailable.uid in uids
    end

    test "filters boolean field with contains operator (should not error)", %{available: available, unavailable: unavailable} do
      actor = viewer_actor()

      # Contains on boolean should also work
      params = %{
        filters: [%{field: "is_available", op: "contains", value: "false"}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      refute available.uid in uids
      assert unavailable.uid in uids
    end

    test "filters boolean with neq", %{available: available, unavailable: unavailable} do
      actor = viewer_actor()

      params = %{
        filters: [%{field: "is_available", op: "neq", value: true}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      refute available.uid in uids
      assert unavailable.uid in uids
    end
  end

  describe "query/3 - array field handling" do
    setup do
      sweep_device =
        device_fixture(%{
          uid: "array-test-sweep",
          hostname: "sweep.local",
          discovery_sources: ["sweep", "agent"]
        })

      armis_device =
        device_fixture(%{
          uid: "array-test-armis",
          hostname: "armis.local",
          discovery_sources: ["armis"]
        })

      multi_source_device =
        device_fixture(%{
          uid: "array-test-multi",
          hostname: "multi.local",
          discovery_sources: ["sweep", "armis", "sysmon"]
        })

      {:ok, sweep: sweep_device, armis: armis_device, multi: multi_source_device}
    end

    test "filters array field with in operator", %{sweep: sweep, multi: multi, armis: armis} do
      actor = viewer_actor()

      # Simulates: discovery_sources:(sweep)
      params = %{
        filters: [%{field: "discovery_sources", op: "in", value: ["sweep"]}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert sweep.uid in uids
      assert multi.uid in uids
      refute armis.uid in uids
    end

    test "filters array field with eq operator (single value)", %{sweep: sweep, armis: armis} do
      actor = viewer_actor()

      params = %{
        filters: [%{field: "discovery_sources", op: "eq", value: "sweep"}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert sweep.uid in uids
      refute armis.uid in uids
    end

    test "filters array field with not_in operator", %{sweep: sweep, armis: armis} do
      actor = viewer_actor()

      params = %{
        filters: [%{field: "discovery_sources", op: "not_in", value: ["armis"]}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert sweep.uid in uids
      refute armis.uid in uids
    end
  end

  describe "query/3 - uid field filtering (regression test)" do
    setup do
      device =
        device_fixture(%{
          uid: "uid-filter-test-#{System.unique_integer([:positive])}",
          hostname: "uid-test.local"
        })

      {:ok, device: device}
    end

    test "uid field filter is NOT ignored for devices", %{device: device} do
      actor = viewer_actor()

      # This was previously broken because uid was in @ignored_fields
      params = %{
        filters: [%{field: "uid", op: "eq", value: device.uid}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      assert length(response["results"]) == 1
      assert hd(response["results"])["uid"] == device.uid
    end

    test "uid filter returns single device, not all devices", %{device: device} do
      actor = viewer_actor()

      # Create additional devices to ensure we're not getting all
      device_fixture(%{uid: "other-device-1"})
      device_fixture(%{uid: "other-device-2"})

      params = %{
        filters: [%{field: "uid", op: "eq", value: device.uid}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      # Should only return the ONE device we're filtering for
      assert length(response["results"]) == 1
      assert hd(response["results"])["uid"] == device.uid
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
