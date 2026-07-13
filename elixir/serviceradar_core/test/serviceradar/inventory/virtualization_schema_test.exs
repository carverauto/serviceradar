defmodule ServiceRadar.Inventory.VirtualizationSchemaTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias Ash.Type.UUID
  alias ServiceRadar.Inventory.VirtualizationCluster
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
          VirtualizationCluster,
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

  test "primary virtualization objects expose structured source identity fields" do
    for resource <- [
          VirtualizationCluster,
          VirtualizationHost,
          VirtualizationGuest
        ],
        field <- [
          :identity_version,
          :identity_state,
          :integration_id,
          :controller_id,
          :native_cluster_id,
          :object_kind,
          :native_object_id,
          :provider_instance_ref
        ] do
      assert Info.attribute(resource, field)
    end

    assert Info.attribute(VirtualizationHost, :integration_id).type == UUID
    assert Info.attribute(VirtualizationGuest, :controller_id).type == UUID
  end
end
