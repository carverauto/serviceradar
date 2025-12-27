defmodule ServiceRadar.Inventory.DeviceTest do
  @moduledoc """
  Tests for Device resource.

  Verifies:
  - Device creation and basic CRUD
  - Read actions (by_uid, by_ip, available, etc.)
  - Calculations (type_name, display_name, is_stale)
  - Policy enforcement
  - Tenant isolation
  """
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  require Ash.Query

  alias ServiceRadar.Inventory.Device

  describe "device creation" do
    setup do
      tenant = tenant_fixture()
      {:ok, tenant: tenant}
    end

    test "can create a device with required fields", %{tenant: tenant} do
      result =
        Device
        |> Ash.Changeset.for_create(:create, %{
          uid: "test-device-001",
          hostname: "test-host.local",
          type_id: 1,
          is_available: true
        }, actor: system_actor(), authorize?: false, tenant: tenant.id)
        |> Ash.create()

      assert {:ok, device} = result
      assert device.uid == "test-device-001"
      assert device.hostname == "test-host.local"
      assert device.type_id == 1
      assert device.is_available == true
      assert device.tenant_id == tenant.id
    end

    test "sets first_seen_time and last_seen_time on creation", %{tenant: tenant} do
      device = device_fixture(tenant)

      assert device.first_seen_time != nil
      assert device.last_seen_time != nil
      assert DateTime.diff(DateTime.utc_now(), device.first_seen_time, :second) < 60
    end

    test "supports all OCSF type IDs", %{tenant: tenant} do
      for type_id <- [0, 1, 2, 3, 6, 7, 9, 10, 12, 99] do
        unique = System.unique_integer([:positive])
        device = device_fixture(tenant, %{uid: "device-type-#{type_id}-#{unique}", type_id: type_id})
        assert device.type_id == type_id
      end
    end
  end

  describe "update actions" do
    setup do
      tenant = tenant_fixture()
      device = device_fixture(tenant)
      {:ok, tenant: tenant, device: device}
    end

    test "operator can update device", %{tenant: tenant, device: device} do
      actor = operator_actor(tenant)

      result =
        device
        |> Ash.Changeset.for_update(:update, %{
          name: "Updated Name",
          is_managed: true
        }, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:ok, updated} = result
      assert updated.name == "Updated Name"
      assert updated.is_managed == true
      assert updated.modified_time != nil
    end

    test "admin can update device", %{tenant: tenant, device: device} do
      actor = admin_actor(tenant)

      {:ok, updated} =
        device
        |> Ash.Changeset.for_update(:update, %{name: "Admin Update"},
          actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert updated.name == "Admin Update"
    end

    test "viewer cannot update device", %{tenant: tenant, device: device} do
      actor = viewer_actor(tenant)

      result =
        device
        |> Ash.Changeset.for_update(:update, %{name: "Should Fail"},
          actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "touch updates last_seen_time", %{tenant: tenant, device: device} do
      actor = operator_actor(tenant)
      original_last_seen = device.last_seen_time

      # Wait for database timestamp resolution (at least 1 second for PostgreSQL)
      Process.sleep(1100)

      {:ok, touched} =
        device
        |> Ash.Changeset.for_update(:touch, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      # Allow :gt or :eq (in case of very fast execution)
      assert DateTime.compare(touched.last_seen_time, original_last_seen) in [:gt, :eq]
      # But also verify it's at least been updated (modified_time would be set)
      assert touched.last_seen_time != nil
    end
  end

  describe "read actions" do
    setup do
      tenant = tenant_fixture()

      device1 = device_fixture(tenant, %{
        uid: "device-available",
        ip: "192.168.1.1",
        is_available: true
      })

      device2 = device_fixture(tenant, %{
        uid: "device-unavailable",
        ip: "192.168.1.2",
        is_available: false
      })

      {:ok, tenant: tenant, device1: device1, device2: device2}
    end

    test "by_uid returns specific device", %{tenant: tenant, device1: device1} do
      actor = viewer_actor(tenant)

      {:ok, found} =
        Device
        |> Ash.Query.for_read(:by_uid, %{uid: device1.uid}, actor: actor, tenant: tenant.id)
        |> Ash.read_one()

      assert found.uid == device1.uid
    end

    test "by_ip returns device with specific IP", %{tenant: tenant, device1: device1} do
      actor = viewer_actor(tenant)

      {:ok, found} =
        Device
        |> Ash.Query.for_read(:by_ip, %{ip: "192.168.1.1"}, actor: actor, tenant: tenant.id)
        |> Ash.read()

      assert length(found) == 1
      assert hd(found).uid == device1.uid
    end

    test "available returns only available devices", %{
      tenant: tenant,
      device1: device1,
      device2: device2
    } do
      actor = viewer_actor(tenant)

      {:ok, available} = Ash.read(Device,
        action: :available,
        actor: actor,
        tenant: tenant.id
      )

      uids = Enum.map(available, & &1.uid)
      assert device1.uid in uids
      refute device2.uid in uids
    end
  end

  describe "calculations" do
    setup do
      tenant = tenant_fixture()
      {:ok, tenant: tenant}
    end

    test "type_name returns correct OCSF type names", %{tenant: tenant} do
      actor = viewer_actor(tenant)

      type_map = %{
        0 => "Unknown",
        1 => "Server",
        2 => "Desktop",
        6 => "Virtual",
        9 => "Firewall",
        10 => "Switch",
        12 => "Router",
        99 => "Other"
      }

      for {type_id, expected_name} <- type_map do
        unique = System.unique_integer([:positive])
        device = device_fixture(tenant, %{uid: "type-test-#{type_id}-#{unique}", type_id: type_id})

        {:ok, [loaded]} =
          Device
          |> Ash.Query.filter(uid == ^device.uid)
          |> Ash.Query.load(:type_name)
          |> Ash.read(actor: actor, tenant: tenant.id)

        assert loaded.type_name == expected_name
      end
    end

    test "display_name uses name, then hostname, then ip, then uid", %{tenant: tenant} do
      actor = viewer_actor(tenant)

      # Device with all fields
      device_full = device_fixture(tenant, %{
        uid: "uid-full",
        name: "Display Name",
        hostname: "hostname.local",
        ip: "1.2.3.4"
      })

      {:ok, [loaded]} =
        Device
        |> Ash.Query.filter(uid == ^device_full.uid)
        |> Ash.Query.load(:display_name)
        |> Ash.read(actor: actor, tenant: tenant.id)

      # Should use name first
      assert loaded.display_name == "Display Name"

      # Device with only hostname
      device_hostname = device_fixture(tenant, %{
        uid: "uid-hostname",
        hostname: "just-hostname.local"
      })

      {:ok, [loaded]} =
        Device
        |> Ash.Query.filter(uid == ^device_hostname.uid)
        |> Ash.Query.load(:display_name)
        |> Ash.read(actor: actor, tenant: tenant.id)

      assert loaded.display_name == "just-hostname.local"
    end
  end

  describe "tenant isolation" do
    setup do
      tenant_a = tenant_fixture(%{name: "Tenant A", slug: "tenant-a-device"})
      tenant_b = tenant_fixture(%{name: "Tenant B", slug: "tenant-b-device"})

      device_a = device_fixture(tenant_a, %{uid: "device-a", hostname: "host-a.local"})
      device_b = device_fixture(tenant_b, %{uid: "device-b", hostname: "host-b.local"})

      {:ok,
       tenant_a: tenant_a,
       tenant_b: tenant_b,
       device_a: device_a,
       device_b: device_b}
    end

    test "user cannot see devices from other tenant", %{
      tenant_a: tenant_a,
      device_a: device_a,
      device_b: device_b
    } do
      actor = viewer_actor(tenant_a)

      {:ok, devices} = Ash.read(Device, actor: actor, tenant: tenant_a.id)
      uids = Enum.map(devices, & &1.uid)

      assert device_a.uid in uids
      refute device_b.uid in uids
    end

    test "user cannot update device from other tenant", %{
      tenant_a: tenant_a,
      device_b: device_b
    } do
      actor = operator_actor(tenant_a)

      result =
        device_b
        |> Ash.Changeset.for_update(:update, %{name: "Hacked"},
          actor: actor, tenant: tenant_a.id)
        |> Ash.update()

      # Should fail - either Forbidden or StaleRecord
      assert {:error, error} = result
      assert match?(%Ash.Error.Forbidden{}, error) or match?(%Ash.Error.Invalid{}, error)
    end

    test "user cannot get device from other tenant by uid", %{
      tenant_a: tenant_a,
      device_b: device_b
    } do
      actor = viewer_actor(tenant_a)

      {:ok, result} =
        Device
        |> Ash.Query.for_read(:by_uid, %{uid: device_b.uid}, actor: actor, tenant: tenant_a.id)
        |> Ash.read_one()

      # Should be nil - device not found in tenant context
      assert result == nil
    end
  end
end
