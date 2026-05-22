defmodule ServiceRadar.Monitoring.ServiceLevelObjectiveEvaluator do
  @moduledoc """
  Computes persisted SLO evaluation attributes from request or window observations.
  """

  @basis_points 10_000
  @default_budget_warning_basis_points 2_500

  @type objective :: struct() | map()

  @spec evaluate(objective(), map()) :: {:ok, map()} | {:error, atom()}
  def evaluate(slo, attrs) do
    case value(slo, :slo_kind) do
      :window_based -> evaluate_window_based(slo, attrs)
      "window_based" -> evaluate_window_based(slo, attrs)
      :request_based -> evaluate_request_based(slo, attrs)
      "request_based" -> evaluate_request_based(slo, attrs)
      nil -> evaluate_request_based(slo, attrs)
      _other -> {:error, :unsupported_slo_kind}
    end
  end

  @spec evaluate_request_based(objective(), map()) :: {:ok, map()} | {:error, atom()}
  def evaluate_request_based(slo, attrs) do
    with {:ok, base} <- base_attrs(slo, attrs),
         {:ok, eligible_events} <- non_negative_integer(attrs, :eligible_events),
         {:ok, good_events} <- non_negative_integer(attrs, :good_events),
         true <- good_events <= eligible_events || {:error, :good_events_exceed_eligible_events} do
      bad_events = Map.get(attrs, :bad_events, eligible_events - good_events)
      bad_events = max(to_integer(bad_events), 0)

      totals =
        evaluation_totals(
          eligible_events,
          good_events,
          bad_events,
          base.goal_basis_points,
          warning_threshold(slo)
        )

      {:ok,
       base
       |> Map.merge(totals)
       |> Map.merge(%{
         total_windows: 0,
         good_windows: 0,
         bad_windows: 0
       })
       |> maybe_projected_exhaustion()
       |> merge_optional(attrs)}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_request_observations}
    end
  end

  @spec evaluate_window_based(objective(), map()) :: {:ok, map()} | {:error, atom()}
  def evaluate_window_based(slo, attrs) do
    with {:ok, base} <- base_attrs(slo, attrs),
         {:ok, total_windows} <- non_negative_integer(attrs, :total_windows),
         {:ok, good_windows} <- non_negative_integer(attrs, :good_windows),
         true <- good_windows <= total_windows || {:error, :good_windows_exceed_total_windows} do
      bad_windows = Map.get(attrs, :bad_windows, total_windows - good_windows)
      bad_windows = max(to_integer(bad_windows), 0)

      totals =
        evaluation_totals(
          total_windows,
          good_windows,
          bad_windows,
          base.goal_basis_points,
          warning_threshold(slo)
        )

      {:ok,
       base
       |> Map.merge(totals)
       |> Map.merge(%{
         eligible_events: 0,
         good_events: 0,
         bad_events: 0,
         total_windows: total_windows,
         good_windows: good_windows,
         bad_windows: bad_windows
       })
       |> maybe_projected_exhaustion()
       |> merge_optional(attrs)}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_window_observations}
    end
  end

  defp base_attrs(slo, attrs) do
    with {:ok, evaluated_at} <- required_datetime(attrs, :evaluated_at),
         {:ok, period_started_at, period_ended_at} <- period_bounds(slo, attrs, evaluated_at),
         {:ok, slo_id} <- required_slo_id(slo),
         {:ok, goal_basis_points} <- goal_basis_points(slo) do
      {:ok,
       %{
         evaluation_key:
           Map.get(attrs, :evaluation_key) ||
             Map.get(attrs, "evaluation_key") ||
             default_evaluation_key(slo_id, evaluated_at),
         slo_id: slo_id,
         period_started_at: truncate_datetime(period_started_at),
         period_ended_at: truncate_datetime(period_ended_at),
         evaluated_at: truncate_datetime(evaluated_at),
         goal_basis_points: goal_basis_points
       }}
    end
  end

  defp evaluation_totals(total, good, bad, goal_basis_points, warning_threshold) do
    compliance_basis_points = ratio_basis_points(good, total)
    budget_basis_points = @basis_points - goal_basis_points
    error_budget_total = div(total * budget_basis_points, @basis_points)
    error_budget_remaining = error_budget_total - bad

    budget_remaining_basis_points =
      if error_budget_total > 0 do
        div(error_budget_remaining * @basis_points, error_budget_total)
      else
        0
      end

    burn_rate = burn_rate(bad, total, budget_basis_points)

    compliance_state =
      compliance_state(
        compliance_basis_points,
        goal_basis_points,
        budget_remaining_basis_points,
        warning_threshold
      )

    %{
      eligible_events: total,
      good_events: good,
      bad_events: bad,
      compliance_basis_points: compliance_basis_points,
      error_budget_total: error_budget_total,
      error_budget_consumed: bad,
      error_budget_remaining: error_budget_remaining,
      budget_remaining_basis_points: budget_remaining_basis_points,
      burn_rate_short: burn_rate,
      burn_rate_long: burn_rate,
      compliance_state: compliance_state,
      severity: severity(compliance_state),
      details: %{
        "error_budget_basis_points" => budget_basis_points,
        "warning_budget_remaining_basis_points" => warning_threshold
      },
      metadata: %{}
    }
  end

  defp compliance_state(
         0,
         _goal_basis_points,
         _budget_remaining_basis_points,
         _warning_threshold
       ), do: :unknown

  defp compliance_state(
         compliance_basis_points,
         goal_basis_points,
         budget_remaining_basis_points,
         warning_threshold
       ) do
    cond do
      compliance_basis_points < goal_basis_points -> :noncompliant
      budget_remaining_basis_points <= warning_threshold -> :at_risk
      true -> :compliant
    end
  end

  defp severity(:noncompliant), do: :critical
  defp severity(:at_risk), do: :warning
  defp severity(_state), do: :info

  defp ratio_basis_points(_good, 0), do: 0
  defp ratio_basis_points(good, total), do: div(good * @basis_points, total)

  defp burn_rate(_bad, _total, budget_basis_points) when budget_basis_points <= 0, do: nil
  defp burn_rate(_bad, 0, _budget_basis_points), do: nil

  defp burn_rate(bad, total, budget_basis_points) do
    bad
    |> Decimal.new()
    |> Decimal.mult(Decimal.new(@basis_points))
    |> Decimal.div(Decimal.new(total))
    |> Decimal.div(Decimal.new(budget_basis_points))
    |> Decimal.round(6)
  end

  defp warning_threshold(slo) do
    slo
    |> value(:alert_policy, %{})
    |> get_map_value(
      :warn_budget_remaining_below_basis_points,
      @default_budget_warning_basis_points
    )
    |> to_integer(@default_budget_warning_basis_points)
  end

  defp merge_optional(evaluation, attrs) do
    attrs
    |> Map.take([:event_id, :alert_id, :projected_exhaustion_at, :details, :metadata])
    |> Enum.reduce(evaluation, fn
      {:details, details}, acc when is_map(details) ->
        Map.update!(acc, :details, &Map.merge(&1, details))

      {:metadata, metadata}, acc when is_map(metadata) ->
        Map.put(acc, :metadata, metadata)

      {:projected_exhaustion_at, %DateTime{} = value}, acc ->
        Map.put(acc, :projected_exhaustion_at, truncate_datetime(value))

      {key, value}, acc when not is_nil(value) ->
        Map.put(acc, key, value)

      _entry, acc ->
        acc
    end)
  end

  defp maybe_projected_exhaustion(%{projected_exhaustion_at: %DateTime{}} = evaluation),
    do: evaluation

  defp maybe_projected_exhaustion(
         %{
           period_started_at: %DateTime{} = period_started_at,
           evaluated_at: %DateTime{} = evaluated_at,
           error_budget_consumed: consumed,
           error_budget_remaining: remaining
         } = evaluation
       )
       when is_integer(consumed) and consumed > 0 and is_integer(remaining) and remaining > 0 do
    elapsed_seconds = DateTime.diff(evaluated_at, period_started_at, :second)

    if elapsed_seconds > 0 do
      seconds_until_exhaustion = div(elapsed_seconds * remaining, consumed)
      exhaustion_at = DateTime.add(evaluated_at, seconds_until_exhaustion, :second)
      Map.put(evaluation, :projected_exhaustion_at, exhaustion_at)
    else
      evaluation
    end
  end

  defp maybe_projected_exhaustion(evaluation), do: evaluation

  defp required(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      nil -> {:error, :"missing_#{key}"}
      value -> {:ok, value}
    end
  end

  defp optional(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp required_datetime(attrs, key) do
    case required(attrs, key) do
      {:ok, %DateTime{} = datetime} -> {:ok, truncate_datetime(datetime)}
      {:ok, _value} -> {:error, :"invalid_#{key}"}
      error -> error
    end
  end

  defp period_bounds(slo, attrs, evaluated_at) do
    case {optional(attrs, :period_started_at), optional(attrs, :period_ended_at)} do
      {%DateTime{} = period_started_at, %DateTime{} = period_ended_at} ->
        validate_period_bounds(
          truncate_datetime(period_started_at),
          truncate_datetime(period_ended_at)
        )

      {nil, nil} ->
        derive_period_bounds(slo, evaluated_at)

      _partial ->
        {:error, :incomplete_period_bounds}
    end
  end

  defp validate_period_bounds(period_started_at, period_ended_at) do
    if DateTime.before?(period_started_at, period_ended_at) do
      {:ok, period_started_at, period_ended_at}
    else
      {:error, :invalid_period_bounds}
    end
  end

  defp derive_period_bounds(slo, %DateTime{} = evaluated_at) do
    case value(slo, :compliance_period_type, :rolling) do
      :calendar -> calendar_period_bounds(slo, evaluated_at)
      "calendar" -> calendar_period_bounds(slo, evaluated_at)
      _rolling -> rolling_period_bounds(slo, evaluated_at)
    end
  end

  defp rolling_period_bounds(slo, evaluated_at) do
    days =
      slo
      |> value(:rolling_period_days, 30)
      |> to_integer(30)
      |> min(30)
      |> max(1)

    period_ended_at = truncate_datetime(evaluated_at)
    period_started_at = DateTime.add(period_ended_at, -days * 86_400, :second)

    {:ok, period_started_at, period_ended_at}
  end

  defp calendar_period_bounds(slo, evaluated_at) do
    evaluated_date = DateTime.to_date(evaluated_at)

    period_start_date =
      calendar_period_start_date(value(slo, :calendar_period, :week), evaluated_date)

    period_end_date =
      calendar_period_end_date(value(slo, :calendar_period, :week), period_start_date)

    {:ok, utc_midnight(period_start_date), utc_midnight(period_end_date)}
  end

  defp calendar_period_start_date(period, date) when period in [:day, "day"], do: date

  defp calendar_period_start_date(period, date) when period in [:week, "week"] do
    Date.add(date, -(Date.day_of_week(date) - 1))
  end

  defp calendar_period_start_date(period, %{year: year, month: month})
       when period in [:month, "month"],
       do: Date.new!(year, month, 1)

  defp calendar_period_start_date(period, %{year: year, month: month})
       when period in [:quarter, "quarter"] do
    quarter_start_month = div(month - 1, 3) * 3 + 1
    Date.new!(year, quarter_start_month, 1)
  end

  defp calendar_period_start_date(_period, date), do: calendar_period_start_date(:week, date)

  defp calendar_period_end_date(period, start_date) when period in [:day, "day"],
    do: Date.add(start_date, 1)

  defp calendar_period_end_date(period, start_date) when period in [:week, "week"],
    do: Date.add(start_date, 7)

  defp calendar_period_end_date(period, start_date) when period in [:month, "month"],
    do: add_months(start_date, 1)

  defp calendar_period_end_date(period, start_date) when period in [:quarter, "quarter"],
    do: add_months(start_date, 3)

  defp calendar_period_end_date(_period, start_date),
    do: calendar_period_end_date(:week, start_date)

  defp add_months(%Date{year: year, month: month}, months) do
    month_index = year * 12 + (month - 1) + months
    Date.new!(div(month_index, 12), rem(month_index, 12) + 1, 1)
  end

  defp utc_midnight(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp required_slo_id(slo) do
    case value(slo, :id) do
      nil -> {:error, :missing_slo_id}
      id -> {:ok, id}
    end
  end

  defp goal_basis_points(slo) do
    case value(slo, :goal_basis_points) do
      value when is_integer(value) and value in 1..9_999 -> {:ok, value}
      _other -> {:error, :invalid_goal_basis_points}
    end
  end

  defp non_negative_integer(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      value when is_binary(value) -> non_negative_integer(%{key => to_integer(value, -1)}, key)
      _other -> {:error, :"invalid_#{key}"}
    end
  end

  defp default_evaluation_key(slo_id, evaluated_at) do
    "slo:#{slo_id}:#{evaluated_at |> truncate_datetime() |> DateTime.to_iso8601()}"
  end

  defp truncate_datetime(%DateTime{} = datetime), do: DateTime.truncate(datetime, :second)
  defp truncate_datetime(value), do: value

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp value(_map, _key, default), do: default

  defp get_map_value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get_map_value(_map, _key, default), do: default

  defp to_integer(value, default \\ 0)
  defp to_integer(value, _default) when is_integer(value), do: value

  defp to_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _other -> default
    end
  end

  defp to_integer(_value, default), do: default
end
