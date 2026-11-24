defmodule ServiceRadarWebNG.HorizonIspAccountabilityModeTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadarWebNG.SRQL

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
