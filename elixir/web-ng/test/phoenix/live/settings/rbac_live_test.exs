defmodule ServiceRadarWebNGWeb.Settings.RbacLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias ServiceRadar.Dashboards.DashboardAccessGrant
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNG.Dashboards.GroupAccess

  require Ash.Query

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

    assert html_response(conn, 200) =~ "rbac-group-profile-loading"
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

    html = render_async(live_view, 5_000)

    assert has_element?(live_view, "#rbac-group-profile-controls[data-state='success']")
    assert html =~ fixture.group.name
    assert html =~ fixture.target_profile.name
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

    html = render_async(live_view, 5_000)

    assert has_element?(live_view, "#rbac-group-profile-empty[data-state='empty']")
    refute html =~ "Unable to load user groups. Try again."
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

    _html = render_async(live_view, 5_000)

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

    loading_html = render(live_view)
    assert loading_html =~ "rbac-group-profile-loading"
    refute loading_html =~ "rbac-group-profile-controls"

    send(failed_query_pid, :release_failed_group_refresh)
    html = render_async(live_view, 5_000)

    assert has_element?(live_view, "#rbac-group-profile-error[data-state='error']")
    assert html =~ "Unable to load user groups. Try again."
    refute html =~ "rbac-group-profile-controls"
    refute html =~ marker
    refute html =~ "No user groups have been created yet."
  end

  @tag :web_ng_shared_fixture_db
  @tag sandbox: :unboxed
  test "opaque assignment events delegate assign and clear to GroupPolicy", %{conn: conn} do
    fixture = group_profile_fixture!()

    {:ok, live_view, _html} =
      conn
      |> log_in_user(fixture.user)
      |> live(~p"/settings/auth/rbac")

    _html = render_async(live_view, 5_000)

    {group_token, profile_token} =
      group_profile_tokens(live_view, fixture.group.name, fixture.target_profile.name)

    live_view
    |> form("#rbac-group-profile-form-#{group_token}", %{
      "group-token" => group_token,
      "profile-token" => profile_token,
      "group-id" => "browser-forged-group",
      "profile-id" => "browser-forged-profile"
    })
    |> render_change()

    _html = render_async(live_view, 5_000)

    assert %{role_profile_id: assigned_profile_id} =
             Ash.get!(UserGroup, fixture.group.id, actor: fixture.system)

    assert assigned_profile_id == fixture.target_profile.id

    {fresh_group_token, _profile_token} =
      group_profile_tokens(live_view, fixture.group.name, fixture.target_profile.name)

    live_view
    |> element(
      "button[phx-click='clear_group_profile'][phx-value-group-token='#{fresh_group_token}']"
    )
    |> render_click(%{"group-id" => "browser-forged-group"})

    _html = render_async(live_view, 5_000)

    assert %{role_profile_id: nil} = Ash.get!(UserGroup, fixture.group.id, actor: fixture.system)

    html = render_click(live_view, "clear_group_profile", %{"group-token" => group_token})

    assert html =~ "Group assignments changed. Reloaded the latest values."
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

    _html = render_async(live_view, 5_000)

    {group_token, profile_token} =
      group_profile_tokens(live_view, fixture.group.name, fixture.target_profile.name)

    Repo.update_all(
      from(p in "role_profiles",
        prefix: "platform",
        where: p.id == ^fixture.authority_profile.id
      ),
      set: [permissions: ["settings.rbac.manage", "identity.user_groups.view"]]
    )

    live_view
    |> form("#rbac-group-profile-form-#{group_token}", %{
      "group-token" => group_token,
      "profile-token" => profile_token
    })
    |> render_change()

    html = render_async(live_view, 5_000)

    assert html =~ "Group assignment could not be updated. Reloaded the latest values."
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

    _html = render_async(live_view, 5_000)
    select_dashboard_group(live_view, fixture.group.name)
    html = render_async(live_view, 5_000)
    page = LazyHTML.from_fragment(html)

    assert has_element?(live_view, "#rbac-dashboard-audience")
    assert dashboard_row_count(page, :authored) == 50
    assert dashboard_row_count(page, :package) == 1
    assert html =~ "Public to users with analytics access"
    assert html =~ "Public to authenticated users"
    assert html =~ "Edit access includes view and cannot be removed here"

    live_view
    |> element("button[phx-click='next_authored_dashboard_audience']")
    |> render_click()

    next_html = render_async(live_view, 5_000)
    next_page = LazyHTML.from_fragment(next_html)

    assert dashboard_row_count(next_page, :authored) == 1
    assert next_html =~ fixture.public_package.name
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

    _html = render_async(live_view, 5_000)
    select_dashboard_group(live_view, fixture.group.name)
    _html = render_async(live_view, 5_000)

    Repo.update_all(
      from(p in "role_profiles",
        prefix: "platform",
        where: p.id == ^fixture.authority_profile.id
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

    html = render_async(live_view, 5_000)

    assert has_element?(live_view, "#rbac-authored-dashboards-error[role='alert']")
    refute has_element?(live_view, "#rbac-package-dashboards-error")
    assert html =~ fixture.public_package.name
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

    _html = render_async(live_view, 5_000)
    group_token = select_dashboard_group(live_view, fixture.group.name)
    _html = render_async(live_view, 5_000)
    row_token = dashboard_row_token(live_view, :authored, fixture.private_authored.title)

    render_click(live_view, "ensure_authored_dashboard_group_view", %{
      "group-token" => group_token,
      "row-token" => row_token,
      "target-id" => "browser-forged-target",
      "grant-id" => "browser-forged-grant"
    })

    _html = render_async(live_view, 5_000)
    assert group_grant_access(:authored, fixture.private_authored.id, fixture.group.id) == "view"

    other_group_token = select_dashboard_group(live_view, fixture.other_group.name)
    _html = render_async(live_view, 5_000)

    html =
      render_click(live_view, "ensure_authored_dashboard_group_view", %{
        "group-token" => other_group_token,
        "row-token" => row_token
      })

    assert html =~ "Dashboard audience could not be updated. Reloaded the latest values."

    assert is_nil(
             group_grant_access(:authored, fixture.private_authored.id, fixture.other_group.id)
           )

    render_click(live_view, "ensure_authored_dashboard_group_view", %{
      "group-token" => other_group_token,
      "row-token" => "forged-row-token"
    })

    _html = render_async(live_view, 5_000)
    stale_row = dashboard_row_token(live_view, :authored, fixture.private_authored.title)

    assert {:ok, _result} =
             GroupAccess.set_group_access(
               %{user: fixture.user},
               {:local, :authored},
               fixture.private_authored.id,
               fixture.other_group.id,
               :edit
             )

    html =
      render_click(live_view, "ensure_authored_dashboard_group_view", %{
        "group-token" => other_group_token,
        "row-token" => stale_row
      })

    assert html =~ "Dashboard audience could not be updated. Reloaded the latest values."

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

    _html = render_async(live_view, 5_000)
    group_token = select_dashboard_group(live_view, fixture.group.name)
    _html = render_async(live_view, 5_000)
    row_token = dashboard_row_token(live_view, :authored, fixture.private_authored.title)

    Repo.update_all(
      from(p in "role_profiles",
        prefix: "platform",
        where: p.id == ^fixture.authority_profile.id
      ),
      set: [permissions: ["identity.user_groups.view"]]
    )

    render_click(live_view, "ensure_authored_dashboard_group_view", %{
      "group-token" => group_token,
      "row-token" => row_token
    })

    html = render_async(live_view, 5_000)

    assert html =~ "Dashboard audience could not be updated. Reloaded the latest values."
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
    |> Ash.Changeset.for_update(:update_role_profile, %{role_profile_id: profile.id},
      actor: system
    )
    |> Ash.update!()

    {:ok, live_view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/settings/auth/rbac")

    assert MapSet.member?(RBAC.permissions_for_user(user), "settings.rbac.manage")

    Repo.update_all(
      from(p in "role_profiles", prefix: "platform", where: p.id == ^profile.id),
      set: [permissions: []]
    )

    name = "#{marker}-revoked-live"

    live_view
    |> element("button[phx-click='open_new_profile']")
    |> render_click()

    live_view
    |> form("#new-profile-form", profile: %{name: name, description: "Synthetic profile"})
    |> render_submit()

    assert render(live_view) =~ "Unexpected error"

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
      |> Ash.Changeset.for_update(:update_role_profile, %{role_profile_id: authority_profile.id},
        actor: system
      )
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
              id: id,
              dashboard_ref: synthetic_dashboard_ref(),
              title: title,
              owner_id: fixture.user.id,
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
          id: package_id,
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

    Repo.insert_all(
      "dashboard_instances",
      [
        %{
          id: public_package.id,
          dashboard_package_id: package_id,
          name: public_package.name,
          route_slug: "#{fixture.marker}-public-package",
          owner_id: fixture.user.id,
          visibility: "public"
        }
      ],
      prefix: "platform"
    )

    Map.merge(fixture, %{
      other_group: other_group,
      public_authored: public_authored,
      edit_authored: edit_authored,
      private_authored: private_authored,
      public_package: public_package
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
    |> element(
      "button[phx-click='select_dashboard_audience_group'][phx-value-group-token='#{group_token}']"
    )
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
    |> LazyHTML.filter("[data-dashboard-source='#{source}'] [data-dashboard-row]")
    |> LazyHTML.to_tree()
    |> length()
  end

  defp group_grant_access(:authored, target_id, group_id) do
    Repo.one(
      from(g in "dashboard_access_grants",
        prefix: "platform",
        where:
          g.dashboard_id == type(^target_id, :binary_id) and
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

    Repo.delete_all(
      from(g in "user_groups", prefix: "platform", where: like(g.name, ^"#{marker}%"))
    )

    Repo.delete_all(
      from(p in "role_profiles", prefix: "platform", where: like(p.name, ^"#{marker}%"))
    )
  end
end
