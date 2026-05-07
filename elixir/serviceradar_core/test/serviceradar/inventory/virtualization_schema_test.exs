defmodule ServiceRadar.Inventory.VirtualizationSchemaTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Inventory.VirtualizationDatastore
  alias ServiceRadar.Inventory.VirtualizationGuest
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadar.Inventory.VirtualizationHostDisk
  alias ServiceRadar.Inventory.VirtualizationNetworkInterface
  alias ServiceRadar.Inventory.VirtualizationStorageSystem

  test "device foreign keys remain canonical device uid strings" do
    for resource <- [
          VirtualizationHost,
          VirtualizationGuest,
          VirtualizationHostDisk,
          VirtualizationNetworkInterface
        ] do
      assert Info.attribute(resource, :device_uid).type == Ash.Type.String
    end
  end

  test "provider references are present on provider-neutral inventory resources" do
    for resource <- [
          ServiceRadar.Inventory.VirtualizationCluster,
          VirtualizationHost,
          VirtualizationGuest,
          VirtualizationDatastore,
          VirtualizationHostDisk,
          VirtualizationNetworkInterface,
          VirtualizationStorageSystem
        ] do
      assert Info.attribute(resource, :provider).allow_nil? == false
      assert Info.attribute(resource, :provider_ref).allow_nil? == false
    end
  end
end
