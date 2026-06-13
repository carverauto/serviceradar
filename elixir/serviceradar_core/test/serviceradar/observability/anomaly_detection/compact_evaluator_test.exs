defmodule ServiceRadar.Observability.AnomalyDetection.CompactEvaluatorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.AnomalyDetection.CompactEvaluator
  alias ServiceRadar.Observability.CausalReasoner

  @context %{
    baseline: [],
    min_samples: 10,
    window_size: 24,
    n_sigma: 3.0,
    confirm_slots: 3,
    consecutive_anomalous: 0
  }

  test "matches rolling reasoner verdicts across deterministic synthetic sequences" do
    Enum.each(1..40, fn series ->
      samples = synthetic_samples(series)
      compact = CompactEvaluator.new(@context)

      Enum.reduce(samples, {@context, compact}, fn {value, order}, {context, compact} ->
        sample = %{value: value, observed_at_unix_nano: order}

        assert {:ok, reference} = CausalReasoner.reason(context, sample)
        {compact, actual} = CompactEvaluator.evaluate(compact, sample)

        assert_equivalent_verdict(actual, reference)

        context = fold_context(context, value, reference)
        assert CompactEvaluator.context(compact).baseline == context.baseline

        assert CompactEvaluator.context(compact).consecutive_anomalous ==
                 context.consecutive_anomalous

        {context, compact}
      end)
    end)
  end

  test "keeps breached values out of the compact baseline" do
    compact = CompactEvaluator.new(@context)

    {compact, _last_baseline} =
      Enum.reduce(1..12, {compact, nil}, fn order, {compact, _last} ->
        CompactEvaluator.evaluate(compact, %{
          value: 40.0 + :math.sin(order) / 10,
          observed_at_unix_nano: order
        })
      end)

    {compact, first} =
      CompactEvaluator.evaluate(compact, %{value: 90.0, observed_at_unix_nano: 13})

    {compact, second} =
      CompactEvaluator.evaluate(compact, %{value: 91.0, observed_at_unix_nano: 14})

    assert first.state == "pending_anomaly"
    assert second.state == "pending_anomaly"
    refute first.include_in_baseline
    refute second.include_in_baseline
    refute 90.0 in CompactEvaluator.context(compact).baseline
    refute 91.0 in CompactEvaluator.context(compact).baseline
  end

  test "keeps rolling variance stable for large cumulative counter magnitudes" do
    context = %{
      @context
      | baseline:
          Enum.map(1..300, fn order ->
            1.0e9 + :math.sin(order) + :math.cos(order / 3)
          end),
        min_samples: 30,
        window_size: 300,
        confirm_slots: 1
    }

    sample = %{value: 1.0e9 + 1.5, observed_at_unix_nano: 301}

    assert {:ok, reference} = CausalReasoner.reason(context, sample)
    {_compact, actual} = context |> CompactEvaluator.new() |> CompactEvaluator.evaluate(sample)

    assert_equivalent_verdict(actual, reference, 1.0e-5)

    actual_rolling = rolling_signal(actual)
    reference_rolling = rolling_signal(reference)

    assert actual_rolling.stddev > 0.5
    assert_in_delta actual_rolling.stddev, reference_rolling.stddev, 1.0e-5
    refute actual.breached
  end

  defp synthetic_samples(series) do
    :rand.seed(:exsss, {series, series * 3 + 1, series * 7 + 2})

    normal =
      Enum.map(1..80, fn order ->
        base = 40.0 + rem(series, 5) * 3
        jitter = (:rand.uniform() - 0.5) * 0.8
        {base + jitter, order}
      end)

    anomalies =
      Enum.map(81..85, fn order ->
        {95.0 + rem(order, 3), order}
      end)

    recovery =
      Enum.map(86..110, fn order ->
        base = 40.0 + rem(series, 5) * 3
        jitter = (:rand.uniform() - 0.5) * 0.8
        {base + jitter, order}
      end)

    normal ++ anomalies ++ recovery
  end

  defp assert_equivalent_verdict(actual, reference, tolerance \\ 1.0e-6) do
    assert actual.state == reference.state
    assert actual.anomalous == reference.anomalous
    assert actual.breached == reference.breached
    assert actual.include_in_baseline == reference.include_in_baseline
    assert actual.next_consecutive_anomalous == reference.next_consecutive_anomalous
    assert actual.baseline_count == reference.baseline_count
    assert actual.sample_value == reference.sample_value
    assert actual.observed_at_unix_nano == reference.observed_at_unix_nano
    assert_in_delta actual.score, reference.score, tolerance

    actual_rolling = rolling_signal(actual)
    reference_rolling = rolling_signal(reference)

    assert actual_rolling.ready == reference_rolling.ready
    assert actual_rolling.breached == reference_rolling.breached
    assert actual_rolling.sample_count == reference_rolling.sample_count
    assert_in_delta actual_rolling.score, reference_rolling.score, tolerance
    assert_optional_float(actual_rolling.mean, reference_rolling.mean, tolerance)
    assert_optional_float(actual_rolling.stddev, reference_rolling.stddev, tolerance)
  end

  defp rolling_signal(verdict), do: Enum.find(verdict.signals, &(&1.name == "rolling"))

  defp assert_optional_float(actual, expected, tolerance)

  defp assert_optional_float(nil, nil, _tolerance), do: :ok

  defp assert_optional_float(actual, expected, tolerance) do
    assert_in_delta actual, expected, tolerance
  end

  defp fold_context(context, value, verdict) do
    baseline =
      if verdict.include_in_baseline do
        context.baseline
        |> Kernel.++([value])
        |> Enum.take(-context.window_size)
      else
        context.baseline
      end

    %{context | baseline: baseline, consecutive_anomalous: verdict.next_consecutive_anomalous}
  end
end
