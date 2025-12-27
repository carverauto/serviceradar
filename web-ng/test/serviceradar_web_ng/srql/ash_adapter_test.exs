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

    test "returns true for pollers" do
      assert AshAdapter.ash_entity?("pollers")
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

    test "returns Poller resource for pollers entity" do
      assert {:ok, ServiceRadar.Infrastructure.Poller} = AshAdapter.get_resource("pollers")
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

    test "returns Infrastructure domain for pollers entity" do
      assert {:ok, ServiceRadar.Infrastructure} = AshAdapter.get_domain("pollers")
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
      tenant = tenant_fixture()

      device1 = device_fixture(tenant, %{
        uid: "device-001",
        hostname: "server1.local",
        ip: "192.168.1.1",
        is_available: true,
        type_id: 1  # Server
      })

      device2 = device_fixture(tenant, %{
        uid: "device-002",
        hostname: "server2.local",
        ip: "192.168.1.2",
        is_available: true,
        type_id: 2  # Desktop
      })

      device3 = device_fixture(tenant, %{
        uid: "device-003",
        hostname: "server3.local",
        ip: "192.168.1.3",
        is_available: false,
        type_id: 1  # Server
      })

      {:ok, tenant: tenant, device1: device1, device2: device2, device3: device3}
    end

    test "returns all devices with no filters", %{tenant: tenant} do
      actor = viewer_actor(tenant)
      {:ok, response} = AshAdapter.query("devices", %{}, actor)

      assert is_list(response["results"])
      assert length(response["results"]) >= 3
      assert response["pagination"]["limit"] == 100
    end

    test "filters by eq operator", %{tenant: tenant, device1: device1} do
      actor = viewer_actor(tenant)

      params = %{
        filters: [%{field: "uid", op: "eq", value: device1.uid}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      assert length(response["results"]) == 1
      assert hd(response["results"])["uid"] == device1.uid
    end

    test "filters by neq operator", %{tenant: tenant, device1: device1} do
      actor = viewer_actor(tenant)

      params = %{
        filters: [%{field: "uid", op: "neq", value: device1.uid}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      refute device1.uid in uids
    end

    test "filters by gt operator on type_id", %{tenant: tenant, device2: device2} do
      actor = viewer_actor(tenant)

      # type_id 2 (Desktop) > type_id 1 (Server)
      params = %{
        filters: [%{field: "type_id", op: "gt", value: 1}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      # Should include device2 (type_id: 2)
      uids = Enum.map(response["results"], & &1["uid"])
      assert device2.uid in uids
    end

    test "filters by gte operator", %{tenant: tenant, device1: device1, device2: device2} do
      actor = viewer_actor(tenant)

      params = %{
        filters: [%{field: "type_id", op: "gte", value: 1}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert device1.uid in uids  # type_id: 1
      assert device2.uid in uids  # type_id: 2
    end

    test "filters by lt operator", %{tenant: tenant, device1: device1, device2: device2} do
      actor = viewer_actor(tenant)

      params = %{
        filters: [%{field: "type_id", op: "lt", value: 2}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert device1.uid in uids  # type_id: 1
      refute device2.uid in uids  # type_id: 2
    end

    test "filters by lte operator", %{tenant: tenant, device1: device1, device3: device3} do
      actor = viewer_actor(tenant)

      params = %{
        filters: [%{field: "type_id", op: "lte", value: 1}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert device1.uid in uids  # type_id: 1
      assert device3.uid in uids  # type_id: 1
    end

    test "filters by contains operator on hostname", %{tenant: tenant, device1: device1} do
      actor = viewer_actor(tenant)

      params = %{
        filters: [%{field: "hostname", op: "contains", value: "server1"}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert device1.uid in uids
    end

    test "filters by in operator", %{tenant: tenant, device1: device1, device2: device2} do
      actor = viewer_actor(tenant)

      params = %{
        filters: [%{field: "uid", op: "in", value: [device1.uid, device2.uid]}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert device1.uid in uids
      assert device2.uid in uids
      assert length(uids) == 2
    end

    test "filters by boolean field", %{tenant: tenant, device1: device1, device2: device2, device3: device3} do
      actor = viewer_actor(tenant)

      params = %{
        filters: [%{field: "is_available", op: "eq", value: true}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert device1.uid in uids
      assert device2.uid in uids
      refute device3.uid in uids
    end

    test "combines multiple filters", %{tenant: tenant, device1: device1} do
      actor = viewer_actor(tenant)

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

    test "sorts by field ascending", %{tenant: tenant} do
      actor = viewer_actor(tenant)

      params = %{
        sort: %{field: "uid", dir: "asc"}
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert uids == Enum.sort(uids)
    end

    test "sorts by field descending", %{tenant: tenant} do
      actor = viewer_actor(tenant)

      params = %{
        sort: %{field: "uid", dir: "desc"}
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert uids == Enum.sort(uids, :desc)
    end

    test "limits results", %{tenant: tenant} do
      actor = viewer_actor(tenant)

      params = %{limit: 2}

      {:ok, response} = AshAdapter.query("devices", params, actor)

      assert length(response["results"]) == 2
      assert response["pagination"]["limit"] == 2
    end

    test "handles string keyed filter params", %{tenant: tenant, device1: device1} do
      actor = viewer_actor(tenant)

      params = %{
        filters: [%{"field" => "uid", "op" => "eq", "value" => device1.uid}]
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      assert length(response["results"]) == 1
      assert hd(response["results"])["uid"] == device1.uid
    end

    test "handles string keyed sort params", %{tenant: tenant} do
      actor = viewer_actor(tenant)

      params = %{
        sort: %{"field" => "uid", "dir" => "desc"}
      }

      {:ok, response} = AshAdapter.query("devices", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert uids == Enum.sort(uids, :desc)
    end
  end

  describe "query/3 - pollers" do
    setup do
      tenant = tenant_fixture()
      poller1 = poller_fixture(tenant, %{id: "poller-001"})
      poller2 = poller_fixture(tenant, %{id: "poller-002"})

      {:ok, tenant: tenant, poller1: poller1, poller2: poller2}
    end

    test "returns all pollers", %{tenant: tenant} do
      actor = viewer_actor(tenant)
      {:ok, response} = AshAdapter.query("pollers", %{}, actor)

      assert is_list(response["results"])
      assert length(response["results"]) >= 2
    end

    test "filters pollers by id", %{tenant: tenant, poller1: poller1} do
      actor = viewer_actor(tenant)

      params = %{
        filters: [%{field: "id", op: "eq", value: poller1.id}]
      }

      {:ok, response} = AshAdapter.query("pollers", params, actor)

      assert length(response["results"]) == 1
      assert hd(response["results"])["id"] == poller1.id
    end
  end

  describe "query/3 - agents" do
    setup do
      tenant = tenant_fixture()
      poller = poller_fixture(tenant)
      agent1 = agent_fixture(poller, %{uid: "agent-001", name: "Agent One"})
      agent2 = agent_fixture(poller, %{uid: "agent-002", name: "Agent Two"})

      {:ok, tenant: tenant, poller: poller, agent1: agent1, agent2: agent2}
    end

    test "returns all agents", %{tenant: tenant} do
      actor = viewer_actor(tenant)
      {:ok, response} = AshAdapter.query("agents", %{}, actor)

      assert is_list(response["results"])
      assert length(response["results"]) >= 2
    end

    test "filters agents by uid", %{tenant: tenant, agent1: agent1} do
      actor = viewer_actor(tenant)

      params = %{
        filters: [%{field: "uid", op: "eq", value: agent1.uid}]
      }

      {:ok, response} = AshAdapter.query("agents", params, actor)

      assert length(response["results"]) == 1
      assert hd(response["results"])["uid"] == agent1.uid
    end

    test "filters agents by name contains", %{tenant: tenant, agent1: agent1} do
      actor = viewer_actor(tenant)

      params = %{
        filters: [%{field: "name", op: "contains", value: "One"}]
      }

      {:ok, response} = AshAdapter.query("agents", params, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert agent1.uid in uids
    end
  end

  describe "query/3 - tenant isolation" do
    setup do
      tenant_a = tenant_fixture(%{name: "Tenant A", slug: "tenant-a-srql"})
      tenant_b = tenant_fixture(%{name: "Tenant B", slug: "tenant-b-srql"})

      device_a = device_fixture(tenant_a, %{uid: "device-tenant-a"})
      device_b = device_fixture(tenant_b, %{uid: "device-tenant-b"})

      {:ok,
       tenant_a: tenant_a,
       tenant_b: tenant_b,
       device_a: device_a,
       device_b: device_b}
    end

    test "user can only see devices from their tenant", %{
      tenant_a: tenant_a,
      device_a: device_a,
      device_b: device_b
    } do
      actor = viewer_actor(tenant_a)
      {:ok, response} = AshAdapter.query("devices", %{}, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert device_a.uid in uids
      refute device_b.uid in uids
    end

    test "query with no actor raises Forbidden error", %{} do
      # Without actor, should raise Forbidden error due to domain require_actor? true
      assert_raise Ash.Error.Forbidden, fn ->
        AshAdapter.query("devices", %{}, nil)
      end
    end
  end

  describe "query/3 - policy enforcement" do
    setup do
      tenant = tenant_fixture()
      device = device_fixture(tenant)

      {:ok, tenant: tenant, device: device}
    end

    test "viewer can read devices", %{tenant: tenant, device: device} do
      actor = viewer_actor(tenant)
      {:ok, response} = AshAdapter.query("devices", %{}, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert device.uid in uids
    end

    test "admin can read devices", %{tenant: tenant, device: device} do
      actor = admin_actor(tenant)
      {:ok, response} = AshAdapter.query("devices", %{}, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert device.uid in uids
    end

    test "operator can read devices", %{tenant: tenant, device: device} do
      actor = operator_actor(tenant)
      {:ok, response} = AshAdapter.query("devices", %{}, actor)

      uids = Enum.map(response["results"], & &1["uid"])
      assert device.uid in uids
    end
  end

  describe "query/3 - response format" do
    setup do
      tenant = tenant_fixture()
      device = device_fixture(tenant, %{
        uid: "format-test",
        hostname: "format.local",
        first_seen_time: DateTime.utc_now(),
        last_seen_time: DateTime.utc_now()
      })

      {:ok, tenant: tenant, device: device}
    end

    test "response has correct structure", %{tenant: tenant} do
      actor = viewer_actor(tenant)
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

    test "pagination has expected fields", %{tenant: tenant} do
      actor = viewer_actor(tenant)
      {:ok, response} = AshAdapter.query("devices", %{limit: 10}, actor)

      pagination = response["pagination"]
      assert Map.has_key?(pagination, "limit")
      assert Map.has_key?(pagination, "next_cursor")
      assert Map.has_key?(pagination, "prev_cursor")
      assert pagination["limit"] == 10
    end

    test "datetime fields are ISO8601 formatted", %{tenant: tenant, device: device} do
      actor = viewer_actor(tenant)

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

    test "result fields are string keyed", %{tenant: tenant} do
      actor = viewer_actor(tenant)
      {:ok, response} = AshAdapter.query("devices", %{}, actor)

      result = hd(response["results"])
      keys = Map.keys(result)

      # All keys should be strings
      assert Enum.all?(keys, &is_binary/1)
      assert "uid" in keys or "id" in keys
    end
  end

  describe "query/3 - error handling" do
    test "returns error for unknown entity" do
      result = AshAdapter.query("unknown_entity", %{}, system_actor())
      assert {:error, {:unknown_entity, "unknown_entity"}} = result
    end

    test "handles invalid filter field gracefully" do
      tenant = tenant_fixture()
      actor = viewer_actor(tenant)

      # This should not crash, just skip the invalid filter
      params = %{
        filters: [%{field: "nonexistent_field_xyz", op: "eq", value: "test"}]
      }

      result = AshAdapter.query("devices", params, actor)

      # Should succeed, just ignoring the invalid filter
      assert {:ok, _response} = result
    end

    test "handles invalid sort field gracefully" do
      tenant = tenant_fixture()
      actor = viewer_actor(tenant)

      params = %{
        sort: %{field: "nonexistent_sort_field", dir: "asc"}
      }

      result = AshAdapter.query("devices", params, actor)

      # Should succeed, just ignoring the invalid sort
      assert {:ok, _response} = result
    end

    test "handles malformed filter gracefully" do
      tenant = tenant_fixture()
      actor = viewer_actor(tenant)

      # Missing required keys
      params = %{
        filters: [%{field: "uid"}]  # Missing op and value
      }

      result = AshAdapter.query("devices", params, actor)

      # Should succeed, skipping malformed filter
      assert {:ok, _response} = result
    end
  end
end
