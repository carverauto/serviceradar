defmodule ServiceRadarWebNGWeb.ServiceLive.Show.Query do
  @moduledoc false

  def build(params, limit) do
    filters = build_filters(params)
    filters = if filters == [], do: ["service_type:plugin"], else: filters

    Enum.join(["in:services"] ++ filters ++ ["sort:timestamp:desc", "limit:#{limit}"], " ")
  end

  def normalize(nil), do: nil
  def normalize(""), do: nil

  def normalize(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  def normalize(_value), do: nil

  def pick_service(services, params) when is_list(services) do
    case parse_datetime(Map.get(params, "timestamp")) do
      {:ok, target} ->
        Enum.find(services, &matches_timestamp?(&1, target)) || List.first(services)

      _ ->
        List.first(services)
    end
  end

  def pick_service(_services, _params), do: nil

  def fallback(params, limit) do
    if Map.has_key?(params, "q") do
      nil
    else
      filters = build_history_fallback_filters(params)

      if filters == [] do
        nil
      else
        Enum.join(["in:services"] ++ filters ++ ["sort:timestamp:desc", "limit:#{limit}"], " ")
      end
    end
  end

  def parse_datetime(value) when is_binary(value) do
    trimmed = String.trim(value)

    case DateTime.from_iso8601(trimmed) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      _ ->
        case Integer.parse(trimmed) do
          {integer, ""} -> parse_unix_timestamp(integer)
          _ -> :error
        end
    end
  end

  def parse_datetime(value) when is_integer(value), do: parse_unix_timestamp(value)
  def parse_datetime(_value), do: :error

  defp build_filters(params) do
    service_id = Map.get(params, "service_id") || Map.get(params, "uid")

    if is_binary(service_id) and service_id != "" do
      ["service_id:\"#{escape_value(service_id)}\""]
    else
      Enum.flat_map(
        [:service_name, :service_type, :gateway_id, :agent_id, :partition],
        &filter_param(params, &1)
      )
    end
  end

  defp build_history_fallback_filters(params) do
    agent_id = Map.get(params, "agent_id")

    keys =
      if is_binary(agent_id) and agent_id != "" do
        [:service_name, :service_type, :agent_id, :partition]
      else
        [:service_name, :service_type, :gateway_id, :partition]
      end

    Enum.flat_map(keys, &filter_param(params, &1))
  end

  defp filter_param(params, key) do
    value = Map.get(params, Atom.to_string(key))

    if is_binary(value) and value != "" do
      ["#{key}:\"#{escape_value(value)}\""]
    else
      []
    end
  end

  defp escape_value(value) do
    value
    |> to_string()
    |> String.replace("\"", "\\\"")
  end

  defp matches_timestamp?(service, %DateTime{} = target) when is_map(service) do
    case parse_datetime(Map.get(service, "timestamp")) do
      {:ok, datetime} -> DateTime.compare(datetime, target) == :eq
      _ -> false
    end
  end

  defp matches_timestamp?(_service, _target), do: false

  defp parse_unix_timestamp(value) when is_integer(value) do
    cond do
      value <= 0 ->
        :error

      value > 1_000_000_000_000_000_000 ->
        :error

      value >= 1_000_000_000_000_000 ->
        seconds = div(value, 1_000_000_000)
        nanos = rem(value, 1_000_000_000)

        seconds
        |> DateTime.from_unix(:second)
        |> case do
          {:ok, datetime} -> {:ok, %{datetime | microsecond: {div(nanos, 1000), 6}}}
          error -> error
        end

      value >= 1_000_000_000_000 ->
        DateTime.from_unix(div(value, 1000), :millisecond)

      value > 1_000_000_000 ->
        DateTime.from_unix(value, :second)

      true ->
        DateTime.from_unix(value, :second)
    end
  end
end
