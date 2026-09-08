defmodule ServiceRadar.Observability.Zen.Native do
  @moduledoc """
  Rustler NIF bindings for evaluating bundled Zen rules.
  """

  use Rustler,
    otp_app: :serviceradar_core,
    crate: "zen_nif"

  @type rule_json :: {String.t(), String.t()}

  @doc """
  Evaluates ordered Zen rule JSON against a JSON-encoded context.
  """
  @spec evaluate_rules(String.t(), [rule_json()]) :: {:ok, String.t()} | {:error, String.t()}
  def evaluate_rules(_context_json, _rules), do: :erlang.nif_error(:nif_not_loaded)
end
