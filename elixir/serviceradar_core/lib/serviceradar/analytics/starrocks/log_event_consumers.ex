defmodule ServiceRadar.Analytics.StarRocks.LogEventConsumers do
  @moduledoc """
  StarRocks history reads for remaining log and event consumers.

  Current alert state, anomaly episodes, addon heartbeats, and Timescale CAGG
  refresh stay on CNPG. These helpers only run when `Readers.mode_for/1` is
  `starrocks` for `:logs` or `:events`.
  """

  alias ServiceRadar.Analytics.StarRocks.Query
  alias ServiceRadar.Analytics.StarRocks.Readers

  @spec fetch(atom(), keyword()) :: term()
  def fetch(dataset, opts) when dataset in [:logs, :events] and is_list(opts) do
    Readers.fetch(dataset, %{
      cnpg: Keyword.fetch!(opts, :cnpg),
      starrocks: Keyword.fetch!(opts, :starrocks)
    })
  end

  @spec event_window_rows(DateTime.t(), DateTime.t(), pos_integer(), keyword()) ::
          {:ok, %{rows: [list()]}} | {:error, term()}
  def event_window_rows(start_at, end_at, bucket_seconds, opts \\ [])
      when is_struct(start_at, DateTime) and is_struct(end_at, DateTime) and
             is_integer(bucket_seconds) and
             bucket_seconds > 0 do
    sql =
      """
      SELECT FROM_UNIXTIME(FLOOR(UNIX_TIMESTAMP(`time`) / #{bucket_seconds}) * #{bucket_seconds}), \
      COALESCE(severity_id, 0), COUNT(*) \
      FROM serviceradar.events \
      WHERE `time` >= '#{iso(start_at)}' AND `time` < '#{iso(end_at)}' \
      GROUP BY 1, 2 ORDER BY 1, 2
      """

    case query(opts).(sql) do
      {:ok, %{rows: rows}} -> {:ok, %{rows: Enum.flat_map(rows, &normalize_window_row/1)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec dns_rpz_clients(pos_integer(), pos_integer(), keyword()) ::
          {:ok, %{rows: [list()]}} | {:error, term()}
  def dns_rpz_clients(lookback_hours, max_hosts, opts \\ [])
      when is_integer(lookback_hours) and lookback_hours > 0 and is_integer(max_hosts) and
             max_hosts > 0 do
    sql =
      """
      SELECT src_endpoint_ip, firewall_rule_name, MAX(`time`) \
      FROM serviceradar.events \
      WHERE class_uid = 4003 \
        AND `time` > DATE_ADD(NOW(), INTERVAL -#{lookback_hours} HOUR) \
        AND firewall_rule_name IS NOT NULL AND firewall_rule_name != '' \
        AND src_endpoint_ip IS NOT NULL AND src_endpoint_ip != '' \
      GROUP BY src_endpoint_ip, firewall_rule_name \
      ORDER BY MAX(`time`) DESC, src_endpoint_ip, firewall_rule_name \
      LIMIT #{max_hosts}
      """

    case query(opts).(sql) do
      {:ok, %{rows: rows}} -> {:ok, %{rows: rows}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec anomaly_detection_present?(DateTime.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def anomaly_detection_present?(since, opts \\ []) when is_struct(since, DateTime) do
    sql =
      "SELECT 1 FROM serviceradar.events WHERE `time` >= '#{iso(since)}' " <>
        "AND class_uid = 2004 AND source_type = 'anomaly_detection' LIMIT 1"

    case query(opts).(sql) do
      {:ok, %{num_rows: n}} when is_integer(n) -> {:ok, n > 0}
      {:ok, %{rows: rows}} when is_list(rows) -> {:ok, rows != []}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec logs_window_bounds(keyword()) ::
          {:ok, %{latest: DateTime.t() | nil, earliest: DateTime.t() | nil}} | {:error, term()}
  def logs_window_bounds(opts \\ []) do
    sql =
      "SELECT MAX(`timestamp`), MIN(`timestamp`) FROM serviceradar.logs " <>
        "WHERE `timestamp` >= DATE_ADD(NOW(), INTERVAL -24 HOUR)"

    case query(opts).(sql) do
      {:ok, %{rows: []}} ->
        {:ok, %{latest: nil, earliest: nil}}

      {:ok, %{rows: [[latest, earliest] | _]}} ->
        {:ok, %{latest: to_datetime(latest), earliest: to_datetime(earliest)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query(opts), do: Keyword.get(opts, :query, &Query.execute/1)

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp normalize_window_row([bucket, severity, count]) do
    case to_datetime(bucket) do
      nil -> []
      datetime -> [[datetime, to_int(severity), to_int(count)]]
    end
  end

  defp normalize_window_row(_), do: []

  defp to_datetime(%DateTime{} = value), do: value

  defp to_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  defp to_datetime(value) when is_integer(value) do
    DateTime.from_unix!(value)
  end

  defp to_datetime(value) when is_binary(value) do
    cond do
      match?({:ok, _, _}, DateTime.from_iso8601(value)) ->
        {:ok, datetime, _} = DateTime.from_iso8601(value)
        datetime

      match?({:ok, _}, NaiveDateTime.from_iso8601(value)) ->
        {:ok, naive} = NaiveDateTime.from_iso8601(value)
        DateTime.from_naive!(naive, "Etc/UTC")

      true ->
        nil
    end
  end

  defp to_datetime(_), do: nil

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_float(value), do: trunc(value)

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp to_int(_), do: 0
end
