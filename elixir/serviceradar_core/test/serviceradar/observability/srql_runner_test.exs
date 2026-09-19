defmodule ServiceRadar.Observability.SRQLRunnerTest do
  # Not async: the routing tests move `cutover_datasets`, which is application
  # environment every other reader in the node shares.
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Observability.SRQLRunner

  defp put_cutover(datasets) do
    previous = Application.get_env(:serviceradar_core, StarRocks, [])

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(previous, :cutover_datasets, datasets)
    )

    on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, previous) end)
  end

  defp put_mysql(fun) do
    previous = Application.get_env(:serviceradar_core, StarRocks, [])
    Application.put_env(:serviceradar_core, StarRocks, Keyword.put(previous, :mysql, fun))
    on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, previous) end)
  end

  defp max_result(value) do
    {:ok,
     %Postgrex.Result{
       command: :select,
       columns: ["max"],
       rows: [[value]],
       num_rows: 1,
       connection_id: nil
     }}
  end

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

  # Background jobs must not answer from CNPG for a dataset the deployment
  # serves from the warehouse, or the same question gets two different answers
  # depending on which job asked it.
  test "a cut-over dataset compiles for the warehouse" do
    put_cutover([:logs])

    translate_fn = fn "in:logs limit:1", 1, nil, nil, mode ->
      assert mode == "starrocks"

      {:ok, Jason.encode!(%{"sql" => "SELECT id FROM serviceradar.logs", "params" => []})}
    end

    query_fn = fn "SELECT id FROM serviceradar.logs", [] ->
      {:ok, %Postgrex.Result{columns: ["id"], rows: [["log-alpha-0001"]]}}
    end

    assert {:ok, [%{"id" => "log-alpha-0001"}]} =
             SRQLRunner.query("in:logs limit:1",
               limit: 1,
               translate_fn: translate_fn,
               query_fn: query_fn
             )
  end

  test "a dataset that is not cut over still compiles for CNPG" do
    put_cutover([])

    translate_fn = fn "in:logs limit:1", 1, nil, nil, mode ->
      assert mode == nil

      {:ok, Jason.encode!(%{"sql" => "SELECT id FROM platform.logs", "params" => []})}
    end

    query_fn = fn "SELECT id FROM platform.logs", [] ->
      {:ok, %Postgrex.Result{columns: ["id"], rows: [["log-alpha-0001"]]}}
    end

    assert {:ok, [%{"id" => "log-alpha-0001"}]} =
             SRQLRunner.query("in:logs limit:1",
               limit: 1,
               translate_fn: translate_fn,
               query_fn: query_fn
             )
  end

  # Flows have no CNPG serving path, so a background reader is told so rather
  # than quietly reading a table the deployment may no longer write.
  test "flows refuse to run until the dataset is cut over" do
    put_cutover([])

    translate_fn = fn _q, _l, _c, _d, _m -> flunk("uncut-over flows must not compile") end
    query_fn = fn _sql, _params -> flunk("uncut-over flows must not reach a backend") end

    assert {:error, :starrocks_required} =
             SRQLRunner.query("in:flows time:last_1h limit:1",
               limit: 1,
               translate_fn: translate_fn,
               query_fn: query_fn
             )
  end

  # The compiler strips quotes off the entity token, so a router that cannot
  # read a quoted one resolves a different entity than the query that runs --
  # here, reading flows from CNPG while every other reader refuses them.
  test "a quoted entity routes exactly like an unquoted one" do
    put_cutover([:flows])

    translate_fn = fn _query, 1, nil, nil, mode ->
      assert mode == "starrocks"

      {:ok,
       Jason.encode!(%{
         "sql" => "SELECT id FROM serviceradar.ocsf_network_activity",
         "params" => []
       })}
    end

    query_fn = fn "SELECT id FROM serviceradar.ocsf_network_activity", [] ->
      {:ok, %Postgrex.Result{columns: ["id"], rows: [["flow-alpha-0001"]]}}
    end

    for query <- [
          ~s|in:"flows" time:last_1h limit:1|,
          ~s|in:'flows' time:last_1h limit:1|,
          ~s|in:FLOWS time:last_1h limit:1|
        ] do
      assert {:ok, [%{"id" => "flow-alpha-0001"}]} =
               SRQLRunner.query(query, limit: 1, translate_fn: translate_fn, query_fn: query_fn)
    end
  end

  # Same two guards the web API applies: a stale hourly view is recompiled
  # against the raw table, and a catalog reference is refused when the JDBC
  # catalog is not provisioned.
  test "a stale hourly view is recompiled against the raw warehouse table" do
    put_cutover([:flows])

    put_mysql(fn
      "SELECT MAX(`bucket`)" <> _ -> max_result(~N[1999-06-14 00:00:00])
      "SELECT MAX(`time`)" <> _ -> max_result(~N[1999-06-15 12:00:00])
    end)

    translate_fn = fn _query, 1, nil, nil, mode ->
      sql =
        if mode == "starrocks",
          do: "SELECT bucket FROM serviceradar.ocsf_network_activity_hourly",
          else: "SELECT time FROM serviceradar.ocsf_network_activity"

      {:ok, Jason.encode!(%{"sql" => sql, "params" => []})}
    end

    query_fn = fn sql, [] ->
      refute sql =~ "_hourly"
      {:ok, %Postgrex.Result{columns: ["time"], rows: [["1999-06-15 12:00:00"]]}}
    end

    assert {:ok, [_row]} =
             SRQLRunner.query("in:flows time:last_7d bucket:1h agg:sum",
               limit: 1,
               translate_fn: translate_fn,
               query_fn: query_fn
             )
  end

  test "a catalog reference is refused while the JDBC catalog is disabled" do
    put_cutover([:flows])

    translate_fn = fn _query, 1, nil, nil, "starrocks" ->
      {:ok,
       Jason.encode!(%{
         "sql" => "SELECT hostname FROM cnpg_platform.platform.ocsf_devices",
         "params" => []
       })}
    end

    query_fn = fn sql, _params -> flunk("catalog-disabled SQL must not be submitted: #{sql}") end

    assert {:error, {:starrocks_catalog_disabled, "cnpg_platform"}} =
             SRQLRunner.query("in:flows time:last_1h hostname:host01 limit:1",
               limit: 1,
               translate_fn: translate_fn,
               query_fn: query_fn
             )
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
end
