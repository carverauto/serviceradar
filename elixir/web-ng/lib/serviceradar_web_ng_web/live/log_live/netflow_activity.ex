defmodule ServiceRadarWebNGWeb.LogLive.NetflowActivity do
  @moduledoc false

  alias ServiceRadarWebNGWeb.NetflowVisualize.Query

  @protocol_keys ["tcp", "udp", "other"]
  @protocol_palette ["#4e79a7", "#59a14f", "#bab0ac"]
  @app_palette ["#4e79a7", "#f28e2b", "#e15759", "#76b7b2", "#59a14f", "#edc948", "#b07aa1", "#ff9da7"]

  def empty(bucket_seconds), do: %{bucket_seconds: bucket_seconds, keys: [], points: [], colors: %{}, error: nil}

  def load(kind, srql_module, query, scope, bucket_seconds, total_points)
      when kind in [:protocol, :app] and is_integer(bucket_seconds) and bucket_seconds > 0 and is_list(total_points) do
    base = query |> Query.flows_base_query("last_1h") |> Query.flows_sanitize_for_stats()

    with {:ok, keys} <- keys(kind, srql_module, base, scope),
         {:ok, rows} <- samples(srql_module, base, scope, bucket_seconds, kind, keys) do
      {:ok,
       %{
         bucket_seconds: bucket_seconds,
         keys: keys,
         points: points(rows, keys, total_points),
         colors: colors(kind, keys),
         error: nil
       }}
    end
  end

  def load(_kind, _srql_module, _query, _scope, _bucket_seconds, _total_points), do: {:error, :invalid_activity_request}

  def error_message(:protocol), do: "Protocol activity could not be loaded. Try again or choose a shorter time window."
  def error_message(:app), do: "Application activity could not be loaded. Try again or choose a shorter time window."

  defp keys(:protocol, _srql_module, _base, _scope), do: {:ok, @protocol_keys}

  defp keys(:app, srql_module, base, scope) do
    query = ~s|#{base} stats:"sum(bytes_total) as total_bytes by app" sort:total_bytes:desc limit:8|

    with {:ok, rows} <- rows(srql_module, query, scope) do
      keys =
        rows
        |> Enum.map(&Map.get(&1, "app"))
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 in ["", "unknown", "Unknown", "—", "-"]))
        |> Enum.uniq()
        |> Enum.take(8)

      {:ok, keys}
    end
  end

  # An empty ranking must not become an unrestricted downsample query.
  defp samples(_srql_module, _base, _scope, _bucket, _kind, []), do: {:ok, []}

  defp samples(srql_module, base, scope, bucket_seconds, kind, keys) do
    field = if kind == :protocol, do: "protocol_group", else: "app"
    values = Enum.map_join(keys, ",", &quoted_value/1)
    bucket = bucket(bucket_seconds)
    query = ~s|#{base} #{field}:(#{values}) bucket:#{bucket} agg:sum value_field:bytes_total series:#{field} limit:2000|
    rows(srql_module, query, scope)
  end

  defp rows(srql_module, query, scope) do
    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        if Enum.all?(results, &is_map/1) do
          {:ok,
           Enum.map(results, fn
             %{"payload" => %{} = payload} -> payload
             row -> row
           end)}
        else
          {:error, :invalid_activity_response}
        end

      {:error, _reason} ->
        {:error, :activity_query_failed}

      _ ->
        {:error, :invalid_activity_response}
    end
  rescue
    _ -> {:error, :activity_query_failed}
  end

  defp points(_rows, [], _total_points), do: []

  defp points(rows, keys, total_points) do
    series_maps = Enum.reduce(rows, %{}, &put_sample/2)

    total_points
    |> Enum.filter(&is_map/1)
    |> Enum.take(120)
    |> Enum.map(fn point ->
      dt = Map.fetch!(point, :bucket_start)

      Enum.reduce(keys, %{"t" => DateTime.to_iso8601(dt)}, fn key, acc ->
        value = Map.get(Map.get(series_maps, key, %{}), DateTime.to_unix(dt, :microsecond), 0)
        Map.put(acc, key, trunc(value))
      end)
    end)
  end

  defp put_sample(%{"timestamp" => timestamp, "series" => series, "value" => value}, acc) when is_binary(series) do
    with {:ok, dt} <- datetime(timestamp),
         series when series != "" <- String.trim(series),
         {:ok, bytes} <- number(value) do
      timestamp = DateTime.to_unix(dt, :microsecond)
      Map.update(acc, series, %{timestamp => bytes}, fn values -> Map.update(values, timestamp, bytes, &(&1 + bytes)) end)
    else
      _ -> acc
    end
  end

  defp put_sample(_row, acc), do: acc

  defp colors(kind, keys) do
    palette = if kind == :protocol, do: @protocol_palette, else: @app_palette
    keys |> Enum.with_index() |> Map.new(fn {key, index} -> {key, Enum.at(palette, index)} end)
  end

  defp quoted_value(value), do: ~s("#{value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")}")

  defp bucket(3600), do: "1h"
  defp bucket(21_600), do: "6h"
  defp bucket(seconds) when rem(seconds, 60) == 0, do: "#{div(seconds, 60)}m"
  defp bucket(seconds), do: "#{seconds}s"

  defp datetime(%DateTime{} = dt), do: {:ok, dt}
  defp datetime(%NaiveDateTime{} = dt), do: {:ok, DateTime.from_naive!(dt, "Etc/UTC")}

  defp datetime(value) when is_binary(value) do
    value = String.trim(value)

    case DateTime.from_iso8601(value) do
      {:ok, dt, _} ->
        {:ok, dt}

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, dt} -> datetime(dt)
          _ -> :error
        end
    end
  end

  defp datetime(_), do: :error

  defp number(%Decimal{} = value), do: {:ok, Decimal.to_float(value)}
  defp number(value) when is_number(value), do: {:ok, value}
  defp number(nil), do: {:ok, 0}

  defp number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  defp number(_), do: :error
end
