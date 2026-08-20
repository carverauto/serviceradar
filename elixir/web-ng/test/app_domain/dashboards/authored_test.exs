defmodule ServiceRadarWebNG.Dashboards.AuthoredTest do
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.RuntimeData

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

    def query("rich" <> _rest, _opts) do
      {:ok,
       %{
         "results" => [
           %{
             "service" => "core",
             "enabled" => true,
             "status" => "ok",
             "details" => %{"owner" => "noc", "region" => "iah"},
             "trend" => [1, 4, 2, 8]
           }
         ]
       }}
    end

    def query("availability" <> _rest, _opts) do
      {:ok, %{"results" => [%{"ok" => 9, "total" => 10, "site" => "ZZA"}]}}
    end

    def query("grouped availability" <> _rest, _opts) do
      {:ok,
       %{
         "results" => [
           %{"is_available" => false, "count" => 12},
           %{"is_available" => true, "count" => 3}
         ]
       }}
    end

    def query("breakdown" <> _rest, _opts) do
      {:ok, %{"results" => [%{"type" => "router", "count" => 12}]}}
    end

    def query("pivot" <> _rest, _opts) do
      {:ok, %{"results" => [%{"site" => "ZZA", "type" => "router", "count" => 12}]}}
    end

    def query("datetime sample" <> _rest, _opts) do
      {:ok,
       %{
         "results" => [
           %{"title" => "Operations", "updated_at" => ~U[2026-05-24 06:33:08.989313Z]}
         ]
       }}
    end

    def query("viz typed" <> _rest, _opts) do
      {:ok,
       %{
         "results" => [%{"label" => "core", "value" => nil}],
         "viz" => %{
           "columns" => [
             %{"name" => "label", "type" => "text"},
             %{"name" => "value", "type" => "float"}
           ]
         }
       }}
    end

    def query("limit probe" <> _rest, opts) do
      {:ok, %{"results" => [%{"limit" => Map.get(opts, :limit)}]}}
    end

    def query("wide values stats:\"sum(value) as value\"" <> _rest, _opts) do
      {:ok, %{"results" => [%{"value" => 12_345}]}}
    end

    def query("wide values stats:\"count() as count\"" <> _rest, _opts) do
      {:ok, %{"results" => [%{"count" => 12_345}]}}
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
    assert Enum.map(preview.fields, & &1.id) == ["service", "status", "timestamp", "value"]

    value_field = Enum.find(preview.fields, &(&1.name == "value"))
    assert value_field.sample == 10
    assert value_field.aggregate_compatible
    assert "avg" in value_field.compatible_aggregations

    assert :table in preview.compatible_visuals
    assert :line in preview.compatible_visuals
    assert :bar in preview.compatible_visuals
    assert :category in preview.compatible_visuals
    assert :status_list in preview.compatible_visuals
    refute :gauge in preview.compatible_visuals
  end

  test "preview bounds authored queries with default time and capped limits", %{scope: scope} do
    assert {:ok, preview} =
             Dashboards.preview_authored_query(scope, "series services limit:999", limit: 250)

    assert preview.query == "series services time:last_24h limit:200"

    assert {:ok, preview} =
             Dashboards.preview_authored_query(
               scope,
               ~s(series services time:last_7d status:"limit:999"),
               limit: 50
             )

    assert preview.query == ~s(series services time:last_7d status:"limit:999" limit:50)

    assert {:ok, preview} =
             Dashboards.preview_authored_query(scope, "series services limit:999",
               limit: 10_000,
               max_limit: 10_000
             )

    assert preview.query == "series services time:last_24h limit:10000"
  end

  test "preview uses SRQL viz column types before sampled row values", %{scope: scope} do
    assert {:ok, preview} = Dashboards.preview_authored_query(scope, "viz typed services")

    assert %{type: :number, aggregate_compatible: true} =
             Enum.find(preview.fields, &(&1.name == "value"))
  end

  test "runtime uses larger bounded results for aggregate panels", %{scope: scope} do
    assert {:ok, %{rows: [%{"limit" => 10_000}], query: query}} =
             RuntimeData.preview_panel_query(scope, %{srql_query: "limit probe", visual_type: :pivot}, %{})

    assert query == "limit probe time:last_24h limit:10000"

    assert {:ok, %{rows: [%{"limit" => 250}], query: query}} =
             RuntimeData.preview_panel_query(scope, %{srql_query: "limit probe", visual_type: :table}, %{})

    assert query == "limit probe time:last_24h limit:250"
  end

  test "runtime pushes stat aggregates into SRQL instead of aggregating preview rows", %{scope: scope} do
    panel = %{
      srql_query: "wide values",
      visual_type: :stat,
      data_binding: %{"value_field" => "value", "aggregate" => "sum"}
    }

    assert {:ok, %{rows: [%{"value" => 12_345}], query: query}} =
             RuntimeData.preview_panel_query(scope, panel, %{})

    assert query == ~s|wide values stats:"sum(value) as value" time:last_24h limit:10000|
  end

  test "runtime pushes count panels into SRQL instead of counting preview rows", %{scope: scope} do
    panel = %{srql_query: "wide values", visual_type: :count, data_binding: %{}}

    assert {:ok, %{rows: [%{"count" => 12_345}], query: query}} =
             RuntimeData.preview_panel_query(scope, panel, %{})

    assert query == ~s|wide values stats:"count() as count" time:last_24h limit:10000|
  end

  test "gauge compatibility is limited to single metrics and availability ratios", %{scope: scope} do
    assert {:ok, stat_preview} = Dashboards.preview_authored_query(scope, "stat services")
    assert :gauge in stat_preview.compatible_visuals

    assert {:ok, series_preview} = Dashboards.preview_authored_query(scope, "series services")
    refute :gauge in series_preview.compatible_visuals

    assert {:ok, grouped_preview} = Dashboards.preview_authored_query(scope, "grouped availability devices")
    assert :gauge in grouped_preview.compatible_visuals
  end

  test "pivot compatibility requires two dimensions plus a numeric field", %{scope: scope} do
    assert {:ok, preview} = Dashboards.preview_authored_query(scope, "breakdown devices")
    assert :bar in preview.compatible_visuals
    refute :pivot in preview.compatible_visuals

    assert {:ok, preview} = Dashboards.preview_authored_query(scope, "pivot devices")
    assert :pivot in preview.compatible_visuals
  end

  test "preview exposes JSON paths from sample object values", %{scope: scope} do
    assert {:ok, preview} = Dashboards.preview_authored_query(scope, "rich services")

    details = Enum.find(preview.fields, &(&1.name == "details"))

    assert details.type == :object
    assert details.json_paths == ["owner", "region"]
    refute details.aggregate_compatible
  end

  test "preview does not treat datetime structs as JSON path maps", %{scope: scope} do
    assert {:ok, preview} = Dashboards.preview_authored_query(scope, "datetime sample dashboards")

    updated_at = Enum.find(preview.fields, &(&1.name == "updated_at"))
    assert updated_at.type == :datetime
    assert updated_at.json_paths == []
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

    assert {:error, {:incompatible_visual_type, :availability, compatible}} =
             Dashboards.create_authored_panel(scope, %{
               dashboard_id: dashboard.id,
               title: "Series availability",
               srql_query: "series services",
               visual_type: :availability
             })

    refute :availability in compatible

    assert {:error, {:incompatible_visual_type, :gauge, compatible}} =
             Dashboards.create_authored_panel(scope, %{
               dashboard_id: dashboard.id,
               title: "Series gauge",
               srql_query: "series services",
               visual_type: :gauge
             })

    refute :gauge in compatible
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

  test "panel bindings must reference fields returned by preview", %{scope: scope, dashboard: dashboard} do
    assert {:error, {:missing_binding_field, "value_field", "missing"}} =
             Dashboards.create_authored_panel(scope, %{
               dashboard_id: dashboard.id,
               title: "Bad binding",
               srql_query: "series services",
               visual_type: :table,
               data_binding: %{"value_field" => "missing"}
             })

    assert {:ok, panel} =
             Dashboards.create_authored_panel(scope, %{
               dashboard_id: dashboard.id,
               title: "Good binding",
               srql_query: "series services",
               visual_type: :table,
               data_binding: %{"value_field" => "value"},
               display_config: %{
                 "table_columns" => [
                   %{"field" => "service", "label" => "Service", "renderer" => "text"},
                   %{"field" => "status", "label" => "Status", "renderer" => "status"}
                 ]
               }
             })

    assert panel.data_binding["value_field"] == "value"
  end

  test "visual configs must reference fields returned by preview", %{scope: scope, dashboard: dashboard} do
    assert {:error, {:missing_visual_config_field, "value_field", "missing"}} =
             Dashboards.create_authored_panel(scope, %{
               dashboard_id: dashboard.id,
               title: "Bad visual config",
               srql_query: "series services",
               visual_type: :table,
               visual_config: %{"value_field" => "missing"}
             })

    assert {:ok, panel} =
             Dashboards.create_authored_panel(scope, %{
               dashboard_id: dashboard.id,
               title: "Good visual config",
               srql_query: "series services",
               visual_type: :table,
               visual_config: %{"value_field" => "value", "thresholds" => [%{"field" => "status"}]}
             })

    assert panel.visual_config["value_field"] == "value"
  end

  test "availability visuals support explicit numerator and denominator bindings", %{scope: scope, dashboard: dashboard} do
    assert {:error, {:required_binding_field, "denominator_field"}} =
             Dashboards.create_authored_panel(scope, %{
               dashboard_id: dashboard.id,
               title: "Missing denominator",
               srql_query: "availability services",
               visual_type: :availability,
               data_binding: %{"numerator_field" => "ok"}
             })

    assert {:ok, panel} =
             Dashboards.create_authored_panel(scope, %{
               dashboard_id: dashboard.id,
               title: "Availability",
               srql_query: "availability services",
               visual_type: :availability,
               data_binding: %{"numerator_field" => "ok", "denominator_field" => "total"}
             })

    assert panel.visual_type == :availability
  end

  test "availability visuals support grouped availability count rows", %{scope: scope, dashboard: dashboard} do
    assert {:ok, preview} = Dashboards.preview_authored_query(scope, "grouped availability devices")
    assert :availability in preview.compatible_visuals
    assert :bar in preview.compatible_visuals
    assert Enum.map(preview.fields, & &1.name) == ["count", "is_available"]

    assert {:ok, panel} =
             Dashboards.create_authored_panel(scope, %{
               dashboard_id: dashboard.id,
               title: "Grouped Availability",
               srql_query: "grouped availability devices",
               visual_type: :availability,
               data_binding: %{"value_field" => "count", "label_field" => "is_available"}
             })

    assert panel.visual_type == :availability
    assert panel.data_binding["value_field"] == "count"
    assert panel.data_binding["label_field"] == "is_available"

    assert {:ok, gauge_panel} =
             Dashboards.create_authored_panel(scope, %{
               dashboard_id: dashboard.id,
               title: "Grouped Availability Gauge",
               srql_query: "grouped availability devices",
               visual_type: :gauge,
               data_binding: %{"value_field" => "count", "label_field" => "is_available"}
             })

    assert gauge_panel.visual_type == :gauge
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

  test "dashboards get human route references and optional slugs", %{scope: scope} do
    assert {:ok, dashboard} =
             Dashboards.create_authored_dashboard(scope, %{
               title: "Routed #{System.unique_integer([:positive])}",
               slug: "ZZA Availability"
             })

    assert dashboard.dashboard_ref in 1_000_000..9_999_999
    assert dashboard.slug == "zza-availability"

    assert {:ok, by_ref} =
             Dashboards.get_authored_dashboard(scope, Integer.to_string(dashboard.dashboard_ref), load: [])

    assert by_ref.id == dashboard.id

    assert {:ok, by_slug} = Dashboards.get_authored_dashboard(scope, "zza-availability", load: [])
    assert by_slug.id == dashboard.id
  end

  test "reserved dashboard slugs are rejected", %{scope: scope} do
    for slug <- ["service-availability-noc", "security-findings", "endpoint-inventory", "new-devices"] do
      assert {:error, {:reserved_dashboard_slug, ^slug}} =
               Dashboards.create_authored_dashboard(scope, %{
                 title: "Bad slug #{slug}",
                 slug: slug
               })
    end
  end

  test "dashboard slugs must start with text and avoid route refs", %{scope: scope} do
    assert {:error, {:route_ref_dashboard_slug, "1234567"}} =
             Dashboards.create_authored_dashboard(scope, %{
               title: "Numeric slug",
               slug: "1234567"
             })

    assert {:error, {:invalid_dashboard_slug, "123-zza"}} =
             Dashboards.create_authored_dashboard(scope, %{
               title: "Leading digit slug",
               slug: "123 ZZA"
             })

    assert {:ok, dashboard} =
             Dashboards.create_authored_dashboard(scope, %{
               title: "Normalized slug",
               slug: "ZZA_Availability"
             })

    assert dashboard.slug == "zza-availability"
  end

  test "dashboard SRQL discovery returns accessible authored dashboards", %{scope: scope} do
    assert {:ok, dashboard} =
             Dashboards.create_authored_dashboard(scope, %{
               title: "ZZA Availability #{System.unique_integer([:positive])}",
               description: "Airport NOC"
             })

    assert {:ok, %{"results" => rows}} =
             ServiceRadarWebNG.SRQL.query("in:dashboards title:%ZZA% limit:20", %{scope: scope})

    assert Enum.any?(rows, &(&1["id"] == dashboard.id and &1["type"] == "authored"))
  end

  test "dashboard SRQL discovery ignores sort tokens and handles status filters", %{scope: scope} do
    assert {:ok, dashboard} =
             Dashboards.create_authored_dashboard(scope, %{
               title: "MSP Availability #{System.unique_integer([:positive])}",
               description: "Airport NOC",
               status: :active
             })

    assert {:ok, %{"results" => rows}} =
             ServiceRadarWebNG.SRQL.query("in:dashboards status:active sort:title:asc limit:20", %{scope: scope})

    assert Enum.any?(rows, &(&1["id"] == dashboard.id and &1["status"] == "active"))
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
