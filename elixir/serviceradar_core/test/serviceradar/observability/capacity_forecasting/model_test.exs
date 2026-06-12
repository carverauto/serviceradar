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
