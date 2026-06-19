defmodule ServiceRadarWebNGWeb.NetflowLive.DashboardWindowSpecTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.NetflowLive.Dashboard

  @moduletag :unit

  test "netflow window specs keep range, bucket, and bucket seconds together" do
    assert Dashboard.netflow_window_specs() == [
             {"1h", %{label: "Last 1 Hour", seconds: 3_600, bucket: "1m", bucket_seconds: 60}},
             {"6h", %{label: "Last 6 Hours", seconds: 21_600, bucket: "5m", bucket_seconds: 300}},
             {"24h", %{label: "Last 24 Hours", seconds: 86_400, bucket: "15m", bucket_seconds: 900}},
             {"7d", %{label: "Last 7 Days", seconds: 604_800, bucket: "1h", bucket_seconds: 3_600}},
             {"30d", %{label: "Last 30 Days", seconds: 2_592_000, bucket: "6h", bucket_seconds: 21_600}}
           ]
  end

  test "rate denominator follows the query time token and floors short spans by bucket" do
    assert Dashboard.netflow_rate_denominator_seconds("in:flows time:last_6h", "1h") == 21_600

    assert Dashboard.netflow_rate_denominator_seconds(
             "in:flows time:[2026-06-19T12:00:00Z,2026-06-19T12:00:30Z]",
             "1h"
           ) == 60
  end
end
