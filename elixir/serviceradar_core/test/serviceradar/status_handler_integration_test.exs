defmodule ServiceRadar.StatusHandlerIntegrationTest do
  @moduledoc """
  Integration coverage for sync status ingestion through DIRE into inventory.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.StatusHandler
  alias ServiceRadar.Identity.Tenant
  alias ServiceRadar.Inventory.{Device, DeviceIdentifier, IdentityReconciler}

  setup_all do
    {:ok, _} = Application.ensure_all_started(:serviceradar_core)
    :ok
  end

  test "sync status update creates device and identifiers" do
    tenant = create_tenant!("sync-flow")
    tenant_id = to_string(tenant.id)
    actor = system_actor(tenant_id)

    armis_id = "armis-#{System.unique_integer([:positive])}"
    ip_octet = rem(System.unique_integer([:positive]), 200) + 10
    ip = "10.0.0.#{ip_octet}"
    mac = "AA:BB:CC:DD:EE:#{mac_suffix()}"

    update = %{
      "ip" => ip,
      "mac" => mac,
      "hostname" => "edge-#{ip_octet}",
      "metadata" => %{"armis_device_id" => armis_id}
    }

    identity_update = %{
      device_id: nil,
      ip: ip,
      mac: mac,
      hostname: "edge-#{ip_octet}",
      partition: "default",
      metadata: %{"armis_device_id" => armis_id}
    }

    assert {:ok, expected_id} = IdentityReconciler.resolve_device_id(identity_update, actor: actor)

    status = %{
      source: "results",
      service_type: "sync",
      message: Jason.encode!([update]),
      tenant_id: tenant_id
    }

    assert {:noreply, %{}} = StatusHandler.handle_cast({:status_update, status}, %{})

    assert {:ok, device} =
             Device.get_by_uid(expected_id, tenant: tenant_id, actor: actor, authorize?: false)

    assert device.ip == ip
    assert device.hostname == "edge-#{ip_octet}"
    assert device.uid == expected_id

    identifier_query =
      DeviceIdentifier
      |> Ash.Query.for_read(:lookup, %{
        identifier_type: :armis_device_id,
        identifier_value: armis_id,
        partition: "default"
      })

    assert {:ok, [identifier | _]} =
             Ash.read(identifier_query, actor: actor, authorize?: false)

    assert identifier.device_id == expected_id
  end

  defp create_tenant!(slug_prefix) do
    suffix = System.unique_integer([:positive])
    slug = "#{slug_prefix}-#{suffix}"
    name = "#{slug_prefix}-name-#{suffix}"

    Tenant
    |> Ash.Changeset.for_create(:create, %{name: name, slug: slug}, authorize?: false)
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, tenant} -> tenant
      {:error, reason} -> raise "failed to create tenant: #{inspect(reason)}"
    end
  end

  defp system_actor(tenant_id) do
    %{
      id: "system",
      email: "gateway@serviceradar",
      role: :admin,
      tenant_id: tenant_id
    }
  end

  defp mac_suffix do
    System.unique_integer([:positive])
    |> rem(256)
    |> Integer.to_string(16)
    |> String.pad_leading(2, "0")
    |> String.upcase()
  end
end
