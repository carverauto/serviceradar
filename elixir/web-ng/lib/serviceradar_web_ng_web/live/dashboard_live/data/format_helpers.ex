defmodule ServiceRadarWebNGWeb.DashboardLive.Data.FormatHelpers do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      defp service_health_metric(%{total: total, availability_pct: pct}, _traces) when total > 0, do: format_percent(pct)

      defp service_health_metric(_services, %{total: total, error_rate: error_rate}) when total > 0,
        do: format_percent(100.0 - error_rate)

      defp service_health_metric(_, _), do: "No data"

      defp max_trend_total(points) do
        points
        |> Enum.map(& &1.total)
        |> Enum.max(fn -> 0 end)
      end

      defp average([]), do: 0.0

      defp average(values) do
        numeric = Enum.filter(values, &is_number/1)

        case numeric do
          [] -> 0.0
          _ -> Enum.sum(numeric) / length(numeric)
        end
      end

      defp unwrap_single_map(%{} = map) when map_size(map) == 1 do
        [{_key, value}] = Map.to_list(map)
        if is_map(value), do: value, else: map
      end

      defp unwrap_single_map(map), do: map

      defp map_value(map, key) when is_map(map) do
        Map.get(map, key) ||
          Enum.find_value(map, fn
            {atom_key, value} when is_atom(atom_key) ->
              if Atom.to_string(atom_key) == key, do: value

            _ ->
              nil
          end)
      end

      defp present?(value) when is_binary(value), do: String.trim(value) != ""
      defp present?(value), do: not is_nil(value)

      defp to_int(value) when is_integer(value), do: max(value, 0)
      defp to_int(value) when is_float(value), do: value |> trunc() |> max(0)
      defp to_int(%Decimal{} = value), do: value |> Decimal.to_integer() |> max(0)

      defp to_int(value) when is_binary(value) do
        case Integer.parse(String.trim(value)) do
          {parsed, _} -> max(parsed, 0)
          _ -> 0
        end
      end

      defp to_int(_), do: 0

      defp to_float(value) when is_float(value), do: value
      defp to_float(value) when is_integer(value), do: value * 1.0
      defp to_float(%Decimal{} = value), do: Decimal.to_float(value)

      defp to_float(value) when is_binary(value) do
        case Float.parse(String.trim(value)) do
          {parsed, _} -> parsed
          _ -> 0.0
        end
      end

      defp to_float(_), do: 0.0

      defp clamp(value, min_value, max_value), do: value |> max(min_value) |> min(max_value)

      defp format_count(value), do: value |> to_int() |> Integer.to_string() |> delimit_integer_string()

      defp format_compact_count(value) do
        count = to_int(value)

        cond do
          count >= 1_000_000 -> "#{format_float(count / 1_000_000)}M"
          count >= 10_000 -> "#{format_float(count / 1_000)}k"
          true -> format_count(count)
        end
      end

      defp delimit_integer_string(value) do
        value
        |> String.reverse()
        |> String.graphemes()
        |> Enum.chunk_every(3)
        |> Enum.map_join(",", &Enum.join/1)
        |> String.reverse()
      end

      defp format_percent(value), do: value |> to_float() |> Float.round(1) |> :erlang.float_to_binary(decimals: 1)
      defp format_float(value), do: value |> to_float() |> Float.round(1) |> :erlang.float_to_binary(decimals: 1)

      defp format_rate(value) when value >= 1_000_000_000, do: "#{format_float(value / 1_000_000_000)}G"
      defp format_rate(value) when value >= 1_000_000, do: "#{format_float(value / 1_000_000)}M"
      defp format_rate(value) when value >= 1_000, do: "#{format_float(value / 1_000)}K"
      defp format_rate(value) when value > 0, do: format_float(value)
      defp format_rate(_), do: "No data"

      defp format_bytes(value) when value >= 1_099_511_627_776, do: "#{format_float(value / 1_099_511_627_776)} TiB"
      defp format_bytes(value) when value >= 1_073_741_824, do: "#{format_float(value / 1_073_741_824)} GiB"
      defp format_bytes(value) when value >= 1_048_576, do: "#{format_float(value / 1_048_576)} MiB"
      defp format_bytes(value) when value >= 1024, do: "#{format_float(value / 1024)} KiB"
      defp format_bytes(value) when value > 0, do: "#{value} B"
      defp format_bytes(_), do: "No data"

      defp bucket_label(%DateTime{} = bucket), do: DateTime.to_iso8601(bucket)
      defp bucket_label(%NaiveDateTime{} = bucket), do: bucket |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
      defp bucket_label(bucket), do: to_string(bucket)

      defp unix_ms(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)

      defp unix_ms(%NaiveDateTime{} = value),
        do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)

      defp unix_ms(_), do: 0
    end
  end
end
