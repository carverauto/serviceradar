defmodule ServiceRadar.Analytics.StarRocks.MetricConsumers do
  @moduledoc """
  StarRocks history reads for remaining metric consumers.

  CNPG current-state SNMP interface facts stay on CNPG. These helpers only
  run when `Readers.mode_for(:metrics)` is `starrocks`.
  """

  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.Query
  alias ServiceRadar.Analytics.StarRocks.Readers

  @sparkline_metrics ~w(ifHCInOctets ifHCOutOctets ifInOctets ifOutOctets)

  @spec metrics_alive?(DateTime.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def metrics_alive?(since, opts \\ []) when is_struct(since, DateTime) do
    sql =
      "SELECT 1 FROM #{Env.table("timeseries_metrics")} WHERE `timestamp` >= '#{iso(since)}' LIMIT 1"

    case query(opts).(sql) do
      {:ok, %{num_rows: n}} when is_integer(n) -> {:ok, n > 0}
      {:ok, %{rows: rows}} when is_list(rows) -> {:ok, rows != []}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec snmp_present?(String.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def snmp_present?(device_id, opts \\ []) when is_binary(device_id) do
    case quote_id(device_id) do
      nil ->
        {:ok, false}

      quoted ->
        sql =
          "SELECT 1 FROM #{Env.table("timeseries_metrics")} " <>
            "WHERE device_id = #{quoted} AND metric_type = 'snmp' " <>
            "AND `timestamp` > DATE_ADD(NOW(), INTERVAL -24 HOUR) LIMIT 1"

        case query(opts).(sql) do
          {:ok, %{num_rows: n}} when is_integer(n) -> {:ok, n > 0}
          {:ok, %{rows: rows}} when is_list(rows) -> {:ok, rows != []}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec directional_rows(
          [String.t()],
          [String.t()],
          [integer()],
          [String.t()],
          DateTime.t(),
          keyword()
        ) :: [{term(), term(), integer(), String.t(), term()}]
  def directional_rows(device_ids, device_ips, if_indexes, metric_names, since, opts \\ []) do
    devices = Enum.flat_map(device_ids, fn id -> List.wrap(quote_id(id)) end)
    ips = Enum.flat_map(device_ips, fn ip -> List.wrap(quote_id(ip)) end)
    indexes = Enum.filter(if_indexes, &is_integer/1)
    names = Enum.flat_map(metric_names, fn name -> List.wrap(quote_id(name)) end)

    if devices == [] or indexes == [] or names == [] do
      []
    else
      sql =
        "SELECT device_id, target_device_ip, if_index, metric_name, value FROM (" <>
          "SELECT device_id, target_device_ip, if_index, metric_name, value, " <>
          "ROW_NUMBER() OVER (PARTITION BY device_id, target_device_ip, if_index, metric_name " <>
          "ORDER BY `timestamp` DESC) AS sample_rank " <>
          "FROM #{Env.table("timeseries_metrics")} " <>
          "WHERE #{scope_predicate(devices, ips)} " <>
          "AND if_index IN (#{Enum.join(indexes, ",")}) " <>
          "AND split_part(metric_name, '::', 1) IN (#{Enum.join(names, ",")}) " <>
          "AND `timestamp` > '#{iso(since)}'" <>
          ") latest WHERE sample_rank = 1"

      case query(opts).(sql) do
        {:ok, %{rows: rows}} ->
          Enum.flat_map(rows, fn
            [device_id, target_device_ip, if_index, metric_name, value] ->
              [{device_id, target_device_ip, if_index, metric_name, value}]

            _ ->
              []
          end)

        _ ->
          []
      end
    end
  end

  defp scope_predicate(devices, []), do: "device_id IN (#{Enum.join(devices, ",")})"

  defp scope_predicate(devices, ips) do
    "(device_id IN (#{Enum.join(devices, ",")}) OR " <>
      "target_device_ip IN (#{Enum.join(ips, ",")}))"
  end

  @spec sparkline_rows([{String.t(), integer()}], DateTime.t(), keyword()) ::
          {:ok, [list()]} | {:error, term()}
  def sparkline_rows(pairs, cutoff, opts \\ []) when is_list(pairs) do
    devices = pairs |> Enum.map(&elem(&1, 0)) |> Enum.flat_map(&List.wrap(quote_id(&1)))
    indexes = pairs |> Enum.map(&elem(&1, 1)) |> Enum.filter(&is_integer/1)
    names = Enum.map(@sparkline_metrics, &quote_id/1)

    if devices == [] or indexes == [] do
      {:ok, []}
    else
      sql =
        "SELECT device_id, if_index, metric_name, date_trunc('minute', `timestamp`) AS bucket, MAX(value) AS value " <>
          "FROM #{Env.table("timeseries_metrics")} " <>
          "WHERE device_id IN (#{Enum.join(devices, ",")}) " <>
          "AND if_index IN (#{Enum.join(indexes, ",")}) " <>
          "AND metric_name IN (#{Enum.join(names, ",")}) " <>
          "AND `timestamp` >= '#{iso(cutoff)}' " <>
          "GROUP BY device_id, if_index, metric_name, bucket " <>
          "ORDER BY device_id, if_index, metric_name, bucket"

      case query(opts).(sql) do
        {:ok, %{rows: rows}} -> {:ok, rows}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec fetch(keyword()) :: term()
  def fetch(opts) when is_list(opts) do
    Readers.fetch(:metrics, %{
      cnpg: Keyword.fetch!(opts, :cnpg),
      starrocks: Keyword.fetch!(opts, :starrocks)
    })
  end

  defp query(opts), do: Keyword.get(opts, :query, &Query.execute/1)

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp quote_id(value) when is_binary(value) do
    if value =~ ~r/^[A-Za-z0-9:_.\/-]+$/, do: "'#{value}'"
  end

  defp quote_id(_), do: nil
end
