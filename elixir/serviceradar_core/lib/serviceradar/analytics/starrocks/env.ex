defmodule ServiceRadar.Analytics.StarRocks.Env do
  @moduledoc """
  Runtime environment for the opt-in StarRocks destination and JDBC catalog.

  Dataset names are mapped from a closed list so operator env cannot mint atoms.
  """

  # These name the datasets the shadow and cutover lists may carry. MTR is
  # deliberately absent: its traces and hops go to the warehouse whenever
  # StarRocks is enabled and to CNPG otherwise, with no shadow or cutover stage,
  # so naming it in either list would mean nothing.
  @datasets %{
    "flows" => :flows,
    "flow_attribution" => :flow_attribution,
    "metrics" => :metrics,
    "logs" => :logs,
    "events" => :events
  }

  @all_datasets [:flows, :flow_attribution, :metrics, :logs, :events]

  # Daily partitions, so retention is a partition count. Every dataset the
  # warehouse holds defaults to one year: the warehouse is what makes long
  # history affordable, so it does not inherit CNPG's shorter raw windows.
  # Tables created from DDL with a smaller `partition_live_number` are raised to
  # these values by `Retention` at core start.
  @default_retention_days [flows: 365, metrics: 365, logs: 365, events: 365, mtr: 365]

  # How far an hourly materialized view may lag its source table before a
  # reader stops trusting it. The views refresh asynchronously with no
  # schedule, so this is the operator's tolerance, not a refresh interval.
  @default_rollup_stale_after_seconds 7_200

  # How long a high-water mark may be reused before the gate re-probes. Purely
  # a round-trip saving; 0 disables reuse and probes every query.
  @default_rollup_cache_ttl_seconds 60

  # Stream Load sizing. Every warehouse load is a transaction and, in
  # shared-data mode, object-store writes plus later compaction, so many small
  # loads cost far more than a few large ones. EventWriter flushes a warehouse
  # batch after `max_age_ms`, splits it into loads of at most `max_rows` rows
  # and `max_bytes` encoded bytes, and runs at most `max_in_flight` of those
  # loads at once. These match the Helm `analytics.starrocks.streamLoad`
  # defaults; they are starting points for the #4516 benchmark, not measured
  # optima.
  @default_stream_load [
    max_rows: 50_000,
    max_bytes: 33_554_432,
    max_age_ms: 2_000,
    max_in_flight: 4
  ]

  @spec config() :: keyword()
  def config do
    enabled = truthy?("SERVICERADAR_STARROCKS_ENABLED")

    [
      enabled: enabled,
      catalog_enabled: truthy?("SERVICERADAR_STARROCKS_CATALOG_ENABLED"),
      cutover_datasets: csv_datasets("SERVICERADAR_STARROCKS_CUTOVER_DATASETS"),
      shadow_datasets: shadow_datasets(enabled),
      fe_http: fe_http(),
      fe_mysql_host: fe_mysql_host(),
      fe_mysql_port: fe_mysql_port(),
      mysql_pool_size: mysql_pool_size(),
      database: nonempty("SERVICERADAR_STARROCKS_DATABASE", "serviceradar"),
      user: nonempty("SERVICERADAR_STARROCKS_USER", "root"),
      password: System.get_env("SERVICERADAR_STARROCKS_PASSWORD", ""),
      retention_days: retention_days(),
      rollup_stale_after_seconds: rollup_stale_after_seconds(),
      rollup_cache_ttl_seconds: rollup_cache_ttl_seconds(),
      stream_load: stream_load()
    ]
  end

  @spec default_stream_load() :: keyword(pos_integer())
  def default_stream_load, do: @default_stream_load

  @spec table(String.t()) :: String.t()
  def table(name) when is_binary(name) do
    database = nonempty("SERVICERADAR_STARROCKS_DATABASE", "serviceradar")
    "#{database}.#{name}"
  end

  @spec default_retention_days() :: keyword(pos_integer())
  def default_retention_days, do: @default_retention_days

  @spec default_rollup_stale_after_seconds() :: pos_integer()
  def default_rollup_stale_after_seconds, do: @default_rollup_stale_after_seconds

  @spec default_rollup_cache_ttl_seconds() :: non_neg_integer()
  def default_rollup_cache_ttl_seconds, do: @default_rollup_cache_ttl_seconds

  # 0 is a real setting here -- serve only a fully current view -- unlike the
  # retention knobs, where it would mean "keep nothing".
  defp rollup_stale_after_seconds do
    case Integer.parse(nonempty("SERVICERADAR_STARROCKS_ROLLUP_STALE_AFTER_SECONDS", "")) do
      {seconds, _} when seconds >= 0 -> seconds
      _ -> @default_rollup_stale_after_seconds
    end
  end

  # 0 is a real setting here too -- never reuse a mark -- so it is honoured
  # literally rather than read as "unset".
  defp rollup_cache_ttl_seconds do
    case Integer.parse(nonempty("SERVICERADAR_STARROCKS_ROLLUP_CACHE_TTL_SECONDS", "")) do
      {seconds, _} when seconds >= 0 -> seconds
      _ -> @default_rollup_cache_ttl_seconds
    end
  end

  defp stream_load do
    Enum.map(@default_stream_load, fn {key, default} ->
      name = "SERVICERADAR_STARROCKS_STREAM_LOAD_" <> String.upcase(Atom.to_string(key))
      {key, positive_int(nonempty(name, ""), default)}
    end)
  end

  # Helm renders `maxBytes` through `quote`, which can turn a large integer into
  # scientific notation ("3.3554432e+07"), so a float spelling is accepted.
  defp positive_int(raw, default) do
    case Integer.parse(raw) do
      {value, ""} when value > 0 ->
        value

      _ ->
        case Float.parse(raw) do
          {value, ""} when value >= 1 -> trunc(value)
          _ -> default
        end
    end
  end

  defp retention_days do
    Enum.map(@default_retention_days, fn {dataset, default} ->
      {dataset, retention_days_for(dataset, default)}
    end)
  end

  defp retention_days_for(dataset, default) do
    name =
      "SERVICERADAR_STARROCKS_RETENTION_DAYS_" <> String.upcase(Atom.to_string(dataset))

    case Integer.parse(nonempty(name, "")) do
      {days, _} when days > 0 -> days
      _ -> default
    end
  end

  defp shadow_datasets(enabled) do
    case csv_datasets("SERVICERADAR_STARROCKS_SHADOW_DATASETS") do
      [] when enabled -> @all_datasets
      datasets -> datasets
    end
  end

  defp fe_http do
    case System.get_env("SERVICERADAR_STARROCKS_FE_HTTP") do
      url when is_binary(url) and url != "" ->
        url

      _ ->
        service = nonempty("SERVICERADAR_STARROCKS_FE_SERVICE", "127.0.0.1")
        port = nonempty("SERVICERADAR_STARROCKS_FE_HTTP_PORT", "8030")
        "http://#{service}:#{port}"
    end
  end

  defp fe_mysql_host do
    case System.get_env("SERVICERADAR_STARROCKS_FE_HOST") do
      host when is_binary(host) and host != "" ->
        host

      _ ->
        case URI.parse(fe_http()) do
          %URI{host: host} when is_binary(host) and host != "" -> host
          _ -> nonempty("SERVICERADAR_STARROCKS_FE_SERVICE", "127.0.0.1")
        end
    end
  end

  defp fe_mysql_port do
    parse_port(nonempty("SERVICERADAR_STARROCKS_FE_QUERY_PORT", "9030"), 9030)
  end

  defp mysql_pool_size do
    parse_port(nonempty("SERVICERADAR_STARROCKS_MYSQL_POOL_SIZE", "8"), 8)
  end

  defp parse_port(raw, default) when is_binary(raw) do
    case Integer.parse(raw) do
      {port, _} when port > 0 and port < 65_536 -> port
      _ -> default
    end
  end

  defp csv_datasets(name) do
    name
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn raw ->
      case Map.fetch(@datasets, String.trim(raw)) do
        {:ok, dataset} -> [dataset]
        :error -> []
      end
    end)
  end

  defp truthy?(name), do: System.get_env(name, "") in ~w(true 1 yes)

  defp nonempty(name, default) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end
end
