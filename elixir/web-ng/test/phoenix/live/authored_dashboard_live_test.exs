defmodule ServiceRadarWebNGWeb.AuthoredDashboardLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Dashboards

  defmodule SRQLStub do
    @moduledoc false

    def query(~S(series site:"MSP\" in:flows) <> _rest, _opts) do
      {:ok, %{"results" => [%{"service" => "escaped-literal", "status" => "ok", "value" => 30}]}}
    end

    def query(~s(series site:"ZZA) <> _rest, _opts) do
      {:ok, %{"results" => [%{"service" => "iah-core", "status" => "ok", "value" => 10}]}}
    end

    def query(~s(series site:"MSP) <> _rest, _opts) do
      {:ok, %{"results" => [%{"service" => "msp-core", "status" => "ok", "value" => 20}]}}
    end

    def query(~s(series site:MSP" in:flows) <> _rest, _opts) do
      {:ok, %{"results" => [%{"service" => "flow-secret", "status" => "leaked", "value" => 99}]}}
    end

    def query("in:flows" <> _rest, _opts) do
      {:ok, %{"results" => [%{"service" => "flow-secret", "status" => "leaked", "value" => 99}]}}
    end

    def query("series" <> _rest, _opts) do
      {:ok,
       %{
         "results" => [
           %{"service" => "core", "status" => "ok", "value" => 10},
           %{"service" => "web-ng", "status" => "ok", "value" => 12}
         ]
       }}
    end

    def query("availability" <> _rest, _opts) do
      {:ok, %{"results" => [%{"available" => 75, "total" => 100, "value" => 75}]}}
    end

    def query("grouped availability" <> _rest, _opts) do
      {:ok,
       %{
         "results" => [
           %{"is_available" => false, "count" => 4},
           %{"is_available" => true, "count" => 8}
         ]
       }}
    end

    def query("stat" <> _rest, _opts) do
      {:ok, %{"results" => [%{"value" => 10, "label" => "services"}]}}
    end

    def query("trend" <> _rest, _opts) do
      {:ok, %{"results" => [%{"value" => 50}, %{"value" => 75}]}}
    end

    def query("rich" <> _rest, _opts) do
      {:ok,
       %{
         "results" => [
           %{
             "service" => "core",
             "enabled" => true,
             "status" => "down",
             "value" => 1,
             "details" => %{"owner" => "noc", "region" => "iah"},
             "trend" => [1, 3, 2, 5]
           }
         ]
       }}
    end

    def query("canonical export" <> _rest, _opts) do
      {:ok,
       %{
         "results" => [
           %{"time" => "2026-08-30T18:00:00Z", "message" => "raw UTC export"}
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
    |> form("#dashboard-metadata-form", %{
      "dashboard" => %{"title" => title, "description" => "Created through LiveView", "visibility" => "private"}
    })
    |> render_submit()

    [dashboard] =
      scope
      |> Dashboards.list_authored_dashboards(%{status: [:active], limit: 100})
      |> Enum.filter(&(&1.title == title))

    assert_redirect(view, ~p"/dashboard/#{Dashboards.authored_dashboard_route_ref(dashboard)}")
    assert dashboard.owner_id == user.id
    assert dashboard.dashboard_ref in 1_000_000..9_999_999
    assert Dashboards.list_authored_panels(scope, dashboard.id) == []
  end

  test "saved dashboard settings creates schema-guided panels", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])
    title = "Multi Query LiveView #{unique}"

    {:ok, view, _html} = live(conn, ~p"/analytics")
    render_async(view, 5_000)

    view
    |> form("#dashboard-metadata-form", %{
      "dashboard" => %{"title" => title, "description" => "", "visibility" => "private"}
    })
    |> render_submit()

    [dashboard] =
      scope
      |> Dashboards.list_authored_dashboards(%{status: [:active], limit: 100})
      |> Enum.filter(&(&1.title == title))

    {:ok, view, _html} = live(conn, ~p"/dashboard/#{Dashboards.authored_dashboard_route_ref(dashboard)}")
    render_async(view, 5_000)

    view
    |> element("button[phx-click='open_settings']", "Settings")
    |> render_click()

    view
    |> element("button[phx-click='new_panel']", "Add Panel")
    |> render_click()

    assert has_element?(view, "select[name='panel[visual_type]'][disabled]")
    assert render(view) =~ "Preview the SRQL query first"
    assert has_element?(view, "select[name='panel[visual_type]'] option[value='']", "Preview query first")
    refute has_element?(view, "select[name='panel[visual_type]'] option[value='availability']")
    refute has_element?(view, "select[name='panel[visual_type]'] option[value='gauge']")
    refute has_element?(view, "select[name='panel[visual_type]'] option[value='table']")

    view
    |> form("form[phx-submit='submit_panel_form']", %{
      "panel" => %{
        "title" => "Service Series",
        "srql_query" => "series services"
      }
    })
    |> render_change()

    render_click(view, "preview_panel_edit")
    refute has_element?(view, "select[name='panel[visual_type]'][disabled]")
    refute has_element?(view, "select[name='panel[visual_type]'] option[value='availability']")
    refute has_element?(view, "select[name='panel[visual_type]'] option[value='gauge']")
    assert has_element?(view, "select[name='panel[visual_type]'] option[value='table']")
    assert has_element?(view, "select[name='panel[visual_type]'] option[value='category']")
    refute has_element?(view, "select[name='panel[value_field]']")

    view
    |> form("form[phx-submit='submit_panel_form']", %{
      "panel" => %{
        "title" => "Service Series",
        "srql_query" => "series services",
        "visual_type" => "table"
      }
    })
    |> render_submit()

    panels = Dashboards.list_authored_panels(scope, dashboard.id)
    assert [panel] = panels
    assert String.starts_with?(panel.dataset_key, "panel_")
    assert Enum.map(panels, & &1.srql_query) == ["series services"]
  end

  test "saved dashboard settings show grouped availability binding controls", %{
    conn: conn,
    scope: scope
  } do
    {:ok, dashboard} =
      Dashboards.create_authored_dashboard(scope, %{
        title: "Grouped Availability LiveView #{System.unique_integer([:positive])}",
        description: "",
        visibility: :private,
        status: :active
      })

    {:ok, view, _html} = live(conn, ~p"/dashboard/#{Dashboards.authored_dashboard_route_ref(dashboard)}")
    render_async(view, 5_000)

    view
    |> element("button[phx-click='open_settings']", "Settings")
    |> render_click()

    view
    |> element("button[phx-click='new_panel']", "Add Panel")
    |> render_click()

    view
    |> form("form[phx-submit='submit_panel_form']", %{
      "panel" => %{
        "title" => "Device Availability",
        "srql_query" => "grouped availability devices"
      }
    })
    |> render_change()

    render_click(view, "preview_panel_edit")

    view
    |> form("form[phx-submit='submit_panel_form']", %{
      "panel" => %{"visual_type" => "availability"}
    })
    |> render_change()

    html = render(view)
    assert html =~ "Count field"
    assert html =~ "Availability field"
    refute html =~ "Available/OK field"
    refute html =~ "Total field"
    assert has_element?(view, "select[name='panel[value_field]'] option[selected][value='count']")
    assert has_element?(view, "select[name='panel[label_field]'] option[selected][value='is_available']")
  end

  test "saved dashboard settings create panels from reusable source query outputs", %{
    conn: conn,
    scope: scope
  } do
    unique = System.unique_integer([:positive])
    title = "Source Query LiveView #{unique}"

    {:ok, dashboard} =
      Dashboards.create_authored_dashboard(scope, %{
        title: title,
        description: "",
        visibility: :private,
        status: :active
      })

    {:ok, view, _html} = live(conn, ~p"/dashboard/#{Dashboards.authored_dashboard_route_ref(dashboard)}")
    render_async(view, 5_000)

    view
    |> element("button[phx-click='open_settings']", "Settings")
    |> render_click()

    view
    |> form("form[phx-submit='run_source_query']", %{
      "source_query" => %{
        "name" => "Service source",
        "srql_query" => "series services",
        "title" => "Services by status",
        "display_label" => "Services",
        "unit" => "",
        "caption" => "",
        "lookback_days" => "30"
      }
    })
    |> render_submit()

    assert has_element?(view, "button[phx-click='create_source_output'][phx-value-visual-type='category']")
    assert render(view) =~ "Source schema"

    view
    |> element("button[phx-click='create_source_output'][phx-value-visual-type='category']")
    |> render_click()

    [panel] = Dashboards.list_authored_panels(scope, dashboard.id)
    assert panel.title == "Services by status"
    assert panel.srql_query == "series services"
    assert panel.visual_type == :category
    assert panel.builder_state["mode"] == "query_first"
    assert panel.metadata["source_query_id"]
    assert panel.metadata["output_id"]
    html = render(view)
    assert html =~ "1 linked panel"
    assert html =~ "Load"

    {:ok, reloaded} = Dashboards.get_authored_dashboard(scope, dashboard.id)
    assert [source] = reloaded.metadata["source_queries"]
    assert source["name"] == "Service source"
    assert source["srql_query"] == "series services"
    assert Enum.any?(source["outputs"], &(&1["visual_type"] == "category"))
  end

  test "dashboard library lists authored dashboards and updates favorite/default preferences", %{
    conn: conn,
    scope: scope
  } do
    {dashboard, _panel} = dashboard_with_panel!(scope, title: "Library LiveView")

    {:ok, view, _html} = live(conn, ~p"/dashboards")
    html = render_async(view, 5_000)

    assert html =~ "Dashboard &amp; Report Library"
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

    assert has_element?(view, "section", "Dashboard Workbench")
    assert has_element?(view, "section", "Email Reports")

    view
    |> element("button[phx-click='edit_panel'][phx-value-id='#{panel.id}']", "Open in Builder")
    |> render_click()

    view
    |> form("form[phx-submit='submit_panel_form']", %{
      "panel" => %{
        "title" => "Updated Service Series",
        "srql_query" => "series services",
        "visual_type" => "table",
        "refresh_interval_seconds" => "60",
        "position" => "1",
        "layout_w" => "12",
        "layout_h" => "8"
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

  test "saved dashboard renders pivot and trend dashlets", %{conn: conn, scope: scope} do
    {dashboard, _panel} =
      dashboard_with_panel!(scope,
        title: "Pivot LiveView",
        srql_query: "rich services",
        visual_type: :pivot,
        data_binding: %{
          "row_field" => "service",
          "column_field" => "status",
          "value_field" => "value",
          "aggregate" => "sum"
        }
      )

    {:ok, view, _html} = live(conn, ~p"/dashboard/#{Dashboards.authored_dashboard_route_ref(dashboard)}")
    html = render_async(view, 5_000)

    assert html =~ "Pivot Table"
    assert html =~ "core"
    assert html =~ "down"
  end

  test "saved dashboard variables substitute into panel SRQL", %{conn: conn, scope: scope} do
    {dashboard, _panel} =
      dashboard_with_panel!(scope,
        title: "Variables LiveView",
        srql_query: "series site:${site}",
        variables: %{
          "site" => %{"label" => "Site", "default" => "ZZA", "options" => ["ZZA", "MSP"]}
        }
      )

    {:ok, view, _html} = live(conn, ~p"/dashboard/#{Dashboards.authored_dashboard_route_ref(dashboard)}")
    html = render_async(view, 5_000)

    assert html =~ "Dashboard Variables"
    assert html =~ "iah-core"

    html = render_change(view, "change_variable", %{"variables" => %{"site" => "MSP"}})
    assert html =~ "msp-core"
    refute html =~ "iah-core"
  end

  test "view-only dashboard variables cannot rewrite panel collection or filters", %{scope: scope} do
    viewer = viewer_user_fixture()

    {dashboard, _panel} =
      dashboard_with_panel!(scope,
        title: "View Only Variables LiveView",
        srql_query: "series site:${site}",
        variables: %{
          "site" => %{"label" => "Site", "default" => "ZZA", "type" => "string"}
        }
      )

    assert {:ok, _grant} =
             Dashboards.grant_authored_dashboard_to_user(scope, %{
               dashboard_id: dashboard.id,
               subject_user_id: viewer.id,
               access: :view
             })

    viewer_conn = log_in_user(build_conn(), viewer)
    {:ok, view, _html} = live(viewer_conn, ~p"/dashboard/#{Dashboards.authored_dashboard_route_ref(dashboard)}")
    html = render_async(view, 5_000)

    assert html =~ "iah-core"
    refute has_element?(view, "button[phx-click='open_settings']")

    html = render_change(view, "change_variable", %{"variables" => %{"site" => ~s(MSP" in:flows)}})
    assert html =~ "escaped-literal"
    refute html =~ "flow-secret"
    refute html =~ "msp-core"
  end

  test "saved dashboard renders gauge and count dashlets with thresholds and trends", %{
    conn: conn,
    scope: scope
  } do
    {dashboard, _panel} =
      dashboard_with_panel!(scope,
        title: "Gauge LiveView",
        srql_query: "availability services",
        visual_type: :gauge,
        data_binding: %{"numerator_field" => "available", "denominator_field" => "total"},
        display_config: %{
          "label" => "Device Availability",
          "unit" => "%",
          "thresholds" => [
            %{"value" => 70, "tone" => "warning"},
            %{"value" => 90, "tone" => "success"}
          ]
        },
        visual_config: %{"trend_query" => "trend availability"},
        refresh_interval_seconds: 60
      )

    {:ok, count_panel} =
      Dashboards.create_authored_panel(scope, %{
        dashboard_id: dashboard.id,
        title: "Current Services",
        srql_query: "stat services",
        visual_type: :count,
        data_binding: %{"value_field" => "value"},
        display_config: %{"label" => "Current Services", "unit" => " services"},
        visual_config: %{"trend_query" => "trend count"},
        position: 1
      })

    {:ok, view, _html} = live(conn, ~p"/dashboard/#{Dashboards.authored_dashboard_route_ref(dashboard)}")
    html = render_async(view, 5_000)

    assert html =~ "Device Availability"
    assert html =~ "dashboard-panel-chart-"
    assert html =~ "Compared to 30 days ago"
    assert html =~ "+25"
    assert html =~ "Refresh 1m"
    assert html =~ count_panel.title
    assert html =~ " services</span>"
  end

  test "saved dashboard panel actions duplicate clone compact inspect refresh and export", %{
    conn: conn,
    scope: scope
  } do
    {dashboard, panel} =
      dashboard_with_panel!(scope,
        title: "Actions LiveView",
        layout: %{"x" => 8, "y" => 12, "w" => 4, "h" => 4, "order" => 0}
      )

    {target, _target_panel} = dashboard_with_panel!(scope, title: "Clone Target")

    {:ok, view, _html} = live(conn, ~p"/dashboard/#{Dashboards.authored_dashboard_route_ref(dashboard)}")
    html = render_async(view, 5_000)

    assert html =~ "download=\"service-series.csv\""
    assert html =~ "/dashboard/#{Dashboards.authored_dashboard_route_ref(dashboard)}/panels/#{panel.id}/export.csv"
    assert html =~ "sr-authored-dashboard-panel"
    assert html =~ "--sr-panel-x: 1"
    assert html =~ "--sr-panel-y: 13"
    assert html =~ "--sr-panel-w: 12"

    html = render_click(view, "toggle_panel_srql", %{"id" => panel.id})
    assert html =~ panel.srql_query

    html = render_click(view, "refresh_panel", %{"id" => panel.id})
    assert html =~ "Panel refreshed"

    html = render_click(view, "duplicate_panel", %{"id" => panel.id})
    assert html =~ "Panel duplicated"
    assert length(Dashboards.list_authored_panels(scope, dashboard.id)) == 2

    html =
      render_submit(view, "clone_panel", %{
        "panel_id" => panel.id,
        "target_dashboard_id" => target.id
      })

    assert html =~ "Panel cloned to"
    assert length(Dashboards.list_authored_panels(scope, target.id)) == 2

    html = render_click(view, "compact_layout", %{})
    assert html =~ "Dashboard layout compacted"

    [first | _] = Dashboards.list_authored_panels(scope, dashboard.id)
    assert first.layout["x"] == 0
    assert first.layout["y"] == 0

    conn =
      get(
        conn,
        ~p"/dashboard/#{Dashboards.authored_dashboard_route_ref(dashboard)}/panels/#{panel.id}/export.csv"
      )

    assert response(conn, 200) =~ ~s("service","status","value")
    assert get_resp_header(conn, "content-type") == ["text/csv; charset=utf-8"]
  end

  @tag :web_ng_shared_fixture_db
  test "CSV export preserves canonical UTC values for a non-UTC dashboard owner", %{
    conn: conn,
    user: user
  } do
    user =
      Ash.update!(user, %{timezone: "America/Chicago"},
        action: :update_timezone_preference,
        actor: user
      )

    scope = Scope.for_user(user)
    conn = log_in_user(conn, user)

    {dashboard, panel} =
      dashboard_with_panel!(scope,
        title: "Canonical Export",
        srql_query: "canonical export",
        visual_type: :table
      )

    conn =
      get(
        conn,
        ~p"/dashboard/#{Dashboards.authored_dashboard_route_ref(dashboard)}/panels/#{panel.id}/export.csv"
      )

    assert response(conn, 200) ==
             ~s("message","time"\n"raw UTC export","2026-08-30T18:00:00Z"\n)
  end

  test "user groups are managed from settings instead of the dashboard creator", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/user-groups")
    html = render_async(view, 5_000)

    assert html =~ "User Groups"
    assert html =~ "Create Group"

    {:ok, _view, html} = live(conn, ~p"/analytics")
    refute html =~ "Create Group"
  end

  defp dashboard_with_panel!(scope, attrs) do
    title = Keyword.fetch!(attrs, :title)

    {:ok, dashboard} =
      Dashboards.create_authored_dashboard(scope, %{
        title: "#{title} #{System.unique_integer([:positive])}",
        description: "LiveView workflow coverage",
        status: :active,
        visibility: :private,
        variables: Keyword.get(attrs, :variables, %{})
      })

    {:ok, panel} =
      Dashboards.create_authored_panel(scope, %{
        dashboard_id: dashboard.id,
        title: "Service Series",
        srql_query: Keyword.get(attrs, :srql_query, "series services"),
        visual_type: Keyword.get(attrs, :visual_type, :table),
        data_binding: Keyword.get(attrs, :data_binding, %{}),
        display_config: Keyword.get(attrs, :display_config, %{}),
        visual_config: Keyword.get(attrs, :visual_config, %{}),
        layout: Keyword.get(attrs, :layout, %{}),
        refresh_interval_seconds: Keyword.get(attrs, :refresh_interval_seconds, 0)
      })

    {dashboard, panel}
  end
end
