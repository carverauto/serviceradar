defmodule ServiceRadarWebNGWeb.SRQL.TimeWindow do
  @moduledoc false

  @default_seconds 3_600

  def token_from_query(query, default \\ nil)

  def token_from_query(query, default) when is_binary(query) do
    query
    |> scrub_quoted_segments()
    |> then(&Regex.run(~r/(?:^|\s)time:(\[[^\]]+\]|\S+)/i, &1))
    |> case do
      [_, token] -> normalize_token(token) || default
      _ -> default
    end
  end

  def token_from_query(_query, default), do: default

  def seconds(value, default \\ @default_seconds)

  def seconds(value, default) do
    case resolve(value) do
      {:ok, %{start: start_dt, end: end_dt}} -> max(DateTime.diff(end_dt, start_dt, :second), 1)
      _ -> default
    end
  end

  def preset_seconds("1h"), do: 3_600
  def preset_seconds("6h"), do: 21_600
  def preset_seconds("24h"), do: 86_400
  def preset_seconds("7d"), do: 604_800
  def preset_seconds("30d"), do: 2_592_000
  def preset_seconds(_), do: @default_seconds

  def resolve(value, now \\ DateTime.utc_now())

  def resolve(value, now) when is_binary(value) do
    value
    |> String.trim()
    |> normalize_token()
    |> resolve_normalized(now)
  end

  def resolve(_value, _now), do: {:error, :unsupported}

  defp resolve_normalized("today", now) do
    start =
      now
      |> DateTime.to_date()
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    {:ok, %{start: start, end: now}}
  end

  defp resolve_normalized("yesterday", now) do
    today = DateTime.to_date(now)
    start = today |> Date.add(-1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    end_dt = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")
    {:ok, %{start: start, end: end_dt}}
  end

  defp resolve_normalized(value, now) when is_binary(value) do
    cond do
      bracketed_time?(value) ->
        parse_bracketed_time(value)

      last_duration?(value) ->
        resolve_last_duration(value, now)

      true ->
        {:error, :unsupported}
    end
  end

  defp resolve_normalized(_value, _now), do: {:error, :unsupported}

  defp normalize_token(nil), do: nil

  defp normalize_token(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      bracketed_time?(value) ->
        value

      Regex.match?(~r/^\d+[smhdw]$/i, value) ->
        "last_#{String.downcase(value)}"

      true ->
        String.downcase(value)
    end
  end

  defp bracketed_time?(value) do
    String.starts_with?(value, "[") and String.ends_with?(value, "]")
  end

  defp parse_bracketed_time(value) do
    inner = value |> String.trim_leading("[") |> String.trim_trailing("]")

    case String.split(inner, ",", parts: 2) do
      [start_raw, end_raw] ->
        with {:ok, start_dt} <- parse_datetime(String.trim(start_raw)),
             {:ok, end_dt} <- parse_datetime(String.trim(end_raw)),
             true <- DateTime.compare(start_dt, end_dt) in [:lt, :eq] do
          {:ok, %{start: start_dt, end: end_dt}}
        else
          _ -> {:error, :bad_time}
        end

      _ ->
        {:error, :bad_time}
    end
  end

  defp last_duration?(value) do
    Regex.match?(~r/^(?:last[_-])?\d+[smhdw]$/i, value)
  end

  defp resolve_last_duration(value, now) do
    normalized = value |> String.downcase() |> String.replace(~r/^last[_-]/, "")
    amount = String.slice(normalized, 0, max(byte_size(normalized) - 1, 0))
    unit = String.slice(normalized, -1, 1)

    case Integer.parse(amount) do
      {n, ""} when n > 0 ->
        case duration_unit_multiplier(unit) do
          seconds when is_integer(seconds) and seconds > 0 ->
            {:ok, %{start: DateTime.add(now, -(n * seconds), :second), end: now}}

          _ ->
            {:error, :bad_time}
        end

      _ ->
        {:error, :bad_time}
    end
  end

  defp duration_unit_multiplier("s"), do: 1
  defp duration_unit_multiplier("m"), do: 60
  defp duration_unit_multiplier("h"), do: 3_600
  defp duration_unit_multiplier("d"), do: 86_400
  defp duration_unit_multiplier("w"), do: 604_800
  defp duration_unit_multiplier(_), do: 0

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} ->
        {:ok, dt}

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
          _ -> :error
        end
    end
  end

  defp scrub_quoted_segments(value), do: scrub_quoted_segments(value, false, false, [])

  defp scrub_quoted_segments(<<>>, _quoted?, _escaped?, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp scrub_quoted_segments(<<"\\", rest::binary>>, true, false, acc) do
    scrub_quoted_segments(rest, true, true, [" " | acc])
  end

  defp scrub_quoted_segments(<<_char::utf8, rest::binary>>, true, true, acc) do
    scrub_quoted_segments(rest, true, false, [" " | acc])
  end

  defp scrub_quoted_segments(<<"\"", rest::binary>>, false, false, acc) do
    scrub_quoted_segments(rest, true, false, [" " | acc])
  end

  defp scrub_quoted_segments(<<"\"", rest::binary>>, true, false, acc) do
    scrub_quoted_segments(rest, false, false, [" " | acc])
  end

  defp scrub_quoted_segments(<<_char::utf8, rest::binary>>, true, false, acc) do
    scrub_quoted_segments(rest, true, false, [" " | acc])
  end

  defp scrub_quoted_segments(<<char::utf8, rest::binary>>, false, false, acc) do
    scrub_quoted_segments(rest, false, false, [<<char::utf8>> | acc])
  end
end
