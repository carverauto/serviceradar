defmodule ServiceRadar.EventWriter.FieldParser do
  @moduledoc """
  Shared field parsing functions for EventWriter processors.

  Provides common parsing and encoding functions used across all processors
  to ensure consistent handling of timestamps, JSON, durations, and other
  common data types from NATS JetStream messages.
  """

  @doc """
  Parses a timestamp from various formats into a DateTime.

  Supports:
  - ISO8601 strings ("2024-01-01T00:00:00Z")
  - Unix timestamps in seconds (1704067200)
  - Unix timestamps in milliseconds (1704067200000)
  - Unix timestamps in nanoseconds (1704067200000000000)

  Returns `DateTime.utc_now()` if parsing fails or input is nil.

  ## Examples

      iex> FieldParser.parse_timestamp("2024-01-01T00:00:00Z")
      ~U[2024-01-01 00:00:00Z]

      iex> FieldParser.parse_timestamp(1704067200)
      ~U[2024-01-01 00:00:00Z]

      iex> FieldParser.parse_timestamp(nil)
      # Returns DateTime.utc_now()
  """
  @spec parse_timestamp(nil | String.t() | integer()) :: DateTime.t()
  def parse_timestamp(nil), do: DateTime.utc_now()

  def parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  def parse_timestamp(ts) when is_integer(ts) do
    cond do
      # Nanoseconds (> 1e18)
      ts > 1_000_000_000_000_000_000 ->
        DateTime.from_unix!(div(ts, 1_000_000_000), :second)

      # Milliseconds (> 1e12)
      ts > 1_000_000_000_000 ->
        DateTime.from_unix!(ts, :millisecond)

      # Seconds
      true ->
        DateTime.from_unix!(ts, :second)
    end
  rescue
    _ -> DateTime.utc_now()
  end

  def parse_timestamp(_), do: DateTime.utc_now()

  @doc """
  Encodes a value for JSONB storage in PostgreSQL.

  - Maps and lists are passed through as-is (Ecto handles encoding)
  - JSON strings are decoded first
  - nil and other values return nil

  ## Examples

      iex> FieldParser.encode_jsonb(%{"key" => "value"})
      %{"key" => "value"}

      iex> FieldParser.encode_jsonb(~s({"key": "value"}))
      %{"key" => "value"}

      iex> FieldParser.encode_jsonb(nil)
      nil
  """
  @spec encode_jsonb(nil | map() | list() | String.t()) :: nil | map() | list()
  def encode_jsonb(nil), do: nil
  def encode_jsonb(value) when is_map(value), do: value
  def encode_jsonb(value) when is_list(value), do: value

  def encode_jsonb(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end

  def encode_jsonb(_), do: nil

  @doc """
  Encodes a value as a JSON string for TEXT storage.

  Used when the database column is TEXT but stores JSON data.

  ## Examples

      iex> FieldParser.encode_json(%{"key" => "value"})
      ~s({"key":"value"})

      iex> FieldParser.encode_json(nil)
      nil
  """
  @spec encode_json(nil | map() | list() | String.t()) :: nil | String.t()
  def encode_json(nil), do: nil

  def encode_json(value) when is_map(value) or is_list(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      _ -> nil
    end
  end

  def encode_json(value) when is_binary(value), do: value
  def encode_json(_), do: nil

  @doc """
  Parses duration in milliseconds from a JSON map.

  Looks for common duration field names and converts to milliseconds.

  ## Examples

      iex> FieldParser.parse_duration_ms(%{"duration_ms" => 1500})
      1500.0

      iex> FieldParser.parse_duration_ms(%{"duration_seconds" => 1.5})
      1500.0
  """
  @spec parse_duration_ms(map()) :: float() | nil
  def parse_duration_ms(json) when is_map(json) do
    cond do
      json["duration_ms"] -> to_float(json["duration_ms"])
      json["durationMs"] -> to_float(json["durationMs"])
      json["duration_seconds"] -> to_float(json["duration_seconds"]) * 1000
      json["durationSeconds"] -> to_float(json["durationSeconds"]) * 1000
      true -> nil
    end
  end

  def parse_duration_ms(_), do: nil

  @doc """
  Parses duration in seconds from a JSON map.

  Looks for common duration field names and converts to seconds.

  ## Examples

      iex> FieldParser.parse_duration_seconds(%{"duration_seconds" => 1.5})
      1.5

      iex> FieldParser.parse_duration_seconds(%{"duration_ms" => 1500})
      1.5
  """
  @spec parse_duration_seconds(map()) :: float() | nil
  def parse_duration_seconds(json) when is_map(json) do
    cond do
      json["duration_seconds"] -> to_float(json["duration_seconds"])
      json["durationSeconds"] -> to_float(json["durationSeconds"])
      json["duration_ms"] -> to_float(json["duration_ms"]) / 1000
      json["durationMs"] -> to_float(json["durationMs"]) / 1000
      true -> nil
    end
  end

  def parse_duration_seconds(_), do: nil

  @doc """
  Parses a numeric value to float, handling strings and integers.

  ## Examples

      iex> FieldParser.parse_value(42)
      42.0

      iex> FieldParser.parse_value("3.14")
      3.14

      iex> FieldParser.parse_value(nil)
      0.0
  """
  @spec parse_value(nil | number() | String.t()) :: float()
  def parse_value(nil), do: 0.0
  def parse_value(v) when is_number(v), do: v / 1
  def parse_value(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end
  def parse_value(_), do: 0.0

  @doc """
  Safely converts a value to int64, clamping to valid range.

  Useful for bigint columns that might receive very large numbers.

  ## Examples

      iex> FieldParser.safe_bigint(12345)
      12345

      iex> FieldParser.safe_bigint(nil)
      nil
  """
  @max_int64 9_223_372_036_854_775_807
  @min_int64 -9_223_372_036_854_775_808

  @spec safe_bigint(nil | integer() | String.t()) :: nil | integer()
  def safe_bigint(nil), do: nil

  def safe_bigint(value) when is_integer(value) do
    cond do
      value > @max_int64 -> @max_int64
      value < @min_int64 -> @min_int64
      true -> value
    end
  end

  def safe_bigint(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> safe_bigint(int)
      :error -> nil
    end
  end

  def safe_bigint(_), do: nil

  @doc """
  Gets a field from a map, trying both snake_case and camelCase variants.

  ## Examples

      iex> FieldParser.get_field(%{"service_name" => "foo"}, "service_name", "serviceName")
      "foo"

      iex> FieldParser.get_field(%{"serviceName" => "bar"}, "service_name", "serviceName")
      "bar"
  """
  @spec get_field(map(), String.t(), String.t(), term()) :: term()
  def get_field(json, snake_key, camel_key, default \\ nil) do
    json[snake_key] || json[camel_key] || default
  end

  # Private helpers

  defp to_float(v) when is_float(v), do: v
  defp to_float(v) when is_integer(v), do: v / 1
  defp to_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end
  defp to_float(_), do: nil
end
