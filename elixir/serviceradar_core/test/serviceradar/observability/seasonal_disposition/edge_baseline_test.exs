defmodule ServiceRadar.Observability.SeasonalDisposition.EdgeBaselineTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.SeasonalDisposition.EdgeBaseline

  defp bucket(series_key, dow, hod, extra) do
    Map.merge(%{series_key: series_key, dow: dow, hod: hod, bucket_count: 8}, extra)
  end

  test "median_mad rows become robust center + MAD-derived sigma scale, grouped by series" do
    rows = [
      bucket("dev-a", 1, 9, %{center: 70.0, mad: 2.0}),
      bucket("dev-a", 1, 10, %{center: 12.5, mad: 0.5}),
      bucket("dev-b", 6, 23, %{center: 3.0, mad: 1.0})
    ]

    result = EdgeBaseline.build(rows, :median_mad)

    assert result |> Map.keys() |> Enum.sort() == ["dev-a", "dev-b"]
    assert %{"buckets" => buckets_a} = result["dev-a"]
    assert length(buckets_a) == 2

    nine = Enum.find(buckets_a, &(&1["hod"] == 9))
    assert nine["dow"] == 1
    assert nine["center"] == 70.0
    # 2.0 * 1.4826 MAD->sigma consistency constant.
    assert_in_delta nine["scale"], 2.9652, 1.0e-6
    assert nine["sample_count"] == 8

    assert %{"buckets" => [only_b]} = result["dev-b"]
    assert_in_delta only_b["scale"], 1.4826, 1.0e-6
  end

  test "p05p95 rows derive scale from the percentile span" do
    rows = [bucket("dev", 2, 3, %{center: 50.0, p05: 44.0, p95: 56.0})]

    assert %{"dev" => %{"buckets" => [bucket]}} = EdgeBaseline.build(rows, :p05p95)
    assert bucket["center"] == 50.0
    # (56 - 44) / 3.2897072539029457 ~= 3.6477
    assert_in_delta bucket["scale"], 12.0 / 3.2897072539029457, 1.0e-9
  end

  test "mean_stddev rows derive center + stddev from the moments" do
    # values [1,2,3,4,5]: count 5, sum 15 (mean 3), sum_sq 55, sample stddev sqrt(2.5).
    rows = [
      bucket("dev", 0, 0, %{bucket_count: 5, bucket_sum: 15.0, bucket_sum_sq: 55.0})
    ]

    assert %{"dev" => %{"buckets" => [bucket]}} = EdgeBaseline.build(rows, :mean_stddev)
    assert_in_delta bucket["center"], 3.0, 1.0e-9
    assert_in_delta bucket["scale"], :math.sqrt(2.5), 1.0e-9
    assert bucket["sample_count"] == 5
  end

  test "accepts string-keyed rows and drops out-of-range or incomplete buckets" do
    rows = [
      %{
        "series_key" => "dev",
        "dow" => 3,
        "hod" => 14,
        "center" => 40.0,
        "mad" => 1.0,
        "bucket_count" => 6
      },
      # out-of-range dow / hod -> dropped
      %{series_key: "dev", dow: 9, hod: 14, center: 1.0, mad: 1.0},
      %{series_key: "dev", dow: 3, hod: 99, center: 1.0, mad: 1.0},
      # missing center/mad -> dropped
      %{series_key: "dev", dow: 4, hod: 4, bucket_count: 6}
    ]

    assert %{"dev" => %{"buckets" => [only]}} = EdgeBaseline.build(rows, :median_mad)
    assert only["dow"] == 3 and only["hod"] == 14
    assert only["sample_count"] == 6
  end

  test "empty input yields an empty payload (rolling-only, back-compat)" do
    assert EdgeBaseline.build([], :median_mad) == %{}
  end
end
