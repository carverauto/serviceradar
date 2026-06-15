defmodule ServiceRadar.Observability.CapacityForecasting.ModelTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.CapacityForecasting.Model

  @start ~U[2026-06-01 00:00:00Z]

  test "linear forecast computes projected value and exhaustion ETA" do
    points =
      for hour <- 0..47 do
        %{at: DateTime.add(@start, hour * 3_600, :second), value: 10.0 + hour}
      end

    assert {:ok, forecast} =
             Model.forecast(points,
               min_points: 24,
               horizon_seconds: 24 * 3_600,
               exhaustion_threshold: 80.0,
               model: :linear
             )

    assert forecast.model == "linear"
    assert_in_delta forecast.slope_per_second, 1.0 / 3_600.0, 1.0e-9
    assert_in_delta forecast.projected_value, 81.0, 0.001
    assert forecast.projected_exhaustion_at == DateTime.add(@start, 70 * 3_600, :second)
    assert forecast.confidence > 0.99
  end

  test "linear forecast sorts aggregate points before fitting the trend" do
    points =
      for hour <- 0..47 do
        %{at: DateTime.add(@start, hour * 3_600, :second), value: 5.0 + hour * 0.5}
      end

    shuffled_points = Enum.reverse(points)

    assert {:ok, ordered_forecast} =
             Model.forecast(points,
               min_points: 24,
               horizon_seconds: 12 * 3_600,
               exhaustion_threshold: 40.0,
               model: :linear
             )

    assert {:ok, shuffled_forecast} =
             Model.forecast(shuffled_points,
               min_points: 24,
               horizon_seconds: 12 * 3_600,
               exhaustion_threshold: 40.0,
               model: :linear
             )

    assert shuffled_forecast.window_started_at == ordered_forecast.window_started_at
    assert shuffled_forecast.window_ended_at == ordered_forecast.window_ended_at
    assert shuffled_forecast.projected_exhaustion_at == ordered_forecast.projected_exhaustion_at
    assert_in_delta shuffled_forecast.slope_per_second, ordered_forecast.slope_per_second, 1.0e-12
    assert_in_delta shuffled_forecast.projected_value, ordered_forecast.projected_value, 1.0e-9
  end

  test "linear forecast reports no exhaustion ETA when trend is flat or decreasing" do
    points =
      for hour <- 0..47 do
        %{at: DateTime.add(@start, hour * 3_600, :second), value: 90.0 - hour * 0.25}
      end

    assert {:ok, forecast} =
             Model.forecast(points,
               min_points: 24,
               horizon_seconds: 24 * 3_600,
               exhaustion_threshold: 100.0,
               model: :linear
             )

    assert forecast.model == "linear"
    assert forecast.slope_per_second < 0.0
    assert forecast.projected_value < forecast.current_value
    assert forecast.projected_exhaustion_at == nil
  end

  test "linear forecast yields no exhaustion when the crossing lands beyond the horizon" do
    # A near-zero positive slope would cross the threshold millennia out; the old code
    # rendered that as a year-5256 date. It must now collapse to nil (no projected exhaustion).
    points =
      for hour <- 0..47 do
        %{at: DateTime.add(@start, hour * 3_600, :second), value: 10.0 + hour * 0.0001}
      end

    assert {:ok, forecast} =
             Model.forecast(points,
               min_points: 24,
               horizon_seconds: 24 * 3_600,
               exhaustion_threshold: 100.0,
               model: :linear
             )

    assert forecast.slope_per_second > 0.0
    assert forecast.projected_exhaustion_at == nil
  end

  test "linear forecast yields no exhaustion when the threshold was already crossed in-window" do
    # Series is already above the threshold across the whole window; this is "already
    # exhausted", not a future forecast, so no (past-dated) exhaustion ETA is emitted.
    points =
      for hour <- 0..47 do
        %{at: DateTime.add(@start, hour * 3_600, :second), value: 150.0 + hour}
      end

    assert {:ok, forecast} =
             Model.forecast(points,
               min_points: 24,
               horizon_seconds: 24 * 3_600,
               exhaustion_threshold: 100.0,
               model: :linear
             )

    assert forecast.projected_exhaustion_at == nil
  end

  test "skips resources that do not have enough aggregate history" do
    points = [
      %{at: @start, value: 10.0},
      %{at: DateTime.add(@start, 3_600, :second), value: 11.0}
    ]

    assert {:skip, "insufficient_history", diagnostics} =
             Model.forecast(points, min_points: 3)

    assert diagnostics.sample_count == 2
    assert diagnostics.min_points == 3
  end

  test "auto model uses linear forecast when seasonality is not detected" do
    points =
      for hour <- 0..71 do
        %{at: DateTime.add(@start, hour * 3_600, :second), value: 40.0}
      end

    assert {:ok, forecast} =
             Model.forecast(points,
               min_points: 48,
               horizon_seconds: 24 * 3_600,
               seasonal_period: 24,
               model: :auto
             )

    assert forecast.model == "linear"
    assert forecast.sample_count == 72
    assert forecast.slope_per_second == 0.0
    assert forecast.projected_value == forecast.current_value
  end

  test "auto model uses additive Holt-Winters when seasonality is present" do
    points =
      for hour <- 0..71 do
        seasonal = if rem(hour, 24) in 8..17, do: 25.0, else: -10.0
        %{at: DateTime.add(@start, hour * 3_600, :second), value: 50.0 + seasonal + hour * 0.05}
      end

    assert {:ok, forecast} =
             Model.forecast(points,
               min_points: 48,
               horizon_seconds: 24 * 3_600,
               seasonal_period: 24,
               model: :auto
             )

    assert forecast.model == "holt_winters_additive"
    assert forecast.sample_count == 72
    assert forecast.projected_value > 0.0
  end
end
