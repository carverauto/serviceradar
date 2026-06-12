defmodule ServiceRadar.Observability.CausalReasonerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.CausalReasoner

  test "returns insufficient baseline verdict without retaining state" do
    context = %{baseline: [1.0, 2.0], min_samples: 3, window_size: 4}
    sample = %{value: 9.0, observed_at_unix_nano: 42}

    assert {:ok, first} = CausalReasoner.reason(context, sample)
    assert {:ok, second} = CausalReasoner.reason(context, sample)

    assert first == second
    assert first.state == "insufficient_baseline"
    assert first.anomalous == false
    assert first.breached == false
    assert first.include_in_baseline == true
    assert first.next_consecutive_anomalous == 0
    assert first.score == 0.0
    assert first.baseline_count == 2
    assert first.sample_value == 9.0
    assert first.observed_at_unix_nano == 42
  end

  test "accepts string-keyed contexts from decoded payloads" do
    context = %{"baseline" => [1.0, 2.0, 3.0, 4.0, 5.0], "min_samples" => 3, "window_size" => 4}
    sample = %{"value" => 3.0}

    assert {:ok, verdict} = CausalReasoner.reason(context, sample)

    assert verdict.state == "clean"
    assert verdict.anomalous == false
    assert verdict.breached == false
    assert verdict.include_in_baseline == true
    assert verdict.next_consecutive_anomalous == 0
    assert verdict.baseline_count == 4
    assert verdict.observed_at_unix_nano == nil
  end

  test "withholds breached samples and waits for sustained confirmation" do
    context = %{
      baseline: [1.0, 2.0, 3.0],
      min_samples: 3,
      window_size: 3,
      n_sigma: 3.0,
      confirm_slots: 2,
      consecutive_anomalous: 1
    }

    assert {:ok, verdict} = CausalReasoner.reason(context, %{value: 5.0})

    assert verdict.state == "anomalous"
    assert verdict.anomalous == true
    assert verdict.breached == true
    assert verdict.include_in_baseline == false
    assert verdict.next_consecutive_anomalous == 2
    assert verdict.score == 3.0
  end

  test "combines a seasonal baseline when rolling baseline is not ready" do
    context = %{
      "baseline" => [1.0],
      "min_samples" => 3,
      "window_size" => 4,
      "seasonal_baseline" => [10.0, 11.0, 12.0, 13.0],
      "seasonal_min_samples" => 3,
      "seasonal_n_sigma" => 2.0
    }

    assert {:ok, verdict} = CausalReasoner.reason(context, %{"value" => 30.0})

    assert verdict.state == "pending_anomaly"
    assert verdict.breached == true
    assert verdict.include_in_baseline == false
    assert Enum.any?(verdict.signals, &(&1.name == "seasonal" and &1.ready and &1.breached))
  end
end
