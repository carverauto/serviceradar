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

  @counter_modulus_32 "4294967296"
  @counter_modulus_64 "18446744073709551616"

  @doc """
  Per-second rate SQL over `value`, `previous_value`, `counter_width` and
  `max_rate_per_second` (the producer's plausibility ceiling, NULL when absent).

  This is the SRQL rate rule (`rust/srql/src/query/downsample/sql.rs`), shared by
  the CNPG and StarRocks topology readers so they cannot diverge. An increase is
  a plain delta unless it exceeds the ceiling. A decrease is a wrap only when the
  implied rate is plausible: a 64-bit counter wraps only under a producer ceiling,
  a 32-bit counter under the ceiling or 2^32/s, and a counter of unknown width
  only when the previous value still fit in 32 bits. Any other decrease is a
  reset and yields NULL.
  """
  @spec counter_rate_sql(String.t()) :: String.t()
  def counter_rate_sql(elapsed_seconds_sql) do
    elapsed = "NULLIF(#{elapsed_seconds_sql}, 0)"
    wrapped_32 = "(value + #{@counter_modulus_32} - previous_value) / #{elapsed}"
    wrapped_64 = "(value + #{@counter_modulus_64} - previous_value) / #{elapsed}"
    ceiling_32 = "COALESCE(max_rate_per_second, #{@counter_modulus_32})"

    """
    CASE
      WHEN value >= previous_value
        AND (max_rate_per_second IS NULL
          OR (value - previous_value) / #{elapsed} <= max_rate_per_second)
        THEN (value - previous_value) / #{elapsed}
      WHEN counter_width = 64 AND max_rate_per_second IS NOT NULL
        AND #{wrapped_64} <= max_rate_per_second THEN #{wrapped_64}
      WHEN counter_width = 32 AND #{wrapped_32} <= #{ceiling_32} THEN #{wrapped_32}
      WHEN counter_width IS NULL AND previous_value < #{@counter_modulus_32}
        AND #{wrapped_32} <= #{ceiling_32} THEN #{wrapped_32}
      ELSE NULL
    END
    """
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
      series = """
      (PARTITION BY gateway_id, agent_id, series_key,
        device_id, target_device_ip, if_index, metric_name ORDER BY `timestamp` DESC)
      """

      elapsed = "TIMESTAMPDIFF(MILLISECOND, previous_timestamp, `timestamp`) / 1000.0"

      sql = """
      SELECT device_id, target_device_ip, if_index, metric_name, rate_value AS value
      FROM (
        SELECT device_id, target_device_ip, if_index, metric_name,
          #{counter_rate_sql(elapsed)} AS rate_value
        FROM (
          SELECT *, ROW_NUMBER() OVER (
            PARTITION BY device_id, target_device_ip, if_index, metric_name
            ORDER BY `timestamp` DESC, COALESCE(gateway_id, ''),
              COALESCE(agent_id, ''), COALESCE(series_key, '')
          ) AS producer_rank
          FROM (
            SELECT gateway_id, agent_id, series_key,
              device_id, target_device_ip, if_index, metric_name, value, counter_width,
              CAST(NULL AS DOUBLE) AS max_rate_per_second, `timestamp`,
              LEAD(value) OVER #{series} AS previous_value,
              LEAD(`timestamp`) OVER #{series} AS previous_timestamp,
              ROW_NUMBER() OVER #{series} AS sample_rank
            FROM #{Env.table("timeseries_metrics")}
            WHERE #{scope_predicate(devices, ips)}
              AND if_index IN (#{Enum.join(indexes, ",")})
              AND split_part(metric_name, '::', 1) IN (#{Enum.join(names, ",")})
              AND `timestamp` > '#{iso(since)}'
          ) samples
          WHERE sample_rank = 1
        ) latest_producers
        WHERE producer_rank = 1 AND `timestamp` > previous_timestamp AND previous_value >= 0 AND value >= 0
      ) rated
      WHERE rate_value IS NOT NULL
      """

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

  @spec sparkline_rows([{String.t(), integer()}], DateTime.t(), pos_integer(), keyword()) ::
          {:ok, [list()]} | {:error, term()}
  def sparkline_rows(pairs, cutoff, bucket_seconds, opts \\ [])
      when is_list(pairs) and is_integer(bucket_seconds) and bucket_seconds > 0 do
    names = Enum.map(@sparkline_metrics, &quote_id/1)

    case pair_predicates(pairs) do
      [] ->
        {:ok, []}

      predicates ->
        sql =
          "SELECT device_id, if_index, metric_name, " <>
            "time_slice(`timestamp`, INTERVAL #{bucket_seconds} SECOND) AS bucket, " <>
            "MAX(value) AS value " <>
            "FROM #{Env.table("timeseries_metrics")} " <>
            "WHERE (#{Enum.join(predicates, " OR ")}) " <>
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

  defp pair_predicates(pairs) do
    pairs
    |> Enum.flat_map(fn
      {device_id, if_index} when is_integer(if_index) ->
        case quote_id(device_id) do
          quoted when is_binary(quoted) -> ["(device_id = #{quoted} AND if_index = #{if_index})"]
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  @doc """
  Per-second rate for each `{device_id, if_index, metric_name}` over the two
  newest samples in the last five minutes.

  The rate is `counter_rate_sql/1`. A missing pair or a reset yields no entry,
  which callers treat as "skip this sample".
  """
  @spec latest_interface_rates([{String.t(), integer(), String.t()}], keyword()) ::
          {:ok, map()} | {:error, term()}
  def latest_interface_rates(keys, opts \\ []) when is_list(keys) do
    case latest_predicates(keys) do
      [] ->
        {:ok, %{}}

      predicates ->
        series =
          "(PARTITION BY device_id, if_index, metric_name ORDER BY `timestamp` DESC)"

        elapsed = "TIMESTAMPDIFF(MILLISECOND, previous_timestamp, `timestamp`) / 1000.0"

        sql =
          "SELECT device_id, if_index, metric_name, rate_value FROM (" <>
            "SELECT device_id, if_index, metric_name, #{counter_rate_sql(elapsed)} AS rate_value " <>
            "FROM (" <>
            "SELECT device_id, if_index, metric_name, value, counter_width, " <>
            "CAST(NULL AS DOUBLE) AS max_rate_per_second, `timestamp`, " <>
            "LEAD(value) OVER #{series} AS previous_value, " <>
            "LEAD(`timestamp`) OVER #{series} AS previous_timestamp, " <>
            "ROW_NUMBER() OVER #{series} AS sample_rank " <>
            "FROM #{Env.table("timeseries_metrics")} " <>
            "WHERE `timestamp` > DATE_ADD(NOW(), INTERVAL -5 MINUTE) " <>
            "AND (#{Enum.join(predicates, " OR ")}) " <>
            ") samples WHERE sample_rank = 1 " <>
            "AND `timestamp` > previous_timestamp AND previous_value >= 0 AND value >= 0" <>
            ") rated WHERE rate_value IS NOT NULL"

        case query(opts).(sql) do
          {:ok, %{rows: rows}} when is_list(rows) -> {:ok, decode_latest_rows(rows)}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_query_result, other}}
        end
    end
  end

  defp latest_predicates(keys) do
    keys
    |> Enum.flat_map(fn
      {device_id, if_index, metric_name} when is_integer(if_index) ->
        case {quote_id(device_id), quote_id(metric_name)} do
          {device, metric} when is_binary(device) and is_binary(metric) ->
            ["(device_id = #{device} AND if_index = #{if_index} AND metric_name = #{metric})"]

          _ ->
            []
        end

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp decode_latest_rows(rows) do
    Enum.reduce(rows, %{}, fn
      [device_id, if_index, metric_name, value], acc
      when is_binary(device_id) and is_binary(metric_name) ->
        case normalize_if_index(if_index) do
          index when is_integer(index) ->
            Map.put_new(acc, {device_id, index, metric_name}, value)

          _ ->
            acc
        end

      _, acc ->
        acc
    end)
  end

  defp normalize_if_index(index) when is_integer(index), do: index

  defp normalize_if_index(index) when is_binary(index) do
    case Integer.parse(index) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_if_index(_index), do: nil

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
