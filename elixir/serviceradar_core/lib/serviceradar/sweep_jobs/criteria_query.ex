defmodule ServiceRadar.SweepJobs.CriteriaQuery do
  @moduledoc """
  Converts sweep targeting criteria to SRQL queries.

  This module provides a shared implementation for converting the target_criteria
  DSL (used by SweepGroup) into SRQL query strings. The same logic is used by:

  - The sweep targeting UI for preview counts
  - The SweepCompiler for extracting target IPs

  ## Example

      criteria = %{
        "discovery_sources" => %{"contains" => "armis"},
        "partition" => %{"eq" => "datacenter-1"}
      }

      CriteriaQuery.to_srql(criteria)
      # => "discovery_sources:armis partition:datacenter-1"

  Multiple criteria are combined with spaces (implicit AND in SRQL).
  """

  @doc """
  Converts target criteria map to an SRQL query string.

  Returns an empty string if criteria is empty or nil.

  ## Examples

      iex> CriteriaQuery.to_srql(%{"partition" => %{"eq" => "default"}})
      "partition:default"

      iex> CriteriaQuery.to_srql(%{"ip" => %{"in_cidr" => "10.0.0.0/8"}})
      "ip:10.0.0.0/8"

      iex> CriteriaQuery.to_srql(%{})
      ""
  """
  @spec to_srql(map() | nil) :: String.t()
  def to_srql(nil), do: ""
  def to_srql(criteria) when criteria == %{}, do: ""

  def to_srql(criteria) when is_map(criteria) do
    clauses =
      criteria
      |> Enum.map(fn {field, spec} -> criteria_clause(field, spec) end)
      |> Enum.reject(fn clause -> is_nil(clause) or clause == "" end)

    Enum.join(clauses, " ")
  end

  @doc """
  Builds a full SRQL query for counting matching devices.

  ## Example

      iex> CriteriaQuery.count_query(%{"partition" => %{"eq" => "default"}})
      "in:devices partition:default stats:\"count() as total\""
  """
  @spec count_query(map() | nil) :: String.t()
  def count_query(criteria) do
    srql = to_srql(criteria)

    if srql == "" do
      ~s|in:devices stats:"count() as total"|
    else
      ~s|in:devices #{srql} stats:"count() as total"|
    end
  end

  @doc """
  Builds a full SRQL query for selecting device IPs.

  ## Example

      iex> CriteriaQuery.select_ips_query(%{"partition" => %{"eq" => "default"}})
      "in:devices partition:default select:ip"
  """
  @spec select_ips_query(map() | nil) :: String.t()
  def select_ips_query(criteria) do
    srql = to_srql(criteria)

    if srql == "" do
      "in:devices select:ip"
    else
      "in:devices #{srql} select:ip"
    end
  end

  # Private functions

  defp criteria_clause(field, spec) when is_map(spec) do
    case Map.to_list(spec) do
      [{operator, value}] -> clause_for_operator(field, operator, value)
      _ -> ""
    end
  end

  defp criteria_clause(_field, _spec), do: ""

  # Tags operators
  defp clause_for_operator("tags", operator, tags) when operator in ["has_any", "has_all"] do
    tags_to_srql(tags, operator)
  end

  # Discovery sources special handling (array field)
  defp clause_for_operator("discovery_sources", "contains", value) do
    "discovery_sources:#{escape_value(value)}"
  end

  defp clause_for_operator("discovery_sources", "not_contains", value) do
    "!discovery_sources:#{escape_value(value)}"
  end

  # IP CIDR/range operators
  defp clause_for_operator("ip", "in_cidr", cidr) do
    "ip:#{escape_value(to_string(cidr))}"
  end

  defp clause_for_operator("ip", "not_in_cidr", cidr) do
    "!ip:#{escape_value(to_string(cidr))}"
  end

  defp clause_for_operator("ip", "in_range", range) do
    "ip:#{escape_value(to_string(range))}"
  end

  # Null operators (not directly translatable to SRQL filter)
  defp clause_for_operator(_field, operator, _value)
       when operator in ["is_null", "is_not_null"] do
    nil
  end

  # Equality operators
  defp clause_for_operator(field, "eq", value) do
    "#{field}:#{escape_value(value)}"
  end

  defp clause_for_operator(field, "neq", value) do
    "!#{field}:#{escape_value(value)}"
  end

  # String matching operators
  defp clause_for_operator(field, "contains", value) do
    "#{field}:#{escape_value("%#{value}%")}"
  end

  defp clause_for_operator(field, "not_contains", value) do
    "!#{field}:#{escape_value("%#{value}%")}"
  end

  defp clause_for_operator(field, "starts_with", value) do
    "#{field}:#{escape_value("#{value}%")}"
  end

  defp clause_for_operator(field, "ends_with", value) do
    "#{field}:#{escape_value("%#{value}")}"
  end

  # Numeric comparison operators
  defp clause_for_operator(field, "gt", value) do
    "#{field}:>#{escape_value(value)}"
  end

  defp clause_for_operator(field, "gte", value) do
    "#{field}:>=#{escape_value(value)}"
  end

  defp clause_for_operator(field, "lt", value) do
    "#{field}:<#{escape_value(value)}"
  end

  defp clause_for_operator(field, "lte", value) do
    "#{field}:<=#{escape_value(value)}"
  end

  # List operators
  defp clause_for_operator(field, "in", value) do
    build_list_clause(field, value, false)
  end

  defp clause_for_operator(field, "not_in", value) do
    build_list_clause(field, value, true)
  end

  defp clause_for_operator(_field, _operator, _value), do: ""

  # Tags to SRQL conversion
  defp tags_to_srql(tags, operator) when is_list(tags) do
    clauses =
      tags
      |> Enum.map(&tag_to_srql/1)
      |> Enum.reject(&(&1 == ""))

    case clauses do
      [] ->
        ""

      _ ->
        separator = if operator == "has_any", do: " OR ", else: " "
        "(" <> Enum.join(clauses, separator) <> ")"
    end
  end

  defp tags_to_srql(_tags, _operator), do: ""

  defp tag_to_srql(tag) do
    value = to_string(tag) |> String.trim()

    case String.split(value, "=", parts: 2) do
      [key, val] when key != "" and val != "" ->
        "tags.#{key}:#{escape_value(val)}"

      [key] when key != "" ->
        "tags:#{escape_value(key)}"

      _ ->
        ""
    end
  end

  # List clause building
  defp build_list_clause(field, values, negated) when is_list(values) do
    escaped = Enum.map_join(values, ",", &escape_value/1)

    prefix = if negated, do: "!", else: ""
    "#{prefix}#{field}:(#{escaped})"
  end

  defp build_list_clause(field, value, negated) do
    build_list_clause(field, parse_list(to_string(value)), negated)
  end

  defp parse_list(value) do
    value
    |> String.split(~r/[\n,]+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Escapes a value for use in SRQL queries.

  Handles special characters and adds quotes when necessary.
  """
  @spec escape_value(term()) :: String.t()
  def escape_value(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    if String.match?(value, ~r/[\s":()]/) do
      "\"#{escaped}\""
    else
      escaped
    end
  end

  def escape_value(value), do: to_string(value)
end
