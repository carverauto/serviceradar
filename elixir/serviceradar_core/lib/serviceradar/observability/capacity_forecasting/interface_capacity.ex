defmodule ServiceRadar.Observability.CapacityForecasting.InterfaceCapacity do
  @moduledoc """
  Resolves the live interface capacity denominator for capacity forecasts.

  Forecasting reads long-horizon interface throughput from hourly CAGGs, but
  link speed lives in the short-retention `discovered_interfaces` inventory
  table. This module joins the latest inventory denominator at forecast time.
  """

  import Ecto.Query

  alias ServiceRadar.Repo

  @spec resolve(map(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def resolve(row, opts \\ []) when is_map(row) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, if_index} <- if_index(row),
         {:ok, partition} <- partition(row),
         identifiers when identifiers != [] <- identifiers(row) do
      query =
        from(i in "discovered_interfaces",
          where: i.partition == ^partition,
          where: i.if_index == ^if_index,
          where:
            fragment(
              "? = ANY(?) OR ? = ANY(?) OR ? = ANY(?)",
              i.device_id,
              type(^identifiers, {:array, :string}),
              i.device_ip,
              type(^identifiers, {:array, :string}),
              i.gateway_id,
              type(^identifiers, {:array, :string})
            ),
          order_by: [desc: i.timestamp],
          limit: 1,
          select: %{
            device_id: i.device_id,
            device_ip: i.device_ip,
            if_index: i.if_index,
            if_name: i.if_name,
            if_alias: i.if_alias,
            speed_bps: i.speed_bps,
            if_speed: i.if_speed,
            timestamp: i.timestamp,
            partition: i.partition
          }
        )

      case repo.one(query) do
        nil -> {:ok, nil}
        match -> {:ok, normalize_match(match)}
      end
    else
      {:error, reason} -> {:ok, %{skip_reason: reason}}
      [] -> {:ok, %{skip_reason: :missing_interface_identity}}
    end
  rescue
    error -> {:error, error}
  end

  @spec utilization_percent(number(), pos_integer()) :: float()
  def utilization_percent(bytes_per_second, speed_bps)
      when is_number(bytes_per_second) and is_integer(speed_bps) and speed_bps > 0 do
    bytes_per_second * 8.0 * 100.0 / speed_bps
  end

  defp normalize_match(match) do
    speed_bps =
      positive_integer(Map.get(match, :speed_bps)) || positive_integer(Map.get(match, :if_speed))

    match
    |> Map.put(:speed_bps, speed_bps)
    |> Map.put(:source, "discovered_interfaces")
    |> maybe_mark_missing_capacity(speed_bps)
  end

  defp maybe_mark_missing_capacity(match, nil),
    do: Map.put(match, :skip_reason, :missing_interface_capacity)

  defp maybe_mark_missing_capacity(match, _speed_bps), do: match

  defp if_index(row) do
    case value(row, "if_index") do
      value when is_integer(value) and value > 0 -> {:ok, value}
      value when is_binary(value) -> parse_positive_integer(value)
      _ -> {:error, :missing_if_index}
    end
  end

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, :missing_if_index}
    end
  end

  defp partition(row) do
    row
    |> identifier_values(["partition", "partition_id"])
    |> Enum.find_value(fn value ->
      value = String.trim(value)
      if value == "", do: nil, else: value
    end)
    |> case do
      nil -> {:error, :missing_partition}
      value -> {:ok, value}
    end
  end

  defp identifiers(row) do
    row
    |> identifier_values(["device_id", "target_device_ip", "device_ip", "gateway_id"])
    |> Enum.flat_map(&split_endpoint/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp identifier_values(row, fields) do
    fields
    |> Enum.map(&value(row, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
  end

  defp split_endpoint(value) do
    case String.split(value, ":", parts: 2) do
      [_, rest] when rest != "" -> [value, rest]
      _ -> [value]
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(value) when is_float(value) and value > 0, do: trunc(value)
  defp positive_integer(_value), do: nil

  defp value(row, field) when is_map(row) do
    Map.get(row, field, Map.get(row, existing_atom(field)))
  rescue
    ArgumentError -> nil
  end

  defp existing_atom(field) when is_atom(field), do: field

  defp existing_atom(field) when is_binary(field) do
    String.to_existing_atom(field)
  rescue
    ArgumentError -> :__serviceradar_missing_field__
  end
end
