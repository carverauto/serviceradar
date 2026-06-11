defmodule ServiceRadar.Inventory.EndpointInventoryPayload do
  @moduledoc false

  @spec required_string(map(), atom()) ::
          {:ok, String.t()} | {:error, {:missing_required_key, atom()}}
  def required_string(payload, key) do
    case string_value(payload, key) do
      nil -> {:error, {:missing_required_key, key}}
      value -> {:ok, value}
    end
  end

  def value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  def string_value(map, key) when is_map(map) do
    case value(map, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when is_atom(value) and not is_nil(value) ->
        Atom.to_string(value)

      value when is_integer(value) ->
        Integer.to_string(value)

      _ ->
        nil
    end
  end

  def string_value(_map, _key), do: nil

  def integer_value(map, key, default) when is_map(map) do
    case value(map, key) do
      value when is_integer(value) -> value
      value when is_float(value) -> round(value)
      value when is_binary(value) -> parse_integer(value, default)
      _ -> default
    end
  end

  def integer_value(_map, _key, default), do: default

  def number_value(map, key) when is_map(map) do
    case value(map, key) do
      value when is_integer(value) ->
        value * 1.0

      value when is_float(value) ->
        value

      value when is_binary(value) ->
        parse_float(value)

      _ ->
        nil
    end
  end

  def number_value(_map, _key), do: nil

  def truthy_value?(true), do: true
  def truthy_value?(value) when value in [false, nil, 0], do: false
  def truthy_value?(value) when is_integer(value), do: value != 0

  def truthy_value?(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> Kernel.in(["true", "1", "yes", "y"])
  end

  def truthy_value?(_value), do: false

  def boolean_value(map, key) when is_map(map) do
    case value(map, key) do
      value when is_boolean(value) ->
        value

      value when value in [0, 1] ->
        value == 1

      value when is_binary(value) ->
        value
        |> String.trim()
        |> String.downcase()
        |> case do
          value when value in ["true", "1", "yes", "y"] -> true
          value when value in ["false", "0", "no", "n"] -> false
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def boolean_value(_map, _key), do: nil

  def datetime_value(map, key) when is_map(map) do
    case value(map, key) do
      %DateTime{} = dt ->
        dt

      %NaiveDateTime{} = ndt ->
        DateTime.from_naive!(ndt, "Etc/UTC")

      value when is_integer(value) ->
        DateTime.from_unix!(value)

      value when is_binary(value) ->
        parse_datetime(value)

      _ ->
        nil
    end
  end

  def datetime_value(_map, _key), do: nil

  def unix_datetime(map, key) do
    case integer_value(map, key, nil) do
      nil -> nil
      value -> DateTime.from_unix!(value)
    end
  end

  def list_value(map, key) when is_map(map) do
    case value(map, key, []) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  def list_value(_map, _key), do: []

  def string_list_value(map, key) when is_map(map) do
    map
    |> list_value(key)
    |> Enum.flat_map(fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: [], else: [value]

      value when is_atom(value) and not is_nil(value) ->
        [Atom.to_string(value)]

      _ ->
        []
    end)
  end

  def string_list_value(_map, _key), do: []

  def map_value(map, key) when is_map(map) do
    case value(map, key, %{}) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  def map_value(_map, _key), do: %{}

  def metadata(map) when is_map(map), do: map_value(map, :metadata)
  def metadata(_map), do: %{}

  def trimmed(nil), do: ""

  def trimmed(value) when is_binary(value), do: String.trim(value)

  def trimmed(value), do: value |> to_string() |> String.trim()

  def trimmed_or_nil(value) do
    case trimmed(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def json_string(value), do: Jason.encode!(value)

  def iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def iso8601(_value), do: nil

  def compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  def blank?(value) when is_binary(value), do: String.trim(value) == ""
  def blank?(nil), do: true
  def blank?(_value), do: false

  defp parse_integer(value, default) do
    case Integer.parse(String.trim(value)) do
      {int, _rest} -> int
      :error -> default
    end
  end

  defp parse_float(value) do
    case Float.parse(String.trim(value)) do
      {float, _rest} -> float
      :error -> nil
    end
  end

  defp parse_datetime(value) do
    value = String.trim(value)

    with {:error, _} <- DateTime.from_iso8601(value),
         {:ok, ndt} <- NaiveDateTime.from_iso8601(value) do
      DateTime.from_naive!(ndt, "Etc/UTC")
    else
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end
end
