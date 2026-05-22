defmodule ServiceRadarWebNG.Dashboards.AuthoredTest do
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Dashboards

  defmodule DashboardSRQLStub do
    @moduledoc false

    def query("invalid" <> _rest, _opts), do: {:error, :syntax_error}

    def query("empty" <> _rest, _opts) do
      {:ok, %{"results" => []}}
    end

    def query("stat" <> _rest, _opts) do
      {:ok, %{"results" => [%{"value" => 42, "label" => "healthy"}]}}
    end

    def query("series" <> _rest, _opts) do
      {:ok,
       %{
         "results" => [
           %{
             "timestamp" => "2026-05-22T00:00:00Z",
             "service" => "core",
             "value" => 10,
             "status" => "ok"
           },
           %{
             "timestamp" => "2026-05-22T00:01:00Z",
             "service" => "web-ng",
             "value" => 12,
             "status" => "ok"
           }
         ]
       }}
    end

    def query(_query, _opts), do: {:ok, %{"results" => []}}
  end

  setup do
    old_srql_module = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, DashboardSRQLStub)

    on_exit(fn ->
      if old_srql_module do
        Application.put_env(:serviceradar_web_ng, :srql_module, old_srql_module)
      else
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      end
    end)

    user = admin_user_fixture()
    scope = Scope.for_user(user)
    {:ok, dashboard} = Dashboards.create_authored_dashboard(scope, %{title: "Ops #{System.unique_integer([:positive])}"})

    {:ok, scope: scope, dashboard: dashboard}
  end

  test "preview returns inferred fields and compatible visualizations", %{scope: scope} do
    assert {:ok, preview} = Dashboards.preview_authored_query(scope, "series services")

    assert preview.row_count == 2
    assert Enum.map(preview.fields, & &1.name) == ["service", "status", "timestamp", "value"]
    assert :table in preview.compatible_visuals
    assert :line in preview.compatible_visuals
    assert :bar in preview.compatible_visuals
    assert :category in preview.compatible_visuals
    assert :status_list in preview.compatible_visuals
  end

  test "invalid SRQL is rejected before panel creation", %{scope: scope, dashboard: dashboard} do
    assert {:error, :syntax_error} = Dashboards.preview_authored_query(scope, "invalid from:")

    assert {:error, :syntax_error} =
             Dashboards.create_authored_panel(scope, %{
               dashboard_id: dashboard.id,
               title: "Bad query",
               srql_query: "invalid from:",
               visual_type: :table
             })
  end

  test "unsupported visual mappings are rejected before panel creation", %{scope: scope, dashboard: dashboard} do
    assert {:error, {:incompatible_visual_type, :stat, compatible}} =
             Dashboards.create_authored_panel(scope, %{
               dashboard_id: dashboard.id,
               title: "Series stat",
               srql_query: "series services",
               visual_type: :stat
             })

    refute :stat in compatible
  end

  test "table fallback can save an empty result set", %{scope: scope, dashboard: dashboard} do
    assert {:ok, panel} =
             Dashboards.create_authored_panel(scope, %{
               dashboard_id: dashboard.id,
               title: "Empty table",
               srql_query: "empty services",
               visual_type: :table
             })

    assert panel.visual_type == :table
    assert panel.field_metadata["compatible_visuals"] == ["table"]
    assert panel.field_metadata["fields"] == []
  end

  test "panel refresh interval must stay within the supported bounds", %{
    scope: scope,
    dashboard: dashboard
  } do
    assert {:error, {:invalid_refresh_interval_seconds, 90_000, 0, 86_400}} =
             Dashboards.create_authored_panel(scope, %{
               dashboard_id: dashboard.id,
               title: "Too chatty",
               srql_query: "series services",
               visual_type: :table,
               refresh_interval_seconds: 90_000
             })
  end

  test "report schedules validate recipients cron and timezone", %{scope: scope, dashboard: dashboard} do
    base_attrs = %{
      dashboard_id: dashboard.id,
      name: "Daily ops",
      recipients: ["ops@example.com"],
      cron: "0 8 * * *",
      timezone: "UTC"
    }

    assert {:ok, schedule} = Dashboards.create_authored_report_schedule(scope, base_attrs)
    assert schedule.next_due_at

    assert {:error, {:invalid_report_recipient, "not-an-email"}} =
             Dashboards.create_authored_report_schedule(scope, %{
               base_attrs
               | name: "Bad email",
                 recipients: ["not-an-email"]
             })

    assert {:error, {:invalid_report_cron, "not cron"}} =
             Dashboards.create_authored_report_schedule(scope, %{base_attrs | name: "Bad cron", cron: "not cron"})

    assert {:error, {:invalid_report_timezone, "Mars/Base"}} =
             Dashboards.create_authored_report_schedule(scope, %{
               base_attrs
               | name: "Bad timezone",
                 timezone: "Mars/Base"
             })
  end

  test "dashboard preferences track favorites and the user default", %{scope: scope, dashboard: dashboard} do
    assert {:ok, preference} = Dashboards.set_dashboard_favorite(scope, :authored, dashboard.id, true)
    assert preference.favorite
    refute preference.is_default

    assert {:ok, default_preference} = Dashboards.set_default_dashboard(scope, :authored, dashboard.id)
    assert default_preference.favorite
    assert default_preference.is_default

    assert [stored] = Dashboards.list_dashboard_preferences(scope)
    assert stored.target_type == :authored
    assert stored.target_id == dashboard.id
    assert stored.favorite
    assert stored.is_default
  end

  test "dashboard ownership is bound to the creating user", %{scope: scope} do
    other_user = admin_user_fixture()

    assert {:ok, dashboard} =
             Dashboards.create_authored_dashboard(scope, %{
               title: "Owned #{System.unique_integer([:positive])}",
               owner_id: other_user.id
             })

    assert dashboard.owner_id == scope.user.id
    refute dashboard.owner_id == other_user.id
  end

  test "sharing requires edit access to the target dashboard", %{dashboard: dashboard} do
    actor = admin_user_fixture()
    recipient = admin_user_fixture()
    actor_scope = Scope.for_user(actor)

    assert {:error, _reason} =
             Dashboards.grant_authored_dashboard_to_user(actor_scope, %{
               dashboard_id: dashboard.id,
               user_id: recipient.id,
               access: :edit
             })
  end

  test "report scheduling requires edit access to the target dashboard", %{dashboard: dashboard} do
    actor = admin_user_fixture()
    actor_scope = Scope.for_user(actor)

    assert {:error, _reason} =
             Dashboards.create_authored_report_schedule(actor_scope, %{
               dashboard_id: dashboard.id,
               name: "Unauthorized",
               recipients: ["noc@example.com"],
               cron: "0 8 * * *",
               timezone: "UTC"
             })
  end
end
