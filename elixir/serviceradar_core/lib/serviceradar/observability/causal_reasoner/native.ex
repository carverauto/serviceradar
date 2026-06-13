defmodule ServiceRadar.Observability.CausalReasoner.Native do
  @moduledoc """
  Rustler NIF bindings for causal anomaly reasoning and native shard state.
  """

  use Rustler,
    otp_app: :serviceradar_core,
    crate: "causal_reasoner_nif"

  alias ServiceRadar.Observability.CausalReasoner

  @type context :: %{
          required(:baseline) => [number()],
          required(:seasonal_baseline) => [number()] | nil,
          required(:trend_baseline) => [number()] | nil,
          required(:rolling_acc) => CausalReasoner.rolling_acc() | nil,
          required(:window_tail) => [number()] | nil,
          required(:rolling_enabled) => boolean() | nil,
          required(:seasonal_enabled) => boolean() | nil,
          required(:trend_enabled) => boolean() | nil,
          required(:min_samples) => pos_integer() | nil,
          required(:seasonal_min_samples) => pos_integer() | nil,
          required(:trend_min_samples) => pos_integer() | nil,
          required(:window_size) => pos_integer() | nil,
          required(:n_sigma) => number() | nil,
          required(:seasonal_n_sigma) => number() | nil,
          required(:trend_n_sigma) => number() | nil,
          required(:confirm_slots) => non_neg_integer() | nil,
          required(:consecutive_anomalous) => non_neg_integer() | nil
        }

  @type sample :: %{
          required(:value) => number(),
          required(:observed_at_unix_nano) => non_neg_integer() | nil
        }

  @type verdict :: CausalReasoner.verdict()
  @type batch_input :: CausalReasoner.batch_input()
  @type series_batch_input :: CausalReasoner.series_batch_input()
  @type indexed_series_batch_input :: CausalReasoner.indexed_series_batch_input()
  @type indexed_value_input :: CausalReasoner.indexed_value_input()
  @type indexed_value_tuple_input :: CausalReasoner.indexed_value_tuple_input()
  @type batch_result ::
          %{
            required(:ok) => verdict() | nil,
            required(:error) => String.t() | nil
          }
  @type indexed_event_result ::
          %{
            required(:index) => non_neg_integer(),
            required(:ok) => verdict() | nil,
            required(:error) => String.t() | nil
          }

  @spec reason(context(), sample()) :: {:ok, verdict()} | {:error, String.t()}
  def reason(_context, _sample), do: :erlang.nif_error(:nif_not_loaded)

  @spec reason_batch([batch_input()]) :: [batch_result()]
  def reason_batch(_inputs), do: :erlang.nif_error(:nif_not_loaded)

  @spec new_shard_state() :: reference()
  def new_shard_state, do: :erlang.nif_error(:nif_not_loaded)

  @spec reason_state_batch(reference(), [series_batch_input()]) :: [batch_result()]
  def reason_state_batch(_state, _inputs), do: :erlang.nif_error(:nif_not_loaded)

  @spec reason_state_batch_events(reference(), [series_batch_input()]) :: [batch_result()]
  def reason_state_batch_events(_state, _inputs), do: :erlang.nif_error(:nif_not_loaded)

  @spec reason_state_batch_changes(reference(), [indexed_series_batch_input()]) :: [
          indexed_event_result()
        ]
  def reason_state_batch_changes(_state, _inputs), do: :erlang.nif_error(:nif_not_loaded)

  @spec reason_state_values_changes(reference(), [indexed_value_input()]) :: [
          indexed_event_result()
        ]
  def reason_state_values_changes(_state, _inputs), do: :erlang.nif_error(:nif_not_loaded)

  @spec reason_state_value_tuples_changes(reference(), [indexed_value_tuple_input()]) :: [
          indexed_event_result()
        ]
  def reason_state_value_tuples_changes(_state, _inputs), do: :erlang.nif_error(:nif_not_loaded)

  @spec forget_series(reference(), String.t()) :: boolean()
  def forget_series(_state, _series_key), do: :erlang.nif_error(:nif_not_loaded)
end
