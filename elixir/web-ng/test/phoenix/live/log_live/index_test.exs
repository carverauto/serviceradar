defmodule ServiceRadarWebNGWeb.LogLive.IndexTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNGWeb.LogLive.IndexTest

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :operator})

    user =
      Ash.update!(user, %{timezone: "America/Chicago"},
        action: :update_timezone_preference,
        actor: user
      )

    conn = log_in_user(conn, user)

    old = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.RecordingSRQLStub)

    old_status = Application.get_env(:serviceradar_web_ng, :logs_rollup_status_fun)

    Application.put_env(
      :serviceradar_web_ng,
      :logs_rollup_status_fun,
      fn -> ServiceRadarWebNGWeb.Stats.empty_logs_rollup_status() end
    )

    :persistent_term.put({__MODULE__, :test_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :test_pid})

      if is_nil(old) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, old)
      end

      if is_nil(old_status) do
        Application.delete_env(:serviceradar_web_ng, :logs_rollup_status_fun)
      else
        Application.put_env(:serviceradar_web_ng, :logs_rollup_status_fun, old_status)
      end
    end)

    %{conn: conn}
  end

  test "logs default to non-live browsing", %{conn: conn} do
    {:ok, lv, html} =
      live(conn, ~p"/observability/logs")

    assert html =~ "Page 1 log"
    assert has_element?(lv, "#logs-live-status", "Off")

    assert [%{cursor: nil} | _] = drain_srql_calls()

    send(lv.pid, {:logs_ingested, %{}})
    send(lv.pid, {:debounced_refresh, "logs"})
    render(lv)

    assert drain_srql_calls() == []
    assert has_element?(lv, "#logs-live-status", "Off")
  end

  test "log level cards render the severity rollup payload", %{conn: conn} do
    {:ok, lv, _html} =
      live(conn, ~p"/observability?#{%{tab: "logs", q: "in:logs time:last_24h sort:timestamp:desc", limit: 20}}")

    assert has_element?(lv, "#logs-level-summary", "100")
    assert has_element?(lv, "#logs-level-summary", "Fatal")
    assert has_element?(lv, "#logs-level-summary", "Warning")
    refute has_element?(lv, "#logs-rollup-warning")
  end

  test "logs pane surfaces an unavailable severity rollup instead of silent zeros", %{conn: conn} do
    :persistent_term.put({__MODULE__, :logs_rollup_error?}, true)

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :logs_rollup_error?})
    end)

    {:ok, lv, html} =
      live(conn, ~p"/observability?#{%{tab: "logs", q: "in:logs time:last_24h sort:timestamp:desc", limit: 20}}")

    assert has_element?(lv, "#logs-rollup-warning", "Log level rollup unavailable")
    assert html =~ "Page 1 log"
  end

  test "logs pane surfaces a stale or partially populated severity rollup", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :logs_rollup_status_fun, fn ->
      ServiceRadarWebNGWeb.Stats.empty_logs_rollup_status()
      |> Map.put(:healthy?, false)
      |> Map.put(:messages, ["Log severity rollup has not populated the 24-hour card window."])
    end)

    {:ok, lv, _html} =
      live(conn, ~p"/observability?#{%{tab: "logs", q: "in:logs time:last_24h", limit: 20}}")

    assert has_element?(lv, "#logs-rollup-warning", "24-hour card window")
    assert has_element?(lv, "#logs-level-summary", "100")
  end

  test "stale deferred log loads do not overwrite the current card query", %{conn: conn} do
    current_query =
      "in:logs severity_text:(fatal,emergency,alert) time:last_24h sort:timestamp:desc"

    {:ok, lv, _html} =
      live(conn, ~p"/observability?#{%{tab: "logs", q: current_query, limit: 20}}")

    _ = drain_srql_calls()

    stale_query = "in:logs time:last_24h sort:timestamp:desc"

    send(
      lv.pid,
      {:load_tab_data, "logs", %{"tab" => "logs", "q" => stale_query, "limit" => "20"},
       "https://example.test/observability"}
    )

    html = render(lv)

    assert drain_srql_calls() == []
    assert html =~ current_query
  end

  test "log rows normalize the OTel SeverityNumber enum name into a badge", %{conn: conn} do
    {:ok, _lv, html} =
      live(conn, ~p"/observability?#{%{tab: "logs", q: "in:logs time:last_24h sort:timestamp:desc", limit: 20}}")

    # SEVERITY_NUMBER_INFO -> INFO label + info color (was "SEVER" truncation +
    # ghost color before the fix).
    assert html =~ "badge-info"
    assert html =~ ~r/badge-info[^>]*>\s*INFO\s*</
    # SEVERITY_NUMBER_WARN -> WARN label + warning color.
    assert html =~ ~r/badge-warning[^>]*>\s*WARN\s*</

    # The raw enum name and its 5-char truncation must never reach the badge.
    refute html =~ "SEVERITY_NUMBER_INFO"
    refute html =~ ">SEVER<"
  end

  @tag :web_ng_shared_fixture_db
  test "log signal rows render their selected canonical instants with unique user-time ids", %{conn: conn} do
    path = ~p"/observability/logs?#{%{q: "in:logs time:last_24h sort:timestamp:desc"}}"
    {:ok, lv, _html} = live_following_redirect(conn, path)

    html = render(lv)
    document = LazyHTML.from_fragment(html)
    times = LazyHTML.query(document, "#logs time")
    ids = LazyHTML.attribute(times, "id")

    assert html =~ ~s(phx-hook="UserTime")
    assert length(ids) >= 4
    assert Enum.all?(ids, &(&1 != ""))
    assert length(ids) == length(Enum.uniq(ids))
    assert has_element?(lv, ~s(#logs time[datetime="2026-08-30T18:00:00Z"][data-user-time-zone="America/Chicago"]))
    assert html =~ "syslog unzoned source"
    assert html =~ "source-only unzoned log"
    assert html =~ "OTel info log"
    assert html =~ "SNMP trap log"
    assert html =~ "GELF log"
    assert has_element?(lv, "#log-00000000-0000-0000-0000-000000000014", "2026-08-30T12:45:56")
    refute has_element?(lv, "#log-00000000-0000-0000-0000-000000000014 time")
    refute html =~ ~s(datetime="2026-08-30T12:34:56Z")
    refute html =~ ~s(datetime="2026-08-30T12:45:56Z")
  end

  @tag :web_ng_shared_fixture_db
  test "trace and metric rows localize labels while metric pivots retain exact UTC bounds", %{conn: conn} do
    {:ok, traces, _html} = live(conn, ~p"/observability/traces")

    assert has_element?(
             traces,
             ~s(#traces time[datetime="2026-08-30T18:00:00Z"][data-user-time-zone="America/Chicago"])
           )

    {:ok, metrics, _html} = live(conn, ~p"/observability/metrics")

    assert has_element?(
             metrics,
             ~s(#metrics time[datetime="2026-08-30T18:00:00Z"][data-user-time-zone="America/Chicago"])
           )

    [href] =
      metrics
      |> element("#metrics-row-0 a[aria-label='View correlated logs']")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("a")
      |> LazyHTML.attribute("href")

    uri = URI.parse(href)

    assert uri.path == "/observability/logs"

    assert URI.decode_query(uri.query) == %{
             "q" =>
               ~s(in:logs trace_id:"aabbccddeeff00112233445566778899" time:[2026-08-30T17:00:00Z,2026-08-30T19:00:00Z] sort:timestamp:desc)
           }
  end

  @tag :web_ng_shared_fixture_db
  test "event and alert rows use the shared user-time contract", %{conn: conn} do
    {:ok, events, _html} = live(conn, ~p"/observability/events")
    assert has_element?(events, ~s(#events time[datetime="2026-08-30T18:00:00Z"]))

    {:ok, alerts, _html} = live(conn, ~p"/observability/alerts")
    assert has_element?(alerts, ~s(#alerts time[datetime="2026-08-30T18:00:00Z"][data-user-time-zone="America/Chicago"]))
    refute has_element?(alerts, "#alerts span", "2026-08-30T18:00:00")
  end

  @tag :web_ng_shared_fixture_db
  test "identified trace metric and alert time ids remain attached after reordering", %{conn: conn} do
    on_exit(fn -> :persistent_term.erase({__MODULE__, :identified_signal_row_order}) end)

    for {path, table, expected} <- [
          {~p"/observability/traces", "traces",
           %{
             "2026-08-30T18:00:00Z" => "trace-time-traces-row-s-aabbccddeeff00112233445566778899",
             "2026-08-30T18:01:00Z" => "trace-time-traces-row-s-11f067aa0ba902b8"
           }},
          {~p"/observability/metrics", "metrics",
           %{
             "2026-08-30T18:00:00Z" => "metric-time-metrics-row-s-00f067aa0ba902b7",
             "2026-08-30T18:01:00Z" => "metric-time-metrics-row-s-bbccddeeff00112233445566778899aa"
           }},
          {~p"/observability/alerts", "alerts",
           %{
             "2026-08-30T18:00:00Z" => "alert-time-alerts-row-s-alert-primary-1",
             "2026-08-30T18:01:00Z" => "alert-time-alerts-row-s-alert-2"
           }}
        ] do
      :persistent_term.put({__MODULE__, :identified_signal_row_order}, :forward)
      {:ok, forward, _html} = live(conn, path)

      :persistent_term.put({__MODULE__, :identified_signal_row_order}, :reverse)
      {:ok, reversed, _html} = live(conn, path)

      assert time_ids_by_datetime(forward, table) == expected
      assert time_ids_by_datetime(reversed, table) == expected
    end
  end

  @tag :web_ng_shared_fixture_db
  test "identical id-less trace metric and alert rows get stable unique rendered time ids", %{conn: conn} do
    :persistent_term.put({__MODULE__, :duplicate_idless_signal_rows?}, true)
    on_exit(fn -> :persistent_term.erase({__MODULE__, :duplicate_idless_signal_rows?}) end)

    for {path, table} <- [
          {~p"/observability/traces", "traces"},
          {~p"/observability/metrics", "metrics"},
          {~p"/observability/alerts", "alerts"}
        ] do
      {:ok, lv, _html} = live(conn, path)

      ids =
        lv
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("##{table} time")
        |> LazyHTML.attribute("id")

      assert length(ids) == 2
      assert ids == Enum.uniq(ids)

      stable_ids =
        lv
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("##{table} time")
        |> LazyHTML.attribute("id")

      assert stable_ids == ids
    end
  end

  test "enabling live mode allows log-ingest refreshes", %{conn: conn} do
    {:ok, lv, _html} =
      live(conn, ~p"/observability?#{%{tab: "logs", q: "in:logs time:last_24h sort:timestamp:desc", limit: 20}}")

    _ = drain_srql_calls()

    lv
    |> element("#logs-live-toggle")
    |> render_click()

    assert has_element?(lv, "#logs-live-status", "On")
    assert [%{cursor: nil} | _] = drain_srql_calls()

    send(lv.pid, {:logs_ingested, %{}})
    send(lv.pid, {:debounced_refresh, "logs"})
    render(lv)

    assert [%{cursor: nil} | _] = drain_srql_calls()
  end

  test "live log refresh bounds broad explicit log queries", %{conn: conn} do
    {:ok, lv, _html} =
      live(conn, ~p"/observability?#{%{tab: "logs", q: "in:logs sort:timestamp:desc", limit: 20}}")

    assert [%{query: initial_query, cursor: nil} | _] = drain_srql_calls()
    assert initial_query == "in:logs time:last_24h sort:timestamp:desc"

    lv
    |> element("#logs-live-toggle")
    |> render_click()

    _ = drain_srql_calls()

    send(lv.pid, {:logs_ingested, %{}})
    send(lv.pid, {:debounced_refresh, "logs"})
    render(lv)

    assert [%{query: refresh_query, cursor: nil} | _] = drain_srql_calls()
    assert refresh_query == "in:logs time:last_24h sort:timestamp:desc"
  end

  test "manual pagination pauses live mode before subsequent refreshes", %{conn: conn} do
    {:ok, lv, html} =
      live(conn, ~p"/observability?#{%{tab: "logs", q: "in:logs time:last_24h sort:timestamp:desc", limit: 20}}")

    assert html =~ "Page 1 log"
    _ = drain_srql_calls()

    lv
    |> element("#logs-live-toggle")
    |> render_click()

    assert has_element?(lv, "#logs-live-status", "On")
    _ = drain_srql_calls()

    lv
    |> element("a", "Next")
    |> render_click()

    assert has_element?(lv, "#logs-live-status", "Off")

    html = render(lv)
    assert html =~ "Page 2 log"
    assert [%{cursor: "cursor-page-2"}] = drain_srql_calls()

    send(lv.pid, {:logs_ingested, %{}})
    send(lv.pid, {:debounced_refresh, "logs"})
    render(lv)

    assert drain_srql_calls() == []
  end

  test "events default to non-live browsing", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/events")

    assert has_element?(lv, "#events-live-status", "Off")
    _ = drain_srql_calls()

    send(lv.pid, {:ocsf_event, %{}})
    send(lv.pid, {:debounced_refresh, "events"})
    render(lv)

    assert drain_srql_calls() == []
    assert has_element?(lv, "#events-live-status", "Off")
  end

  test "enabling live mode allows event-ingest refreshes", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/events")

    _ = drain_srql_calls()

    lv
    |> element("#events-live-toggle")
    |> render_click()

    assert has_element?(lv, "#events-live-status", "On")
    assert [%{cursor: nil} | _] = drain_srql_calls()

    send(lv.pid, {:ocsf_event, %{}})
    send(lv.pid, {:debounced_refresh, "events"})
    render(lv)

    assert [%{cursor: nil} | _] = drain_srql_calls()
  end

  test "manual pagination pauses events live mode before subsequent refreshes", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/events")

    _ = drain_srql_calls()

    lv
    |> element("#events-live-toggle")
    |> render_click()

    assert has_element?(lv, "#events-live-status", "On")
    _ = drain_srql_calls()

    lv
    |> element("a", "Next")
    |> render_click()

    assert has_element?(lv, "#events-live-status", "Off")
    assert [%{cursor: "cursor-page-2"}] = drain_srql_calls()

    send(lv.pid, {:ocsf_event, %{}})
    send(lv.pid, {:debounced_refresh, "events"})
    render(lv)

    assert drain_srql_calls() == []
  end

  test "traces default to non-live browsing", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/traces")

    assert has_element?(lv, "#traces-live-status", "Off")
    _ = drain_srql_calls()

    send(lv.pid, {:otel_traces_ingested, %{count: 3}})
    send(lv.pid, {:debounced_refresh, "traces"})
    render(lv)

    assert drain_srql_calls() == []
    assert has_element?(lv, "#traces-live-status", "Off")
  end

  test "enabling live mode allows trace-ingest refreshes", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/traces")

    _ = drain_srql_calls()

    lv
    |> element("#traces-live-toggle")
    |> render_click()

    assert has_element?(lv, "#traces-live-status", "On")
    assert drain_srql_calls() != []

    send(lv.pid, {:otel_traces_ingested, %{count: 3}})
    send(lv.pid, {:debounced_refresh, "traces"})
    render(lv)

    assert drain_srql_calls() != []
  end

  test "trace summary refreshes drive live mode, not just span ingest", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/traces")

    _ = drain_srql_calls()

    lv
    |> element("#traces-live-toggle")
    |> render_click()

    assert has_element?(lv, "#traces-live-status", "On")
    assert drain_srql_calls() != []

    send(lv.pid, {:otel_trace_summaries_refreshed, %{count: 2}})
    send(lv.pid, {:debounced_refresh, "traces"})
    render(lv)

    assert drain_srql_calls() != []
  end

  test "trace summary refreshes stay quiet when live is off", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/traces")

    assert has_element?(lv, "#traces-live-status", "Off")
    _ = drain_srql_calls()

    send(lv.pid, {:otel_trace_summaries_refreshed, %{count: 2}})
    send(lv.pid, {:debounced_refresh, "traces"})
    render(lv)

    assert drain_srql_calls() == []
    assert has_element?(lv, "#traces-live-status", "Off")
  end

  test "metrics default to non-live browsing", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/metrics")

    assert has_element?(lv, "#metrics-live-status", "Off")
    _ = drain_srql_calls()

    send(lv.pid, {:otel_metrics_ingested, %{count: 5}})
    send(lv.pid, {:debounced_refresh, "metrics"})
    render(lv)

    assert drain_srql_calls() == []
    assert has_element?(lv, "#metrics-live-status", "Off")
  end

  test "enabling live mode allows metric-ingest refreshes", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/metrics")

    _ = drain_srql_calls()

    lv
    |> element("#metrics-live-toggle")
    |> render_click()

    assert has_element?(lv, "#metrics-live-status", "On")
    assert drain_srql_calls() != []

    send(lv.pid, {:otel_metrics_ingested, %{count: 5}})
    send(lv.pid, {:debounced_refresh, "metrics"})
    render(lv)

    assert drain_srql_calls() != []
  end

  test "alerts default to non-live browsing", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/alerts")

    assert has_element?(lv, "#alerts-live-status", "Off")
    _ = drain_srql_calls()

    send(lv.pid, {:ocsf_event, %{}})
    send(lv.pid, {:debounced_refresh, "alerts"})
    render(lv)

    assert drain_srql_calls() == []
    assert has_element?(lv, "#alerts-live-status", "Off")
  end

  test "unrelated events do not schedule live alert refreshes", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/alerts")

    lv
    |> element("#alerts-live-toggle")
    |> render_click()

    _ = drain_srql_calls()
    send(lv.pid, {:ocsf_event, %{}})
    render(lv)

    assert drain_srql_calls() == []
    timers = :sys.get_state(lv.pid).socket.assigns[:_refresh_timers] || %{}
    refute Map.has_key?(timers, "alerts")
  end

  test "alert creation drives live mode", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/alerts")

    _ = drain_srql_calls()

    lv
    |> element("#alerts-live-toggle")
    |> render_click()

    assert has_element?(lv, "#alerts-live-status", "On")
    assert [%{cursor: nil} | _] = drain_srql_calls()

    send(lv.pid, {:alert_created, %{id: "alert-1"}})
    send(lv.pid, {:debounced_refresh, "alerts"})
    render(lv)

    assert [%{cursor: nil} | _] = drain_srql_calls()
  end

  test "alert creation stays quiet when live is off", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/alerts")

    assert has_element?(lv, "#alerts-live-status", "Off")
    _ = drain_srql_calls()

    send(lv.pid, {:alert_created, %{id: "alert-1"}})
    send(lv.pid, {:debounced_refresh, "alerts"})
    render(lv)

    assert drain_srql_calls() == []
    assert has_element?(lv, "#alerts-live-status", "Off")
  end

  test "netflows keep the shared observability shell visible", %{conn: conn} do
    {:ok, _lv, html} =
      live(conn, ~p"/observability?#{%{tab: "netflows", q: "in:flows time:last_1h sort:timestamp:desc", limit: 20}}")

    assert html =~ "Observability"
    assert html =~ "Unified view of logs, traces, metrics, and infrastructure signals."
  end

  # Regression for the initial tab load dropping list results: the first
  # connected render must already contain the rows (no deferred diff, no
  # manual re-run). Asserting on the html returned by live/2 is intentional —
  # it is the join-time render.
  test "metrics tab renders rows on the initial connected mount without a manual run", %{conn: conn} do
    {:ok, lv, html} =
      live(conn, ~p"/observability?#{%{tab: "metrics"}}")

    assert html =~ "metrics-service"
    refute html =~ "No metrics found."

    # Tab switching still works after the initial load.
    html = render_patch(lv, ~p"/observability?#{%{tab: "logs"}}")
    assert html =~ "Page 1 log"
  end

  test "metrics pane labels span samples and cumulative sums distinctly", %{conn: conn} do
    {:ok, _lv, html} =
      live(conn, ~p"/observability?#{%{tab: "metrics"}}")

    assert html =~ "span sample"
    assert html =~ "sum (cumulative)"
    assert html =~ "cumulative"
  end

  test "metrics pane labels the two views distinctly", %{conn: conn} do
    # Default view: span samples stay the default table and carry their
    # exemplar label; the toggle advertises the OTLP metrics view.
    {:ok, _lv, html} =
      live(conn, ~p"/observability?#{%{tab: "metrics"}}")

    assert html =~ "Span samples (slow-span exemplars)"
    assert html =~ "OTLP metrics"
    assert html =~ "metrics-view-toggle"
  end

  test "metrics OTLP view lists metric names from the points stats payload", %{conn: conn} do
    {:ok, _lv, html} =
      live(conn, ~p"/observability?#{%{tab: "metrics", mview: "points"}}")

    # Name rows: name, type badge, unit, point count.
    assert html =~ "falco.outputs.queue"
    assert html =~ "gen"
    assert html =~ "42"
    assert html =~ "sum"
    assert html =~ "gauge"
    assert html =~ "ms"

    # Span-sample table is replaced in this view.
    refute html =~ "Span samples (slow-span exemplars)"

    calls = drain_srql_calls()

    # Names rollup scoped to the active window, plus the type/unit enrichment
    # sample (the window token follows the pane's default query).
    assert Enum.any?(calls, fn call ->
             String.starts_with?(call.query, "in:otel_metric_points time:") and
               String.ends_with?(
                 call.query,
                 ~s|stats:"count() as points by metric_name" sort:points:desc limit:100|
               )
           end)

    assert Enum.any?(calls, fn call ->
             String.starts_with?(call.query, "in:otel_metric_points time:") and
               String.ends_with?(call.query, "sort:timestamp:desc limit:250")
           end)
  end

  test "clicking a metric name issues the recent-points query", %{conn: conn} do
    {:ok, lv, _html} =
      live(conn, ~p"/observability?#{%{tab: "metrics", mview: "points"}}")

    _ = drain_srql_calls()

    lv
    |> element("#otlp-metric-name-0 a", "falco.outputs.queue")
    |> render_click()

    render(lv)

    calls = drain_srql_calls()

    assert Enum.any?(
             calls,
             &(&1.query == ~s|in:otel_metric_points metric_name:"falco.outputs.queue" sort:timestamp:desc limit:500|)
           )
  end

  test "cumulative monotonic counters render a rate with stored temporality", %{conn: conn} do
    {:ok, _lv, html} =
      live(
        conn,
        ~p"/observability?#{%{tab: "metrics", mview: "points", metric: "falco.outputs.queue"}}"
      )

    # 60/minute counter -> 1/s, labeled from the stored temporality field.
    assert html =~ "current rate"
    assert html =~ "1/s"
    assert html =~ "temporality: cumulative"
    refute html =~ "Select a metric to load its recent points."
  end

  test "metrics stat cards are clickable filters", %{conn: conn} do
    {:ok, _lv, html} =
      live(conn, ~p"/observability?#{%{tab: "metrics"}}")

    # Cards reflect the spans_red_1h rollup payload, not zeros.
    assert html =~ "1.2k"

    # Total -> reset metrics list; Slow Spans -> is_slow:true drill-down.
    assert html =~ "q=in%3Aotel_metrics+sort%3Atimestamp%3Adesc"
    assert html =~ "q=in%3Aotel_metrics+is_slow%3Atrue+sort%3Atimestamp%3Adesc"

    # Errors / Error Rate cards pivot to the error trace list (the RED error
    # counts come from spans, which drill down via trace summaries).
    assert html =~ "q=in%3Aotel_trace_summaries+error_count%3A%3E0+sort%3Atimestamp%3Adesc"
    assert html =~ "tab=traces"
  end

  test "traces stat cards are clickable filters", %{conn: conn} do
    {:ok, _lv, html} =
      live(conn, ~p"/observability?#{%{tab: "traces"}}")

    # Total -> reset; Successful -> error_count:0; Errors -> error_count:>0.
    assert html =~ "q=in%3Aotel_trace_summaries+sort%3Atimestamp%3Adesc"
    assert html =~ "q=in%3Aotel_trace_summaries+error_count%3A0+sort%3Atimestamp%3Adesc"
    assert html =~ "q=in%3Aotel_trace_summaries+error_count%3A%3E0+sort%3Atimestamp%3Adesc"
  end

  test "trace rows navigate to the trace detail view", %{conn: conn} do
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/observability?#{%{tab: "traces", q: "in:otel_trace_summaries time:last_24h sort:timestamp:desc", limit: 20}}"
      )

    html = render(lv)

    assert html =~ "Click a trace to open the span waterfall."
    assert html =~ "/observability/traces/aabbccddeeff00112233445566778899"
    refute html =~ "tab=logs&amp;q=in%3Alogs+trace_id"

    # Row with a usable trace_id is clickable; row without one is inert.
    assert has_element?(lv, "#traces-row-0[phx-click]")
    refute has_element?(lv, "#traces-row-1[phx-click]")
  end

  test "default traces tab falls back to raw spans when summaries are stale", %{conn: conn} do
    :persistent_term.put({__MODULE__, :empty_trace_summaries?}, true)

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :empty_trace_summaries?})
    end)

    {:ok, _lv, html} =
      live(conn, ~p"/observability?#{%{tab: "traces"}}")

    assert html =~ "serviceradar-web-ng"
    assert html =~ "GET /observability"
    refute html =~ "No traces found."

    queries = Enum.map(drain_srql_calls(), & &1.query)

    assert Enum.any?(queries, &String.starts_with?(&1, "in:otel_trace_summaries"))
    assert Enum.any?(queries, &String.starts_with?(&1, "in:traces time:last_24h"))
  end

  defp drain_srql_calls(acc \\ []) do
    receive do
      {:srql_query, payload} ->
        drain_srql_calls([payload | acc])
    after
      100 ->
        Enum.reverse(acc)
    end
  end

  defp live_following_redirect(conn, path) do
    case live(conn, path) do
      {:ok, _lv, _html} = result -> result
      {:error, {:live_redirect, %{to: to}}} -> live(conn, to)
    end
  end

  defp time_ids_by_datetime(live_view, table) do
    times =
      live_view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("##{table} time")

    times
    |> LazyHTML.attribute("datetime")
    |> Enum.zip(LazyHTML.attribute(times, "id"))
    |> Map.new()
  end

  defmodule RecordingSRQLStub do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    @impl true
    def query(query) when is_binary(query), do: query(query, %{})

    @impl true
    def query(query, opts) when is_binary(query) do
      case :persistent_term.get({IndexTest, :test_pid}, nil) do
        pid when is_pid(pid) ->
          send(pid, {:srql_query, %{query: query, cursor: Map.get(opts, :cursor), limit: Map.get(opts, :limit)}})

        _ ->
          :ok
      end

      if String.contains?(query, "rollup_stats:severity") and
           :persistent_term.get({IndexTest, :logs_rollup_error?}, false) do
        {:error, :undefined_table}
      else
        query_success(query, opts)
      end
    end

    defp query_success(query, opts) do
      cursor = Map.get(opts, :cursor)

      results =
        cond do
          String.contains?(query, "rollup_stats:severity") -> [logs_severity_rollup_payload()]
          String.contains?(query, "rollup_stats:red") -> [red_rollup_payload()]
          String.contains?(query, "rollup_stats:summary") -> [traces_rollup_payload()]
          String.starts_with?(query, "in:otel_trace_summaries") -> maybe_sample_trace_summaries()
          String.starts_with?(query, "in:traces") -> sample_raw_traces()
          String.starts_with?(query, "in:otel_metric_points") -> otlp_points_results(query)
          String.starts_with?(query, "in:otel_metrics") -> sample_metrics()
          String.starts_with?(query, "in:events") -> sample_events()
          String.starts_with?(query, "in:alerts") -> sample_alerts()
          true -> sample_logs(cursor)
        end

      {:ok,
       %{
         "results" => results,
         "pagination" => pagination(cursor),
         "error" => nil
       }}
    end

    @impl true
    def query_request(%{"query" => query}) when is_binary(query), do: query(query, %{})
    def query_request(_payload), do: {:error, :invalid_request}

    defp red_rollup_payload do
      %{
        "total" => 1200,
        "errors" => 24,
        "slow" => 36,
        "error_rate" => 2.0,
        "avg_duration_ms" => 12.5,
        "p50_duration_ms" => 8.0,
        "p95_duration_ms" => 42.0,
        "max_duration_ms" => 480.0
      }
    end

    defp logs_severity_rollup_payload do
      %{
        "total" => 100,
        "fatal" => 2,
        "error" => 8,
        "warning" => 15,
        "info" => 70,
        "debug" => 5
      }
    end

    defp traces_rollup_payload do
      %{
        "total" => 900,
        "errors" => 18,
        "avg_duration_ms" => 11.0,
        "p95_duration_ms" => 40.0
      }
    end

    defp otlp_points_results(query) do
      cond do
        String.contains?(query, "stats:") -> otlp_points_stats_payload()
        String.contains?(query, "metric_name:") -> sample_otlp_points()
        true -> sample_otlp_recent_points()
      end
    end

    defp otlp_points_stats_payload do
      [
        %{"payload" => %{"metric_name" => "falco.outputs.queue", "points" => 42}},
        %{"payload" => %{"metric_name" => "gen", "points" => 7}}
      ]
    end

    # Best-effort enrichment sample: newest points across all metric names.
    defp sample_otlp_recent_points do
      [
        %{
          "timestamp" => "2026-08-30T18:00:00Z",
          "metric_name" => "falco.outputs.queue",
          "metric_type" => "sum",
          "unit" => "1",
          "temporality" => "cumulative",
          "is_monotonic" => true,
          "service_name" => "falco",
          "attributes" => ~s({"queue":"0"}),
          "attributes_hash" => "hash-falco",
          "value" => 130.0
        },
        %{
          "timestamp" => "2026-08-30T18:00:00Z",
          "metric_name" => "gen",
          "metric_type" => "gauge",
          "unit" => "ms",
          "temporality" => "unspecified",
          "is_monotonic" => nil,
          "service_name" => "telemetrygen",
          "attributes" => ~s({}),
          "attributes_hash" => "hash-gen",
          "value" => 3.5
        }
      ]
    end

    # Recent points for one metric: a cumulative monotonic counter growing by
    # 60 per minute -> rate 1/s with a reset-free series.
    defp sample_otlp_points do
      for {ts, value} <- [
            {"2026-04-18T15:02:00Z", 130.0},
            {"2026-04-18T15:01:00Z", 70.0},
            {"2026-04-18T15:00:00Z", 10.0}
          ] do
        %{
          "timestamp" => ts,
          "metric_name" => "falco.outputs.queue",
          "metric_type" => "sum",
          "unit" => "1",
          "temporality" => "cumulative",
          "is_monotonic" => true,
          "service_name" => "falco",
          "attributes" => ~s({"queue":"0"}),
          "attributes_hash" => "hash-falco",
          "value" => value
        }
      end
    end

    defp sample_metrics do
      rows = [
        %{
          "timestamp" => "2026-08-30T18:00:00Z",
          "service_name" => "metrics-service",
          "metric_type" => "span",
          "span_name" => "GET /api/devices",
          "span_id" => "00f067aa0ba902b7",
          "trace_id" => "aabbccddeeff00112233445566778899",
          "duration_ms" => 250.5,
          "is_slow" => true
        },
        %{
          "timestamp" => "2026-08-30T18:01:00Z",
          "service_name" => "falco",
          "metric_type" => "sum",
          "metric_name" => "falco.outputs.queue",
          "value" => 1234.0
        }
      ]

      identified_rows =
        List.update_at(rows, 1, &Map.put(&1, "trace_id", "bbccddeeff00112233445566778899aa"))

      rows
      |> ordered_identified_rows(identified_rows)
      |> duplicate_idless_rows(%{
        "timestamp" => "2026-08-30T18:00:00Z",
        "service_name" => "identical-metric",
        "metric_type" => "gauge",
        "metric_name" => "queue.depth",
        "value" => 1.0
      })
    end

    defp sample_traces do
      rows = [
        %{
          "trace_id" => "aabbccddeeff00112233445566778899",
          "timestamp" => "2026-08-30T18:00:00Z",
          "root_service_name" => "web-ng",
          "root_span_name" => "GET /api/devices",
          "duration_ms" => 12.5,
          "span_count" => 3,
          "error_count" => 0
        },
        %{
          "timestamp" => "2026-08-30T18:01:00Z",
          "root_service_name" => "core-elx",
          "root_span_name" => "orphan summary",
          "duration_ms" => 1.0,
          "span_count" => 1,
          "error_count" => 0
        }
      ]

      identified_rows = List.update_at(rows, 1, &Map.put(&1, "span_id", "11f067aa0ba902b8"))

      rows
      |> ordered_identified_rows(identified_rows)
      |> duplicate_idless_rows(%{
        "timestamp" => "2026-08-30T18:00:00Z",
        "root_service_name" => "identical-trace",
        "root_span_name" => "id-less",
        "duration_ms" => 1.0,
        "span_count" => 1,
        "error_count" => 0
      })
    end

    defp maybe_sample_trace_summaries do
      if :persistent_term.get({IndexTest, :empty_trace_summaries?}, false) do
        []
      else
        sample_traces()
      end
    end

    defp sample_raw_traces do
      [
        %{
          "trace_id" => "bbccddeeff00112233445566778899aa",
          "span_id" => "00f067aa0ba902b7",
          "timestamp" => "2026-04-18T15:03:00Z",
          "service_name" => "serviceradar-web-ng",
          "name" => "GET /observability",
          "duration_ms" => 9.25,
          "status_code" => 1
        }
      ]
    end

    defp sample_logs("cursor-page-2") do
      [
        %{
          "id" => "00000000-0000-0000-0000-000000000002",
          "timestamp" => "2026-04-18T15:01:00Z",
          "severity_text" => "INFO",
          "service_name" => "page-two-service",
          "body" => "Page 2 log"
        }
      ]
    end

    defp sample_logs(_cursor) do
      [
        %{
          "id" => "00000000-0000-0000-0000-000000000001",
          "timestamp" => "2026-08-30T12:34:56",
          "observed_timestamp" => "2026-08-30T18:00:00Z",
          "severity_text" => "INFO",
          "service_name" => "page-one-service",
          "source" => "syslog",
          "body" => "Page 1 log — syslog unzoned source"
        },
        %{
          "id" => "00000000-0000-0000-0000-000000000014",
          "timestamp" => "2026-08-30T12:45:56",
          "severity_text" => "INFO",
          "service_name" => "source-only-service",
          "source" => "syslog",
          "body" => "source-only unzoned log"
        },
        # OTel-SDK producers write the raw SeverityNumber enum name into
        # severity_text. The badge must normalize it to a label + color.
        %{
          "id" => "00000000-0000-0000-0000-000000000011",
          "timestamp" => "2026-04-18T15:02:01Z",
          "severity_text" => "SEVERITY_NUMBER_INFO",
          "service_name" => "otel-info-service",
          "source" => "otel",
          "body" => "OTel info log"
        },
        %{
          "id" => "00000000-0000-0000-0000-000000000012",
          "timestamp" => "2026-04-18T15:02:02Z",
          "severity_text" => "SEVERITY_NUMBER_WARN",
          "service_name" => "otel-warn-service",
          "source" => "snmp_trap",
          "body" => "SNMP trap log"
        },
        %{
          "id" => "00000000-0000-0000-0000-000000000013",
          "timestamp" => "2026-04-18T15:02:03Z",
          "severity_text" => "INFO",
          "service_name" => "gelf-service",
          "source" => "gelf",
          "body" => "GELF log"
        }
      ]
    end

    defp sample_events do
      [
        %{
          "id" => "event-1",
          "time" => "2026-08-30T18:00:00Z",
          "severity" => "High",
          "source" => "otel",
          "message" => "OTel event"
        }
      ]
    end

    defp sample_alerts do
      rows = [
        %{
          "id" => "alert-1",
          "triggered_at" => "2026-08-30T18:00:00",
          "severity" => "critical",
          "status" => "pending",
          "title" => "Alert"
        }
      ]

      identified_rows =
        List.update_at(rows, 0, &Map.put(&1, "alert_id", "alert-primary-1")) ++
          [
            %{
              "id" => "alert-2",
              "triggered_at" => "2026-08-30T18:01:00",
              "severity" => "warning",
              "status" => "pending",
              "title" => "Second alert"
            }
          ]

      rows
      |> ordered_identified_rows(identified_rows)
      |> duplicate_idless_rows(%{
        "triggered_at" => "2026-08-30T18:00:00",
        "severity" => "critical",
        "status" => "pending",
        "title" => "Identical id-less alert"
      })
    end

    defp ordered_identified_rows(default_rows, identified_rows) do
      case :persistent_term.get({IndexTest, :identified_signal_row_order}, nil) do
        :forward -> identified_rows
        :reverse -> Enum.reverse(identified_rows)
        nil -> default_rows
      end
    end

    defp duplicate_idless_rows(rows, idless_row) do
      if :persistent_term.get({IndexTest, :duplicate_idless_signal_rows?}, false) do
        [idless_row, idless_row]
      else
        rows
      end
    end

    defp pagination("cursor-page-2") do
      %{"prev_cursor" => "cursor-page-1"}
    end

    defp pagination(_cursor) do
      %{"next_cursor" => "cursor-page-2"}
    end
  end
end
