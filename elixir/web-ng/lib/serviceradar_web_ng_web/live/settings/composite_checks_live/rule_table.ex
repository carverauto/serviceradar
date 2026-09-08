defmodule ServiceRadarWebNGWeb.Settings.CompositeChecksLive.RuleTable do
  @moduledoc """
  Presentation helpers for a composite check's decision table.

  The table's columns come from the check's *persisted* inputs, not from the
  unsaved vantage point rows in the form. A rule matches on an input key, so a
  column for an input that does not exist yet would produce a rule that can
  never match.

  `match` omits a key to mean "any value", which is also how the generator
  writes it. The form therefore renders an explicit "any" option and drops it on
  the way back in, rather than storing the wildcard `"*"` — one representation
  for one meaning.
  """

  @any "any"

  @statuses [:healthy, :degraded, :down, :unknown]

  @doc "The selectable statuses, in severity order."
  def statuses, do: @statuses

  @doc "The sentinel a select uses for \"this input is not constrained\"."
  def any_value, do: @any

  @doc """
  Match columns for a check's inputs, in the order they were authored.

  Only inputs that a rule can match on appear: every input kind is matchable
  today, but the options differ, so the kind travels with the column.
  """
  def columns(inputs) do
    inputs
    |> Enum.sort_by(& &1.position)
    |> Enum.map(fn input ->
      %{
        key: input.key,
        label: input.label || input.key,
        kind: input.kind,
        options: options_for(input.kind)
      }
    end)
  end

  defp options_for(:vantage_point) do
    [{@any, "any"}, {"available", "available"}, {"blocked", "blocked"}]
  end

  defp options_for(:device_metadata) do
    [{@any, "any"}, {"true", "true"}, {"false", "false"}]
  end

  @doc """
  The select value for a column of a rule's match map.

  An absent key is the wildcard, so it renders as "any". A list value has no
  single-select representation; it renders as "any" but is left untouched unless
  the operator actually changes that cell, which `match_from_params/3` handles.
  """
  def cell_value(match, %{key: key}) do
    case Map.get(match, key) do
      nil -> @any
      value when is_list(value) -> @any
      "*" -> @any
      value -> to_string(value)
    end
  end

  @doc """
  Builds a match map from submitted cell params.

  `existing` is the rule's current match: a cell the operator did not change and
  that holds a value the select cannot represent (a list of literals) is carried
  through unchanged rather than being flattened to "any". Editing a status must
  not silently widen a hand-written match.
  """
  def match_from_params(columns, params, existing) do
    cells = Map.get(params, "match", %{})

    Enum.reduce(columns, %{}, fn column, acc ->
      submitted = Map.get(cells, column.key, @any)
      current = Map.get(existing, column.key)

      cond do
        submitted != @any -> Map.put(acc, column.key, cast(column.kind, submitted))
        is_list(current) -> Map.put(acc, column.key, current)
        true -> acc
      end
    end)
  end

  defp cast(:device_metadata, "true"), do: true
  defp cast(:device_metadata, "false"), do: false
  defp cast(_kind, value), do: value

  @doc """
  Reorders `rules` by moving the rule with `id` one place up or down.

  The catch-all is excluded: its position is structural and the resource forbids
  updating it at all, so it must never be handed to a renumbering pass.
  """
  def move(rules, id, direction) do
    authored = Enum.reject(rules, & &1.catch_all)

    case Enum.find_index(authored, &(&1.id == id)) do
      nil -> authored
      index -> swap(authored, index, target_index(index, direction, length(authored)))
    end
  end

  defp target_index(index, :up, _length), do: index - 1
  defp target_index(index, :down, _length), do: index + 1

  defp swap(list, index, target) when target < 0 or index == target, do: list

  defp swap(list, index, target) do
    if target >= length(list) do
      list
    else
      a = Enum.at(list, index)
      b = Enum.at(list, target)

      list
      |> List.replace_at(index, b)
      |> List.replace_at(target, a)
    end
  end

  @doc """
  Rules whose stored position no longer matches their place in `ordered`.

  Returns `[{rule, position}]` so the caller updates only what actually moved:
  every rule update is a policy-checked write, and rewriting untouched rows
  would churn `updated_at` for the whole table on every nudge.
  """
  def repositions(ordered) do
    ordered
    |> Enum.with_index()
    |> Enum.reject(fn {rule, index} -> rule.position == index end)
  end
end
