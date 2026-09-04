defmodule ServiceRadar.FlowAttribution.CorrelationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.FlowAttribution.Correlation

  describe "correlation_sql/0" do
    test "includes public endpoint VIP→backend DNAT join paths" do
      sql = Correlation.correlation_sql()

      assert sql =~ "public_endpoints_current"
      assert sql =~ "public_endpoint_backends"
      assert sql =~ "endpoint_targets"
      assert sql =~ "exposure_rank"
      assert sql =~ "backend_ip_norm"
      assert sql =~ "vip_ip_norm"
      assert sql =~ "public_endpoint"
      assert sql =~ "public_endpoint_backfills"
      # IPv4-mapped IPv6 normalization for pod attributions
      assert sql =~ "::ffff:"
    end

    test "stamps public_endpoint into attributed flow payload" do
      sql = Correlation.correlation_sql()

      assert sql =~ "'public_endpoint', candidates.public_endpoint"
      assert sql =~ "'event_type', 'attributed_flow'"
    end

    test "keeps existing exact and listener match ranks" do
      sql = Correlation.correlation_sql()

      assert sql =~ "0 AS match_rank"
      assert sql =~ "1 AS match_rank"
      assert sql =~ "2 AS match_rank"
      assert sql =~ "a.remote_ip IN ('0.0.0.0', '::')"
    end

    test "orders public endpoint candidates after every local strategy" do
      sql = Correlation.correlation_sql()

      assert sql =~ "3 + pe.exposure_rank AS match_rank"
      refute sql =~ ~r/^\s*pe\.exposure_rank AS match_rank/m
    end

    test "prefers container-scoped process owners when ranks tie" do
      sql = Correlation.correlation_sql()

      assert sql =~ "(container_id IS NULL) ASC"
    end
  end
end
