defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.TimeWindow do
  @moduledoc false

  def flows_window_label_from_query(query, fallback_time) when is_binary(query) and is_binary(fallback_time) do
    # Prefer explicit bracket range, otherwise show the state time token.
    case parse_time_window_from_query(query) do
      {:ok, {start_dt, end_dt}} ->
        # Keep this short in the UI; full query is already visible in the SRQL bar.
        "#{DateTime.to_iso8601(start_dt)} - #{DateTime.to_iso8601(end_dt)}"

      _ ->
        human_time_token(fallback_time)
    end
  rescue
    _ -> human_time_token(fallback_time)
  end

  def flows_window_label_from_query(_query, fallback_time), do: human_time_token(fallback_time)

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
    case Regex.run(~r/(?:^|\s)time:(?:"([^"]+)"|(\[[^\]]+\])|(\S+))/, query) do
      [_, quoted, _, _] when is_binary(quoted) and quoted != "" -> parse_time_token(quoted)
      [_, _, bracket, _] when is_binary(bracket) and bracket != "" -> parse_time_token(bracket)
      [_, _, _, token] when is_binary(token) and token != "" -> parse_time_token(token)
      _ -> {:error, :no_time}
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
end
