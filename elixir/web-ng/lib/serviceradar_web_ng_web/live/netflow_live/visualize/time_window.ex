defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.TimeWindow do
  @moduledoc false

  def display_window_from_query(query, fallback_time) when is_binary(query) and is_binary(fallback_time) do
    case time_token_from_query(query) do
      {:ok, token} -> display_time_token(token, fallback_time)
      {:error, _reason} -> relative_display(fallback_time)
    end
  rescue
    _ -> relative_display(fallback_time)
  end

  def display_window_from_query(_query, fallback_time), do: relative_display(fallback_time)

  def human_time_token(token) when is_binary(token) do
    t = String.trim(token)

    cond do
      String.starts_with?(t, "last_") ->
        String.replace_prefix(t, "last_", "Last ")

      bracket_range?(t) ->
        "Custom range"

      true ->
        t
    end
  end

  def parse_time_window_from_query(query) when is_binary(query) do
    with {:ok, token} <- time_token_from_query(query) do
      parse_time_token(token)
    end
  end

  defp time_token_from_query(query) do
    captures =
      Regex.run(
        ~r/(?:^|\s)time:(?:"([^"]+)"|(\[[^\]]+\])|(\S+))/,
        query,
        capture: :all_but_first
      )

    case Enum.find(captures || [], &(is_binary(&1) and &1 != "")) do
      token when is_binary(token) -> {:ok, token}
      nil -> {:error, :no_time}
    end
  end

  def parse_time_token("last_1h"), do: relative_window(3600)
  def parse_time_token("last_6h"), do: relative_window(6 * 3600)
  def parse_time_token("last_12h"), do: relative_window(12 * 3600)
  def parse_time_token("last_24h"), do: relative_window(24 * 3600)
  def parse_time_token("last_7d"), do: relative_window(7 * 24 * 3600)
  def parse_time_token("last_30d"), do: relative_window(30 * 24 * 3600)

  def parse_time_token(token) when is_binary(token) do
    token = String.trim(token)

    if bracket_range?(token) do
      parse_bracket_range(token)
    else
      case parse_last_duration_seconds(token) do
        {:ok, seconds} -> relative_window(seconds)
        {:error, _} -> {:error, :unsupported_time}
      end
    end
  end

  def relative_window(seconds) when is_integer(seconds) and seconds > 0 do
    end_dt = DateTime.truncate(DateTime.utc_now(), :second)
    start_dt = DateTime.add(end_dt, -seconds, :second)
    {:ok, {start_dt, end_dt}}
  end

  def parse_dt(value) when is_binary(value) do
    v = value |> String.trim() |> String.trim(~s|"|)

    case DateTime.from_iso8601(v) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, :invalid_dt}
    end
  end

  def bracket_range?(token) when is_binary(token) do
    String.starts_with?(token, "[") and String.ends_with?(token, "]")
  end

  def parse_bracket_range(token) when is_binary(token) do
    token
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(",", parts: 2)
    |> case do
      [s, e] ->
        with {:ok, sdt} <- parse_dt(s),
             {:ok, edt} <- parse_dt(e) do
          {:ok, {sdt, edt}}
        end

      _ ->
        {:error, :invalid_range}
    end
  end

  def parse_last_duration_seconds(token) when is_binary(token) do
    case Regex.run(~r/^last_(\d+)([mhd])$/, token) do
      [_, n, unit] ->
        {n, ""} = Integer.parse(n)

        seconds =
          case unit do
            "m" -> n * 60
            "h" -> n * 3600
            "d" -> n * 24 * 3600
          end

        {:ok, seconds}

      _ ->
        {:error, :invalid_last}
    end
  end

  defp display_time_token(token, fallback_time) do
    if bracket_range?(token) do
      case parse_time_token(token) do
        {:ok, {start_dt, end_dt}} -> %{type: :absolute, start: start_dt, end: end_dt}
        {:error, _reason} -> relative_display(fallback_time)
      end
    else
      relative_display(token)
    end
  end

  defp relative_display(token), do: %{type: :relative, label: human_time_token(token)}
end
