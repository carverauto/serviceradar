defmodule ServiceRadar.Observability.CausalPredictionSubject do
  @moduledoc """
  Builds NATS subjects for causal prediction verdicts.

  The payload keeps the readable series/resource key, but the NATS subject token
  must not contain delimiters, whitespace, or wildcard tokens.
  """

  @subject_root "signals.analytics.predictions"

  @spec build(term(), String.t()) :: String.t()
  def build(value, fallback \\ "anomaly") do
    "#{@subject_root}.#{token(value, fallback)}"
  end

  @spec token(term(), String.t()) :: String.t()
  def token(value, fallback \\ "anomaly") do
    value
    |> string_value()
    |> case do
      nil -> fallback
      value -> String.replace(value, ~r/[.\s*>]/, "_")
    end
  end

  defp string_value(nil), do: nil

  defp string_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_value(value), do: to_string(value)
end
