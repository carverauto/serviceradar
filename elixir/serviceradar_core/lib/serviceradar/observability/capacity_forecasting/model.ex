defmodule ServiceRadar.Observability.CapacityForecasting.Model do
  @moduledoc """
  Pure capacity forecasting helpers.

  The scheduled worker owns I/O. This module only turns ordered aggregate
  samples into a forecast snapshot, which keeps retry behavior and tests
  deterministic.
  """

  @default_horizon_seconds 90 * 24 * 60 * 60
  @default_min_points 24
  @default_period 24
  @seasonal_strength_threshold 0.25
  @epsilon 1.0e-9

  @type point :: %{required(:at) => DateTime.t(), required(:value) => number()}
  @type forecast :: %{
          model: String.t(),
          current_value: float(),
          slope_per_second: float(),
          intercept: float(),
          projected_value: float(),
          projected_exhaustion_at: DateTime.t() | nil,
          confidence: float(),
          lower_bound: float(),
          upper_bound: float(),
          sample_count: pos_integer(),
          window_started_at: DateTime.t(),
          window_ended_at: DateTime.t(),
          diagnostics: map()
        }

  @spec forecast([point()], keyword()) ::
          {:ok, forecast()} | {:skip, String.t(), map()}
  def forecast(points, opts \\ []) when is_list(points) do
    points = normalize_points(points)
    min_points = positive_integer(Keyword.get(opts, :min_points), @default_min_points)

    if length(points) < min_points do
      {:skip, "insufficient_history", %{sample_count: length(points), min_points: min_points}}
    else
      model_choice = Keyword.get(opts, :model, :auto)
      period = positive_integer(Keyword.get(opts, :seasonal_period), @default_period)

      cond do
        model_choice in [:seasonal, "seasonal", :holt_winters, "holt_winters"] ->
          seasonal_forecast(points, opts, period)

        model_choice in [:auto, "auto"] and seasonal?(points, period) ->
          seasonal_forecast(points, opts, period)

        true ->
          linear_forecast(points, opts)
      end
    end
  end

  @spec linear_forecast([point()], keyword()) :: {:ok, forecast()}
  def linear_forecast(points, opts \\ []) when is_list(points) do
    points = normalize_points(points)
    first_at = first_at(points)
    xs = Enum.map(points, &DateTime.diff(&1.at, first_at, :second))
    ys = Enum.map(points, &(&1.value * 1.0))

    {slope, intercept} = least_squares(xs, ys)

    horizon_seconds =
      positive_integer(Keyword.get(opts, :horizon_seconds), @default_horizon_seconds)

    threshold = Keyword.get(opts, :exhaustion_threshold)
    {last_point, last_x} = {List.last(points), List.last(xs)}
    projected_x = last_x + horizon_seconds
    projected_value = intercept + slope * projected_x
    residuals = residuals(xs, ys, slope, intercept)
    rmse = rmse(residuals)

    {:ok,
     %{
       model: "linear",
       current_value: last_point.value * 1.0,
       slope_per_second: slope,
       intercept: intercept,
       projected_value: projected_value,
       projected_exhaustion_at: exhaustion_at(first_at, last_x, slope, intercept, threshold),
       confidence: confidence(rmse, ys, threshold),
       lower_bound: projected_value - 1.96 * rmse,
       upper_bound: projected_value + 1.96 * rmse,
       sample_count: length(points),
       window_started_at: first_at,
       window_ended_at: last_point.at,
       diagnostics: %{
         "rmse" => rmse,
         "horizon_seconds" => horizon_seconds,
         "model" => "linear"
       }
     }}
  end

  defp seasonal_forecast(points, opts, period) do
    case holt_winters(points, opts, period) do
      {:ok, forecast} -> {:ok, forecast}
      :not_enough_seasonal_history -> linear_forecast(points, opts)
    end
  end

  defp holt_winters(points, opts, period) do
    points = normalize_points(points)

    if length(points) < period * 2 do
      :not_enough_seasonal_history
    else
      values = Enum.map(points, &(&1.value * 1.0))
      first_at = first_at(points)
      step_seconds = median_step_seconds(points)

      horizon_seconds =
        positive_integer(Keyword.get(opts, :horizon_seconds), @default_horizon_seconds)

      steps = max(1, div(horizon_seconds, step_seconds))
      alpha = valid_ratio(Keyword.get(opts, :alpha), 0.35)
      beta = valid_ratio(Keyword.get(opts, :beta), 0.05)
      gamma = valid_ratio(Keyword.get(opts, :gamma), 0.25)
      threshold = Keyword.get(opts, :exhaustion_threshold)
      initial_seasons = initial_seasonals(values, period)
      initial_trend = initial_trend(values, period)

      {%{level: level, trend: trend, seasons: seasons}, residuals} =
        values
        |> Enum.with_index()
        |> Enum.reduce(
          {%{level: hd(values), trend: initial_trend, seasons: initial_seasons}, []},
          fn {value, index}, {state, residual_acc} ->
            season = Map.get(state.seasons, rem(index, period), 0.0)
            fitted = state.level + state.trend + season
            next_level = alpha * (value - season) + (1.0 - alpha) * (state.level + state.trend)
            next_trend = beta * (next_level - state.level) + (1.0 - beta) * state.trend
            next_season = gamma * (value - next_level) + (1.0 - gamma) * season

            next_state = %{
              level: next_level,
              trend: next_trend,
              seasons: Map.put(state.seasons, rem(index, period), next_season)
            }

            {next_state, [value - fitted | residual_acc]}
          end
        )

      projected_value = project_seasonal(level, trend, seasons, length(values), period, steps)
      current_value = List.last(values)
      slope = (projected_value - current_value) / horizon_seconds
      rmse = rmse(Enum.reverse(residuals))
      last_at = List.last(points).at

      {:ok,
       %{
         model: "holt_winters_additive",
         current_value: current_value,
         slope_per_second: slope,
         intercept: level,
         projected_value: projected_value,
         projected_exhaustion_at:
           seasonal_exhaustion_at(
             level,
             trend,
             seasons,
             length(values),
             period,
             step_seconds,
             threshold,
             last_at,
             steps
           ),
         confidence: confidence(rmse, values, threshold),
         lower_bound: projected_value - 1.96 * rmse,
         upper_bound: projected_value + 1.96 * rmse,
         sample_count: length(points),
         window_started_at: first_at,
         window_ended_at: last_at,
         diagnostics: %{
           "rmse" => rmse,
           "horizon_seconds" => horizon_seconds,
           "period" => period,
           "step_seconds" => step_seconds,
           "model" => "holt_winters_additive"
         }
       }}
    end
  end

  @spec least_squares([number()], [number()]) :: {float(), float()}
  def least_squares([_ | _] = xs, ys) when length(xs) == length(ys) do
    n = length(xs) * 1.0
    sum_x = Enum.sum(xs) * 1.0
    sum_y = Enum.sum(ys) * 1.0
    sum_xx = xs |> Enum.map(&(&1 * &1)) |> Enum.sum() |> Kernel.*(1.0)
    sum_xy = xs |> Enum.zip(ys) |> Enum.map(fn {x, y} -> x * y end) |> Enum.sum() |> Kernel.*(1.0)
    denominator = n * sum_xx - sum_x * sum_x

    if abs(denominator) < @epsilon do
      {0.0, sum_y / n}
    else
      slope = (n * sum_xy - sum_x * sum_y) / denominator
      intercept = (sum_y - slope * sum_x) / n
      {slope, intercept}
    end
  end

  defp normalize_points(points) do
    points
    |> Enum.map(&normalize_point/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&DateTime.to_unix(&1.at, :microsecond))
  end

  defp normalize_point(%{at: %DateTime{} = at, value: value}) when is_number(value) do
    %{at: DateTime.truncate(at, :microsecond), value: value * 1.0}
  end

  defp normalize_point(%{"at" => %DateTime{} = at, "value" => value}) when is_number(value) do
    %{at: DateTime.truncate(at, :microsecond), value: value * 1.0}
  end

  defp normalize_point(_), do: nil

  defp first_at([%{at: at} | _]), do: at

  defp residuals(xs, ys, slope, intercept) do
    xs
    |> Enum.zip(ys)
    |> Enum.map(fn {x, y} -> y - (intercept + slope * x) end)
  end

  defp rmse([]), do: 0.0

  defp rmse(residuals) do
    residuals
    |> Enum.map(&(&1 * &1))
    |> Enum.sum()
    |> Kernel./(max(length(residuals), 1))
    |> :math.sqrt()
  end

  defp exhaustion_at(_first_at, _last_x, slope, _intercept, _threshold) when slope <= 0.0, do: nil

  defp exhaustion_at(_first_at, _last_x, _slope, _intercept, threshold)
       when not is_number(threshold), do: nil

  defp exhaustion_at(first_at, last_x, slope, intercept, threshold) do
    cross_x = (threshold - intercept) / slope

    cond do
      cross_x < 0 ->
        nil

      cross_x <= last_x ->
        DateTime.add(first_at, round(last_x), :second)

      true ->
        DateTime.add(first_at, round(cross_x), :second)
    end
  end

  defp seasonal_exhaustion_at(
         _level,
         _trend,
         _seasons,
         _count,
         _period,
         _step_seconds,
         threshold,
         _last_at,
         _steps
       )
       when not is_number(threshold), do: nil

  defp seasonal_exhaustion_at(
         level,
         trend,
         seasons,
         count,
         period,
         step_seconds,
         threshold,
         last_at,
         steps
       ) do
    Enum.find_value(1..steps, fn step ->
      value = project_seasonal(level, trend, seasons, count, period, step)

      if value >= threshold do
        DateTime.add(last_at, step * step_seconds, :second)
      end
    end)
  end

  defp project_seasonal(level, trend, seasons, count, period, step) do
    level + step * trend + Map.get(seasons, rem(count + step - 1, period), 0.0)
  end

  defp median_step_seconds([_]), do: 3_600

  defp median_step_seconds(points) do
    steps =
      points
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [%{at: a}, %{at: b}] -> max(DateTime.diff(b, a, :second), 1) end)
      |> Enum.sort()

    Enum.at(steps, div(length(steps), 2), 3_600)
  end

  defp initial_trend(values, period) do
    first = Enum.take(values, period)
    second = values |> Enum.drop(period) |> Enum.take(period)

    if length(second) == period do
      (Enum.sum(second) / period - Enum.sum(first) / period) / period
    else
      0.0
    end
  end

  defp initial_seasonals(values, period) do
    period_values = Enum.take(values, period)
    average = Enum.sum(period_values) / max(length(period_values), 1)

    period_values
    |> Enum.with_index()
    |> Map.new(fn {value, index} -> {index, value - average} end)
  end

  defp seasonal?(points, period) when length(points) >= period * 2 do
    values = Enum.map(points, & &1.value)
    seasonals = values |> initial_seasonals(period) |> Map.values()
    seasonal_amplitude = mean_abs(seasonals)
    total_std = stddev(values)

    total_std > @epsilon and seasonal_amplitude / total_std >= @seasonal_strength_threshold
  end

  defp seasonal?(_points, _period), do: false

  defp confidence(rmse, values, threshold) do
    scale =
      cond do
        is_number(threshold) and threshold > 0 -> threshold
        range(values) > @epsilon -> range(values)
        true -> max(abs(Enum.sum(values) / max(length(values), 1)), 1.0)
      end

    (1.0 - rmse / scale)
    |> max(0.0)
    |> min(1.0)
  end

  defp range(values), do: Enum.max(values) - Enum.min(values)

  defp stddev(values) do
    mean = Enum.sum(values) / max(length(values), 1)

    values
    |> Enum.map(&:math.pow(&1 - mean, 2))
    |> Enum.sum()
    |> Kernel./(max(length(values) - 1, 1))
    |> :math.sqrt()
  end

  defp mean_abs(values) do
    values
    |> Enum.map(&abs/1)
    |> Enum.sum()
    |> Kernel./(max(length(values), 1))
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp valid_ratio(value, _default) when is_float(value) and value > 0.0 and value < 1.0,
    do: value

  defp valid_ratio(_value, default), do: default
end
