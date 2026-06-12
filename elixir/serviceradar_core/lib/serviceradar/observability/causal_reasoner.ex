defmodule ServiceRadar.Observability.CausalReasoner do
  @moduledoc """
  Stateless causal anomaly reasoner boundary.
  """

  alias __MODULE__.Native

  @type context :: %{
          required(:baseline) => [number()],
          optional(:min_samples) => pos_integer(),
          optional(:window_size) => pos_integer(),
          optional(:n_sigma) => number(),
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
          required(:score) => number(),
          required(:reason) => String.t(),
          required(:baseline_count) => non_neg_integer(),
          required(:sample_value) => number(),
          required(:observed_at_unix_nano) => non_neg_integer() | nil
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
      min_samples: get_optional(context, :min_samples),
      window_size: get_optional(context, :window_size),
      n_sigma: get_optional(context, :n_sigma),
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
