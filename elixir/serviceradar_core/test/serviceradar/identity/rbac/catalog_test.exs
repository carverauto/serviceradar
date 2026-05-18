defmodule ServiceRadar.Identity.RBAC.CatalogTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Identity.RBAC.Catalog

  @file_transfer_permissions ~w(
    devices.remote_access.files.list
    devices.remote_access.files.download
    devices.remote_access.files.upload
    devices.remote_access.files.manage
    devices.remote_access.files.approve
    devices.remote_access.files.export
    devices.remote_access.file_transfers.delete
  )

  @recording_permissions ~w(
    devices.remote_access.recordings.export
    devices.remote_access.recordings.view_all
    devices.remote_access.recordings.delete
  )

  @remote_access_open_permissions ~w(
    devices.remote_access.ssh.open
    devices.remote_access.rdp.open
  )

  test "remote-access open permissions are admin-only catalog keys" do
    keys = Catalog.permission_keys()
    admin_permissions = Catalog.permissions_for_role(:admin)
    operator_permissions = Catalog.permissions_for_role(:operator)

    for permission <- @remote_access_open_permissions do
      assert permission in keys
      assert MapSet.member?(admin_permissions, permission)
      refute MapSet.member?(operator_permissions, permission)
    end
  end

  test "remote-access file-transfer permissions are admin-only catalog keys" do
    keys = Catalog.permission_keys()
    admin_permissions = Catalog.permissions_for_role(:admin)
    operator_permissions = Catalog.permissions_for_role(:operator)

    for permission <- @file_transfer_permissions do
      assert permission in keys
      assert MapSet.member?(admin_permissions, permission)
      refute MapSet.member?(operator_permissions, permission)
    end
  end

  test "remote-access recording permissions are admin-only catalog keys" do
    keys = Catalog.permission_keys()
    admin_permissions = Catalog.permissions_for_role(:admin)
    operator_permissions = Catalog.permissions_for_role(:operator)

    for permission <- @recording_permissions do
      assert permission in keys
      assert MapSet.member?(admin_permissions, permission)
      refute MapSet.member?(operator_permissions, permission)
    end
  end
end
