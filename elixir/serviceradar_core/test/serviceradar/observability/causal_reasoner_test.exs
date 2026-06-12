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
    assert first.score == 0.0
    assert first.baseline_count == 2
    assert first.sample_value == 9.0
    assert first.observed_at_unix_nano == 42
  end

  test "accepts string-keyed contexts from decoded payloads" do
    context = %{"baseline" => [1.0, 2.0, 3.0, 4.0, 5.0], "min_samples" => 3, "window_size" => 4}
    sample = %{"value" => 9.0}

    assert {:ok, verdict} = CausalReasoner.reason(context, sample)

    assert verdict.state == "ready"
    assert verdict.anomalous == false
    assert verdict.baseline_count == 4
    assert verdict.observed_at_unix_nano == nil
  end
end
