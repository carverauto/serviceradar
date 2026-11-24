defmodule ServiceRadarWebNG.HorizonIspAccountabilityModeTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.SRQL
  alias ServiceRadarWebNGWeb.Api.QueryController

  @moduletag :db_free

  @events_scope %{permissions: MapSet.new(["observability.events.view"])}
  @traces_scope %{permissions: MapSet.new(["observability.traces.view"])}

  setup do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    on_exit(fn ->
      Application.put_env(:serviceradar_core, StarRocks, prev)
    end)

    %{prev: prev}
  end

  test "refuses with :starrocks_required when StarRocks is disabled even with explicit mode overrides",
       %{prev: prev} do
    mysql = fn sql -> flunk("disabled StarRocks must not execute SQL: #{sql}") end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:enabled, false)
      |> Keyword.put(:mysql, mysql)
    )

    query = "in:horizon_isp_accountability time:last_24h limit:5"

    assert {:error, :forbidden} = SRQL.query(query, %{scope: @traces_scope})
    assert {:error, :starrocks_required} = SRQL.query(query, %{scope: @events_scope})

    for mode <- ["postgres", "cnpg", "starrocks", "starrocks_raw"] do
      assert {:error, :starrocks_required} =
               SRQL.query(query, %{scope: @events_scope, mode: mode})
    end
  end

  test "compiles via Rust NIF, routes to StarRocks, and returns viz metadata when enabled",
       %{prev: prev} do
    parent = self()

    mysql = fn sql ->
      send(parent, {:starrocks_query, sql})

      {:ok,
       postgrex_result(
         [
           "bucket_hour",
           "asn",
           "as_org",
           "target_id",
           "forwarding_loss_pct",
           "avg_rtt_ms",
           "max_rtt_ms",
           "mtu_blackhole_count",
           "first_blame_tier"
         ],
         [["2026-11-24 01:00:00", 13_335, "Cloudflare", "tgt-1", 2.5, 14.2, 22.8, 1, "pmtud_blackhole"]]
       )}
    end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:enabled, true)
      |> Keyword.put(:cutover_datasets, [])
      |> Keyword.put(:mysql, mysql)
    )

    query =
      "in:horizon_isp_accountability asn:13335 as_org:Cloudflare target_id:tgt-1 mtu_blackhole_count:>0 time:last_24h sort:forwarding_loss_pct:desc limit:10"

    assert {:ok, %{"results" => [row], "viz" => viz, "error" => nil}} =
             SRQL.query(query, %{scope: @events_scope, mode: "postgres"})

    assert row["asn"] == 13_335
    assert row["as_org"] == "Cloudflare"
    assert row["first_blame_tier"] == "pmtud_blackhole"
    assert is_map(viz) and viz["columns"] != []

    col_names = Enum.map(viz["columns"], & &1["name"])
    assert "bucket_hour" in col_names
    assert "mtu_blackhole_count" in col_names
    assert "first_blame_tier" in col_names

    assert_received {:starrocks_query, sql}
    assert sql =~ "FROM serviceradar.horizon_isp_accountability_mv"
    assert sql =~ "`asn` = 13335"
    assert sql =~ "`as_org` = 'Cloudflare'"
    assert sql =~ "`target_id` = 'tgt-1'"
    assert sql =~ "`mtu_blackhole_count` > 0"
    assert sql =~ "`bucket_hour` >="
    assert sql =~ "`bucket_hour` <="
    assert sql =~ "`day` >= date_trunc('day', '"
    assert sql =~ "`day` <= '"
    refute sql =~ "`time` >="
    assert sql =~ "ORDER BY `forwarding_loss_pct` DESC"
  end

  test "maps sort:time:asc to bucket_hour and rejects unsupported filters/clauses", %{prev: prev} do
    parent = self()

    mysql = fn sql ->
      send(parent, {:starrocks_query, sql})
      {:ok, postgrex_result(["bucket_hour", "asn"], [["2026-11-24 01:00:00", 13_335]])}
    end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:enabled, true)
      |> Keyword.put(:mysql, mysql)
    )

    assert {:ok, %{"results" => [_]}} =
             SRQL.query("in:horizon_isp_accountability sort:time:asc limit:5", %{
               scope: @events_scope
             })

    assert_received {:starrocks_query, sort_sql}
    assert sort_sql =~ "ORDER BY `bucket_hour` ASC"

    assert {:error, msg} =
             SRQL.query("in:horizon_isp_accountability hop_ttl:1 limit:5", %{
               scope: @events_scope
             })

    assert to_string(msg) =~ "hop_ttl"

    assert {:error, _} =
             SRQL.query("in:horizon_isp_accountability stats:count() as n", %{
               scope: @events_scope
             })

    assert {:error, reason} =
             ServiceRadarSRQL.Native.translate(
               "in:horizon_isp_accountability limit:5",
               nil,
               nil,
               nil,
               nil
             )

    assert to_string(reason) =~ "StarRocks"
  end

  test "HTTP QueryController enforces RBAC, StarRocks-only refusal, and JSON contract", %{
    prev: prev
  } do
    parent = self()
    events_scope = %Scope{user: nil, permissions: MapSet.new(["observability.events.view"])}
    traces_scope = %Scope{user: nil, permissions: MapSet.new(["observability.traces.view"])}

    fail_mysql = fn sql -> flunk("refused HTTP query must not execute SQL: #{sql}") end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:enabled, false)
      |> Keyword.put(:mysql, fail_mysql)
    )

    for scope <- [traces_scope, nil],
        query <- [
          "in:horizon_isp_accountability time:last_24h limit:5",
          "IN:horizon_isp_accountability limit:5",
          "in:horizon_paths limit:5 IN:horizon_isp_accountability"
        ] do
      conn = post_query(scope, %{"query" => query})
      assert conn.status == 403
      assert %{"error" => "forbidden"} = Jason.decode!(conn.resp_body)
    end

    alias_conn = post_query(events_scope, %{"query" => "in:horizon_isp_accountability_mv limit:5"})
    assert alias_conn.status == 403
    assert %{"error" => "forbidden"} = Jason.decode!(alias_conn.resp_body)

    for extra <- [%{}, %{"mode" => "starrocks"}, %{"mode" => "cnpg"}] do
      params = Map.merge(%{"query" => "in:horizon_isp_accountability time:last_24h limit:5"}, extra)
      conn = post_query(events_scope, params)
      assert conn.status == 400
      assert %{"error" => "starrocks_required"} = Jason.decode!(conn.resp_body)
    end

    columns = [
      "day",
      "bucket_hour",
      "asn",
      "as_org",
      "target_id",
      "forwarding_loss_pct",
      "avg_rtt_ms",
      "max_rtt_ms",
      "mtu_blackhole_count",
      "min_effective_mtu",
      "active_outage_count",
      "bgp_anomaly_count",
      "bgp_zombie_count",
      "first_blame_tier",
      "sample_count"
    ]

    row_values = [
      ~N[2026-11-23 00:00:00],
      ~N[2026-11-23 14:00:00],
      64_512,
      "O'Reilly\\ISP",
      "tgt-edge-01",
      3.25,
      18.5,
      31.0,
      1,
      nil,
      2,
      1,
      0,
      "bgp_hijack",
      42
    ]

    mysql = fn sql ->
      send(parent, {:starrocks_http_query, sql})
      {:ok, postgrex_result(columns, [row_values])}
    end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:enabled, true)
      |> Keyword.put(:cutover_datasets, [])
      |> Keyword.put(:mysql, mysql)
    )

    ok_conn =
      post_query(events_scope, %{
        "query" =>
          ~S|in:horizon_isp_accountability as_org:"O'Reilly\\ISP" asn:(64512,64513) !mtu_blackhole_count:(99,100) time:[2026-11-23T14:00:00Z,2026-11-23T15:00:00Z] sort:day:asc,forwarding_loss_pct:desc limit:10|,
        "mode" => "cnpg"
      })

    assert ok_conn.status == 200
    body = Jason.decode!(ok_conn.resp_body)
    assert body["error"] == nil
    assert body["schema"]["columns"] == columns
    assert [row] = body["results"]
    assert row["day"] == "2026-11-23T00:00:00Z"
    assert row["bucket_hour"] == "2026-11-23T14:00:00Z"
    assert row["asn"] == 64_512
    assert row["as_org"] == "O'Reilly\\ISP"
    assert row["min_effective_mtu"] == nil
    assert row["first_blame_tier"] == "bgp_hijack"
    assert row["sample_count"] == 42

    assert_received {:starrocks_http_query, sql}
    assert sql =~ "FROM serviceradar.horizon_isp_accountability_mv"
    assert sql =~ "`as_org` = 'O''Reilly\\\\ISP'"
    assert sql =~ "`asn` IN (64512, 64513)"
    assert sql =~ "`mtu_blackhole_count` NOT IN (99, 100)"
    assert sql =~ "`day` >= date_trunc('day', '2026-11-23 14:00:00.000000')"
    assert sql =~ "`day` <= '2026-11-23 15:00:00.000000'"
    assert sql =~ "ORDER BY `day` ASC NULLS LAST, `forwarding_loss_pct` DESC NULLS FIRST"

    for invalid_query <- [
          "in:horizon_isp_accountability sort:unknown_field:asc",
          "in:horizon_isp_accountability forwarding_loss_pct:NaN",
          "in:horizon_isp_accountability avg_rtt_ms:>inf",
          "in:horizon_isp_accountability min_effective_mtu:9999999999999",
          "in:horizon_isp_accountability asn:()",
          "in:horizon_isp_accountability bucket:1h",
          "in:horizon_isp_accountability other:true"
        ] do
      bad_conn = post_query(events_scope, %{"query" => invalid_query})
      assert bad_conn.status == 400, "expected 400 for #{invalid_query}, got #{bad_conn.status}"
      assert %{"error" => error_msg} = Jason.decode!(bad_conn.resp_body)
      assert is_binary(error_msg) and error_msg != ""
      refute_received {:starrocks_http_query, _}
    end
  end

  test "query_arrow encodes all 15 columns into Arrow IPC and enforces RBAC and StarRocks gating",
       %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:enabled, false)
      |> Keyword.put(:mysql, fn sql -> flunk("disabled StarRocks must not run: #{sql}") end)
    )

    query = "in:horizon_isp_accountability time:last_24h limit:5"

    assert {:error, :forbidden} = SRQL.query_arrow(query, %{scope: @traces_scope})
    assert {:error, :starrocks_required} = SRQL.query_arrow(query, %{scope: @events_scope})

    columns = [
      "day",
      "bucket_hour",
      "asn",
      "as_org",
      "target_id",
      "forwarding_loss_pct",
      "avg_rtt_ms",
      "max_rtt_ms",
      "mtu_blackhole_count",
      "min_effective_mtu",
      "active_outage_count",
      "bgp_anomaly_count",
      "bgp_zombie_count",
      "first_blame_tier",
      "sample_count"
    ]

    row = [
      ~N[2026-11-23 00:00:00],
      ~N[2026-11-23 14:00:00],
      64_512,
      "Example Transit",
      "tgt-arrow-01",
      1.75,
      11.4,
      19.2,
      0,
      nil,
      0,
      0,
      0,
      "isp_transit",
      12
    ]

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:enabled, true)
      |> Keyword.put(:mysql, fn _sql -> {:ok, postgrex_result(columns, [row])} end)
    )

    assert {:ok, %{payload: payload, schema: %{"columns" => ^columns}, viz: viz}} =
             SRQL.query_arrow(query, %{scope: @events_scope})

    assert is_binary(payload)
    assert binary_part(payload, 0, 6) == "ARROW1"
    assert binary_part(payload, byte_size(payload) - 6, 6) == "ARROW1"
    assert Enum.map(viz["columns"], & &1["name"]) == columns
  end

  defp post_query(scope, params) do
    "POST"
    |> Plug.Test.conn("/api/query")
    |> Plug.Conn.assign(:current_scope, scope)
    |> QueryController.execute(params)
  end

  defp postgrex_result(columns, rows) do
    %Postgrex.Result{
      command: :select,
      columns: columns,
      rows: rows,
      num_rows: length(rows),
      connection_id: nil
    }
  end
end
