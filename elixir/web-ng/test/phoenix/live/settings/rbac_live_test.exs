defmodule ServiceRadarWebNGWeb.Settings.RbacLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.AshTestHelpers

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
        "identity.user_groups.manage"
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

  defp cleanup_unboxed!(marker, email) do
    Repo.delete_all(from(u in "ng_users", prefix: "platform", where: u.email == ^email))

    Repo.delete_all(
      from(g in "user_groups", prefix: "platform", where: like(g.name, ^"#{marker}%"))
    )

    Repo.delete_all(
      from(p in "role_profiles", prefix: "platform", where: like(p.name, ^"#{marker}%"))
    )
  end
end
