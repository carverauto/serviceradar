defmodule ServiceRadarWebNGWeb.Settings.VisibilityProfilesLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Inventory.VisibilityProfile
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  setup :register_and_log_in_admin_user

  @tag :visibility_profiles_live
  test "renders visibility profile list and create route", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/settings/networks/visibility-profiles")

    assert html =~ "Visibility Profiles"

    {:ok, _lv, html} =
      lv
      |> element("a", "New Profile")
      |> render_click()
      |> follow_redirect(conn, ~p"/settings/networks/visibility-profiles/new")

    assert html =~ "New Visibility Profile"
    assert html =~ "Passive Fingerprinting"
  end

  @tag :visibility_profiles_live
  test "creates visibility profile with fingerprint DPI attribution and snapshot toggles", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/visibility-profiles/new")

    lv
    |> form("#visibility-profile-form",
      form: %{
        name: "Edge HTTP Passive",
        description: "HTTP only",
        enabled: "true",
        target_query: "hostname:%edge%",
        priority: "10",
        capture_interfaces: "eth0",
        sample_interval_ms: "30000",
        retention_days: "14",
        fingerprint: %{"tcp" => "false", "tls" => "false", "http" => "true"},
        dpi: %{
          "enabled" => "true",
          "protocols" => %{"dns" => "true", "tls" => "true", "http1" => "false"}
        },
        flow_attribution: %{"tcp" => "true", "udp" => "true", "quic" => "false"},
        process_snapshot_interval_s: "90"
      }
    )
    |> render_submit()

    assert_redirect(lv, ~p"/settings/networks/visibility-profiles")

    {:ok, _lv, html} = live(conn, ~p"/settings/networks/visibility-profiles")
    assert html =~ "Edge HTTP Passive"
    assert html =~ "eth0"
    assert html =~ "HTTP"
    assert html =~ "DPI DNS"
    assert html =~ "DPI TLS"
    assert html =~ "Flow TCP"
    assert html =~ "Flow UDP"
    assert html =~ "Snapshots 90s"

    {:ok, profiles} = Ash.read(VisibilityProfile, scope: scope)
    profile = Enum.find(profiles, &(&1.name == "Edge HTTP Passive"))

    assert profile.dpi == %{"enabled" => true, "protocols" => ["tls", "dns"]}
    assert profile.flow_attribution == %{"tcp" => true, "udp" => true, "quic" => false}
    assert profile.process_snapshot_interval_s == 90
  end

  @tag :visibility_profiles_live
  test "syncs SRQL builder when query is pasted", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/visibility-profiles/new")

    lv
    |> element("button[phx-click='builder_toggle']")
    |> render_click()

    lv
    |> form("#visibility-profile-form", form: %{target_query: ~s(hostname:%edge%)})
    |> render_change()

    assert has_element?(
             lv,
             "select[name='builder[filters][0][field]'] option[value='hostname'][selected]"
           )

    assert has_element?(lv, "input[name='builder[filters][0][value]'][value='edge']")
  end

  @tag :visibility_profiles_live
  test "edits existing visibility profile", %{conn: conn, scope: scope} do
    {:ok, profile} =
      VisibilityProfile
      |> Ash.Changeset.for_create(:create, %{
        name: "Visibility #{System.unique_integer([:positive])}",
        target_query: "hostname:%old%",
        capture_interfaces: ["eth0"],
        fingerprint: %{"tcp" => true, "tls" => true, "http" => false}
      })
      |> Ash.create(scope: scope)

    {:ok, lv, html} = live(conn, ~p"/settings/networks/visibility-profiles/#{profile.id}/edit")

    assert html =~ "Edit Visibility Profile"

    lv
    |> form("#visibility-profile-form",
      form: %{
        name: "Visibility Edited",
        target_query: "hostname:%new%",
        priority: "5",
        capture_interfaces: "eth1",
        sample_interval_ms: "45000",
        retention_days: "21",
        fingerprint: %{"tcp" => "true", "tls" => "false", "http" => "true"}
      }
    )
    |> render_submit()

    assert_redirect(lv, ~p"/settings/networks/visibility-profiles")
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end
end
