defmodule ServiceRadar.Observability.AnomalyDetection.NativeContextEngineTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.AnomalyDetection.NativeContextEngine

  test "evaluates sparse state changes through native shard resources" do
    start_supervised!(
      {NativeContextEngine, shard_count: 2, min_samples: 3, window_size: 3, confirm_slots: 1}
    )

    samples = [
      sample("series-a", 0, 10.0),
      sample("series-a", 1, 11.0),
      sample("series-a", 2, 12.0),
      sample("series-a", 3, 30.0),
      sample("series-a", 4, 31.0),
      sample("series-a", 5, 11.5)
    ]

    assert [
             {%{series_key: "series-a", observed_at_unix_nano: 3}, {:ok, open}},
             {%{series_key: "series-a", observed_at_unix_nano: 5}, {:ok, clear}}
           ] = NativeContextEngine.evaluate_events_batch(samples)

    assert open.anomalous == true
    assert clear.anomalous == false
    assert clear.breached == false
  end

  test "skips already committed event IDs on redelivery" do
    start_supervised!(
      {NativeContextEngine, shard_count: 1, min_samples: 3, window_size: 3, confirm_slots: 1}
    )

    samples = [
      sample("series-redelivery", 0, 10.0),
      sample("series-redelivery", 1, 11.0),
      sample("series-redelivery", 2, 12.0),
      sample("series-redelivery", 3, 30.0)
    ]

    assert [{%{series_key: "series-redelivery"}, {:ok, %{anomalous: true}}}] =
             NativeContextEngine.evaluate_events_batch(samples)

    assert Enum.all?(NativeContextEngine.evaluate_events_batch(samples), fn
             {_sample, {:drop, :duplicate_event}} -> true
             _other -> false
           end)
  end

  test "profiled batch evaluation reports phase timings" do
    start_supervised!(
      {NativeContextEngine, shard_count: 1, min_samples: 3, window_size: 3, confirm_slots: 1}
    )

    {results, profile} =
      NativeContextEngine.evaluate_events_batch_profiled([
        sample("series-profile", 0, 10.0),
        sample("series-profile", 1, 11.0),
        sample("series-profile", 2, 12.0),
        sample("series-profile", 3, 30.0)
      ])

    assert [{%{series_key: "series-profile"}, {:ok, %{anomalous: true}}}] = results
    assert profile.input_samples == 4
    assert profile.candidates == 4
    assert profile.duplicate_drops == 0
    assert profile.emitted_results == 1
    assert is_integer(profile.total_ns) and profile.total_ns > 0
    assert is_integer(profile.native_eval_ns) and profile.native_eval_ns >= 0
    assert is_integer(profile.shard_input_build_ns) and profile.shard_input_build_ns >= 0
  end

  test "serializes concurrent callers instead of returning shard lock errors" do
    start_supervised!(
      {NativeContextEngine, shard_count: 1, min_samples: 3, window_size: 3, confirm_slots: 1}
    )

    results =
      1..20
      |> Task.async_stream(
        fn batch ->
          NativeContextEngine.evaluate_events_batch([
            sample("series-#{batch}", batch * 10, 10.0),
            sample("series-#{batch}", batch * 10 + 1, 11.0),
            sample("series-#{batch}", batch * 10 + 2, 12.0)
          ])
        end,
        max_concurrency: 20,
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, result} -> result end)

    refute Enum.any?(results, fn
             {_sample, {:error, "runtime shard state lock unavailable"}} -> true
             {_sample, {:error, {:shard_exit, _reason}}} -> true
             _other -> false
           end)
  end

  defp sample(series_key, order, value) do
    %{
      series_key: series_key,
      event_id: "#{series_key}-#{order}",
      order_key: {order, "#{series_key}-#{order}"},
      value: value,
      observed_at_unix_nano: order,
      subject: "metrics.sysmon.cpu",
      metric_class: "sysmon.cpu"
    }
  end
end
