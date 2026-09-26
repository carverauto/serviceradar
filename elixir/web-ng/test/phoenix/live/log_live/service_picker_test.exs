defmodule ServiceRadarWebNGWeb.LogLive.ServicePickerTest do
  @moduledoc """
  The OTel service picker on the logs, traces and metrics panes, driven
  through the LiveView. SRQL is a recording stub: the catalog it serves is
  invented (`svc-0001`...), and the assertions are on the queries the page
  sends and the URL it patches to.
  """
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNGWeb.LogLive.ServicePickerTest
  alias ServiceRadarWebNGWeb.Observability.ServiceFilter

  @moduletag :web_ng_shared_fixture_db

  @catalog_size 5_000

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :operator})
    conn = log_in_user(conn, user)

    old = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.CatalogStub)

    old_status = Application.get_env(:serviceradar_web_ng, :logs_rollup_status_fun)

    Application.put_env(:serviceradar_web_ng, :logs_rollup_status_fun, fn ->
      ServiceRadarWebNGWeb.Stats.empty_logs_rollup_status()
    end)

    :persistent_term.put({__MODULE__, :test_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :test_pid})
      restore_env(:srql_module, old)
      restore_env(:logs_rollup_status_fun, old_status)
    end)

    %{conn: conn}
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)

  defp catalog_queries(acc \\ []) do
    receive do
      {:srql_query, "in:otel_services" <> _ = query} -> catalog_queries([query | acc])
      {:srql_query, _other} -> catalog_queries(acc)
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp patched_q(lv) do
    lv |> assert_patch() |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.fetch!("q")
  end

  defp open_picker(lv, pane) do
    lv |> element("##{pane}-service-filter") |> render_click()
    # start_async: let the search task report back before asserting.
    render_async(lv)
  end

  test "no catalog query runs during the disconnected render", %{conn: conn} do
    conn = get(conn, ~p"/observability/logs")

    assert html_response(conn, 200) =~ "logs-service-filter"
    assert catalog_queries() == []
  end

  test "search runs on the server and shows at most 50 of many, with the total", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/logs")
    _ = catalog_queries()

    open_picker(lv, "logs")

    assert [list, count] = Enum.sort_by(catalog_queries(), &String.contains?(&1, "stats:"))
    assert list =~ "signal:logs"
    assert list =~ "limit:50"
    assert count =~ ~s|stats:"count() as total"|

    assert has_element?(lv, "#service-picker-count", "Showing 50 of #{@catalog_size}")
    assert has_element?(lv, "#service-picker-option-49")
    refute has_element?(lv, "#service-picker-option-50")

    lv |> form("#service-picker-search-form", %{search: "pay"}) |> render_change()
    render_async(lv)

    searches = catalog_queries()
    assert length(searches) == 2
    assert Enum.all?(searches, &(&1 =~ ~s(service_name:"%pay%")))
  end

  test "the picker is scoped to the pane's signal", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/traces")
    _ = catalog_queries()

    open_picker(lv, "traces")

    queries = catalog_queries()
    assert queries != []
    assert Enum.all?(queries, &(&1 =~ "signal:traces"))
  end

  test "applying keeps every other filter, adds the selection and reloads from page one", %{conn: conn} do
    q = "in:logs time:last_1h severity_text:error"
    {:ok, lv, _html} = live(conn, ~p"/observability/logs?#{%{q: q}}")

    open_picker(lv, "logs")
    lv |> element(~s(#service-picker-options input[data-service-name="svc-0002"])) |> render_click()
    lv |> element(~s(#service-picker-options input[data-service-name="svc-0001"])) |> render_click()
    lv |> element("#service-picker-apply") |> render_click()

    q = patched_q(lv)
    assert q =~ "in:logs"
    assert q =~ "time:last_1h"
    assert q =~ "severity_text:error"
    assert ServiceFilter.parse(q) == {:exact, ["svc-0002", "svc-0001"]}
  end

  test "a new selection replaces the previous service filter", %{conn: conn} do
    q = ~s(in:logs time:last_1h service_name:"svc-0001")
    {:ok, lv, _html} = live(conn, ~p"/observability/logs?#{%{q: q}}")

    assert has_element?(lv, "#logs-service-filter", "svc-0001")

    open_picker(lv, "logs")
    # The current selection is pinned and checked; untick it, pick another.
    lv |> element(~s(#service-picker-option-0 input[data-service-name="svc-0001"][checked])) |> render_click()
    lv |> element(~s(#service-picker-options input[data-service-name="svc-0003"])) |> render_click()
    lv |> element("#service-picker-apply") |> render_click()

    q = patched_q(lv)
    assert q =~ "time:last_1h"
    assert ServiceFilter.parse(q) == {:exact, ["svc-0003"]}
  end

  test "a % typed into the free-text fallback is sent as a literal exact name", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/logs")

    open_picker(lv, "logs")
    lv |> form("#service-picker-search-form", %{search: "pay%"}) |> render_change()
    render_async(lv)

    lv |> element("#service-picker-use-typed") |> render_click()
    lv |> element("#service-picker-apply") |> render_click()

    # List form: SRQL reads a list value as exact, never as a LIKE pattern.
    assert patched_q(lv) =~ ~s|service_name:("pay%")|
  end

  test "the service filter follows a tab switch", %{conn: conn} do
    q = ~s(in:logs time:last_1h service_name:"svc-0001")
    {:ok, lv, _html} = live(conn, ~p"/observability/logs?#{%{q: q}}")

    lv |> element("#observability-tab-traces") |> render_click()
    assert_patch(lv)

    assert has_element?(lv, "#traces-service-filter", "svc-0001")
  end

  test "a wildcard filter is not carried to traces, and the traces pane says so", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/logs?#{%{q: "in:logs service_name:%pay%"}}")

    lv |> element("#observability-tab-traces") |> render_click()
    patched = assert_patch(lv)

    refute patched =~ "pay"
    assert has_element?(lv, "#service-filter-not-carried")
    assert has_element?(lv, "#traces-service-filter", "All services")
  end

  test "clicking a row's service applies that single-service filter", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/traces?#{%{q: "in:otel_trace_summaries time:last_1h"}}")

    lv |> element("#traces-row-0-service") |> render_click()

    q = patched_q(lv)
    assert q =~ "in:otel_trace_summaries"
    assert q =~ "time:last_1h"
    assert ServiceFilter.parse(q) == {:exact, ["svc-0001"]}
  end

  test "stat cards are scoped to a multi-service selection", %{conn: conn} do
    q = ~s|in:logs service_name:("svc-0001","svc-0002")|
    {:ok, lv, _html} = live(conn, ~p"/observability/logs?#{%{q: q}}")

    assert_received {:srql_query, "in:logs time:last_24h rollup_stats:severity" <> filter}
    assert filter == ~s| service_name:("svc-0001","svc-0002")|
    assert has_element?(lv, "#service-stats-scope", "svc-0001, svc-0002")
  end

  test "the traces services card counts the catalog for the card window", %{conn: conn} do
    {:ok, _lv, _html} = live(conn, ~p"/observability/traces")

    assert ~s|in:otel_services signal:traces time:last_24h stats:"count() as total"| in catalog_queries()
  end

  test "the OTLP points view scopes its metric-name rollup to a multi-service selection", %{conn: conn} do
    q = ~s|in:otel_metrics time:last_6h service_name:("svc-0001","svc-0002")|
    {:ok, _lv, _html} = live(conn, ~p"/observability/metrics?#{%{q: q, mview: "points"}}")

    queries = srql_queries()

    assert ~s|in:otel_metric_points time:last_6h service_name:("svc-0001","svc-0002") sort:timestamp:desc limit:250| in queries
    refute Enum.any?(queries, &(&1 =~ "in:otel_metric_points" and &1 =~ ~s|service_name:"(|))
  end

  describe "trace stat cards under a service filter" do
    # The trace list matches a service anywhere in the trace; the summary rollup
    # groups root spans by the ROOT service. A trace rooted in `checkout` that
    # calls `billing` is therefore in the `billing` list but absent from the
    # rollup's `billing` bucket, and the cards must count it from the list's
    # own entity instead.
    test "count the traces the list shows, not the root-grouped rollup", %{conn: conn} do
      q = ~s(in:otel_trace_summaries time:last_6h sort:timestamp:desc service_name:"billing")
      {:ok, lv, _html} = live(conn, ~p"/observability/traces?#{%{q: q}}")

      queries = srql_queries()

      assert ~s|in:otel_trace_summaries time:last_6h service_name:"billing" stats:"count() as total"| in queries

      assert ~s|in:otel_trace_summaries time:last_6h service_name:"billing" error_count:>0 stats:"count() as total"| in queries

      refute Enum.any?(queries, &(&1 =~ "rollup_stats:summary" and &1 =~ "service_name"))

      assert has_element?(lv, "#traces-card-total", "1")
      assert has_element?(lv, "#traces-card-successful", "0")
      assert has_element?(lv, "#traces-card-errors", "1")
      assert has_element?(lv, "#traces-card-error-rate", "100")

      # Duration cards cannot be narrowed and say so rather than pass for filtered.
      assert has_element?(lv, ~s(#traces-card-avg-duration [data-role="all-services"]))
      assert has_element?(lv, ~s(#traces-card-p95-duration [data-role="all-services"]))
      refute has_element?(lv, ~s(#traces-card-total [data-role="all-services"]))
    end

    test "unfiltered, every trace card still comes from the rollup", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/observability/traces?#{%{q: "in:otel_trace_summaries time:last_6h"}}")

      queries = srql_queries()

      assert "in:otel_traces time:last_24h rollup_stats:summary" in queries
      refute Enum.any?(queries, &(&1 =~ "in:otel_trace_summaries" and &1 =~ "stats:"))

      assert has_element?(lv, "#traces-card-total", "900")
      assert has_element?(lv, "#traces-card-errors", "9")
      refute has_element?(lv, ~s(#traces-summary-cards [data-role="all-services"]))
    end
  end

  defp srql_queries(acc \\ []) do
    receive do
      {:srql_query, query} -> srql_queries([query | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defmodule CatalogStub do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    @catalog_size 5_000

    def query(query) when is_binary(query), do: query(query, %{})

    @impl true
    def query(query, _opts) when is_binary(query) do
      case :persistent_term.get({ServicePickerTest, :test_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:srql_query, query})
        _ -> :ok
      end

      {:ok, %{"results" => results(query), "pagination" => %{}, "error" => nil}}
    end

    @impl true
    def query_request(%{"query" => query}) when is_binary(query), do: query(query, %{})
    def query_request(_payload), do: {:error, :invalid_request}

    defp results("in:otel_services" <> _ = query) do
      matches? = not String.contains?(query, "pay")

      cond do
        String.contains?(query, "stats:") -> [%{"total" => if(matches?, do: @catalog_size, else: 0)}]
        matches? -> Enum.map(1..50, &%{"service_name" => "svc-" <> String.pad_leading("#{&1}", 4, "0")})
        true -> []
      end
    end

    defp results("in:logs" <> _ = query) do
      if String.contains?(query, "rollup_stats:severity") do
        [%{"total" => 10, "fatal" => 0, "error" => 1, "warning" => 2, "info" => 7, "debug" => 0}]
      else
        [
          %{
            "id" => "00000000-0000-0000-0000-000000000001",
            "timestamp" => "2026-08-30T18:00:00Z",
            "severity_text" => "INFO",
            "service_name" => "svc-0001",
            "body" => "invented log line"
          }
        ]
      end
    end

    # The root-grouped rollup: a `service_name` filter selects by ROOT service,
    # and no trace here is rooted in the filtered services.
    defp results("in:otel_traces" <> _ = query) do
      if String.contains?(query, "service_name") do
        [%{"total" => 0, "errors" => 0}]
      else
        [%{"total" => 900, "errors" => 9, "avg_duration_ms" => 20.0, "p95_duration_ms" => 80.0}]
      end
    end

    # One `checkout`-rooted trace calls `billing` and carries an error.
    defp results("in:otel_trace_summaries" <> _ = query) do
      if String.contains?(query, "stats:") do
        [%{"total" => if(String.contains?(query, ~s(service_name:"billing")), do: 1, else: 0)}]
      else
        trace_rows()
      end
    end

    defp results(_query), do: []

    defp trace_rows do
      [
        %{
          "trace_id" => "0af7651916cd43dd8448eb211c80319c",
          "timestamp" => "2026-08-30T18:00:00Z",
          "root_service_name" => "svc-0001",
          "root_span_name" => "GET /invented",
          "span_count" => 3,
          "error_count" => 0,
          "duration_ms" => 12.0
        }
      ]
    end
  end
end
