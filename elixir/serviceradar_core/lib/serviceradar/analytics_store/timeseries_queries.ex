defmodule ServiceRadar.AnalyticsStore.TimeseriesQueries do
  @moduledoc """
  Portable SQL for in-process `timeseries_metrics` readers.

  Timescale `time_bucket` / `DISTINCT ON` are not used: DuckDB has neither.
  Hive `_partition_date` is added only when the table is on pg_duckdb.
  """

  alias ServiceRadar.AnalyticsStore

  @doc "Latest interface metric value in a recent window."
  @spec latest_interface_value_sql(String.t(), String.t(), integer(), DateTime.t(), keyword()) ::
          {String.t(), [term()]}
  def latest_interface_value_sql(device_id, metric_name, if_index, cutoff, opts \\ []) do
    sql = """
    SELECT m.value
    FROM platform.timeseries_metrics AS m
    WHERE m.device_id = $1
      AND m.metric_name = $2
      AND m.if_index = $3
      AND m.timestamp > $4::timestamptz#{hive_prune(opts, "m", cutoff)}
    ORDER BY m.timestamp DESC
    LIMIT 1
    """

    {sql, [device_id, metric_name, if_index, cutoff]}
  end

  @doc "EXISTS-style probe: any SNMP sample for a device in the window."
  @spec snmp_present_sql(String.t(), DateTime.t(), keyword()) :: {String.t(), [term()]}
  def snmp_present_sql(device_id, cutoff, opts \\ []) do
    sql = """
    SELECT 1
    FROM platform.timeseries_metrics
    WHERE device_id = $1
      AND metric_type = 'snmp'
      AND timestamp > $2::timestamptz#{hive_prune(opts, nil, cutoff)}
    LIMIT 1
    """

    {sql, [device_id, cutoff]}
  end

  @doc """
  Interface sparkline buckets.

  `bucket_seconds` is the on-read floor (60 / 300 / 900 / ...). Postgres
  `time_bucket` is not used so the same SQL runs on DuckDB.
  """
  @spec interface_sparkline_sql(
          DateTime.t(),
          [String.t()],
          [integer()],
          [String.t()],
          pos_integer(),
          keyword()
        ) :: {String.t(), [term()]}
  def interface_sparkline_sql(
        cutoff,
        device_ids,
        if_indexes,
        metric_names,
        bucket_seconds,
        opts \\ []
      )
      when is_integer(bucket_seconds) and bucket_seconds > 0 do
    sql = """
    WITH wanted(device_id, if_index) AS (
      SELECT unnest($2::text[]) AS device_id, unnest($3::int[]) AS if_index
    )
    SELECT
      m.device_id,
      m.if_index,
      m.metric_name,
      to_timestamp(floor(extract(epoch FROM m.timestamp) / $5) * $5) AS bucket,
      MAX(m.value)::float8 AS value
    FROM platform.timeseries_metrics AS m
    INNER JOIN wanted w ON w.device_id = m.device_id AND w.if_index = m.if_index
    WHERE m.timestamp >= $1
      AND m.metric_name = ANY($4::text[])#{hive_prune(opts, "m", cutoff)}
    GROUP BY m.device_id, m.if_index, m.metric_name, bucket
    ORDER BY m.device_id, m.if_index, m.metric_name, bucket
    """

    {sql, [cutoff, device_ids, if_indexes, metric_names, bucket_seconds]}
  end

  defp hive_prune(opts, qualifier, %DateTime{} = cutoff) do
    case AnalyticsStore.dialect("timeseries_metrics", opts) do
      :duckdb ->
        date = cutoff |> DateTime.to_date() |> Date.to_iso8601()
        column = if qualifier, do: "#{qualifier}._partition_date", else: "_partition_date"
        "\n      AND #{column} >= DATE '#{date}'"

      :postgres ->
        ""
    end
  end
end
