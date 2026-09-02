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

  # The notification platform's whole permission surface, keyed to the default
  # role set each one ships with. This map is the contract: the section must hold
  # exactly these nine keys, so a tenth key cannot appear, one cannot quietly
  # disappear, and none can be re-scoped to a wider role without this test
  # failing. Written out literally rather than derived from
  # `ServiceRadar.Identity.Constants`, because a test that reads the same
  # constant the catalog reads would pass through a change to that constant.
  @notification_permissions %{
    "notifications.channels.view" => [:operator, :admin],
    "notifications.channels.manage" => [:admin],
    "notifications.routes.view" => [:operator, :admin],
    "notifications.routes.manage" => [:admin],
    "notifications.providers.manage" => [:admin],
    "notifications.deliveries.view" => [:helpdesk, :operator, :admin],
    "notifications.test.send" => [:admin],
    "notifications.silences.manage" => [:operator, :admin],
    "notifications.stream.subscribe" => [:operator, :admin]
  }
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

  test "validation run permissions default to operator execute and viewer read" do
    keys = Catalog.permission_keys()
    admin = Catalog.permissions_for_role(:admin)
    operator = Catalog.permissions_for_role(:operator)
    viewer = Catalog.permissions_for_role(:viewer)

    assert "validation_runs.execute" in keys
    assert "validation_runs.read" in keys
    assert MapSet.member?(admin, "validation_runs.execute")
    assert MapSet.member?(operator, "validation_runs.execute")
    refute MapSet.member?(viewer, "validation_runs.execute")
    assert MapSet.member?(viewer, "validation_runs.read")
  end

  test "personal API credential and MCP permissions default to all roles" do
    keys = Catalog.permission_keys()

    for permission <- ["settings.api_credentials.manage", "settings.mcp.manage"] do
      assert permission in keys

      for role <- [:viewer, :helpdesk, :operator, :admin] do
        assert MapSet.member?(Catalog.permissions_for_role(role), permission)
      end
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

  describe "notifications section" do
    test "holds exactly the nine declared keys with their default roles" do
      section = notifications_section()

      declared = section.permissions |> Enum.map(& &1.key) |> Enum.sort()
      expected = @notification_permissions |> Map.keys() |> Enum.sort()

      assert length(declared) == 9
      assert declared == expected

      for permission <- section.permissions do
        assert Enum.sort(permission.default_roles) ==
                 Enum.sort(Map.fetch!(@notification_permissions, permission.key)),
               "#{permission.key} default roles were re-scoped"
      end
    end

    test "owns every notifications.* key in the whole catalog" do
      section_keys = MapSet.new(notifications_section().permissions, & &1.key)

      catalog_keys =
        Catalog.permission_keys()
        |> Enum.filter(&String.starts_with?(&1, "notifications."))
        |> MapSet.new()

      assert MapSet.equal?(section_keys, catalog_keys)
    end

    test "no observability.notifications key exists anywhere in the catalog" do
      # The keys were never namespaced under observability; asserting it here
      # stops a future surface from reintroducing a second spelling that RBAC
      # would treat as an unrelated, ungranted permission.
      for key <- Catalog.permission_keys() do
        refute String.starts_with?(key, "observability.notifications."),
               "#{key} is a second spelling of a notifications permission"
      end
    end

    test "every key is a three-part notifications key" do
      for key <- Map.keys(@notification_permissions) do
        assert [<<"notifications">>, _middle, _leaf] = String.split(key, ".")
      end
    end

    test "role membership matches the declared defaults" do
      # The catalog is the source of truth for what a role holds, so this walks
      # the same nine keys back out through the role API the app calls.
      for {key, roles} <- @notification_permissions,
          role <- [:viewer, :helpdesk, :operator, :admin] do
        granted = MapSet.member?(Catalog.permissions_for_role(role), key)

        if role in roles do
          assert granted, "#{role} should hold #{key}"
        else
          refute granted, "#{role} should not hold #{key}"
        end
      end
    end

    test "a viewer holds no notification permission at all" do
      viewer_permissions = Catalog.permissions_for_role(:viewer)

      for key <- Map.keys(@notification_permissions) do
        refute MapSet.member?(viewer_permissions, key)
      end
    end
  end

  describe "permission metadata" do
    test "every catalog entry declares section, resource, and action" do
      for section <- Catalog.catalog(), permission <- section.permissions do
        assert is_binary(permission.section) and permission.section != ""
        assert is_binary(permission.resource) and permission.resource != ""
        assert is_binary(permission.action) and permission.action != ""
        assert permission.section == section.section
      end
    end

    test "colon-separated keys still declare a non-empty action" do
      keys = Catalog.permission_keys()

      for key <- ~w(visibility_profiles:read visibility_profiles:write visibility_profiles:delete) do
        assert key in keys
        perm = catalog_permission!(key)
        assert perm.action != ""
        assert perm.resource == "visibility_profiles"
      end
    end
  end

  describe "dashboards section" do
    test "authored and package resources share the dashboards section" do
      section = dashboards_section()
      resources = section.permissions |> Enum.map(& &1.resource) |> Enum.uniq() |> Enum.sort()

      assert "dashboards.authored" in resources
      assert "dashboards.packages" in resources

      authored_keys =
        section.permissions
        |> Enum.filter(&(&1.resource == "dashboards.authored"))
        |> Enum.map(& &1.key)
        |> Enum.sort()

      assert authored_keys == [
               "analytics.dashboards.create",
               "analytics.dashboards.delete",
               "analytics.dashboards.edit",
               "analytics.dashboards.share",
               "analytics.dashboards.view_all"
             ]
    end

    test "grid hides aliased cli.dashboard keys under the canonical packages actions" do
      visible =
        dashboards_section().permissions
        |> Enum.reject(&Map.get(&1, :alias_of))
        |> Enum.filter(&(&1.resource == "dashboards.packages"))

      actions = visible |> Enum.map(& &1.action) |> Enum.sort()
      keys = visible |> Enum.map(& &1.key) |> Enum.sort()

      assert actions == ["disable", "enable", "publish", "share", "view_all"]

      assert keys == [
               "dashboards.packages.disable",
               "dashboards.packages.enable",
               "dashboards.packages.publish",
               "dashboards.packages.share",
               "dashboards.packages.view_all"
             ]
    end

    test "package share defaults to operators and view_all to admins" do
      share = catalog_permission!("dashboards.packages.share")
      view_all = catalog_permission!("dashboards.packages.view_all")

      assert :operator in share.default_roles
      refute :viewer in share.default_roles
      assert view_all.default_roles == ServiceRadar.Identity.Constants.admin_roles()
    end
  end

  describe "permission aliases" do
    test "a deprecated key satisfies the canonical check and vice versa" do
      deprecated = MapSet.new(["cli.dashboard.publish"])
      canonical = MapSet.new(["dashboards.packages.publish"])

      assert Catalog.holds?(deprecated, "dashboards.packages.publish")
      assert Catalog.holds?(canonical, "cli.dashboard.publish")
      refute Catalog.holds?(MapSet.new(["cli.dashboard.enable"]), "dashboards.packages.publish")
    end

    test "equivalent keys are bidirectional" do
      assert Enum.sort(Catalog.equivalent_keys("cli.dashboard.enable")) ==
               Enum.sort(["cli.dashboard.enable", "dashboards.packages.enable"])

      assert Enum.sort(Catalog.equivalent_keys("dashboards.packages.enable")) ==
               Enum.sort(["cli.dashboard.enable", "dashboards.packages.enable"])
    end
  end

  defp notifications_section do
    section = Enum.find(Catalog.catalog(), &(&1.section == "notifications"))
    assert section, "the catalog has no notifications section"
    section
  end

  defp dashboards_section do
    section = Enum.find(Catalog.catalog(), &(&1.section == "dashboards"))
    assert section, "the catalog has no dashboards section"
    section
  end

  defp catalog_permission!(key) do
    Catalog.catalog()
    |> Enum.flat_map(& &1.permissions)
    |> Enum.find(&(&1.key == key))
    |> then(fn
      nil -> flunk("catalog has no #{key}")
      perm -> perm
    end)
  end
end
