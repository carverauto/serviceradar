defmodule ServiceRadarWebNGWeb.TraceLive.ShowTest do
  @moduledoc """
  Tests for the trace detail view (TraceLive.Show): span waterfall ordering,
  error styling, retention/not-found states, trace id validation, and the
  correlated logs panel.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNGWeb.TraceLive.ShowTest

  @trace_id "abcdefabcdefabcdefabcdefabcdef12"

  setup %{conn: conn} do
    user =
      %{role: :operator}
      |> AccountsFixtures.user_fixture()
      |> then(fn user ->
        Ash.update!(user, %{timezone: "America/Chicago"},
          action: :update_timezone_preference,
          actor: user
        )
      end)

    conn = log_in_user(conn, user)

    old = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.RecordingSRQLStub)

    :persistent_term.put({__MODULE__, :test_pid}, self())
    :persistent_term.put({__MODULE__, :scenario}, :full)

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :test_pid})
      :persistent_term.erase({__MODULE__, :scenario})

      if is_nil(old) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, old)
      end
    end)

    %{conn: conn}
  end

  test "renders the span waterfall in parent/child order", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/traces/#{@trace_id}")

    # Stub returns spans out of order (child2, child1, root); the waterfall
    # must place the root first and order children by start time.
    assert has_element?(lv, "#trace-spans-row-0", "GET /api/devices")
    assert has_element?(lv, "#trace-spans-row-1", "core.query")
    assert has_element?(lv, "#trace-spans-row-2", "render.json")

    html = render(lv)

    # Children are depth-indented under the root.
    assert html =~ "padding-left: 16px"

    # Header summary values come from the trace summary row.
    assert html =~ "3 spans"
    assert has_element?(lv, "#trace-error-badge", "1 error")

    queries = drain_srql_queries()

    assert ~s(in:otel_trace_summaries trace_id:"#{@trace_id}" limit:1) in queries

    assert ~s(in:traces trace_id:"#{@trace_id}" sort:start_time_unix_nano:asc limit:1000) in queries

    # Correlated logs window derives from the trace's own span times ±5m.
    assert ~s(in:logs trace_id:"#{@trace_id}" time:[2023-11-14T22:08:20Z,2023-11-14T22:18:20Z] sort:timestamp:asc limit:50) in queries
  end

  test "renders correlated logs with a logs-tab pivot", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/traces/#{@trace_id}")

    assert has_element?(lv, "#trace-logs-row-0", "query exploded")
    assert has_element?(lv, "#trace-logs-tab-link", "View in logs tab")

    html = render(lv)
    # Log rows navigate to the log detail route.
    assert html =~ "/logs/11111111-2222-3333-4444-555555555555"
  end

  @tag :web_ng_shared_fixture_db
  test "uses the canonical observed instant for correlated logs with unzoned source timestamps", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/traces/#{@trace_id}")

    lv
    |> element("#trace-spans-row-0")
    |> render_click()

    assert has_element?(
             lv,
             ~s(time#trace-span-aaaaaaaaaaaaaaaa-start-time[datetime="2023-11-14T22:13:20.000000Z"][data-user-time-zone="America/Chicago"])
           )

    assert has_element?(
             lv,
             ~s(time#trace-span-aaaaaaaaaaaaaaaa-end-time[datetime="2023-11-14T22:13:20.050000Z"][data-user-time-zone="America/Chicago"])
           )

    assert has_element?(
             lv,
             ~s(time#trace-log-11111111-2222-3333-4444-555555555555-time[datetime="2023-11-14T22:13:20Z"][data-user-time-zone="America/Chicago"])
           )

    refute has_element?(
             lv,
             ~s(time#trace-log-11111111-2222-3333-4444-555555555555-time[datetime="2023-11-14T16:13:20Z"])
           )

    refute render(lv) =~ "2023-11-14T16:13:20Z"
  end

  test "error span gets error styling and expands details", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/traces/#{@trace_id}")

    assert has_element?(lv, "#trace-spans-row-1 .badge-error")
    refute has_element?(lv, "#trace-spans-row-2 .badge-error")

    lv
    |> element("#trace-spans-row-1")
    |> render_click()

    assert has_element?(lv, "#trace-spans-detail-1")

    html = render(lv)
    assert html =~ "bbbbbbbbbbbbbbbb"
    assert html =~ "boom"
    assert html =~ "db.statement"
  end

  test "?span= auto-expands and highlights the matching span", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/traces/#{@trace_id}?span=bbbbbbbbbbbbbbbb")

    # The core.query span (waterfall row 1) is expanded without any click.
    assert has_element?(lv, "#trace-spans-detail-1")

    html = render(lv)
    assert html =~ "boom"
    assert html =~ "db.statement"

    # The matching row carries the highlight ring.
    assert has_element?(lv, "#trace-spans-row-1.ring-2")
    refute has_element?(lv, "#trace-spans-row-0.ring-2")
  end

  test "?span= is normalized before matching", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/traces/#{@trace_id}?span=BBBBBBBBBBBBBBBB")

    assert has_element?(lv, "#trace-spans-detail-1")
    assert has_element?(lv, "#trace-spans-row-1.ring-2")
  end

  test "bogus or unknown ?span= params are ignored", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/traces/#{@trace_id}?span=not-a-span-id")

    assert has_element?(lv, "#trace-spans-row-0", "GET /api/devices")
    refute has_element?(lv, "[id^='trace-spans-detail-']")

    # A well-formed span id that is not part of this trace is also ignored.
    {:ok, lv, _html} = live(conn, ~p"/observability/traces/#{@trace_id}?span=dddddddddddddddd")

    assert has_element?(lv, "#trace-spans-row-0", "GET /api/devices")
    refute has_element?(lv, "[id^='trace-spans-detail-']")
  end

  test "span inspector shows ingest identity chips only when present", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/traces/#{@trace_id}")

    # core.query carries ingest attribution from srql.
    lv
    |> element("#trace-spans-row-1")
    |> render_click()

    html = render(lv)
    assert html =~ "Ingest Identity"
    assert html =~ "spiffe://sr/agent/edge-1"
    assert html =~ "Ingest Agent"
    assert html =~ "agent-edge-1"
    assert html =~ "Ingest Partition"
    assert html =~ "tenant-a"

    # render.json carries the blank defaults — no chips.
    lv
    |> element("#trace-spans-row-2")
    |> render_click()

    html = render(lv)
    refute html =~ "Ingest Identity"
    refute html =~ "Ingest Partition"

    # The root span omits the fields entirely — no chips either.
    lv
    |> element("#trace-spans-row-0")
    |> render_click()

    html = render(lv)
    refute html =~ "Ingest Identity"
  end

  test "shows retention notice when summary exists but spans expired", %{conn: conn} do
    :persistent_term.put({__MODULE__, :scenario}, :expired)

    {:ok, lv, html} = live(conn, ~p"/observability/traces/#{@trace_id}")

    assert html =~ "Span data for this trace is no longer retained."
    assert html =~ "3 spans"
    refute has_element?(lv, "#trace-spans")
    refute has_element?(lv, "#trace-not-found")
  end

  @tag :web_ng_shared_fixture_db
  test "does not derive correlated-log bounds from an offset-less summary string", %{conn: conn} do
    :persistent_term.put({__MODULE__, :scenario}, :unzoned_summary)

    {:ok, _lv, _html} = live(conn, ~p"/observability/traces/#{@trace_id}")

    queries = drain_srql_queries()

    refute Enum.any?(queries, &String.starts_with?(&1, "in:logs "))
    refute Enum.any?(queries, &String.contains?(&1, "2026-06-10T11:55:00Z"))
  end

  test "orphan trace header falls back to service_set when root service is unknown", %{conn: conn} do
    :persistent_term.put({__MODULE__, :scenario}, :orphan)

    {:ok, _lv, html} = live(conn, ~p"/observability/traces/#{@trace_id}")

    # Header renders the service from service_set rather than a blank "—".
    assert html =~ "core-elx"
    refute html =~ "Trace not found or expired."
  end

  test "shows not-found state when neither summary nor spans exist", %{conn: conn} do
    :persistent_term.put({__MODULE__, :scenario}, :missing)

    {:ok, lv, html} = live(conn, ~p"/observability/traces/#{@trace_id}")

    assert html =~ "Trace not found or expired."
    refute has_element?(lv, "#trace-spans")
    refute has_element?(lv, "#trace-summary-bar")
  end

  test "invalid trace id redirects back to the traces pane", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/observability?tab=traces"}}} =
             live(conn, ~p"/observability/traces/not-a-trace-id")
  end

  test "uppercase trace ids are canonicalized before querying", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/traces/#{String.upcase(@trace_id)}")

    assert has_element?(lv, "#trace-spans-row-0", "GET /api/devices")

    queries = drain_srql_queries()
    assert Enum.any?(queries, &(&1 =~ ~s(trace_id:"#{@trace_id}")))
    refute Enum.any?(queries, &(&1 =~ String.upcase(@trace_id)))
  end

  defp drain_srql_queries(acc \\ []) do
    receive do
      {:srql_query, query} ->
        drain_srql_queries([query | acc])
    after
      100 ->
        Enum.reverse(acc)
    end
  end

  defmodule RecordingSRQLStub do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    @trace_id "abcdefabcdefabcdefabcdefabcdef12"
    @base_ns 1_700_000_000_000_000_000
    @ms 1_000_000

    def query(query) when is_binary(query), do: query(query, %{})

    @impl true
    def query(query, _opts) when is_binary(query) do
      case :persistent_term.get({ShowTest, :test_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:srql_query, query})
        _ -> :ok
      end

      scenario = :persistent_term.get({ShowTest, :scenario}, :full)

      {:ok, %{"results" => results(query, scenario), "pagination" => %{}, "error" => nil}}
    end

    @impl true
    def query_request(%{"query" => query}) when is_binary(query), do: query(query, %{})
    def query_request(_payload), do: {:error, :invalid_request}

    defp results("in:otel_trace_summaries" <> _rest, scenario) when scenario in [:full, :expired, :unzoned_summary] do
      [
        %{
          "trace_id" => @trace_id,
          "timestamp" =>
            if(scenario == :unzoned_summary,
              do: "2026-06-10T12:00:00",
              else: "2026-06-10T12:00:00Z"
            ),
          "root_span_name" => "GET /api/devices",
          "root_service_name" => "web-ng",
          "duration_ms" => 50.0,
          "span_count" => 3,
          "error_count" => 1,
          "status_code" => 2,
          "service_set" => ["web-ng", "core-elx"]
        }
      ]
    end

    # Orphan trace: the summary has no root span name/service (the true root was
    # never exported) but service_set still records the services seen. Spans are
    # expired, so the header must fall back to service_set for the service name.
    defp results("in:otel_trace_summaries" <> _rest, :orphan) do
      [
        %{
          "trace_id" => @trace_id,
          "timestamp" => "2026-06-10T12:00:00Z",
          "root_span_name" => nil,
          "root_service_name" => nil,
          "duration_ms" => 50.0,
          "span_count" => 3,
          "error_count" => 0,
          "status_code" => nil,
          "service_set" => ["core-elx"]
        }
      ]
    end

    defp results("in:traces" <> _rest, :full) do
      # Deliberately out of order: child2, child1, root.
      [
        %{
          "trace_id" => @trace_id,
          "span_id" => "cccccccccccccccc",
          "parent_span_id" => "aaaaaaaaaaaaaaaa",
          "name" => "render.json",
          "service_name" => "web-ng",
          "kind" => 1,
          "start_time_unix_nano" => @base_ns + 35 * @ms,
          "end_time_unix_nano" => @base_ns + 45 * @ms,
          "status_code" => 1,
          "status_message" => "",
          "attributes" => "{}",
          "timestamp" => "2023-11-14T22:13:20Z",
          # Rows ingested before the attribution columns landed carry the
          # NOT NULL DEFAULT '' values.
          "ingest_identity" => "",
          "ingest_agent_id" => "",
          "ingest_partition" => ""
        },
        %{
          "trace_id" => @trace_id,
          "span_id" => "bbbbbbbbbbbbbbbb",
          "parent_span_id" => "aaaaaaaaaaaaaaaa",
          "name" => "core.query",
          "service_name" => "core-elx",
          "kind" => 3,
          "start_time_unix_nano" => @base_ns + 5 * @ms,
          "end_time_unix_nano" => @base_ns + 30 * @ms,
          "status_code" => 2,
          "status_message" => "boom",
          "attributes" => ~s({"db.statement":"SELECT 1"}),
          "timestamp" => "2023-11-14T22:13:20Z",
          "ingest_identity" => "spiffe://sr/agent/edge-1",
          "ingest_agent_id" => "agent-edge-1",
          "ingest_partition" => "tenant-a"
        },
        %{
          "trace_id" => @trace_id,
          "span_id" => "aaaaaaaaaaaaaaaa",
          "parent_span_id" => "",
          "name" => "GET /api/devices",
          "service_name" => "web-ng",
          "kind" => 2,
          "start_time_unix_nano" => @base_ns,
          "end_time_unix_nano" => @base_ns + 50 * @ms,
          "status_code" => 0,
          "status_message" => "",
          "attributes" => "{}",
          "timestamp" => "2023-11-14T22:13:20Z"
        }
      ]
    end

    defp results("in:logs" <> _rest, :full) do
      [
        %{
          "id" => "11111111-2222-3333-4444-555555555555",
          "timestamp" => "2023-11-14T16:13:20",
          "observed_timestamp" => "2023-11-14T22:13:20Z",
          "severity_text" => "ERROR",
          "service_name" => "core-elx",
          "body" => "query exploded",
          "trace_id" => @trace_id
        }
      ]
    end

    defp results(_query, _scenario), do: []
  end
end
