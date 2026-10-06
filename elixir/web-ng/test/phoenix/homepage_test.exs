defmodule ServiceRadarWebNG.HomepageTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.PrivilegedMembership
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.Homepage
  alias ServiceRadarWebNGWeb.Auth.SSOProvisioning
  alias ServiceRadarWebNGWeb.UserAuth

  @moduletag :web_ng_shared_fixture_db

  setup %{conn: conn} do
    ServiceRadar.Repo.query!("DELETE FROM platform.authorization_settings")

    system = SystemActor.system(:homepage_test)
    admin = admin_user_fixture()
    viewer = viewer_user_fixture()
    admin_scope = Scope.for_user(admin)

    conn =
      conn
      |> Map.replace!(:secret_key_base, ServiceRadarWebNGWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})
      |> fetch_flash()

    {:ok, conn: conn, system: system, admin: admin, viewer: viewer, admin_scope: admin_scope}
  end

  test "sign-in lands on user, then group, then deployment homepage, then /dashboard; a deep link beats them all",
       %{conn: conn, system: system, admin: admin, admin_scope: admin_scope, viewer: viewer} do
    dashboard = dashboard!(admin_scope, :public)
    dashboard_path = "/dashboard/" <> Dashboards.authored_dashboard_route_ref(dashboard)

    {:ok, _settings} = AuthorizationSettings.save_default_homepage(%{"kind" => "dashboards_index"}, actor: admin)
    group = group!(system, admin, "homepage-precedence", 100, authored(dashboard))
    member!(admin_scope, group, viewer)
    {:ok, viewer} = User.update_homepage_preference(viewer, %{"kind" => "overview"}, actor: viewer)

    assert redirected_to(UserAuth.log_in_user(conn, viewer, %{"return_to" => "/devices"})) == "/devices"
    assert redirected_to(UserAuth.log_in_user(conn, viewer)) == "/dashboard"

    {:ok, viewer} = User.update_homepage_preference(viewer, nil, actor: viewer)
    assert redirected_to(UserAuth.log_in_user(conn, viewer)) == dashboard_path

    # `/` follows the same resolution as sign-in.
    assert conn |> log_in_user(viewer) |> get(~p"/") |> redirected_to() == dashboard_path

    clear_group_homepage!(group, admin)
    assert redirected_to(UserAuth.log_in_user(conn, viewer)) == "/dashboards"

    {:ok, _settings} = AuthorizationSettings.save_default_homepage(nil, actor: admin)
    assert redirected_to(UserAuth.log_in_user(conn, viewer)) == "/dashboard"
  end

  test "groups rank by priority, then case-insensitive name; an unreadable group homepage is skipped before ranking",
       %{system: system, admin: admin, admin_scope: admin_scope, viewer: viewer} do
    private = dashboard!(admin_scope, :private)
    beta_target = dashboard!(admin_scope, :public)
    alpha_target = dashboard!(admin_scope, :public)

    member!(admin_scope, group!(system, admin, "homepage-first", 10, authored(private)), viewer)
    member!(
      admin_scope,
      group!(system, admin, "beta-homepage", 50, authored(beta_target)),
      viewer
    )
    member!(
      admin_scope,
      group!(system, admin, "Alpha-homepage", 50, authored(alpha_target)),
      viewer
    )

    viewer_scope = Scope.for_user(viewer)

    # Priority 10 wins only once its dashboard is readable; until then the
    # priority-50 tie goes to the name that sorts first ignoring case.
    assert %{source: :group, path: path} = Homepage.resolve(viewer_scope)
    assert path == route(alpha_target)

    {:ok, _private} = Dashboards.update_authored_dashboard(admin_scope, private, %{visibility: :public})
    assert Homepage.resolve(viewer_scope).path == route(private)
  end

  test "an unavailable user homepage falls through with a one-time notice; an unavailable group homepage is silent",
       %{conn: conn, system: system, admin: admin, admin_scope: admin_scope} do
    own = dashboard!(admin_scope, :private)
    group_target = dashboard!(admin_scope, :private)
    {:ok, admin} = User.update_homepage_preference(admin, authored(own), actor: admin)
    member!(
      admin_scope,
      group!(system, admin, "homepage-fallthrough", 100, authored(group_target)),
      admin
    )

    {:ok, _archived} = Dashboards.archive_authored_dashboard(admin_scope, own)
    conn_after = UserAuth.log_in_user(conn, admin)
    assert redirected_to(conn_after) == route(group_target)
    assert Phoenix.Flash.get(conn_after.assigns.flash, :info) =~ "no longer available"

    {:ok, admin} = User.update_homepage_preference(admin, nil, actor: admin)
    {:ok, _archived} = Dashboards.archive_authored_dashboard(admin_scope, group_target)
    conn_after = UserAuth.log_in_user(conn, admin)
    assert redirected_to(conn_after) == "/dashboard"
    assert is_nil(Phoenix.Flash.get(conn_after.assigns.flash, :info))
  end

  test "an SSO sign-in through a mapped IdP group lands on that group's homepage on the same request",
       %{conn: conn, system: system, admin: admin, admin_scope: admin_scope} do
    target = dashboard!(admin_scope, :public)
    group = group!(system, admin, "homepage-sso-#{System.unique_integer([:positive])}", 100, authored(target))

    {:ok, _settings} =
      AuthorizationSettings.create_settings(
        %{
          default_role: :viewer,
          role_mappings: [%{"source" => "groups", "value" => "idp-noc", "user_group_id" => group.id}]
        },
        actor: system
      )

    marker = "homepage-sso-#{System.unique_integer([:positive])}"

    {:ok, _provisioned} =
      User.provision_sso_user(
        %{email: "#{marker}@example.test", external_id: "oidc|#{marker}", role: :viewer, provider: :oidc},
        actor: system
      )

    assert {:ok, user} =
             SSOProvisioning.find_or_create_user(
               %{email: "#{marker}@example.test", name: "Synthetic SSO User", external_id: "oidc|#{marker}"},
               %{"sub" => "oidc|#{marker}", "email" => "#{marker}@example.test", "groups" => ["idp-noc"]},
               :oidc,
               system
             )

    assert redirected_to(UserAuth.log_in_user(conn, user)) == route(target)
  end

  test "dashboards hub 'Set as default' sets the profile homepage that drives sign-in",
       %{conn: conn, admin: admin, admin_scope: admin_scope} do
    target = dashboard!(admin_scope, :private)
    conn = log_in_user(conn, admin)

    {:ok, hub, _html} = live(conn, ~p"/dashboards")
    render_async(hub, 5_000)

    hub
    |> element("button[phx-click='set_default'][phx-value-id='#{target.id}']")
    |> render_click()

    {:ok, reloaded} = Ash.get(User, admin.id, actor: admin)
    assert reloaded.homepage == authored(target)

    {:ok, profile, _html} = live(conn, ~p"/settings/profile")
    assert profile |> element("#user_homepage option[selected]") |> render() =~ "authored:#{target.id}"

    assert redirected_to(UserAuth.log_in_user(build_session_conn(), reloaded)) == route(target)
  end

  defp build_session_conn do
    build_conn()
    |> Map.replace!(:secret_key_base, ServiceRadarWebNGWeb.Endpoint.config(:secret_key_base))
    |> init_test_session(%{})
    |> fetch_flash()
  end

  defp dashboard!(scope, visibility) do
    {:ok, dashboard} =
      Dashboards.create_authored_dashboard(scope, %{
        title: "Homepage target #{System.unique_integer([:positive])}",
        description: "",
        visibility: visibility,
        status: :active
      })

    dashboard
  end

  defp group!(system, manager, name, priority, homepage) do
    {:ok, group} = UserGroup.create_group(%{name: name}, actor: system)

    {:ok, group} =
      group
      |> Ash.Changeset.for_update(:update_homepage, %{homepage: homepage, homepage_priority: priority}, actor: manager)
      |> Ash.update()

    group
  end

  defp clear_group_homepage!(group, manager) do
    group
    |> Ash.Changeset.for_update(:update_homepage, %{homepage: nil}, actor: manager)
    |> Ash.update!()
  end

  # Membership writes must cross the privilege mutation boundary with a
  # scoped manager; direct :create_manual writes are rejected even for
  # system actors (RequirePrivilegeBoundary).
  defp member!(scope, group, user) do
    {:ok, membership} = PrivilegedMembership.add(scope, group.id, user.id)
    membership
  end

  defp authored(dashboard), do: %{"kind" => "dashboard", "target_type" => "authored", "target_id" => dashboard.id}

  defp route(dashboard), do: "/dashboard/" <> Dashboards.authored_dashboard_route_ref(dashboard)
end
