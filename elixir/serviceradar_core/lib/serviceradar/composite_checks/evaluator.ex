defmodule ServiceRadar.CompositeChecks.Evaluator do
  @moduledoc """
  Decision table evaluation for composite checks. Pure — no I/O, no repo, no Ash.

  Rules are sorted by ascending `position` and the first match wins. A rule
  matches when every key in its `match` map matches the corresponding resolved
  input value. Semantics:

    * a key absent from `match` is a wildcard
    * the string `"*"` is an explicit wildcard
    * a list matches if the value matches any member
    * values compare by their string form, so `:available` matches `"available"`
      and `true` matches `"true"`

  The trailing catch-all rule (empty `match`) is what makes the table total: it
  matches everything, so every input combination resolves to a verdict. A table
  without one can return `{:error, :no_matching_rule}`, which callers treat as a
  configuration fault rather than a verdict.

  This function is shared by the scheduled pass, the per-device refresh, and the
  authoring preview. That sharing is deliberate: it is what guarantees a preview
  cannot produce a different verdict than a persisted evaluation.
  """

  @type input_value :: atom() | boolean() | String.t()
  @type decision :: %{verdict: String.t(), status: atom(), matched_rule_id: term()}

  @wildcard "*"
  @absent :__absent__

  @spec verdict(%{optional(String.t()) => input_value()}, [struct()]) ::
          {:ok, decision()} | {:error, :no_matching_rule}
  def verdict(inputs, rules) when is_map(inputs) and is_list(rules) do
    normalized = Map.new(inputs, fn {key, value} -> {to_string(key), normalize(value)} end)

    rules
    |> Enum.sort_by(& &1.position)
    |> Enum.find(&matches?(&1, normalized))
    |> case do
      nil ->
        {:error, :no_matching_rule}

      rule ->
        {:ok, %{verdict: rule.verdict, status: rule.status, matched_rule_id: rule.id}}
    end
  end

  defp matches?(%{match: match}, inputs) when is_map(match) do
    Enum.all?(match, fn {key, matcher} ->
      matches_value?(matcher, Map.get(inputs, to_string(key), @absent))
    end)
  end

  # A rule naming an input that was never resolved cannot be satisfied. Treating
  # it as a match would silently apply a rule whose premise was never checked.
  defp matches_value?(_matcher, @absent), do: false
  defp matches_value?(@wildcard, _value), do: true

  defp matches_value?(matcher, value) when is_list(matcher) do
    Enum.any?(matcher, &matches_value?(&1, value))
  end

  defp matches_value?(matcher, value), do: normalize(matcher) == value

  defp normalize(value) when is_binary(value), do: value
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value), do: to_string(value)
end
