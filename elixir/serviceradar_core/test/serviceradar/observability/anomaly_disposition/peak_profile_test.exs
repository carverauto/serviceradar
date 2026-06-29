defmodule ServiceRadar.Observability.AnomalyDisposition.PeakProfileTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.AnomalyDisposition.PeakProfile

  defmodule StubRunner do
    @moduledoc false
    def query(_query, _opts) do
      {:ok,
       [
         %{
           "series" => "sr:ns03",
           "dow" => 2,
           "hod" => 9,
           "center" => 55.0,
           "p05" => 50.0,
           "p95" => 61.5,
           "bucket_count" => 8
         },
         %{
           "series" => "sr:ns03",
           "dow" => 3,
           "hod" => 9,
           "center" => 40.0,
           "p05" => 36.0,
           "p95" => 45.0,
           "bucket_count" => 7
         },
         # string-typed numerics (SRQL can return strings) for the same series, other hour
         %{
           "series" => "sr:ns99",
           "dow" => 2,
           "hod" => 9,
           "center" => "61.0",
           "p05" => "57.0",
           "p95" => "66.0",
           "bucket_count" => "9"
         }
       ]}
    end
  end

  defmodule EmptyRunner do
    @moduledoc false
    def query(_query, _opts), do: {:ok, []}
  end

  defmodule ErrorRunner do
    @moduledoc false
    def query(_query, _opts), do: {:error, :boom}
  end

  @ctx %{
    series_key: "svc/cpu/a",
    device_id: "sr:ns03",
    metric_class: "sysmon.cpu",
    metric_name: "cpu.usage_percent",
    dow: 2,
    hod: 9
  }

  test "peak_query scopes by metric + uses the profile_hour_of_week_peak verb" do
    q = PeakProfile.peak_query("sysmon.cpu", "cpu.usage_percent", "180d", 4000, "Etc/UTC")
    assert q =~ ~s|metric_type:"sysmon.cpu"|
    assert q =~ ~s|metric_name:"cpu.usage_percent"|
    assert q =~ "stats:profile_hour_of_week_peak(value)"
    assert q =~ "series:uid"
    assert q =~ ~s|timezone:"Etc/UTC"|
    # the verb reads max_value itself; agg:max would route to the (timezone-less) downsample path
    refute q =~ "agg:max"
  end

  test "returns the matching (series, dow, hod) row as center/scale/sample_count" do
    fetch = PeakProfile.fetcher(StubRunner)
    profile = fetch.(@ctx)
    assert profile.center == 55.0
    # scale = (p95 - center) / z95, so a peak at p95 scores z ~ 1.645
    assert_in_delta profile.scale, (61.5 - 55.0) / 1.644_853_626_951_472_2, 1.0e-9
    assert profile.sample_count == 8
  end

  test "parses string-typed numerics and matches the right series" do
    fetch = PeakProfile.fetcher(StubRunner)
    profile = fetch.(%{@ctx | device_id: "sr:ns99"})
    assert profile.center == 61.0
    assert profile.sample_count == 9
  end

  test "returns nil when no row matches the series/hour" do
    fetch = PeakProfile.fetcher(StubRunner)
    assert fetch.(%{@ctx | hod: 14}) == nil
  end

  defmodule PayloadRunner do
    @moduledoc false
    # the REAL SRQL result shape: each row's columns are wrapped under "payload"
    def query(_query, _opts) do
      {:ok,
       [
         %{
           "payload" => %{
             "series" => "sr:ns03",
             "dow" => 2,
             "hod" => 9,
             "center" => 59,
             "p95" => 61.6,
             "bucket_count" => 5
           }
         }
       ]}
    end
  end

  test "unwraps the SRQL payload envelope (the real row shape)" do
    profile = PeakProfile.fetcher(PayloadRunner).(@ctx)
    assert profile.center == 59.0
    assert profile.sample_count == 5
    assert_in_delta profile.scale, (61.6 - 59.0) / 1.644_853_626_951_472_2, 1.0e-9
  end

  test "returns nil on empty result, runner error, or missing metric scope" do
    assert PeakProfile.fetcher(EmptyRunner).(@ctx) == nil
    assert PeakProfile.fetcher(ErrorRunner).(@ctx) == nil
    assert PeakProfile.fetcher(StubRunner).(Map.delete(@ctx, :metric_class)) == nil
  end
end
