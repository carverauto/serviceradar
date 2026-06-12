defmodule ServiceRadar.Observability.CausalReasoner.Native do
  @moduledoc """
  Rustler NIF bindings for the stateless causal anomaly reasoner.
  """

  use Rustler,
    otp_app: :serviceradar_core,
    crate: "causal_reasoner_nif"

  @type context :: %{
          required(:baseline) => [number()],
          required(:seasonal_baseline) => [number()] | nil,
          required(:trend_baseline) => [number()] | nil,
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

  @type verdict :: ServiceRadar.Observability.CausalReasoner.verdict()

  @spec reason(context(), sample()) :: {:ok, verdict()} | {:error, String.t()}
  def reason(_context, _sample), do: :erlang.nif_error(:nif_not_loaded)
end
