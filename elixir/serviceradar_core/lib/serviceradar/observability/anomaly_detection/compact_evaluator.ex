defmodule ServiceRadar.Observability.AnomalyDetection.CompactEvaluator do
  @moduledoc """
  Allocation-light rolling anomaly evaluator for high-cardinality metric series.

  The existing `CausalReasoner` remains the reference implementation and supports
  the richer multi-signal verdict shape. This module is the hot-path rolling
  state model: it keeps bounded clean baseline values plus incremental
  Welford statistics so evaluating one sample is O(1) with respect to the
  window size while staying stable for large cumulative counter magnitudes.
  """

  alias ServiceRadar.Observability.CausalReasoner

  @default_min_samples 30
  @default_window_size 300
  @default_n_sigma 3.0
  @default_confirm_slots 5

  defstruct baseline: :queue.new(),
            count: 0,
            mean: 0.0,
            m2: 0.0,
            min_samples: @default_min_samples,
            window_size: @default_window_size,
            n_sigma: @default_n_sigma,
            confirm_slots: @default_confirm_slots,
            consecutive_anomalous: 0

  @type t :: %__MODULE__{
          baseline: :queue.queue(number()),
          count: non_neg_integer(),
          mean: number(),
          m2: number(),
          min_samples: pos_integer(),
          window_size: pos_integer(),
          n_sigma: number(),
          confirm_slots: pos_integer(),
          consecutive_anomalous: non_neg_integer()
        }

  @type context :: CausalReasoner.context()
  @type sample :: CausalReasoner.sample()
  @type verdict :: CausalReasoner.verdict()

  @spec new(context() | keyword()) :: t()
  def new(context_or_opts \\ %{})

  def new(opts) when is_list(opts) do
    opts
    |> Map.new()
    |> new()
  end

  def new(context) when is_map(context) do
    window_size = positive_int(value(context, :window_size), @default_window_size)

    state = %__MODULE__{
      min_samples: positive_int(value(context, :min_samples), @default_min_samples),
      window_size: window_size,
      n_sigma: clean_threshold(number(value(context, :n_sigma), @default_n_sigma)),
      confirm_slots: positive_int(value(context, :confirm_slots), @default_confirm_slots),
      consecutive_anomalous: non_negative_int(value(context, :consecutive_anomalous), 0)
    }

    context
    |> value(:baseline, [])
    |> clean_window_values(window_size)
    |> Enum.reduce(state, &append_baseline(&2, &1))
  end

  @spec evaluate(t(), sample()) :: {t(), verdict()}
  def evaluate(%__MODULE__{} = state, sample) when is_map(sample) do
    sample_value = value(sample, :value)
    observed_at = value(sample, :observed_at_unix_nano)

    cond do
      not is_number(sample_value) or not finite?(sample_value) ->
        {state, error_verdict(sample_value, observed_at, "sample value must be finite")}

      state.count < state.min_samples or state.count < 2 ->
        verdict =
          insufficient_baseline_verdict(
            state,
            sample_value,
            observed_at,
            "#{state.count} clean samples; requires at least #{max(state.min_samples, 2)}"
          )

        {append_baseline(state, sample_value), verdict}

      true ->
        evaluate_ready(state, sample_value, observed_at)
    end
  end

  @spec context(t()) :: context()
  def context(%__MODULE__{} = state) do
    %{
      baseline: :queue.to_list(state.baseline),
      min_samples: state.min_samples,
      window_size: state.window_size,
      n_sigma: state.n_sigma,
      confirm_slots: state.confirm_slots,
      consecutive_anomalous: state.consecutive_anomalous
    }
  end

  defp evaluate_ready(state, sample_value, observed_at) do
    {mean, stddev} = stats(state)
    score = z_score(sample_value, mean, stddev, state.n_sigma)
    breached = score >= state.n_sigma
    next_consecutive = if breached, do: state.consecutive_anomalous + 1, else: 0
    anomalous = breached and next_consecutive >= state.confirm_slots

    verdict_state =
      cond do
        anomalous -> "anomalous"
        breached -> "pending_anomaly"
        true -> "clean"
      end

    verdict = %{
      state: verdict_state,
      anomalous: anomalous,
      breached: breached,
      include_in_baseline: not breached,
      next_consecutive_anomalous: next_consecutive,
      score: score,
      reason: reason_for_state(verdict_state, state.confirm_slots, next_consecutive),
      baseline_count: state.count,
      sample_value: sample_value,
      observed_at_unix_nano: observed_at,
      signals: [
        %{
          name: "rolling",
          enabled: true,
          ready: true,
          breached: breached,
          score: score,
          threshold: state.n_sigma,
          sample_count: state.count,
          mean: mean,
          stddev: stddev,
          reason: signal_reason("rolling", score, state.n_sigma, breached)
        },
        disabled_signal("seasonal", state.n_sigma),
        disabled_signal("trend", state.n_sigma)
      ]
    }

    state =
      state
      |> Map.put(:consecutive_anomalous, next_consecutive)
      |> maybe_append_clean(sample_value, verdict)

    {state, verdict}
  end

  defp maybe_append_clean(state, sample_value, %{include_in_baseline: true}),
    do: append_baseline(state, sample_value)

  defp maybe_append_clean(state, _sample_value, _verdict), do: state

  defp append_baseline(state, value) when is_number(value) do
    state =
      if state.count >= state.window_size do
        {{:value, dropped}, baseline} = :queue.out(state.baseline)

        state
        |> Map.put(:baseline, baseline)
        |> remove_welford(dropped)
      else
        state
      end

    state
    |> add_welford(value)
    |> Map.update!(:baseline, &:queue.in(value, &1))
  end

  defp append_baseline(state, _value), do: state

  defp add_welford(%{count: count, mean: mean, m2: m2} = state, value) do
    next_count = count + 1
    delta = value - mean
    next_mean = mean + delta / next_count
    next_m2 = m2 + delta * (value - next_mean)

    %{state | count: next_count, mean: next_mean, m2: max(next_m2, 0.0)}
  end

  defp remove_welford(%{count: count} = state, _value) when count <= 1 do
    %{state | count: 0, mean: 0.0, m2: 0.0}
  end

  defp remove_welford(%{count: count, mean: mean, m2: m2} = state, value) do
    next_count = count - 1
    next_mean = (count * mean - value) / next_count
    next_m2 = m2 - (value - mean) * (value - next_mean)

    %{state | count: next_count, mean: next_mean, m2: max(next_m2, 0.0)}
  end

  defp stats(%{count: count, mean: mean, m2: m2}) do
    variance = m2 / (count - 1)
    {mean, :math.sqrt(max(variance, 0.0))}
  end

  defp z_score(sample_value, mean, stddev, threshold) do
    if stddev <= :erlang.float(0.0) + 1.0e-12 do
      if abs(sample_value - mean) <= 1.0e-12, do: 0.0, else: threshold + 1.0
    else
      abs((sample_value - mean) / stddev)
    end
  end

  defp insufficient_baseline_verdict(state, sample_value, observed_at, reason) do
    %{
      state: "insufficient_baseline",
      anomalous: false,
      breached: false,
      include_in_baseline: true,
      next_consecutive_anomalous: 0,
      score: 0.0,
      reason: "rolling baseline has #{reason}",
      baseline_count: state.count,
      sample_value: sample_value,
      observed_at_unix_nano: observed_at,
      signals: [
        %{
          name: "rolling",
          enabled: true,
          ready: false,
          breached: false,
          score: 0.0,
          threshold: state.n_sigma,
          sample_count: state.count,
          mean: nil,
          stddev: nil,
          reason: "rolling baseline has #{reason}"
        },
        disabled_signal("seasonal", state.n_sigma),
        disabled_signal("trend", state.n_sigma)
      ]
    }
  end

  defp error_verdict(sample_value, observed_at, reason) do
    %{
      state: "error",
      anomalous: false,
      breached: false,
      include_in_baseline: false,
      next_consecutive_anomalous: 0,
      score: 0.0,
      reason: reason,
      baseline_count: 0,
      sample_value: sample_value,
      observed_at_unix_nano: observed_at,
      signals: []
    }
  end

  defp disabled_signal(name, threshold) do
    %{
      name: name,
      enabled: false,
      ready: false,
      breached: false,
      score: 0.0,
      threshold: threshold,
      sample_count: 0,
      mean: nil,
      stddev: nil,
      reason: "signal disabled"
    }
  end

  defp reason_for_state("anomalous", confirm_slots, next_consecutive) do
    "breach confirmed after #{next_consecutive}/#{confirm_slots} consecutive anomalous slots"
  end

  defp reason_for_state("pending_anomaly", confirm_slots, next_consecutive) do
    "breach pending confirmation at #{next_consecutive}/#{confirm_slots} consecutive anomalous slots"
  end

  defp reason_for_state(_state, _confirm_slots, _next_consecutive),
    do: "all ready signals are clean; consecutive anomalous slots reset"

  defp signal_reason(name, score, threshold, true),
    do: "#{name} z-score #{format_float(score)} breached #{format_float(threshold)}"

  defp signal_reason(name, score, threshold, false),
    do: "#{name} z-score #{format_float(score)} is below #{format_float(threshold)}"

  defp format_float(value), do: :erlang.float_to_binary(value * 1.0, decimals: 3)

  defp clean_window_values(values, window_size) when is_list(values) do
    values
    |> Enum.filter(&(is_number(&1) and finite?(&1)))
    |> Enum.take(-window_size)
  end

  defp clean_window_values(_values, _window_size), do: []

  defp value(map, key, default \\ nil) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp number(value, _default) when is_number(value), do: value
  defp number(_value, default), do: default

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp non_negative_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value, default), do: default

  defp clean_threshold(value) when is_number(value) and value > 0, do: value
  defp clean_threshold(_value), do: @default_n_sigma

  defp finite?(value), do: value == value and value not in [:infinity, :neg_infinity]
end
