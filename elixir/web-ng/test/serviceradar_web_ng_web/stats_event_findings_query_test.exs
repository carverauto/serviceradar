defmodule ServiceRadarWebNGWeb.StatsEventFindingsQueryTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Stats.Query

  @moduletag :db_free

  test "builds finding rollup drill-down queries from the same predicate family as the rollup counts" do
    assert Query.anomaly_findings_data_query(time: "last_7d") ==
             "in:events finding_rollup:anomaly time:last_7d sort:time:desc"

    assert Query.capacity_at_risk_data_query(time: "last_7d") ==
             "in:events finding_rollup:capacity_at_risk time:last_7d sort:time:desc"

    assert Query.health_findings_data_query(time: "last_7d") ==
             "in:events finding_rollup:health time:last_7d sort:time:desc"
  end

  test "supports optional limit for event-list drill-downs" do
    assert Query.finding_rollup_data_query(:health, time: "last_24h", limit: 100) ==
             "in:events finding_rollup:health time:last_24h sort:time:desc limit:100"
  end

  test "rejects unsupported finding rollup groups" do
    assert_raise ArgumentError, ~r/unknown finding rollup kind/, fn ->
      Query.finding_rollup_data_query(:all_capacity)
    end
  end
end
