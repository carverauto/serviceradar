defmodule ServiceRadarWebNGWeb.EventLive.IndexTest do
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

  test "finding stat links use the same rollup predicates as their counts", %{conn: conn} do
    {:ok, view, _html} =
      live(conn, ~p"/events?#{%{q: "in:events time:last_7d sort:time:desc", limit: 20}}")

    assert has_element?(
             view,
             ~s|a[href="#{events_path_for_query("in:events finding_rollup:anomaly time:last_7d sort:time:desc")}"]|,
             "Anomaly findings"
           )

    assert has_element?(
             view,
             ~s|a[href="#{events_path_for_query("in:events finding_rollup:capacity_at_risk time:last_7d sort:time:desc")}"]|,
             "At-risk capacity"
           )

    assert has_element?(
             view,
             ~s|a[href="#{events_path_for_query("in:events finding_rollup:health time:last_7d sort:time:desc")}"]|,
             "Health findings"
           )
  end

  test "event broadcasts coalesce into one debounced refresh", %{conn: conn} do
    {:ok, view, _html} =
      live(conn, ~p"/events?#{%{q: "in:events time:last_7d sort:time:desc", limit: 20}}")

    _ = drain_srql_calls()

    send(view.pid, {:ocsf_event, %{}})
    send(view.pid, {:health_event, %{}})
    send(view.pid, {:ocsf_event, %{}})
    render(view)

    assert drain_srql_calls() == []

    send(view.pid, :debounced_events_refresh)
    render(view)

    calls = drain_srql_calls()
    queries = Enum.map(calls, & &1.query)

    assert Enum.count(queries, &(&1 == "in:events time:last_7d sort:time:desc")) == 1
    assert Enum.count(queries, &(&1 == "in:events time:last_7d rollup_stats:anomaly_findings")) == 1
  end

  defp events_path_for_query(query), do: "/events?" <> URI.encode_query(%{q: query})

  defp drain_srql_calls(acc \\ []) do
    receive do
      {:srql_query, payload} ->
        drain_srql_calls([payload | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defmodule RecordingSRQLStub do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    def query(query) when is_binary(query), do: query(query, %{})

    def query(query, opts) when is_binary(query) do
      record_query(query, opts)

      cond do
        String.contains?(query, "rollup_stats:anomaly_findings") ->
          {:ok,
           %{
             "results" => [
               %{
                 "total" => 9,
                 "anomalies" => 6,
                 "at_risk" => 3,
                 "critical" => 2,
                 "high" => 4
               }
             ],
             "pagination" => %{},
             "error" => nil
           }}

        String.starts_with?(query, "in:events") ->
          {:ok, %{"results" => sample_events(), "pagination" => %{}, "error" => nil}}

        true ->
          {:ok, %{"results" => [], "pagination" => %{}, "error" => nil}}
      end
    end

    def query(_query, _opts), do: {:error, :invalid_query}

    def query_request(%{"query" => query}) when is_binary(query), do: query(query, %{})
    def query_request(_payload), do: {:error, :invalid_request}

    defp record_query(query, opts) do
      case :persistent_term.get({ServiceRadarWebNGWeb.EventLive.IndexTest, :test_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:srql_query, %{query: query, opts: opts}})
        _ -> :ok
      end
    end

    defp sample_events do
      [
        %{
          "id" => "00000000-0000-0000-0000-000000000101",
          "time" => "2026-07-04T12:00:00Z",
          "severity" => "High",
          "log_provider" => "anomaly_detection",
          "message" => "Sample anomaly finding",
          "metadata" => %{
            "service_radar" => %{"source_type" => "anomaly_detection"},
            "detection_finding" => %{"type" => "anomaly"}
          }
        }
      ]
    end
  end
end
