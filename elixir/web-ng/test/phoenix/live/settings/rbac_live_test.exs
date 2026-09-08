defmodule ServiceRadarWebNGWeb.Settings.RbacLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias ServiceRadar.Dashboards.DashboardAccessGrant
  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Identity.GroupPolicy
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNG.Dashboards.GroupAccess

  require Ash.Query

  @async_timeout 15_000

  test "dashboards section lists authored and package resources without aliased cli keys", %{
    conn: conn
  } do
    admin = AshTestHelpers.admin_user_fixture()

    {:ok, lv, _html} =
      conn
      |> log_in_user(admin)
      |> live(~p"/settings/auth/rbac")

    html =
      lv
      |> element("button[phx-click='select_section'][phx-value-section='dashboards']")
      |> render_click()

    assert html =~ "Authored"
    assert html =~ "Packages"
    refute html =~ "cli.dashboard"
    assert html =~ "publish"
    assert html =~ "share"
    assert html =~ "view all"
  end

  @tag :web_ng_shared_fixture_db
  @tag sandbox: :unboxed
  test "disconnected render shows loading without invoking the group query seam", %{conn: conn} do
    fixture = group_profile_fixture!()
    test_pid = self()

    install_group_profile_query!(fn kind, _scope ->
      send(test_pid, {:group_profile_query, kind})
      {:error, :must_not_run_during_disconnected_render}
    end)

    conn = conn |> log_in_user(fixture.user) |> get(~p"/settings/auth/rbac")

    assert conn
           |> html_response(200)
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#rbac-group-profile-loading[data-state='loading']")
           |> LazyHTML.to_tree() != []

    refute_received {:group_profile_query, _kind}
  end

  @tag :web_ng_shared_fixture_db
  @tag sandbox: :unboxed
  test "connected mount loads user groups and assignable profiles", %{conn: conn} do
    fixture = group_profile_fixture!()

    {:ok, live_view, _html} =
      conn
      |> log_in_user(fixture.user)
      |> live(~p"/settings/auth/rbac")

    _html = render_async(live_view, @async_timeout)

    assert has_element?(live_view, "#rbac-group-profile-controls[data-state='success']")

    assert has_element?(
             live_view,
             "[data-group-profile-row][data-group-name='#{fixture.group.name}']"
           )

    assert has_element?(
             live_view,
             "#rbac-group-profile-controls option[data-profile-name='#{fixture.target_profile.name}']"
           )
  end

  @tag :web_ng_shared_fixture_db
  @tag sandbox: :unboxed
  test "an empty group query renders the empty state rather than a failure", %{conn: conn} do
    fixture = group_profile_fixture!()
    install_group_profile_query!(fn _kind, _scope -> {:ok, []} end)

    {:ok, live_view, _html} =
      conn
      |> log_in_user(fixture.user)
      |> live(~p"/settings/auth/rbac")

    _html = render_async(live_view, @async_timeout)

    assert has_element?(live_view, "#rbac-group-profile-empty[data-state='empty']")
    refute has_element?(live_view, "#rbac-group-profile-error")
  end

  @tag :web_ng_shared_fixture_db
  @tag sandbox: :unboxed
  test "a failed refresh replaces successful group controls with loading and a retryable error",
       %{
         conn: conn
       } do
    fixture = group_profile_fixture!()
    marker = "synthetic-internal-group-query-marker"
    test_pid = self()
    query_mode = start_supervised!({Agent, fn -> :success end})

    install_group_profile_query!(fn
      :groups, _scope ->
        case Agent.get(query_mode, & &1) do
          :success ->
            {:ok, [fixture.group]}

          :failure ->
            send(test_pid, {:failed_group_refresh_waiting, self()})

            receive do
              :release_failed_group_refresh ->
                {:error, {:synthetic_backend_failure, marker}}
            end
        end

      :profiles, _scope ->
        case Agent.get(query_mode, & &1) do
          :success -> {:ok, [fixture.target_profile]}
          :failure -> {:error, :profiles_must_not_be_queried_after_group_failure}
        end
    end)

    {:ok, live_view, _html} =
      conn
      |> log_in_user(fixture.user)
      |> live(~p"/settings/auth/rbac")

    _html = render_async(live_view, @async_timeout)

    assert has_element?(live_view, "#rbac-group-profile-controls[data-state='success']")

    {group_token, profile_token} =
      group_profile_tokens(live_view, fixture.group.name, fixture.target_profile.name)

    Agent.update(query_mode, fn _mode -> :failure end)

    live_view
    |> form("#rbac-group-profile-form-#{group_token}", %{
      "group-token" => group_token,
      "profile-token" => profile_token
    })
    |> render_change()

    assert_receive {:failed_group_refresh_waiting, failed_query_pid}, 1_000

    assert has_element?(live_view, "#rbac-group-profile-loading")
    refute has_element?(live_view, "#rbac-group-profile-controls")

    send(failed_query_pid, :release_failed_group_refresh)
    html = render_async(live_view, @async_timeout)

    assert has_element?(live_view, "#rbac-group-profile-error[data-state='error']")

    assert live_view |> element("#rbac-group-profile-error") |> render() =~
             "Unable to load user groups. Try again."

    refute has_element?(live_view, "#rbac-group-profile-controls")
    refute html =~ marker
    refute has_element?(live_view, "#rbac-group-profile-empty")
  end

  @tag :web_ng_shared_fixture_db
  @tag sandbox: :unboxed
  test "opaque assignment events delegate assign and clear to GroupPolicy", %{conn: conn} do
    fixture = group_profile_fixture!()

    {:ok, live_view, _html} =
      conn
      |> log_in_user(fixture.user)
      |> live(~p"/settings/auth/rbac")

    _html = render_async(live_view, @async_timeout)

    {group_token, profile_token} =
      group_profile_tokens(live_view, fixture.group.name, fixture.target_profile.name)

    live_view
    |> element("#rbac-group-profile-form-#{group_token}")
    |> render_change(%{
      "group-token" => group_token,
      "profile-token" => profile_token,
      "group-id" => "browser-forged-group",
      "profile-id" => "browser-forged-profile"
    })

    _html = render_async(live_view, @async_timeout)

    assert %{role_profile_id: assigned_profile_id} =
             Ash.get!(UserGroup, fixture.group.id, actor: fixture.system)

    assert assigned_profile_id == fixture.target_profile.id

    {fresh_group_token, _profile_token} =
      group_profile_tokens(live_view, fixture.group.name, fixture.target_profile.name)

    live_view
    |> element("button[phx-click='clear_group_profile'][phx-value-group-token='#{fresh_group_token}']")
    |> render_click(%{"group-id" => "browser-forged-group"})

    _html = render_async(live_view, @async_timeout)

    assert %{role_profile_id: nil} = Ash.get!(UserGroup, fixture.group.id, actor: fixture.system)

    _html = render_click(live_view, "clear_group_profile", %{"group-token" => group_token})

    assert live_view |> element("#flash-error") |> render() =~
             "Group assignments changed. Reloaded the latest values."

    assert %{role_profile_id: nil} = Ash.get!(UserGroup, fixture.group.id, actor: fixture.system)
  end

  @tag :web_ng_shared_fixture_db
  @tag sandbox: :unboxed
  test "group profile mutation fails after manage authority is revoked from an open page", %{
    conn: conn
  } do
    fixture = group_profile_fixture!()

    {:ok, live_view, _html} =
      conn
      |> log_in_user(fixture.user)
      |> live(~p"/settings/auth/rbac")

    _html = render_async(live_view, @async_timeout)

    {group_token, profile_token} =
      group_profile_tokens(live_view, fixture.group.name, fixture.target_profile.name)

    Repo.update_all(
      from(p in "role_profiles",
        prefix: "platform",
        where: p.id == type(^fixture.authority_profile.id, :binary_id)
      ),
      set: [permissions: ["settings.rbac.manage", "identity.user_groups.view"]]
    )

    live_view
    |> form("#rbac-group-profile-form-#{group_token}", %{
      "group-token" => group_token,
      "profile-token" => profile_token
    })
    |> render_change()

    _html = render_async(live_view, @async_timeout)

    assert live_view |> element("#flash-error") |> render() =~
             "Group assignment could not be updated. Reloaded the latest values."

    assert %{role_profile_id: nil} = Ash.get!(UserGroup, fixture.group.id, actor: fixture.system)
  end

  @tag :web_ng_shared_fixture_db
  @tag sandbox: :unboxed
  test "connected audience pages stay bounded and render source-accurate public and edit states",
       %{
         conn: conn
       } do
    fixture = dashboard_audience_fixture!(51)

    {:ok, live_view, _html} =
      conn
      |> log_in_user(fixture.user)
      |> live(~p"/settings/auth/rbac")

    _html = render_async(live_view, @async_timeout)
    select_dashboard_group(live_view, fixture.group.name)
    html = render_async(live_view, @async_timeout)
    page = LazyHTML.from_fragment(html)

    assert has_element?(live_view, "#rbac-dashboard-audience")
    assert dashboard_row_count(page, :authored) == 50
    assert dashboard_row_count(page, :package) == 2

    assert live_view
           |> element("[data-dashboard-name='#{fixture.public_authored.title}']")
           |> render() =~ "Public to users with analytics access"

    assert live_view
           |> element("[data-dashboard-name='#{fixture.public_package.name}']")
           |> render() =~ "Public to authenticated users"

    assert live_view
           |> element("[data-dashboard-name='#{fixture.edit_authored.title}']")
           |> render() =~ "Edit access includes view and cannot be removed here"

    live_view
    |> element("button[phx-click='next_authored_dashboard_audience']")
    |> render_click()

    next_html = render_async(live_view, @async_timeout)
    next_page = LazyHTML.from_fragment(next_html)

    assert dashboard_row_count(next_page, :authored) == 1
    assert has_element?(live_view, "[data-dashboard-name='#{fixture.public_package.name}']")
  end

  @tag :web_ng_shared_fixture_db
  @tag sandbox: :unboxed
  test "a successful group profile refresh preserves audience rows and uses the refreshed group token",
       %{conn: conn} do
    fixture = dashboard_audience_fixture!(3)

    {:ok, live_view, _html} =
      conn
      |> log_in_user(fixture.user)
      |> live(~p"/settings/auth/rbac")

    _html = render_async(live_view, @async_timeout)
    initial_group_token = select_dashboard_group(live_view, fixture.group.name)
    _html = render_async(live_view, @async_timeout)

    assert has_element?(
             live_view,
             "[data-dashboard-source='authored'] [data-dashboard-name='#{fixture.private_authored.title}']"
           )

    {assignment_group_token, profile_token} =
      group_profile_tokens(live_view, fixture.group.name, fixture.target_profile.name)

    live_view
    |> form("#rbac-group-profile-form-#{assignment_group_token}", %{
      "group-token" => assignment_group_token,
      "profile-token" => profile_token
    })
    |> render_change()

    _html = render_async(live_view, @async_timeout)

    assert has_element?(
             live_view,
             "[data-dashboard-source='authored'] [data-dashboard-name='#{fixture.private_authored.title}']"
           )

    # The accepted group load starts the two audience loads; render_async waits
    # only for the tasks present when it is called, so settle the second stage too.
    _html = render_async(live_view, @async_timeout)

    {fresh_group_token, _fresh_profile_token} =
      group_profile_tokens(live_view, fixture.group.name, fixture.target_profile.name)

    refute fresh_group_token == initial_group_token

    for {source, name, id} <- [
          {:authored, fixture.private_authored.title, fixture.private_authored.id},
          {:package, fixture.private_package.name, fixture.private_package.id}
        ] do
      button = dashboard_button(source, name, :ensure)
      assert has_element?(live_view, "#{button}[phx-value-group-token='#{fresh_group_token}']")
      live_view |> element(button) |> render_click()
      _html = render_async(live_view, @async_timeout)
      assert group_grant_access(source, id, fixture.group.id) == "view"
    end

    authored_token = dashboard_row_token(live_view, :authored, fixture.private_authored.title)
    send(live_view.pid, {:refresh_dashboard_group_tokens, 0})
    _html = render_async(live_view, @async_timeout)

    assert dashboard_row_token(live_view, :authored, fixture.private_authored.title) ==
             authored_token

    assert {:ok, _group} = GroupPolicy.delete(%{user: fixture.user}, fixture.group.id)

    live_view
    |> element("button[phx-click='clear_group_profile'][phx-value-group-token='#{fresh_group_token}']")
    |> render_click()

    _html = render_async(live_view, @async_timeout)
    refute has_element?(live_view, "[data-group-name='#{fixture.group.name}']")
    refute has_element?(live_view, "#rbac-dashboard-audience")
  end

  @tag :web_ng_shared_fixture_db
  @tag sandbox: :unboxed
  test "private package buttons grant and revoke view while leaving the authored window unchanged",
       %{conn: conn} do
    fixture = dashboard_audience_fixture!(3)
    {:ok, live_view, _html} = conn |> log_in_user(fixture.user) |> live(~p"/settings/auth/rbac")
    _html = render_async(live_view, @async_timeout)
    select_dashboard_group(live_view, fixture.group.name)
    _html = render_async(live_view, @async_timeout)
    authored_before = live_view |> element("[data-dashboard-source='authored']") |> render()

    assert %{visibility: :private} =
             Ash.get!(DashboardInstance, fixture.private_package.id, actor: fixture.system)

    live_view
    |> element(dashboard_button(:package, fixture.private_package.name, :ensure))
    |> render_click()

    _html = render_async(live_view, @async_timeout)
    assert group_grant_access(:package, fixture.private_package.id, fixture.group.id) == "view"

    assert %{visibility: :shared} =
             Ash.get!(DashboardInstance, fixture.private_package.id, actor: fixture.system)

    assert live_view |> element("[data-dashboard-source='authored']") |> render() ==
             authored_before

    live_view
    |> element(dashboard_button(:package, fixture.private_package.name, :revoke))
    |> render_click()

    _html = render_async(live_view, @async_timeout)
    assert is_nil(group_grant_access(:package, fixture.private_package.id, fixture.group.id))

    assert %{visibility: :shared} =
             Ash.get!(DashboardInstance, fixture.private_package.id, actor: fixture.system)

    assert live_view |> element("[data-dashboard-source='authored']") |> render() ==
             authored_before

    assert is_nil(group_grant_access(:authored, fixture.private_authored.id, fixture.group.id))
    assert group_grant_access(:authored, fixture.edit_authored.id, fixture.group.id) == "edit"
  end

  @tag :web_ng_shared_fixture_db
  @tag sandbox: :unboxed
  test "a failed authored next page preserves the package stream and reports only authored error",
       %{
         conn: conn
       } do
    fixture = dashboard_audience_fixture!(51)

    {:ok, live_view, _html} =
      conn
      |> log_in_user(fixture.user)
      |> live(~p"/settings/auth/rbac")

    _html = render_async(live_view, @async_timeout)
    select_dashboard_group(live_view, fixture.group.name)
    _html = render_async(live_view, @async_timeout)

    Repo.update_all(
      from(p in "role_profiles",
        prefix: "platform",
        where: p.id == type(^fixture.authority_profile.id, :binary_id)
      ),
      set: [
        permissions: [
          "settings.rbac.manage",
          "identity.user_groups.view",
          "identity.user_groups.manage",
          "dashboards.packages.share",
          "dashboards.packages.view_all"
        ]
      ]
    )

    live_view
    |> element("button[phx-click='next_authored_dashboard_audience']")
    |> render_click()

    html = render_async(live_view, @async_timeout)

    assert has_element?(live_view, "#rbac-authored-dashboards-error[role='alert']")
    refute has_element?(live_view, "#rbac-package-dashboards-error")
    assert has_element?(live_view, "[data-dashboard-name='#{fixture.public_package.name}']")
    refute html =~ "synthetic_page_failure"
  end

  @tag :web_ng_shared_fixture_db
  @tag sandbox: :unboxed
  test "audience mutations reject forged cross-group and stale row state", %{conn: conn} do
    fixture = dashboard_audience_fixture!(3)

    {:ok, live_view, _html} =
      conn
      |> log_in_user(fixture.user)
      |> live(~p"/settings/auth/rbac")

    _html = render_async(live_view, @async_timeout)
    group_token = select_dashboard_group(live_view, fixture.group.name)
    _html = render_async(live_view, @async_timeout)
    row_token = dashboard_row_token(live_view, :authored, fixture.private_authored.title)

    render_click(live_view, "ensure_authored_dashboard_group_view", %{
      "group-token" => group_token,
      "row-token" => row_token,
      "target-id" => "browser-forged-target",
      "grant-id" => "browser-forged-grant"
    })

    _html = render_async(live_view, @async_timeout)
    assert group_grant_access(:authored, fixture.private_authored.id, fixture.group.id) == "view"

    other_group_token = select_dashboard_group(live_view, fixture.other_group.name)
    _html = render_async(live_view, @async_timeout)

    _html =
      render_click(live_view, "ensure_authored_dashboard_group_view", %{
        "group-token" => other_group_token,
        "row-token" => row_token
      })

    assert live_view |> element("#flash-error") |> render() =~
             "Dashboard audience could not be updated. Reloaded the latest values."

    assert is_nil(group_grant_access(:authored, fixture.private_authored.id, fixture.other_group.id))

    render_click(live_view, "ensure_authored_dashboard_group_view", %{
      "group-token" => other_group_token,
      "row-token" => "forged-row-token"
    })

    _html = render_async(live_view, @async_timeout)
    stale_row = dashboard_row_token(live_view, :authored, fixture.private_authored.title)

    assert {:ok, _result} =
             GroupAccess.set_group_access(
               %{user: fixture.user},
               {:local, :authored},
               fixture.private_authored.id,
               fixture.other_group.id,
               :edit
             )

    _html =
      render_click(live_view, "ensure_authored_dashboard_group_view", %{
        "group-token" => other_group_token,
        "row-token" => stale_row
      })

    assert live_view |> element("#flash-error") |> render() =~
             "Dashboard audience could not be updated. Reloaded the latest values."

    assert group_grant_access(:authored, fixture.private_authored.id, fixture.other_group.id) ==
             "edit"
  end

  @tag :web_ng_shared_fixture_db
  @tag sandbox: :unboxed
  test "audience mutation fails closed after manage authority is revoked from an open page", %{
    conn: conn
  } do
    fixture = dashboard_audience_fixture!(3)

    {:ok, live_view, _html} =
      conn
      |> log_in_user(fixture.user)
      |> live(~p"/settings/auth/rbac")

    _html = render_async(live_view, @async_timeout)
    group_token = select_dashboard_group(live_view, fixture.group.name)
    _html = render_async(live_view, @async_timeout)
    row_token = dashboard_row_token(live_view, :authored, fixture.private_authored.title)

    Repo.update_all(
      from(p in "role_profiles",
        prefix: "platform",
        where: p.id == type(^fixture.authority_profile.id, :binary_id)
      ),
      set: [permissions: ["identity.user_groups.view"]]
    )

    render_click(live_view, "ensure_authored_dashboard_group_view", %{
      "group-token" => group_token,
      "row-token" => row_token
    })

    _html = render_async(live_view, @async_timeout)

    assert live_view |> element("#flash-error") |> render() =~
             "Dashboard audience could not be updated. Reloaded the latest values."

    assert is_nil(group_grant_access(:authored, fixture.private_authored.id, fixture.group.id))
  end

  @tag :web_ng_shared_fixture_db
  @tag sandbox: :unboxed
  test "rejects a role-profile mutation after mounted RBAC authority is revoked", %{conn: conn} do
    marker = "live-authority-#{System.unique_integer([:positive])}"
    email = "#{marker}@example.test"
    on_exit(fn -> cleanup_unboxed!(marker, email) end)

    system = AshTestHelpers.system_actor()
    user = AshTestHelpers.admin_user_fixture(%{email: email})
    profile = custom_profile!(system, marker, ["settings.rbac.manage"])

    user
    |> Ash.Changeset.for_update(:update_role_profile, %{role_profile_id: profile.id}, actor: system)
    |> Ash.update!()

    {:ok, live_view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/settings/auth/rbac")

    assert MapSet.member?(RBAC.permissions_for_user(user), "settings.rbac.manage")

    Repo.update_all(
      from(p in "role_profiles",
        prefix: "platform",
        where: p.id == type(^profile.id, :binary_id)
      ),
      set: [permissions: []]
    )

    name = "#{marker}-revoked-live"

    live_view
    |> element("button[phx-click='open_new_profile']:not([phx-value-clone-source-id])")
    |> render_click()

    live_view
    |> form("#new-profile-form", profile: %{name: name, description: "Synthetic profile"})
    |> render_submit()

    assert live_view |> element("#flash-error") |> render() =~ "Unexpected error"

    assert {:ok, []} =
             RoleProfile
             |> Ash.Query.filter(name == ^name)
             |> Ash.read(actor: system)
  end

  defp custom_profile!(actor, marker, permissions) do
    RoleProfile
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "#{marker}-profile",
        permissions: permissions
      },
      actor: actor,
      context: %{privilege_boundary_owned: true}
    )
    |> Ash.create!()
  end

  @tag :web_ng_shared_fixture_db
  @tag sandbox: :unboxed
  test "created and cloned profiles immediately become assignable without losing matrix edits", %{
    conn: conn
  } do
    fixture = group_profile_fixture!()
    {:ok, live_view, _html} = conn |> log_in_user(fixture.user) |> live(~p"/settings/auth/rbac")
    _html = render_async(live_view, @async_timeout)
    select_matrix_profile(live_view, fixture.target_profile.id)

    live_view
    |> element("button[phx-click='set_profile_permissions'][phx-value-mode='all']")
    |> render_click()

    for mode <- [:create, :clone] do
      select_matrix_profile(live_view, fixture.target_profile.id)

      selector =
        case mode do
          :create ->
            "button[phx-click='open_new_profile']:not([phx-value-clone-source-id])"

          :clone ->
            "button[phx-click='open_new_profile'][phx-value-clone-source-id='#{fixture.target_profile.id}']"
        end

      live_view |> element(selector) |> render_click()
      name = "#{fixture.marker}-#{mode}-profile"

      live_view
      |> form("#new-profile-form", profile: %{name: name, description: "Synthetic lifecycle"})
      |> render_submit()

      _html = render_async(live_view, @async_timeout)
      assign_profile_from_controls(live_view, fixture.group.name, name)

      created =
        RoleProfile |> Ash.Query.filter(name == ^name) |> Ash.read_one!(actor: fixture.system)

      assert %{role_profile_id: assigned} =
               Ash.get!(UserGroup, fixture.group.id, actor: fixture.system)

      assert assigned == created.id

      if mode == :create,
        do: assert(created.permissions == []),
        else: assert("devices.view" in created.permissions)
    end

    select_matrix_profile(live_view, fixture.target_profile.id)

    assert has_element?(
             live_view,
             "button[phx-click='save_profile'][phx-value-profile-id='#{fixture.target_profile.id}']"
           )

    assert %{permissions: []} =
             Ash.get!(RoleProfile, fixture.target_profile.id, actor: fixture.system)

    live_view |> element("button[phx-click='save_profile']") |> render_click()

    assert "devices.view" in Ash.get!(RoleProfile, fixture.target_profile.id, actor: fixture.system).permissions
  end

  @tag :web_ng_shared_fixture_db
  @tag sandbox: :unboxed
  test "rename refreshes options and delete clears options and associations while preserving unsaved permissions",
       %{conn: conn} do
    fixture = group_profile_fixture!()
    {:ok, live_view, _html} = conn |> log_in_user(fixture.user) |> live(~p"/settings/auth/rbac")
    _html = render_async(live_view, @async_timeout)
    assign_profile_from_controls(live_view, fixture.group.name, fixture.target_profile.name)
    select_matrix_profile(live_view, fixture.target_profile.id)

    live_view
    |> element("button[phx-click='set_profile_permissions'][phx-value-mode='all']")
    |> render_click()

    live_view |> element("button[phx-click='start_rename_profile']") |> render_click()
    name = "#{fixture.marker}-renamed-profile"

    live_view
    |> form("form[phx-submit='rename_profile']", profile: %{name: name})
    |> render_submit()

    _html = render_async(live_view, @async_timeout)

    assert has_element?(
             live_view,
             "#rbac-group-profile-controls option[data-profile-name='#{name}'][selected]"
           )

    refute has_element?(
             live_view,
             "#rbac-group-profile-controls option[data-profile-name='#{fixture.target_profile.name}']"
           )

    assert has_element?(live_view, "button[phx-click='save_profile']")
    live_view |> element("button[phx-click='save_profile']") |> render_click()

    assert "devices.view" in Ash.get!(RoleProfile, fixture.target_profile.id, actor: fixture.system).permissions

    live_view |> element("button[phx-click='open_delete_profile']") |> render_click()

    live_view
    |> element("#rbac-delete-profile-modal button[phx-click='delete_profile']")
    |> render_click()

    _html = render_async(live_view, @async_timeout)

    refute has_element?(
             live_view,
             "#rbac-group-profile-controls option[data-profile-name='#{name}']"
           )

    assert has_element?(
             live_view,
             "[data-group-name='#{fixture.group.name}'] option[value=''][selected]"
           )

    refute has_element?(
             live_view,
             "[data-group-name='#{fixture.group.name}'] button[phx-click='clear_group_profile']"
           )

    assert %{role_profile_id: nil} = Ash.get!(UserGroup, fixture.group.id, actor: fixture.system)
  end

  defp select_matrix_profile(live_view, profile_id) do
    live_view
    |> element("button[phx-click='select_profile'][phx-value-profile-id='#{profile_id}']")
    |> render_click()
  end

  defp assign_profile_from_controls(live_view, group_name, profile_name) do
    {group_token, profile_token} = group_profile_tokens(live_view, group_name, profile_name)

    live_view
    |> form("#rbac-group-profile-form-#{group_token}", %{
      "group-token" => group_token,
      "profile-token" => profile_token
    })
    |> render_change()

    render_async(live_view, @async_timeout)
  end

  defp group_profile_fixture! do
    marker = "group-profile-live-#{System.unique_integer([:positive])}"
    email = "#{marker}@example.test"
    on_exit(fn -> cleanup_unboxed!(marker, email) end)

    system = AshTestHelpers.system_actor()
    user = AshTestHelpers.admin_user_fixture(%{email: email})

    authority_profile =
      custom_profile!(system, "#{marker}-authority", [
        "settings.rbac.manage",
        "identity.user_groups.view",
        "identity.user_groups.manage",
        "analytics.dashboards.share",
        "analytics.dashboards.edit",
        "dashboards.packages.share",
        "dashboards.packages.view_all"
      ])

    target_profile = custom_profile!(system, "#{marker}-target", [])

    user =
      user
      |> Ash.Changeset.for_update(:update_role_profile, %{role_profile_id: authority_profile.id}, actor: system)
      |> Ash.update!()

    group =
      UserGroup
      |> Ash.Changeset.for_create(
        :create,
        %{name: "#{marker}-group", description: "Synthetic group profile test"},
        actor: system
      )
      |> Ash.create!()

    %{
      marker: marker,
      system: system,
      user: user,
      authority_profile: authority_profile,
      target_profile: target_profile,
      group: group
    }
  end

  defp dashboard_audience_fixture!(authored_count) do
    fixture = group_profile_fixture!()

    other_group =
      UserGroup
      |> Ash.Changeset.for_create(
        :create,
        %{name: "#{fixture.marker}-other-group", description: "Synthetic alternate audience"},
        actor: fixture.system
      )
      |> Ash.create!()

    authored =
      Enum.map(0..(authored_count - 1), fn index ->
        visibility = if index == 0, do: :public, else: :private
        label = index |> Integer.to_string() |> String.pad_leading(3, "0")
        title = "#{fixture.marker}-authored-#{label}"
        id = Ecto.UUID.generate()

        Repo.insert_all(
          "authored_dashboards",
          [
            %{
              id: Ecto.UUID.dump!(id),
              dashboard_ref: synthetic_dashboard_ref(),
              title: title,
              owner_id: Ecto.UUID.dump!(fixture.user.id),
              visibility: Atom.to_string(visibility)
            }
          ],
          prefix: "platform"
        )

        %{id: id, title: title}
      end)

    [public_authored, edit_authored, private_authored | _rest] = authored

    DashboardAccessGrant
    |> Ash.Changeset.for_create(
      :set_group_access,
      %{
        dashboard_id: edit_authored.id,
        subject_group_id: fixture.group.id,
        granted_by_id: fixture.user.id,
        access: :edit
      },
      actor: fixture.system,
      context: %{dashboard_group_access_boundary_owned: true}
    )
    |> Ash.create!()

    package_id = Ecto.UUID.generate()
    package_name = "#{fixture.marker}-package"

    Repo.insert_all(
      "dashboard_packages",
      [
        %{
          id: Ecto.UUID.dump!(package_id),
          dashboard_id: package_name,
          name: package_name,
          version: "1.0.0"
        }
      ],
      prefix: "platform"
    )

    public_package = %{
      id: Ecto.UUID.generate(),
      name: "#{fixture.marker}-public-package"
    }

    private_package = %{id: Ecto.UUID.generate(), name: "#{fixture.marker}-private-package"}

    Repo.insert_all(
      "dashboard_instances",
      [
        %{
          id: Ecto.UUID.dump!(public_package.id),
          dashboard_package_id: Ecto.UUID.dump!(package_id),
          name: public_package.name,
          route_slug: "#{fixture.marker}-public-package",
          owner_id: Ecto.UUID.dump!(fixture.user.id),
          visibility: "public"
        },
        %{
          id: Ecto.UUID.dump!(private_package.id),
          dashboard_package_id: Ecto.UUID.dump!(package_id),
          name: private_package.name,
          route_slug: "#{fixture.marker}-private-package",
          owner_id: Ecto.UUID.dump!(fixture.user.id),
          visibility: "private"
        }
      ],
      prefix: "platform"
    )

    Map.merge(fixture, %{
      other_group: other_group,
      public_authored: public_authored,
      edit_authored: edit_authored,
      private_authored: private_authored,
      public_package: public_package,
      private_package: private_package
    })
  end

  defp install_group_profile_query!(query_fun) do
    previous = Application.get_env(:serviceradar_web_ng, :rbac_policy_data_query)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:serviceradar_web_ng, :rbac_policy_data_query)
      else
        Application.put_env(:serviceradar_web_ng, :rbac_policy_data_query, previous)
      end
    end)

    Application.put_env(:serviceradar_web_ng, :rbac_policy_data_query, query_fun)
  end

  defp group_profile_tokens(live_view, group_name, profile_name) do
    page = live_view |> render() |> LazyHTML.from_fragment()
    row = LazyHTML.query(page, "[data-group-profile-row][data-group-name='#{group_name}']")

    [group_token] =
      row
      |> LazyHTML.query("input[name='group-token']")
      |> LazyHTML.attribute("value")

    [profile_token] =
      row
      |> LazyHTML.query("option[data-profile-name='#{profile_name}']")
      |> LazyHTML.attribute("value")

    {group_token, profile_token}
  end

  defp select_dashboard_group(live_view, group_name) do
    page = live_view |> render() |> LazyHTML.from_fragment()
    row = LazyHTML.query(page, "[data-group-profile-row][data-group-name='#{group_name}']")

    [group_token] =
      row
      |> LazyHTML.query("button[phx-click='select_dashboard_audience_group']")
      |> LazyHTML.attribute("phx-value-group-token")

    live_view
    |> element("button[phx-click='select_dashboard_audience_group'][phx-value-group-token='#{group_token}']")
    |> render_click()

    group_token
  end

  defp dashboard_row_token(live_view, source, name) do
    page = live_view |> render() |> LazyHTML.from_fragment()

    [row_token] =
      page
      |> LazyHTML.query(
        "[data-dashboard-source='#{source}'] [data-dashboard-row][data-dashboard-name='#{name}'] [data-row-token]"
      )
      |> LazyHTML.attribute("data-row-token")

    row_token
  end

  defp dashboard_row_count(page, source) do
    page
    |> LazyHTML.query("[data-dashboard-source='#{source}'] [data-dashboard-row]")
    |> LazyHTML.to_tree()
    |> length()
  end

  defp dashboard_button(source, name, operation) do
    "[data-dashboard-source='#{source}'] [data-dashboard-name='#{name}'] button[phx-click='#{operation}_#{source}_dashboard_group_view']"
  end

  defp group_grant_access(source, target_id, group_id) do
    {table, target_field} =
      case source do
        :authored -> {"dashboard_access_grants", :dashboard_id}
        :package -> {"dashboard_instance_access_grants", :dashboard_instance_id}
      end

    Repo.one(
      from(g in table,
        prefix: "platform",
        where:
          field(g, ^target_field) == type(^target_id, :binary_id) and
            g.subject_group_id == type(^group_id, :binary_id) and g.subject_type == "group",
        select: g.access
      )
    )
  end

  defp synthetic_dashboard_ref do
    1_000_000 + :erlang.phash2(Ecto.UUID.generate(), 9_000_000)
  end

  defp cleanup_unboxed!(marker, email) do
    Repo.delete_all(
      from(d in "authored_dashboards",
        prefix: "platform",
        where: like(d.title, ^"#{marker}-%")
      )
    )

    Repo.delete_all(
      from(d in "dashboard_instances",
        prefix: "platform",
        where: like(d.name, ^"#{marker}-%")
      )
    )

    Repo.delete_all(
      from(p in "dashboard_packages",
        prefix: "platform",
        where: like(p.dashboard_id, ^"#{marker}-%")
      )
    )

    Repo.delete_all(from(u in "ng_users", prefix: "platform", where: u.email == ^email))

    Repo.delete_all(from(g in "user_groups", prefix: "platform", where: like(g.name, ^"#{marker}%")))

    Repo.delete_all(from(p in "role_profiles", prefix: "platform", where: like(p.name, ^"#{marker}%")))
  end
end
