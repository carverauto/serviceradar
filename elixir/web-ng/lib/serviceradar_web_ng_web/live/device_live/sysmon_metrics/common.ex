defmodule ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Common do
  @moduledoc false

  def escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  def escape_value(other), do: escape_value(to_string(other))

  def format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  def format_error(%ArgumentError{} = err), do: Exception.message(err)
  def format_error(reason) when is_binary(reason), do: reason
  def format_error(reason), do: inspect(reason)

  def timestamp_sort_key(row) when is_map(row) do
    case parse_datetime(Map.get(row, "timestamp")) do
      {:ok, dt} -> DateTime.to_unix(dt, :millisecond)
      _ -> 0
    end
  end

  def timestamp_sort_key(_), do: 0

  def parse_datetime(%DateTime{} = dt), do: {:ok, dt}

  def parse_datetime(%NaiveDateTime{} = ndt) do
    {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
  end

  def parse_datetime(value) when is_binary(value) do
    value = String.trim(value)

    with {:error, _} <- DateTime.from_iso8601(value),
         {:ok, ndt} <- NaiveDateTime.from_iso8601(value) do
      {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
    else
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, :invalid_datetime}
    end
  end

  def parse_datetime(_), do: {:error, :invalid_datetime}

  def parse_number(value) when is_integer(value), do: value * 1.0
  def parse_number(value) when is_float(value), do: value

  def parse_number(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      match?({_, ""}, Float.parse(value)) ->
        {v, ""} = Float.parse(value)
        v

      match?({_, ""}, Integer.parse(value)) ->
        {v, ""} = Integer.parse(value)
        v * 1.0

      true ->
        nil
    end
  end

  def parse_number(_), do: nil

  def map_value(%{} = row, key) do
    Map.get(row, key) || Map.get(row, to_string(key)) || Map.get(row, existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  def map_value(_row, _key), do: nil

  defp existing_atom(key) when is_atom(key), do: key
  defp existing_atom(key) when is_binary(key), do: String.to_existing_atom(key)
end
