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
  )

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

  test "northbound action permissions use least-privilege defaults" do
    keys = Catalog.permission_keys()
    admin_permissions = Catalog.permissions_for_role(:admin)
    operator_permissions = Catalog.permissions_for_role(:operator)
    viewer_permissions = Catalog.permissions_for_role(:viewer)

    assert "northbound.actions.view" in keys
    assert "northbound.actions.manage" in keys
    assert "northbound.actions.launch" in keys
    assert "northbound.actions.cancel" in keys
    assert "northbound.event_handlers.manage" in keys

    assert MapSet.member?(admin_permissions, "northbound.actions.manage")
    assert MapSet.member?(admin_permissions, "northbound.event_handlers.manage")
    refute MapSet.member?(operator_permissions, "northbound.actions.manage")
    refute MapSet.member?(operator_permissions, "northbound.event_handlers.manage")

    assert MapSet.member?(operator_permissions, "northbound.actions.launch")
    assert MapSet.member?(operator_permissions, "northbound.actions.cancel")
    refute MapSet.member?(viewer_permissions, "northbound.actions.launch")
    refute MapSet.member?(viewer_permissions, "northbound.actions.cancel")

    assert MapSet.member?(viewer_permissions, "northbound.actions.view")
  end
end
