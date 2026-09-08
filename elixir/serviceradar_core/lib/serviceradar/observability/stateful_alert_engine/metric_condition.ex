defmodule ServiceRadar.Observability.StatefulAlertEngine.MetricCondition do
  @moduledoc """
  Evaluating a metric rule's threshold/baseline condition against a metric
  record and tagging the record with the violation flag and condition details
  (`__stateful_alert_violation__` / `__stateful_alert_condition__`) consumed by
  the snapshot bucketing path.
  """

  import ServiceRadar.Observability.StatefulAlertEngine.Helpers
  import ServiceRadar.Observability.StatefulAlertEngine.Record

  def tag_metric_violation(metric, rule) do
    {violated?, details} = metric_condition_result(metric, rule.match || %{})

    metric
    |> Map.put(:__stateful_alert_violation__, violated?)
    |> Map.put(:__stateful_alert_condition__, details)
  end

  def metric_condition_result(metric, match) do
    condition = metric_condition(match)

    if map_size(condition) == 0 do
      {true, %{}}
    else
      value = metric_number(fetch_attr(metric, :value))
      threshold = metric_threshold(metric, condition)
      comparison = metric_comparison(condition)
      violated? = compare_metric_value(value, threshold, comparison)

      details =
        compact_map(%{
          "value" => value,
          "comparison" => comparison,
          "threshold" => threshold,
          "baseline_value" => metric_baseline(metric, condition),
          "baseline_multiplier" => condition_number(condition, "baseline_multiplier", 1.0),
          "baseline_offset" => condition_number(condition, "baseline_offset", 0.0)
        })

      {violated?, details}
    end
  end

  def metric_condition(match) do
    cond do
      is_map(match["condition"]) -> match["condition"]
      is_map(match["metric_condition"]) -> match["metric_condition"]
      is_map(match["threshold_condition"]) -> match["threshold_condition"]
      true -> %{}
    end
  end

  def metric_threshold(metric, condition) do
    explicit =
      condition_number(condition, "threshold") ||
        condition_number(condition, "value")

    case explicit do
      nil ->
        case metric_baseline(metric, condition) do
          nil ->
            nil

          baseline ->
            multiplier = condition_number(condition, "baseline_multiplier", 1.0)
            offset = condition_number(condition, "baseline_offset", 0.0)
            baseline * multiplier + offset
        end

      threshold ->
        threshold
    end
  end

  def metric_baseline(metric, condition) do
    condition_number(condition, "baseline_value") ||
      condition_number(condition, "baseline") ||
      metric_baseline_from_path(metric, condition)
  end

  def metric_baseline_from_path(metric, condition) do
    case condition["baseline_path"] || condition[:baseline_path] do
      path when is_binary(path) -> metric_number(get_nested_value(metric_match_map(metric), path))
      _ -> nil
    end
  end

  def condition_number(condition, key), do: condition_number(condition, key, nil)

  def condition_number(condition, key, default) when is_map(condition) do
    case Map.get(condition, key) || Map.get(condition, String.to_existing_atom(key)) do
      nil -> default
      value -> metric_number(value) || default
    end
  rescue
    ArgumentError -> default
  end

  def metric_number(value) when is_integer(value), do: value / 1
  def metric_number(value) when is_float(value), do: value

  def metric_number(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  def metric_number(_value), do: nil

  def metric_comparison(condition) do
    comparison = condition["comparison"] || condition[:comparison] || "gt"

    comparison
    |> to_string()
    |> String.downcase()
  end

  def compare_metric_value(nil, _threshold, _comparison), do: false
  def compare_metric_value(_value, nil, _comparison), do: false

  def compare_metric_value(value, threshold, comparison) when comparison in ["gt", ">"],
    do: value > threshold

  def compare_metric_value(value, threshold, comparison) when comparison in ["gte", "ge", ">="],
    do: value >= threshold

  def compare_metric_value(value, threshold, comparison) when comparison in ["lt", "<"],
    do: value < threshold

  def compare_metric_value(value, threshold, comparison) when comparison in ["lte", "le", "<="],
    do: value <= threshold

  def compare_metric_value(value, threshold, comparison) when comparison in ["eq", "=="],
    do: value == threshold

  def compare_metric_value(value, threshold, comparison) when comparison in ["neq", "!="],
    do: value != threshold

  def compare_metric_value(_value, _threshold, _comparison), do: false
end
