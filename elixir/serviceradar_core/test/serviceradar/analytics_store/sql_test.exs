defmodule ServiceRadar.AnalyticsStore.SQLTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore
  alias ServiceRadar.AnalyticsStore.SQL
  alias ServiceRadar.Repo

  test "postgres translations stay on the primary repo" do
    assert SQL.repo_for_translation(%{"sql" => "select 1"}) == Repo
    assert SQL.repo_for_translation(%{"dialect" => "postgres"}) == Repo
  end

  test "duckdb translations fail closed without an analytics head" do
    assert SQL.repo_for_translation(%{"dialect" => "duckdb"}) ==
             {:error, :analytics_head_unavailable}
  end

  test "duckdb translations can inject a test query fn without a live head" do
    assert SQL.repo_for_translation(%{"dialect" => "duckdb"},
             analytics_query_fn: fn _, _ -> :ok end
           ) ==
             ServiceRadar.AnalyticsRepo
  end

  test "flipped table selects AnalyticsRepo only when the head is up" do
    cfg =
      AnalyticsStore.Config.validate!(
        AnalyticsStore.Config.load(
          driver: :pg_duckdb,
          storage: :filesystem,
          filesystem_path: "/var/lib/serviceradar/analytics",
          head_host: "analytics-head",
          tables: "timeseries_metrics"
        )
      )

    assert SQL.repo_for_table("timeseries_metrics", config: cfg) ==
             {:error, :analytics_head_unavailable}

    assert SQL.repo_for_table("ocsf_network_activity", config: cfg, repo: Repo) == Repo
  end

  test "drivers_json is empty on the timescale default" do
    assert SQL.drivers_json(config: AnalyticsStore.Config.load([])) == "{}"
  end
end
