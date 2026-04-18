defmodule ServiceRadarWebNGWeb.LogLive.IndexTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AccountsFixtures

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :operator})
    conn = log_in_user(conn, user)

    old = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.RecordingSRQLStub)

    :persistent_term.put({__MODULE__, :test_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :test_pid})

      if is_nil(old) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, old)
      end
    end)

    %{conn: conn}
  end

  test "logs default to non-live browsing", %{conn: conn} do
    {:ok, lv, html} =
      live(conn, ~p"/observability?#{%{tab: "logs", q: "in:logs time:last_24h sort:timestamp:desc", limit: 20}}")

    assert html =~ "Page 1 log"
    assert has_element?(lv, "#logs-live-status", "Off")

    assert [%{cursor: nil}] = drain_srql_calls()

    send(lv.pid, {:logs_ingested, %{}})
    send(lv.pid, {:debounced_refresh, "logs"})
    render(lv)

    assert drain_srql_calls() == []
    assert has_element?(lv, "#logs-live-status", "Off")
  end

  test "enabling live mode allows log-ingest refreshes", %{conn: conn} do
    {:ok, lv, _html} =
      live(conn, ~p"/observability?#{%{tab: "logs", q: "in:logs time:last_24h sort:timestamp:desc", limit: 20}}")

    _ = drain_srql_calls()

    lv
    |> element("#logs-live-toggle")
    |> render_click()

    assert has_element?(lv, "#logs-live-status", "On")
    assert [%{cursor: nil}] = drain_srql_calls()

    send(lv.pid, {:logs_ingested, %{}})
    send(lv.pid, {:debounced_refresh, "logs"})
    render(lv)

    assert [%{cursor: nil}] = drain_srql_calls()
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

  test "netflows keep the shared observability shell visible", %{conn: conn} do
    {:ok, _lv, html} =
      live(conn, ~p"/observability?#{%{tab: "netflows", q: "in:flows time:last_1h sort:timestamp:desc", limit: 20}}")

    assert html =~ "Observability"
    assert html =~ "Unified view of logs, traces, metrics, and infrastructure signals."
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

  defmodule RecordingSRQLStub do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    @impl true
    def query(query) when is_binary(query), do: query(query, %{})

    @impl true
    def query(query, opts) when is_binary(query) do
      case :persistent_term.get({ServiceRadarWebNGWeb.LogLive.IndexTest, :test_pid}, nil) do
        pid when is_pid(pid) ->
          send(pid, {:srql_query, %{query: query, cursor: Map.get(opts, :cursor), limit: Map.get(opts, :limit)}})

        _ ->
          :ok
      end

      cursor = Map.get(opts, :cursor)

      {:ok,
       %{
         "results" => sample_logs(cursor),
         "pagination" => pagination(cursor),
         "error" => nil
       }}
    end

    @impl true
    def query_request(%{"query" => query}) when is_binary(query), do: query(query, %{})
    def query_request(_payload), do: {:error, :invalid_request}

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
          "timestamp" => "2026-04-18T15:02:00Z",
          "severity_text" => "INFO",
          "service_name" => "page-one-service",
          "body" => "Page 1 log"
        }
      ]
    end

    defp pagination("cursor-page-2") do
      %{"prev_cursor" => "cursor-page-1"}
    end

    defp pagination(_cursor) do
      %{"next_cursor" => "cursor-page-2"}
    end
  end
end
