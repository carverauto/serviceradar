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
    devices.console.open
    devices.console.credentials.use
    devices.remote_access.ssh.open
    devices.remote_access.ssh.target.override
    devices.remote_access.rdp.open
    devices.remote_access.app.open
    devices.remote_access.tcp.open
  )

  @visibility_profile_permissions ~w(
    visibility_profiles:read
    visibility_profiles:write
    visibility_profiles:delete
  )

  test "Ansible catalog presents canonical operations and non-executable schedule keys" do
    section = Enum.find(Catalog.catalog(), &(&1.section == "ansible"))
    permissions = Map.new(section.permissions, &{&1.key, &1})

    assert map_size(permissions) == 10
    assert permissions["ansible.runs.view"].label == "View Ansible operations"
    assert permissions["ansible.runs.launch"].label == "Launch Ansible playbooks"
    assert permissions["ansible.runs.cancel"].label == "Cancel Ansible operations"

    for key <- ["ansible.schedules.view", "ansible.schedules.manage"] do
      label = permissions[key].label
      description = permissions[key].description

      assert label =~ "Reserved Ansible schedule"
      assert description =~ "Reserved permission key"
      refute description =~ "Create, edit, enable"
      refute description =~ "scheduled / recurring Ansible playbook runs"
    end
  end

  test "visibility profile permissions are catalog keys with phase one defaults" do
    keys = Catalog.permission_keys()
    admin_permissions = Catalog.permissions_for_role(:admin)
    operator_permissions = Catalog.permissions_for_role(:operator)
    viewer_permissions = Catalog.permissions_for_role(:viewer)

    for permission <- @visibility_profile_permissions do
      assert permission in keys
      assert MapSet.member?(admin_permissions, permission)
    end

    assert MapSet.member?(operator_permissions, "visibility_profiles:read")
    assert MapSet.member?(operator_permissions, "visibility_profiles:write")
    refute MapSet.member?(operator_permissions, "visibility_profiles:delete")

    assert MapSet.member?(viewer_permissions, "visibility_profiles:read")
    refute MapSet.member?(viewer_permissions, "visibility_profiles:write")
    refute MapSet.member?(viewer_permissions, "visibility_profiles:delete")
  end

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

  test "prefix tag manage permission is an operator+ catalog key" do
    keys = Catalog.permission_keys()
    admin_permissions = Catalog.permissions_for_role(:admin)
    operator_permissions = Catalog.permissions_for_role(:operator)
    viewer_permissions = Catalog.permissions_for_role(:viewer)

    assert "settings.prefix_tags.manage" in keys
    assert MapSet.member?(admin_permissions, "settings.prefix_tags.manage")
    assert MapSet.member?(operator_permissions, "settings.prefix_tags.manage")
    refute MapSet.member?(viewer_permissions, "settings.prefix_tags.manage")
  end
end
