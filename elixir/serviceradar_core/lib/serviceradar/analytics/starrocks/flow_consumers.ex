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

  The hourly rollup is an async materialized view, and an unrefreshed one
  returns short counts with no error. A whole-hour bucket therefore reads it
  only when `RollupFreshness` says it has caught up; a stale or missing view,
  or a failed probe, reads the raw warehouse table instead, which yields the
  same sampling-weighted quantity. `RollupFreshnessCache` lets the queries of
  one dashboard render share the probes.
  """

  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.Query
  alias ServiceRadar.Analytics.StarRocks.Readers
  alias ServiceRadar.Analytics.StarRocks.RollupFreshness

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

  A bucket of whole hours reads the hourly rollup while it is fresh; anything
  finer, or a stale rollup, reads the raw table. Only `limit` buckets can be
  returned, so the scan never starts earlier than `limit` buckets before `:now`
  (default `DateTime.utc_now/0`), however old `cutoff` is. The lower edge is
  floored to the bucket, so it selects the same rows from either source.
  """
  @spec traffic_rows(DateTime.t(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, [list()]} | {:error, term()}
  def traffic_rows(%DateTime{} = cutoff, bucket_seconds, limit, opts \\ [])
      when is_integer(bucket_seconds) and bucket_seconds > 0 and is_integer(limit) and limit > 0 do
    {table, time, bytes, packets, flows} = traffic_source(bucket_seconds, opts)
    lower = lower_edge(cutoff, bucket_seconds, limit, opts)

    sql =
      "SELECT bucket, bytes_total, packets_total, flow_count FROM (" <>
        "SELECT time_slice(#{time}, INTERVAL #{bucket_seconds} SECOND) AS bucket, " <>
        "#{bytes} AS bytes_total, #{packets} AS packets_total, #{flows} AS flow_count " <>
        "FROM #{table} WHERE #{time} >= '#{iso(lower)}' " <>
        "GROUP BY 1 ORDER BY 1 DESC LIMIT #{limit}) recent ORDER BY bucket ASC"

    rows(opts, sql)
  end

  defp traffic_source(bucket_seconds, opts) when rem(bucket_seconds, @hour) == 0 do
    if RollupFreshness.fresh?(:flows, opts) do
      {Env.table("ocsf_network_activity_hourly"), "bucket", "SUM(bytes_total)",
       "SUM(packets_total)", "SUM(flow_count)"}
    else
      raw_traffic_source()
    end
  end

  defp traffic_source(_bucket_seconds, _opts), do: raw_traffic_source()

  defp raw_traffic_source,
    do: {Env.table("ocsf_network_activity"), "`time`", @raw_bytes, @raw_packets, "COUNT(*)"}

  defp lower_edge(cutoff, bucket_seconds, limit, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    drawable = DateTime.to_unix(now) - limit * bucket_seconds
    edge = max(DateTime.to_unix(cutoff), drawable)

    DateTime.from_unix!(edge - Integer.mod(edge, bucket_seconds))
  end

  @doc """
  Whether any flow at or after `since` has `ip` as its source or destination.

  A value that is not an address cannot equal a stored flow address, so it is
  `{:ok, false}` without a query.
  """
  @spec seen_for_ip?(term(), DateTime.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def seen_for_ip?(ip, %DateTime{} = since, opts \\ []) do
    case address(ip) do
      {:ok, literal} ->
        exists?(opts, since, "(src_endpoint_ip = #{literal} OR dst_endpoint_ip = #{literal})")

      :error ->
        {:ok, false}
    end
  end

  @doc """
  Whether any flow at or after `since` was exported by `sampler`. A value that
  is not an address is `{:ok, false}` without a query.
  """
  @spec seen_for_sampler?(term(), DateTime.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def seen_for_sampler?(sampler, %DateTime{} = since, opts \\ []) do
    case address(sampler) do
      {:ok, literal} -> exists?(opts, since, "sampler_address = #{literal}")
      :error -> {:ok, false}
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
      {:error, _reason} -> :error
    end
  end

  defp address(_value), do: :error

  defp iso(%DateTime{} = dt), do: dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()
end
