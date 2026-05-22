defmodule ServiceRadarWebNGWeb.AuthoredDashboardLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Dashboards

  defmodule SRQLStub do
    @moduledoc false

    def query("series" <> _rest, _opts) do
      {:ok,
       %{
         "results" => [
           %{"service" => "core", "status" => "ok", "value" => 10},
           %{"service" => "web-ng", "status" => "ok", "value" => 12}
         ]
       }}
    end

    def query("rich" <> _rest, _opts) do
      {:ok,
       %{
         "results" => [
           %{
             "service" => "core",
             "enabled" => true,
             "status" => "down",
             "details" => %{"owner" => "noc", "region" => "iah"},
             "trend" => [1, 3, 2, 5]
           }
         ]
       }}
    end

    def query(_query, _opts), do: {:ok, %{"results" => []}}
  end

  setup %{conn: conn} do
    old_srql_module = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, SRQLStub)

    on_exit(fn ->
      if old_srql_module do
        Application.put_env(:serviceradar_web_ng, :srql_module, old_srql_module)
      else
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      end
    end)

    user = admin_user_fixture()
    scope = Scope.for_user(user)

    {:ok, conn: log_in_user(conn, user), user: user, scope: scope}
  end

  test "creator saves an SRQL dashboard and redirects to the saved dashboard", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    unique = System.unique_integer([:positive])
    title = "Creator LiveView #{unique}"

    {:ok, view, html} = live(conn, ~p"/analytics")
    html = render_async(view, 5_000) <> html

    assert html =~ "Dashboard Creator"
    assert html =~ "New Dashboard"

    view
    |> form("form[phx-submit='save']", %{
      "dashboard" => %{
        "title" => title,
        "description" => "Created through LiveView",
        "visibility" => "private",
        "panel_title" => "Service Series",
        "srql_query" => "series services",
        "visual_type" => "table"
      }
    })
    |> render_submit()

    [dashboard] =
      scope
      |> Dashboards.list_authored_dashboards(%{status: [:active], limit: 100})
      |> Enum.filter(&(&1.title == title))

    assert_redirect(view, ~p"/dashboard/#{Dashboards.authored_dashboard_route_ref(dashboard)}")
    assert dashboard.owner_id == user.id
    assert dashboard.dashboard_ref in 1_000_000..9_999_999
  end

  test "dashboard library lists authored dashboards and updates favorite/default preferences", %{
    conn: conn,
    scope: scope
  } do
    {dashboard, _panel} = dashboard_with_panel!(scope, title: "Library LiveView")

    {:ok, view, _html} = live(conn, ~p"/dashboards")
    html = render_async(view, 5_000)

    assert html =~ "Dashboard Library"
    assert has_element?(view, ".sr-ops-page-title", "Dashboards")
    assert has_element?(view, "#srql-query-bar input[name='q'][value='in:dashboards limit:100']")
    assert has_element?(view, "a[href='/dashboards'][aria-current='page']")
    assert html =~ dashboard.title

    view
    |> element("button[phx-click='toggle_favorite'][phx-value-id='#{dashboard.id}']")
    |> render_click()

    render_async(view, 5_000)

    assert [favorite] = Dashboards.list_dashboard_preferences(scope)
    assert favorite.target_type == :authored
    assert favorite.target_id == dashboard.id
    assert favorite.favorite
    refute favorite.is_default

    render_click(view, "set_default", %{"type" => "authored", "id" => dashboard.id})

    html = render_async(view, 5_000)

    assert html =~ "Favorites"
    assert html =~ "Default"

    assert [default] = Dashboards.list_dashboard_preferences(scope)
    assert default.favorite
    assert default.is_default
  end

  test "saved dashboard settings edit panels and manage report schedules", %{
    conn: conn,
    scope: scope
  } do
    {dashboard, panel} = dashboard_with_panel!(scope, title: "Settings LiveView")

    {:ok, view, _html} = live(conn, ~p"/dashboard/#{Dashboards.authored_dashboard_route_ref(dashboard)}")
    html = render_async(view, 5_000)

    assert html =~ dashboard.title
    assert html =~ panel.title
    assert html =~ "core"
    assert has_element?(view, "button[phx-click='open_settings']", "Settings")

    view
    |> element("button[phx-click='open_settings']", "Settings")
    |> render_click()

    assert has_element?(view, "section", "Dashboard Settings")
    assert has_element?(view, "section", "Email Reports")

    view
    |> element("button[phx-click='edit_panel'][phx-value-id='#{panel.id}']")
    |> render_click()

    view
    |> form("form[phx-submit='save_panel']", %{
      "panel" => %{
        "title" => "Updated Service Series",
        "srql_query" => "series services",
        "visual_type" => "table",
        "refresh_interval_seconds" => "60",
        "position" => "1",
        "visual_config_json" => "{}",
        "layout_json" => "{}"
      }
    })
    |> render_submit()

    assert render(view) =~ "Updated Service Series"

    view
    |> form("form[phx-submit='create_report_schedule']", %{
      "schedule" => %{
        "name" => "Morning report",
        "cron" => "0 8 * * *",
        "timezone" => "UTC",
        "recipients" => "noc@example.com"
      }
    })
    |> render_submit()

    assert render(view) =~ "Morning report"
    assert [schedule] = Dashboards.list_authored_report_schedules(scope, dashboard.id)
    assert schedule.enabled

    view
    |> element("button[phx-click='toggle_report_schedule'][phx-value-id='#{schedule.id}']")
    |> render_click()

    assert [disabled_schedule] = Dashboards.list_authored_report_schedules(scope, dashboard.id)
    refute disabled_schedule.enabled

    view
    |> element("button[phx-click='delete_report_schedule'][phx-value-id='#{schedule.id}']")
    |> render_click()

    assert Dashboards.list_authored_report_schedules(scope, dashboard.id) == []
    assert render(view) =~ "No report schedules yet."
  end

  test "saved dashboard table renders status boolean JSON and sparkline cells", %{
    conn: conn,
    scope: scope
  } do
    {dashboard, _panel} =
      dashboard_with_panel!(scope,
        title: "Rich Table LiveView",
        srql_query: "rich services",
        display_config: %{
          "table_columns" => [
            %{"field" => "service", "label" => "Service"},
            %{"field" => "status", "label" => "Status", "renderer" => "status"},
            %{"field" => "enabled", "label" => "Enabled", "renderer" => "boolean_icon"},
            %{"field" => "details", "label" => "Owner", "path" => "owner", "renderer" => "text"},
            %{"field" => "trend", "label" => "Trend", "renderer" => "sparkline"}
          ]
        }
      )

    {:ok, view, _html} = live(conn, ~p"/dashboard/#{Dashboards.authored_dashboard_route_ref(dashboard)}")
    html = render_async(view, 5_000)

    assert html =~ "badge-error"
    assert html =~ "down"
    assert html =~ "badge-success"
    assert html =~ "noc"
    assert html =~ "aria-label=\"sparkline\""
    refute html =~ "{&quot;owner&quot;"
  end

  defp dashboard_with_panel!(scope, attrs) do
    title = Keyword.fetch!(attrs, :title)

    {:ok, dashboard} =
      Dashboards.create_authored_dashboard(scope, %{
        title: "#{title} #{System.unique_integer([:positive])}",
        description: "LiveView workflow coverage",
        status: :active,
        visibility: :private
      })

    {:ok, panel} =
      Dashboards.create_authored_panel(scope, %{
        dashboard_id: dashboard.id,
        title: "Service Series",
        srql_query: Keyword.get(attrs, :srql_query, "series services"),
        visual_type: Keyword.get(attrs, :visual_type, :table),
        display_config: Keyword.get(attrs, :display_config, %{})
      })

    {dashboard, panel}
  end
end
