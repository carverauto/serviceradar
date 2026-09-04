defmodule ServiceRadarWebNG.Dashboards.PackageAccessTest do
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadar.Dashboards.DashboardAccessGrant
  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardInstanceAccessGrant
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadar.Identity.UserGroupMembership
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.RBAC

  require Ash.Query

  setup do
    admin = admin_user_fixture()
    owner = user_fixture()
    viewer = viewer_user()

    %{
      admin: admin,
      owner: owner,
      viewer: viewer,
      admin_scope: user_scope(admin),
      owner_scope: user_scope(owner),
      viewer_scope: user_scope(viewer),
      system: SystemActor.system(:test)
    }
  end

  test "public instances are listed for any authenticated user", %{
    owner_scope: owner_scope,
    viewer_scope: viewer_scope
  } do
    {_package, instance} = create_instance!(owner_scope, visibility: :public)

    ids = enabled_ids(viewer_scope)
    assert instance.id in ids
  end

  test "private instances are owner-only", %{
    owner: owner,
    owner_scope: owner_scope,
    viewer_scope: viewer_scope
  } do
    {_package, instance} =
      create_instance!(owner_scope, visibility: :private, owner_id: owner.id)

    assert instance.id in enabled_ids(owner_scope)
    refute instance.id in enabled_ids(viewer_scope)

    assert {:error, :not_found} =
             Dashboards.get_enabled_instance_by_slug(instance.route_slug, scope: viewer_scope)
  end

  test "shared instances require a grant", %{
    owner: owner,
    owner_scope: owner_scope,
    viewer: viewer,
    viewer_scope: viewer_scope,
    system: system
  } do
    {_package, instance} =
      create_instance!(owner_scope, visibility: :shared, owner_id: owner.id)

    refute instance.id in enabled_ids(viewer_scope)

    {:ok, _grant} =
      DashboardInstanceAccessGrant
      |> Ash.Changeset.for_create(:create, %{
        dashboard_instance_id: instance.id,
        subject_user_id: viewer.id,
        access: :view,
        granted_by_id: owner.id
      })
      |> Ash.create(actor: system)

    assert instance.id in enabled_ids(viewer_scope)
  end

  test "group grants follow membership", %{
    owner: owner,
    owner_scope: owner_scope,
    viewer: viewer,
    viewer_scope: viewer_scope,
    system: system
  } do
    {_package, instance} =
      create_instance!(owner_scope, visibility: :shared, owner_id: owner.id)

    {:ok, group} =
      UserGroup
      |> Ash.Changeset.for_create(:create, %{
        name: "pkg-access-#{System.unique_integer([:positive])}"
      })
      |> Ash.create(actor: system)

    {:ok, _grant} =
      DashboardInstanceAccessGrant
      |> Ash.Changeset.for_create(
        :create_group,
        %{
          dashboard_instance_id: instance.id,
          subject_group_id: group.id,
          access: :view,
          granted_by_id: owner.id
        },
        context: %{dashboard_group_access_boundary_owned: true}
      )
      |> Ash.create(actor: system)

    refute instance.id in enabled_ids(viewer_scope)

    {:ok, membership} =
      UserGroupMembership
      |> Ash.Changeset.for_create(:create_manual, %{group_id: group.id, user_id: viewer.id},
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create(actor: system)

    assert instance.id in enabled_ids(viewer_scope)

    :ok =
      membership
      |> Ash.Changeset.for_destroy(:destroy, %{}, context: %{privilege_boundary_owned: true})
      |> Ash.destroy(actor: system)

    refute instance.id in enabled_ids(viewer_scope)
  end

  test "grants are deleted with the instance", %{
    owner: owner,
    owner_scope: owner_scope,
    system: system
  } do
    {_package, instance} =
      create_instance!(owner_scope, visibility: :shared, owner_id: owner.id)

    {:ok, grant} =
      DashboardInstanceAccessGrant
      |> Ash.Changeset.for_create(:create, %{
        dashboard_instance_id: instance.id,
        subject_user_id: owner.id,
        access: :view,
        granted_by_id: owner.id
      })
      |> Ash.create(actor: system)

    :ok = Ash.destroy(instance, actor: system)

    assert {:ok, nil} =
             DashboardInstanceAccessGrant
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(id == ^grant.id)
             |> Ash.read_one(actor: system)
  end

  test "duplicate user grants upsert to a single row", %{
    owner: owner,
    owner_scope: owner_scope,
    viewer: viewer,
    system: system
  } do
    {_package, instance} =
      create_instance!(owner_scope, visibility: :shared, owner_id: owner.id)

    attrs = %{
      dashboard_instance_id: instance.id,
      subject_user_id: viewer.id,
      access: :view,
      granted_by_id: owner.id
    }

    {:ok, first} =
      DashboardInstanceAccessGrant
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create(actor: system)

    {:ok, second} =
      DashboardInstanceAccessGrant
      |> Ash.Changeset.for_create(:create, Map.put(attrs, :access, :edit))
      |> Ash.create(actor: system)

    assert first.id == second.id
    assert second.access == :edit

    {:ok, rows} =
      DashboardInstanceAccessGrant
      |> Ash.Query.for_read(:for_instance, %{dashboard_instance_id: instance.id})
      |> Ash.read(actor: system)

    assert length(rows) == 1
  end

  test "authored and package grant matching agree for an equivalent user grant", %{
    owner: owner,
    viewer: viewer,
    viewer_scope: viewer_scope,
    system: system
  } do
    {:ok, dashboard} =
      Dashboards.create_authored_dashboard(user_scope(owner), %{
        title: "Authored #{System.unique_integer([:positive])}",
        visibility: :shared
      })

    {_package, instance} =
      create_instance!(user_scope(owner), visibility: :shared, owner_id: owner.id)

    {:ok, _} =
      DashboardAccessGrant
      |> Ash.Changeset.for_create(:create, %{
        dashboard_id: dashboard.id,
        subject_user_id: viewer.id,
        access: :view,
        granted_by_id: owner.id
      })
      |> Ash.create(actor: system)

    {:ok, _} =
      DashboardInstanceAccessGrant
      |> Ash.Changeset.for_create(:create, %{
        dashboard_instance_id: instance.id,
        subject_user_id: viewer.id,
        access: :view,
        granted_by_id: owner.id
      })
      |> Ash.create(actor: system)

    assert {:ok, %AuthoredDashboard{id: dash_id}} =
             AuthoredDashboard
             |> Ash.Query.for_read(:by_id, %{id: dashboard.id})
             |> Ash.read_one(scope: viewer_scope)

    assert dash_id == dashboard.id

    assert {:ok, %DashboardInstance{id: instance_id}} =
             Dashboards.get_enabled_instance_by_slug(instance.route_slug, scope: viewer_scope)

    assert instance_id == instance.id
  end

  test "scope filters enabled_instances", %{
    owner: owner,
    owner_scope: owner_scope,
    viewer_scope: viewer_scope
  } do
    {_pkg, public_instance} = create_instance!(owner_scope, visibility: :public)

    {_pkg, private_instance} =
      create_instance!(owner_scope, visibility: :private, owner_id: owner.id)

    viewer_ids = enabled_ids(viewer_scope)
    assert public_instance.id in viewer_ids
    refute private_instance.id in viewer_ids
  end

  test "create_instance records the scoped user as owner", %{
    admin: admin,
    admin_scope: admin_scope
  } do
    package =
      DashboardPackage
      |> Ash.Changeset.for_create(:create, package_attrs())
      |> Ash.create!(actor: system_actor())

    {:ok, instance} =
      Dashboards.create_instance(
        package,
        %{
          name: "Owned Instance",
          route_slug: "owned-#{System.unique_integer([:positive])}",
          enabled: true
        },
        scope: admin_scope
      )

    assert instance.owner_id == admin.id
  end

  test "system-created instances have a null owner" do
    {_package, instance} = create_instance!(nil, visibility: :public)
    assert is_nil(instance.owner_id)
  end

  test "view_all bypass sees private instances", %{
    owner: owner,
    owner_scope: owner_scope,
    admin_scope: admin_scope
  } do
    {_package, instance} =
      create_instance!(owner_scope, visibility: :private, owner_id: owner.id)

    assert instance.id in enabled_ids(admin_scope)
  end

  defp viewer_user do
    user_fixture()
    |> Ash.Changeset.for_update(:update_role, %{role: :viewer}, actor: system_actor())
    |> Ash.update!()
  end

  defp user_scope(user) do
    Scope.for_user(user, permissions: RBAC.permissions_for_user(user))
  end

  defp enabled_ids(scope) do
    [scope: scope]
    |> Dashboards.enabled_instances()
    |> Enum.map(& &1.id)
  end

  defp create_instance!(scope, attrs) do
    attrs = Map.new(attrs)

    attrs =
      case scope do
        %{user: %{id: id}} -> Map.put_new(attrs, :owner_id, id)
        _ -> attrs
      end

    package =
      DashboardPackage
      |> Ash.Changeset.for_create(:create, package_attrs())
      |> Ash.create!(actor: system_actor())

    {:ok, instance} =
      Dashboards.create_instance(
        package,
        Map.merge(
          %{
            name: "Access Test",
            route_slug: "access-#{System.unique_integer([:positive])}",
            enabled: true,
            placement: :dashboard
          },
          attrs
        ),
        actor: system_actor()
      )

    {package, instance}
  end

  defp package_attrs do
    unique = System.unique_integer([:positive])

    %{
      dashboard_id: "com.test.access.#{unique}",
      name: "Access Test",
      version: "0.1.0",
      manifest: %{},
      renderer: %{
        "kind" => "browser_module",
        "interface_version" => "dashboard-browser-module-v1",
        "artifact" => "renderer.js",
        "sha256" => String.duplicate("a", 64)
      },
      data_frames: [],
      capabilities: [],
      settings_schema: %{},
      wasm_object_key: "dashboards/test/#{unique}.js",
      content_hash: String.duplicate("a", 64),
      verification_status: "verified",
      status: :enabled
    }
  end
end
