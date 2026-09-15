defmodule ServiceRadar.Observability.SRQLRunnerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.SRQLRunner

  test "query_page returns mapped rows and next cursor for a full page" do
    translate_fn = fn "in:devices", 2, nil, "next", nil ->
      {:ok,
       Jason.encode!(%{
         "sql" => "select ip, hostname from devices",
         "params" => [],
         "pagination" => %{"limit" => 2, "next_cursor" => "cursor-2"}
       })}
    end

    query_fn = fn "select ip, hostname from devices", [] ->
      {:ok,
       %Postgrex.Result{
         columns: ["ip", "hostname"],
         rows: [["10.0.0.1", "router-1"], ["10.0.0.2", "router-2"]]
       }}
    end

    assert {:ok, %{rows: rows, next_cursor: "cursor-2"}} =
             SRQLRunner.query_page("in:devices",
               limit: 2,
               direction: "next",
               translate_fn: translate_fn,
               query_fn: query_fn
             )

    assert rows == [
             %{"hostname" => "router-1", "ip" => "10.0.0.1"},
             %{"hostname" => "router-2", "ip" => "10.0.0.2"}
           ]
  end

  test "query_page suppresses next cursor when the page is short" do
    translate_fn = fn "in:devices", 2, nil, "next", nil ->
      {:ok,
       Jason.encode!(%{
         "sql" => "select ip from devices",
         "params" => [],
         "pagination" => %{"limit" => 2, "next_cursor" => "cursor-2"}
       })}
    end

    query_fn = fn "select ip from devices", [] ->
      {:ok, %Postgrex.Result{columns: ["ip"], rows: [["10.0.0.1"]]}}
    end

    assert {:ok, %{rows: [%{"ip" => "10.0.0.1"}], next_cursor: nil}} =
             SRQLRunner.query_page("in:devices",
               limit: 2,
               direction: "next",
               translate_fn: translate_fn,
               query_fn: query_fn
             )
  end

  test "query_page applies a custom text param decoder" do
    translate_fn = fn "in:devices ip:10.0.0.0/8", nil, nil, nil, nil ->
      {:ok,
       Jason.encode!(%{
         "sql" => "select ip from devices where ip <<= $1",
         "params" => [%{"t" => "text", "v" => "10.0.0.0/8"}]
       })}
    end

    query_fn = fn "select ip from devices where ip <<= $1", [{:decoded, "10.0.0.0/8"}] ->
      {:ok, %Postgrex.Result{columns: ["ip"], rows: []}}
    end

    text_param_decoder = fn value -> {:ok, {:decoded, value}} end

    assert {:ok, %{rows: [], next_cursor: nil}} =
             SRQLRunner.query_page("in:devices ip:10.0.0.0/8",
               translate_fn: translate_fn,
               query_fn: query_fn,
               text_param_decoder: text_param_decoder
             )
  end

  test "query_page decodes a valid date param" do
    translate_fn = fn "in:sweep_coverage time:last_30d", nil, nil, nil, nil ->
      {:ok,
       Jason.encode!(%{
         "sql" => "select day from sweep_coverage_daily where day >= $1",
         "params" => [%{"t" => "date", "v" => "2026-01-15"}]
       })}
    end

    query_fn = fn "select day from sweep_coverage_daily where day >= $1", [~D[2026-01-15]] ->
      {:ok, %Postgrex.Result{columns: ["day"], rows: [["2026-01-15"]]}}
    end

    assert {:ok, %{rows: [%{"day" => "2026-01-15"}], next_cursor: nil}} =
             SRQLRunner.query_page("in:sweep_coverage time:last_30d",
               translate_fn: translate_fn,
               query_fn: query_fn
             )
  end

  test "query_page rejects a malformed date param" do
    translate_fn = fn "in:sweep_coverage time:last_30d", nil, nil, nil, nil ->
      {:ok,
       Jason.encode!(%{
         "sql" => "select day from sweep_coverage_daily where day >= $1",
         "params" => [%{"t" => "date", "v" => "not-a-date"}]
       })}
    end

    query_fn = fn _sql, _params ->
      flunk("query_fn must not run when a param fails to decode")
    end

    assert {:error, :invalid_date_param} =
             SRQLRunner.query_page("in:sweep_coverage time:last_30d",
               translate_fn: translate_fn,
               query_fn: query_fn
             )
  end

  test "query returns only rows from the page result" do
    translate_fn = fn "in:devices", nil, nil, nil, nil ->
      {:ok, Jason.encode!(%{"sql" => "select ip from devices", "params" => []})}
    end

    query_fn = fn "select ip from devices", [] ->
      {:ok, %Postgrex.Result{columns: ["ip"], rows: [["10.0.0.1"]]}}
    end

    assert {:ok, [%{"ip" => "10.0.0.1"}]} =
             SRQLRunner.query("in:devices", translate_fn: translate_fn, query_fn: query_fn)
  end

  test "duckdb-tagged translations execute on the analytics query fn" do
    translate_fn = fn "in:timeseries_metrics time:last_24h", nil, nil, nil, nil ->
      {:ok,
       Jason.encode!(%{
         "sql" => "select count(*) from timeseries_metrics",
         "params" => [],
         "dialect" => "duckdb"
       })}
    end

    query_fn = fn _sql, _params ->
      flunk("primary Repo must not run duckdb SQL")
    end

    analytics_query_fn = fn "select count(*) from timeseries_metrics", [] ->
      {:ok, %Postgrex.Result{columns: ["count"], rows: [[3]]}}
    end

    assert {:ok, [%{"count" => 3}]} =
             SRQLRunner.query("in:timeseries_metrics time:last_24h",
               translate_fn: translate_fn,
               query_fn: query_fn,
               analytics_query_fn: analytics_query_fn
             )
  end

  test "duckdb-tagged translations fail closed without a head" do
    translate_fn = fn "in:timeseries_metrics time:last_24h", nil, nil, nil, nil ->
      {:ok,
       Jason.encode!(%{
         "sql" => "select 1",
         "params" => [],
         "dialect" => "duckdb"
       })}
    end

    assert {:error, :analytics_head_unavailable} =
             SRQLRunner.query("in:timeseries_metrics time:last_24h", translate_fn: translate_fn)
  end
end
