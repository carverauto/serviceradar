defmodule ServiceRadar.Observability.CausalReasoner do
  @moduledoc """
  Stateless causal anomaly reasoner boundary.
  """

  alias __MODULE__.Native

  @type context :: %{
          required(:baseline) => [number()],
          optional(:seasonal_baseline) => [number()],
          optional(:trend_baseline) => [number()],
          optional(:rolling_enabled) => boolean(),
          optional(:seasonal_enabled) => boolean(),
          optional(:trend_enabled) => boolean(),
          optional(:min_samples) => pos_integer(),
          optional(:seasonal_min_samples) => pos_integer(),
          optional(:trend_min_samples) => pos_integer(),
          optional(:window_size) => pos_integer(),
          optional(:n_sigma) => number(),
          optional(:seasonal_n_sigma) => number(),
          optional(:trend_n_sigma) => number(),
          optional(:confirm_slots) => non_neg_integer(),
          optional(:consecutive_anomalous) => non_neg_integer()
        }

  @type sample :: %{
          required(:value) => number(),
          optional(:observed_at_unix_nano) => non_neg_integer()
        }

  @type verdict :: %{
          required(:state) => String.t(),
          required(:anomalous) => boolean(),
          required(:breached) => boolean(),
          required(:include_in_baseline) => boolean(),
          required(:next_consecutive_anomalous) => non_neg_integer(),
          required(:score) => number(),
          required(:reason) => String.t(),
          required(:baseline_count) => non_neg_integer(),
          required(:sample_value) => number(),
          required(:observed_at_unix_nano) => non_neg_integer() | nil,
          required(:signals) => [signal_verdict()]
        }

  @type signal_verdict :: %{
          required(:name) => String.t(),
          required(:enabled) => boolean(),
          required(:ready) => boolean(),
          required(:breached) => boolean(),
          required(:score) => number(),
          required(:threshold) => number(),
          required(:sample_count) => non_neg_integer(),
          required(:mean) => number() | nil,
          required(:stddev) => number() | nil,
          required(:reason) => String.t()
        }

  @doc """
  Evaluates one sample against an immutable caller-owned context.
  """
  @spec reason(context(), sample()) :: {:ok, verdict()} | {:error, String.t()}
  def reason(context, sample) when is_map(context) and is_map(sample) do
    Native.reason(normalize_context(context), normalize_sample(sample))
  end

  defp normalize_context(context) do
    %{
      baseline: Map.get(context, :baseline, Map.get(context, "baseline", [])),
      seasonal_baseline: get_optional(context, :seasonal_baseline),
      trend_baseline: get_optional(context, :trend_baseline),
      rolling_enabled: get_optional(context, :rolling_enabled),
      seasonal_enabled: get_optional(context, :seasonal_enabled),
      trend_enabled: get_optional(context, :trend_enabled),
      min_samples: get_optional(context, :min_samples),
      seasonal_min_samples: get_optional(context, :seasonal_min_samples),
      trend_min_samples: get_optional(context, :trend_min_samples),
      window_size: get_optional(context, :window_size),
      n_sigma: get_optional(context, :n_sigma),
      seasonal_n_sigma: get_optional(context, :seasonal_n_sigma),
      trend_n_sigma: get_optional(context, :trend_n_sigma),
      confirm_slots: get_optional(context, :confirm_slots),
      consecutive_anomalous: get_optional(context, :consecutive_anomalous)
    }
  end

  defp normalize_sample(sample) do
    %{
      value: Map.get(sample, :value, Map.get(sample, "value")),
      observed_at_unix_nano: get_optional(sample, :observed_at_unix_nano)
    }
  end

  defp get_optional(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
