defmodule ServiceRadar.AnalyticsStore.ViewsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.Views
  alias ServiceRadar.ColdTier.Registry

  test "S3 view globs published hive partitions only" do
    {:ok, entry} = Registry.fetch("timeseries_metrics")
    sql = Views.view_sql(s3_cfg(), entry)

    assert sql =~ ~s(CREATE VIEW platform."timeseries_metrics")

    assert sql =~
             "s3://serviceradar-demo-analytics/analytics/v1/timeseries_metrics/date=*/*.parquet"

    assert sql =~ "hive_partitioning := true"
    assert sql =~ ~s("_partition_date")
    assert sql =~ "r['date']"
    refute sql =~ "_staging"
    refute sql =~ "fdw_primary"
    refute sql =~ "UNION ALL"
    refute sql =~ "postgres_fdw"
    refute sql =~ "serviceradar-control-plane-db-backups"
  end

  test "filesystem view uses the data-dir prefix" do
    {:ok, entry} = Registry.fetch("ocsf_network_activity")

    cfg =
      Config.load(
        driver: :pg_duckdb,
        storage: :filesystem,
        filesystem_path: "/var/lib/serviceradar/analytics",
        head_host: "analytics-head"
      )

    sql = Views.view_sql(cfg, entry)

    assert sql =~
             "/var/lib/serviceradar/analytics/analytics/v1/ocsf_network_activity/date=*/*.parquet"

    refute sql =~ "_staging"
  end

  test "ensure_all only rebuilds flipped tables" do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    query = fn _conn, sql, _params ->
      Agent.update(agent, fn acc -> [sql | acc] end)
      :ok
    end

    assert :ok = Views.ensure_all(:conn, s3_cfg(tables: "timeseries_metrics"), query: query)
    sqls = Agent.get(agent, &Enum.reverse/1)

    assert Enum.any?(sqls, &(&1 =~ ~s(CREATE VIEW platform."timeseries_metrics")))
    refute Enum.any?(sqls, &(&1 =~ ~s(CREATE VIEW platform."ocsf_network_activity")))
    refute Enum.any?(sqls, &(&1 =~ "UNION ALL"))
  end

  defp s3_cfg(opts \\ []) do
    Config.load(
      Keyword.merge(
        [
          driver: :pg_duckdb,
          storage: :s3,
          s3_bucket_url: "s3://serviceradar-demo-analytics",
          s3_access_key_id: "id",
          s3_secret_access_key: "secret",
          s3_endpoint: "us-ord-10.linodeobjects.com",
          head_host: "analytics-head"
        ],
        opts
      )
    )
  end
end
