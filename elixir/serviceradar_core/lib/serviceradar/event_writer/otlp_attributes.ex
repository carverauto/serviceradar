defmodule ServiceRadar.EventWriter.OtlpAttributes do
  @moduledoc """
  Shared helpers for converting OTLP protobuf attribute structures
  (`KeyValue` / `AnyValue`) into plain Elixir terms.
  """

  alias Opentelemetry.Proto.Common.V1.AnyValue
  alias Opentelemetry.Proto.Common.V1.ArrayValue
  alias Opentelemetry.Proto.Common.V1.KeyValue
  alias Opentelemetry.Proto.Common.V1.KeyValueList

  @doc """
  Converts a list of OTLP `KeyValue` structs into a plain map.
  """
  @spec key_values_to_map(term()) :: map()
  def key_values_to_map(values) when is_list(values) do
    Enum.reduce(values, %{}, fn
      %KeyValue{key: key, value: value}, acc when is_binary(key) and key != "" ->
        Map.put(acc, key, any_value_to_term(value))

      _, acc ->
        acc
    end)
  end

  def key_values_to_map(_), do: %{}

  @doc """
  Converts an OTLP `AnyValue` into a plain Elixir term.
  """
  @spec any_value_to_term(term()) :: term()
  def any_value_to_term(%AnyValue{value: {:string_value, value}}), do: value
  def any_value_to_term(%AnyValue{value: {:bool_value, value}}), do: value
  def any_value_to_term(%AnyValue{value: {:int_value, value}}), do: value
  def any_value_to_term(%AnyValue{value: {:double_value, value}}), do: value

  def any_value_to_term(%AnyValue{value: {:bytes_value, value}}) when is_binary(value),
    do: Base.encode64(value)

  def any_value_to_term(%AnyValue{value: {:array_value, %ArrayValue{values: values}}}) do
    Enum.map(values, &any_value_to_term/1)
  end

  def any_value_to_term(%AnyValue{value: {:kvlist_value, %KeyValueList{values: values}}}) do
    key_values_to_map(values)
  end

  def any_value_to_term(_), do: nil
end
