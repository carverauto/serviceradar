defmodule ServiceRadar.Observability.CausalReasoner do
  @moduledoc """
  Stateless causal anomaly reasoner boundary.
  """

  alias __MODULE__.Native

  @type context :: %{
          required(:baseline) => [number()],
          optional(:seasonal_baseline) => [number()],
          optional(:trend_baseline) => [number()],
          optional(:rolling_acc) => rolling_acc() | nil,
          optional(:window_tail) => [number()] | nil,
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

  @type rolling_acc :: %{
          required(:count) => non_neg_integer(),
          required(:mean) => number(),
          required(:m2) => number()
        }

  @type batch_input :: %{
          required(:context) => context(),
          required(:sample) => sample()
        }

  @type series_batch_input :: %{
          required(:series_key) => String.t(),
          required(:context) => context(),
          required(:sample) => sample()
        }

  @type indexed_series_batch_input :: %{
          required(:index) => non_neg_integer(),
          required(:series_key) => String.t(),
          required(:context) => context(),
          required(:sample) => sample()
        }

  @type indexed_value_input :: %{
          required(:index) => non_neg_integer(),
          required(:series_key) => String.t(),
          required(:context) => context() | nil,
          required(:value) => number(),
          optional(:observed_at_unix_nano) => non_neg_integer()
        }

  @type indexed_value_tuple_input ::
          {non_neg_integer(), String.t(), context() | nil, number(), non_neg_integer() | nil}

  @type indexed_event_result :: {non_neg_integer(), batch_result()}

  @type shard_state :: reference()

  @type batch_result :: {:ok, verdict()} | {:error, String.t()}

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
          required(:next_rolling_acc) => rolling_acc(),
          required(:next_window_tail) => [number()],
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

  @doc """
  Evaluates an ordered batch of independent context/sample pairs.
  """
  @spec reason_batch([batch_input() | {context(), sample()}]) :: [batch_result()]
  def reason_batch(inputs) when is_list(inputs) do
    inputs
    |> Enum.map(&normalize_batch_input/1)
    |> Native.reason_batch()
    |> Enum.map(&normalize_batch_result/1)
  end

  @doc """
  Allocates a native shard state resource for hot per-series rolling context.
  """
  @spec new_shard_state() :: shard_state()
  def new_shard_state, do: Native.new_shard_state()

  @doc """
  Evaluates a shard-local ordered batch while keeping rolling state inside the NIF.
  """
  @spec reason_state_batch(shard_state(), [series_batch_input()]) :: [batch_result()]
  def reason_state_batch(shard_state, inputs) when is_list(inputs) do
    inputs
    |> Enum.map(&normalize_series_batch_input/1)
    |> then(&Native.reason_state_batch(shard_state, &1))
    |> Enum.map(&normalize_batch_result/1)
  end

  @doc """
  Evaluates a shard-local ordered batch and returns only event-facing verdict fields.
  """
  @spec reason_state_batch_events(shard_state(), [series_batch_input()]) :: [batch_result()]
  def reason_state_batch_events(shard_state, inputs) when is_list(inputs) do
    inputs
    |> Enum.map(&normalize_series_batch_input/1)
    |> then(&Native.reason_state_batch_events(shard_state, &1))
    |> Enum.map(&normalize_batch_result/1)
  end

  @doc """
  Evaluates a shard-local ordered batch and returns only anomaly/clear state changes.
  """
  @spec reason_state_batch_changes(shard_state(), [indexed_series_batch_input()]) :: [
          indexed_event_result()
        ]
  def reason_state_batch_changes(shard_state, inputs) when is_list(inputs) do
    inputs
    |> Enum.map(&normalize_indexed_series_batch_input/1)
    |> then(&Native.reason_state_batch_changes(shard_state, &1))
    |> Enum.map(&normalize_indexed_batch_result/1)
  end

  @doc """
  Evaluates compact value inputs and returns only anomaly/clear state changes.
  """
  @spec reason_state_values_changes(shard_state(), [indexed_value_input()]) :: [
          indexed_event_result()
        ]
  def reason_state_values_changes(shard_state, inputs) when is_list(inputs) do
    inputs
    |> Enum.map(&normalize_indexed_value_input/1)
    |> then(&Native.reason_state_values_changes(shard_state, &1))
    |> Enum.map(&normalize_indexed_batch_result/1)
  end

  @doc """
  Evaluates compact tuple value inputs and returns only anomaly/clear state changes.
  """
  @spec reason_state_value_tuples_changes(shard_state(), [indexed_value_tuple_input()]) :: [
          indexed_event_result()
        ]
  def reason_state_value_tuples_changes(shard_state, inputs) when is_list(inputs) do
    inputs
    |> Enum.map(&normalize_indexed_value_tuple_input/1)
    |> then(&Native.reason_state_value_tuples_changes(shard_state, &1))
    |> Enum.map(&normalize_indexed_batch_result/1)
  end

  @doc """
  Drops one series from a native shard state resource.
  """
  @spec forget_series(shard_state(), String.t()) :: boolean()
  def forget_series(shard_state, series_key) when is_binary(series_key) do
    Native.forget_series(shard_state, series_key)
  end

  defp normalize_context(context) do
    %{
      baseline: Map.get(context, :baseline, Map.get(context, "baseline", [])),
      seasonal_baseline: get_optional(context, :seasonal_baseline),
      trend_baseline: get_optional(context, :trend_baseline),
      rolling_acc: get_optional(context, :rolling_acc),
      window_tail: get_optional(context, :window_tail),
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

  defp normalize_batch_input({context, sample}) when is_map(context) and is_map(sample) do
    %{context: normalize_context(context), sample: normalize_sample(sample)}
  end

  defp normalize_batch_input(%{} = input) do
    %{
      context: normalize_context(Map.get(input, :context, Map.get(input, "context", %{}))),
      sample: normalize_sample(Map.get(input, :sample, Map.get(input, "sample", %{})))
    }
  end

  defp normalize_series_batch_input(%{} = input) do
    %{
      series_key: Map.get(input, :series_key, Map.get(input, "series_key")),
      context: normalize_context(Map.get(input, :context, Map.get(input, "context", %{}))),
      sample: normalize_sample(Map.get(input, :sample, Map.get(input, "sample", %{})))
    }
  end

  defp normalize_indexed_series_batch_input(%{} = input) do
    input
    |> normalize_series_batch_input()
    |> Map.put(:index, Map.get(input, :index, Map.get(input, "index")))
  end

  defp normalize_indexed_value_input(%{} = input) do
    context = Map.get(input, :context, Map.get(input, "context"))

    %{
      index: Map.get(input, :index, Map.get(input, "index")),
      series_key: Map.get(input, :series_key, Map.get(input, "series_key")),
      context: if(is_nil(context), do: nil, else: normalize_context(context)),
      value: Map.get(input, :value, Map.get(input, "value")),
      observed_at_unix_nano: get_optional(input, :observed_at_unix_nano)
    }
  end

  defp normalize_indexed_value_tuple_input({index, series_key, context, value, observed_at}) do
    {
      index,
      series_key,
      if(is_nil(context), do: nil, else: normalize_context(context)),
      value,
      observed_at
    }
  end

  defp normalize_batch_result(%{ok: %{} = verdict, error: nil}), do: {:ok, verdict}

  defp normalize_batch_result(%{ok: nil, error: reason}) when is_binary(reason),
    do: {:error, reason}

  defp normalize_batch_result(%{"ok" => %{} = verdict, "error" => nil}), do: {:ok, verdict}

  defp normalize_batch_result(%{"ok" => nil, "error" => reason}) when is_binary(reason),
    do: {:error, reason}

  defp normalize_batch_result(%{error: reason}) when is_binary(reason), do: {:error, reason}
  defp normalize_batch_result(%{"error" => reason}) when is_binary(reason), do: {:error, reason}

  defp normalize_indexed_batch_result(%{index: index, ok: ok, error: error}),
    do: {index, normalize_batch_result(%{ok: ok, error: error})}

  defp normalize_indexed_batch_result(%{"index" => index, "ok" => ok, "error" => error}),
    do: {index, normalize_batch_result(%{"ok" => ok, "error" => error})}

  defp get_optional(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
