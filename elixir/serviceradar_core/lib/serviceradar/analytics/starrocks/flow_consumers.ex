defmodule ServiceRadar.Analytics.StarRocks.FlowConsumers do
  @moduledoc """
  StarRocks flow reads for the consumers that query flows without going through
  SRQL: the dashboard throughput sparkline and the device page's "has this
  device any flows?" probes.

  They used to read `platform.ocsf_network_activity` and its CNPG aggregates
  directly, so cutting the `flows` dataset over moved every NetFlow page to the
  warehouse and left these behind on a copy that a deployment is free to stop
  writing. `cut_over?/0` is the one question a caller asks; when it is false
  the caller keeps its CNPG query, which is still the right source for an
  installation without the warehouse.

  Values reach the Frontend as literals, because it is queried over the text
  protocol. Every interpolated value is therefore validated here first: an
  address must parse with `:inet`, and a time is rendered from a `DateTime`.

  The hourly rollup refreshes asynchronously, so it can trail the raw table by
  the hour in progress. Only the long sparklines use hour buckets, where one
  missing point at the right-hand edge is not worth a freshness probe per
  dashboard load.
  """

  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.Query
  alias ServiceRadar.Analytics.StarRocks.Readers

  @hour 3_600

  # What the hourly rollup stores, so a sparkline read from the raw table and
  # one read from the rollup are the same quantity: the sampling-weighted total
  # the NetFlow pages chart.
  @weight "GREATEST(COALESCE(sampling_rate, 1), 1)"
  @raw_bytes "SUM(COALESCE(bytes_total, COALESCE(bytes_in, 0) + COALESCE(bytes_out, 0)) * #{@weight})"
  @raw_packets "SUM(COALESCE(packets_total, COALESCE(packets_in, 0) + COALESCE(packets_out, 0)) * #{@weight})"

  @doc "Whether flow reads belong to the warehouse in this deployment."
  @spec cut_over?() :: boolean()
  def cut_over?, do: Readers.backend(:flows) == :starrocks

  @doc """
  The newest `limit` traffic buckets at or after `cutoff`, oldest first, as
  `[bucket, bytes_total, packets_total, flow_count]`.

  A bucket of whole hours reads the hourly rollup; anything finer reads the raw
  table, which is the only place that grain exists.
  """
  @spec traffic_rows(DateTime.t(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, [list()]} | {:error, term()}
  def traffic_rows(%DateTime{} = cutoff, bucket_seconds, limit, opts \\ [])
      when is_integer(bucket_seconds) and bucket_seconds > 0 and is_integer(limit) and limit > 0 do
    {table, time, bytes, packets, flows} =
      if rem(bucket_seconds, @hour) == 0 do
        {Env.table("ocsf_network_activity_hourly"), "bucket", "SUM(bytes_total)",
         "SUM(packets_total)", "SUM(flow_count)"}
      else
        {Env.table("ocsf_network_activity"), "`time`", @raw_bytes, @raw_packets, "COUNT(*)"}
      end

    sql =
      "SELECT bucket, bytes_total, packets_total, flow_count FROM (" <>
        "SELECT time_slice(#{time}, INTERVAL #{bucket_seconds} SECOND) AS bucket, " <>
        "#{bytes} AS bytes_total, #{packets} AS packets_total, #{flows} AS flow_count " <>
        "FROM #{table} WHERE #{time} >= '#{iso(cutoff)}' " <>
        "GROUP BY 1 ORDER BY 1 DESC LIMIT #{limit}) recent ORDER BY bucket ASC"

    rows(opts, sql)
  end

  @doc "Whether any flow at or after `since` has `ip` as its source or destination."
  @spec seen_for_ip?(String.t(), DateTime.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def seen_for_ip?(ip, %DateTime{} = since, opts \\ []) do
    with {:ok, literal} <- address(ip) do
      exists?(opts, since, "(src_endpoint_ip = #{literal} OR dst_endpoint_ip = #{literal})")
    end
  end

  @doc "Whether any flow at or after `since` was exported by `sampler`."
  @spec seen_for_sampler?(String.t(), DateTime.t(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def seen_for_sampler?(sampler, %DateTime{} = since, opts \\ []) do
    with {:ok, literal} <- address(sampler) do
      exists?(opts, since, "sampler_address = #{literal}")
    end
  end

  defp exists?(opts, since, predicate) do
    sql =
      "SELECT 1 FROM #{Env.table("ocsf_network_activity")} " <>
        "WHERE `time` >= '#{iso(since)}' AND #{predicate} LIMIT 1"

    case rows(opts, sql) do
      {:ok, rows} -> {:ok, rows != []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rows(opts, sql) do
    case Keyword.get(opts, :query, &Query.execute/1).(sql) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  end

  # Only a string `:inet` parses as an address is ever quoted. It is quoted as
  # given rather than re-rendered, because the column holds the address as it
  # was written and equality has to meet it in that form; a string that parses
  # as an address cannot contain a quote.
  defp address(value) when is_binary(value) do
    trimmed = String.trim(value)

    case trimmed |> String.to_charlist() |> :inet.parse_address() do
      {:ok, _parsed} -> {:ok, "'#{trimmed}'"}
      {:error, _reason} -> {:error, :invalid_address}
    end
  end

  defp address(_value), do: {:error, :invalid_address}

  defp iso(%DateTime{} = dt), do: dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()
end
