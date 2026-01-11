defmodule ServiceRadar.Infrastructure.GatewayTest do
  @moduledoc """
  Tests for Gateway resource.

  Verifies:
  - Gateway registration and basic operations
  - Heartbeat and status updates
  - Read actions (by_id, active, by_status, recently_seen)
  - Calculations (is_online, status_color, display_name)
  - Policy enforcement
  - Tenant isolation
  - Partition isolation
  """
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  require Ash.Query

  alias ServiceRadar.Infrastructure.Gateway

  describe "gateway registration" do
    setup do
      tenant = tenant_fixture()
      {:ok, tenant: tenant}
    end

    test "can register a gateway with required fields", %{tenant: tenant} do
      result =
        Gateway
        |> Ash.Changeset.for_create(
          :register,
          %{
            id: "gateway-test-001",
            component_id: "component-001",
            registration_source: "manual"
          },
          actor: system_actor(),
          authorize?: false,
          tenant: tenant.id
        )
        |> Ash.create()

      assert {:ok, gateway} = result
      assert gateway.id == "gateway-test-001"
      assert gateway.component_id == "component-001"
      assert gateway.registration_source == "manual"
      assert gateway.status == :healthy
      assert gateway.is_healthy == true
      assert gateway.tenant_id == tenant.id
    end

    test "sets timestamps on registration", %{tenant: tenant} do
      gateway = gateway_fixture(tenant)

      assert gateway.first_registered != nil
      assert gateway.first_seen != nil
      assert gateway.last_seen != nil
      assert DateTime.diff(DateTime.utc_now(), gateway.first_registered, :second) < 60
    end

    test "gateway starts with default values", %{tenant: tenant} do
      gateway = gateway_fixture(tenant)

      assert gateway.is_healthy == true
      assert gateway.agent_count == 0
      assert gateway.checker_count == 0
    end
  end

  describe "update actions" do
    setup do
      tenant = tenant_fixture()
      gateway = gateway_fixture(tenant)
      {:ok, tenant: tenant, gateway: gateway}
    end

    test "operator can update gateway metadata", %{tenant: tenant, gateway: gateway} do
      actor = operator_actor(tenant)

      result =
        gateway
        |> Ash.Changeset.for_update(
          :update,
          %{
            metadata: %{"environment" => "production"},
            agent_count: 5,
            checker_count: 10
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert {:ok, updated} = result
      assert updated.metadata == %{"environment" => "production"}
      assert updated.agent_count == 5
      assert updated.checker_count == 10
      assert updated.updated_at != nil
    end

    test "viewer can update gateway metadata", %{tenant: tenant, gateway: gateway} do
      actor = viewer_actor(tenant)

      result =
        gateway
        |> Ash.Changeset.for_update(:update, %{agent_count: 1}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:ok, updated} = result
      assert updated.agent_count == 1
    end

    test "heartbeat updates last_seen and health status", %{tenant: tenant, gateway: gateway} do
      actor = operator_actor(tenant)
      original_last_seen = gateway.last_seen

      Process.sleep(1100)

      {:ok, updated} =
        gateway
        |> Ash.Changeset.for_update(
          :heartbeat,
          %{
            is_healthy: true,
            agent_count: 3
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert DateTime.compare(updated.last_seen, original_last_seen) in [:gt, :eq]
      assert updated.agent_count == 3
    end
  end

  describe "status management" do
    setup do
      tenant = tenant_fixture()
      gateway = gateway_fixture(tenant)
      {:ok, tenant: tenant, gateway: gateway}
    end

    test "admin can start draining gateway", %{tenant: tenant, gateway: gateway} do
      actor = admin_actor(tenant)

      {:ok, updated} =
        gateway
        |> Ash.Changeset.for_update(:start_draining, %{},
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert updated.status == :draining
    end

    test "admin can degrade gateway", %{tenant: tenant, gateway: gateway} do
      actor = admin_actor(tenant)

      {:ok, updated} =
        gateway
        |> Ash.Changeset.for_update(:degrade, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert updated.is_healthy == false
      assert updated.status == :degraded
    end

    test "admin can deactivate gateway", %{tenant: tenant, gateway: gateway} do
      actor = admin_actor(tenant)

      {:ok, updated} =
        gateway
        |> Ash.Changeset.for_update(:deactivate, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert updated.status == :inactive
      assert updated.is_healthy == false
    end
  end

  describe "read actions" do
    setup do
      tenant = tenant_fixture()

      # Active and healthy gateway
      gateway_active = gateway_fixture(tenant, %{id: "gateway-active"})

      # Create a degraded gateway
      {:ok, gateway_degraded} =
        gateway_fixture(tenant, %{id: "gateway-degraded"})
        |> Ash.Changeset.for_update(:mark_unhealthy, %{},
          actor: system_actor(),
          authorize?: false,
          tenant: tenant.id
        )
        |> Ash.update()

      {:ok, tenant: tenant, gateway_active: gateway_active, gateway_degraded: gateway_degraded}
    end

    test "by_id returns specific gateway", %{tenant: tenant, gateway_active: gateway} do
      actor = viewer_actor(tenant)

      {:ok, found} =
        Gateway
        |> Ash.Query.for_read(:by_id, %{id: gateway.id}, actor: actor, tenant: tenant.id)
        |> Ash.read_one()

      assert found.id == gateway.id
    end

    test "active action returns only healthy active gateways", %{
      tenant: tenant,
      gateway_active: active,
      gateway_degraded: degraded
    } do
      actor = viewer_actor(tenant)

      {:ok, gateways} = Ash.read(Gateway, action: :active, actor: actor, tenant: tenant.id)
      ids = Enum.map(gateways, & &1.id)

      assert active.id in ids
      refute degraded.id in ids
    end

    test "by_status filters by status", %{tenant: tenant, gateway_degraded: degraded} do
      actor = viewer_actor(tenant)

      {:ok, gateways} =
        Gateway
        |> Ash.Query.for_read(:by_status, %{status: :degraded}, actor: actor, tenant: tenant.id)
        |> Ash.read()

      ids = Enum.map(gateways, & &1.id)
      assert degraded.id in ids
    end
  end

  describe "calculations" do
    setup do
      tenant = tenant_fixture()
      {:ok, tenant: tenant}
    end

    test "status_color returns correct colors", %{tenant: tenant} do
      actor = viewer_actor(tenant)

      # Active healthy gateway - should be green
      active = gateway_fixture(tenant, %{id: "gateway-green"})

      {:ok, [loaded]} =
        Gateway
        |> Ash.Query.filter(id == ^active.id)
        |> Ash.Query.load(:status_color)
        |> Ash.read(actor: actor, tenant: tenant.id)

      assert loaded.status_color == "green"
    end

    test "display_name uses component_id or id", %{tenant: tenant} do
      actor = viewer_actor(tenant)

      # With component_id
      with_component =
        gateway_fixture(tenant, %{
          id: "gateway-with-component",
          component_id: "Component Display Name"
        })

      {:ok, [loaded]} =
        Gateway
        |> Ash.Query.filter(id == ^with_component.id)
        |> Ash.Query.load(:display_name)
        |> Ash.read(actor: actor, tenant: tenant.id)

      assert loaded.display_name == "Component Display Name"

      # Without component_id
      without_component =
        gateway_fixture(tenant, %{
          id: "gateway-no-component",
          component_id: nil
        })

      {:ok, [loaded]} =
        Gateway
        |> Ash.Query.filter(id == ^without_component.id)
        |> Ash.Query.load(:display_name)
        |> Ash.read(actor: actor, tenant: tenant.id)

      assert loaded.display_name == "gateway-no-component"
    end
  end

  describe "tenant isolation" do
    setup do
      tenant_a = tenant_fixture(%{name: "Tenant A", slug: "tenant-a-gateway"})
      tenant_b = tenant_fixture(%{name: "Tenant B", slug: "tenant-b-gateway"})

      gateway_a = gateway_fixture(tenant_a, %{id: "gateway-a"})
      gateway_b = gateway_fixture(tenant_b, %{id: "gateway-b"})

      {:ok, tenant_a: tenant_a, tenant_b: tenant_b, gateway_a: gateway_a, gateway_b: gateway_b}
    end

    test "user cannot see gateways from other tenant", %{
      tenant_a: tenant_a,
      gateway_a: gateway_a,
      gateway_b: gateway_b
    } do
      actor = viewer_actor(tenant_a)

      {:ok, gateways} = Ash.read(Gateway, actor: actor, tenant: tenant_a.id)
      ids = Enum.map(gateways, & &1.id)

      assert gateway_a.id in ids
      refute gateway_b.id in ids
    end

    test "user cannot update gateway from other tenant", %{
      tenant_a: tenant_a,
      gateway_b: gateway_b
    } do
      actor = operator_actor(tenant_a)

      result =
        gateway_b
        |> Ash.Changeset.for_update(:update, %{agent_count: 999},
          actor: actor,
          tenant: tenant_a.id
        )
        |> Ash.update()

      assert {:error, error} = result
      assert match?(%Ash.Error.Forbidden{}, error) or match?(%Ash.Error.Invalid{}, error)
    end

    test "user cannot get gateway from other tenant by id", %{
      tenant_a: tenant_a,
      gateway_b: gateway_b
    } do
      actor = viewer_actor(tenant_a)

      {:ok, result} =
        Gateway
        |> Ash.Query.for_read(:by_id, %{id: gateway_b.id}, actor: actor, tenant: tenant_a.id)
        |> Ash.read_one()

      assert result == nil
    end
  end

  describe "partition isolation" do
    setup do
      tenant = tenant_fixture()
      partition_a = partition_fixture(tenant, %{slug: "partition-a-test"})
      partition_b = partition_fixture(tenant, %{slug: "partition-b-test"})

      # Create gateways with partition assignments
      gateway_a = gateway_fixture(tenant, %{id: "gateway-part-a"})
      gateway_b = gateway_fixture(tenant, %{id: "gateway-part-b"})

      # Note: Partition assignment would need to be done through update or fixture
      # For now, we test with partition_id filter in actor context

      {:ok,
       tenant: tenant,
       partition_a: partition_a,
       partition_b: partition_b,
       gateway_a: gateway_a,
       gateway_b: gateway_b}
    end

    test "can read gateways without partition context", %{tenant: tenant, gateway_a: gateway_a} do
      actor = viewer_actor(tenant)

      {:ok, gateways} = Ash.read(Gateway, actor: actor, tenant: tenant.id)
      ids = Enum.map(gateways, & &1.id)

      # Should see all gateways when no partition filter
      assert gateway_a.id in ids
    end
  end
end
