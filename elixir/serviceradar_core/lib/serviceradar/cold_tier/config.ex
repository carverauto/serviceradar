defmodule ServiceRadar.ColdTier.Config do
  @moduledoc """
  Typed access to the deployment-supplied cold-tier configuration
  (`config :serviceradar_core, ServiceRadar.ColdTier` — populated from
  SERVICERADAR_COLD_* environment variables in runtime.exs).

  Archive work requires `enabled?/0`; absent intent and incomplete intended
  configuration have distinct states for operational reporting. Connection
  helpers alone do not establish activation. See `state/0`.
  """

  @doc "Deployment environment shared by the application and shipped core release."
  @spec from_env() :: keyword()
  def from_env do
    [
      enabled: System.get_env("SERVICERADAR_COLD_TIER_ENABLED") in ["true", "1"],
      bucket_url: System.get_env("SERVICERADAR_COLD_TIER_BUCKET_URL"),
      s3_endpoint: System.get_env("SERVICERADAR_COLD_TIER_S3_ENDPOINT"),
      s3_endpoint_runtime: System.get_env("SERVICERADAR_COLD_TIER_S3_ENDPOINT_RUNTIME"),
      s3_region: System.get_env("SERVICERADAR_COLD_TIER_S3_REGION"),
      s3_url_style: System.get_env("SERVICERADAR_COLD_TIER_S3_URL_STYLE"),
      s3_use_ssl: System.get_env("SERVICERADAR_COLD_TIER_S3_USE_SSL", "true") in ["true", "1"],
      s3_access_key_id: secret_env("SERVICERADAR_COLD_TIER_S3_ACCESS_KEY_ID"),
      s3_secret_access_key: secret_env("SERVICERADAR_COLD_TIER_S3_SECRET_ACCESS_KEY"),
      head_host: System.get_env("SERVICERADAR_COLD_TIER_HEAD_HOST"),
      head_port: parse_int_env("SERVICERADAR_COLD_TIER_HEAD_PORT", 5432),
      head_database: System.get_env("SERVICERADAR_COLD_TIER_HEAD_DATABASE"),
      head_username: System.get_env("SERVICERADAR_COLD_TIER_HEAD_USERNAME"),
      head_password: secret_env("SERVICERADAR_COLD_TIER_HEAD_PASSWORD"),
      primary_host: System.get_env("SERVICERADAR_COLD_TIER_PRIMARY_HOST"),
      primary_port: parse_int_env("SERVICERADAR_COLD_TIER_PRIMARY_PORT", 5432),
      primary_database: System.get_env("SERVICERADAR_COLD_TIER_PRIMARY_DATABASE"),
      primary_fdw_username: System.get_env("SERVICERADAR_COLD_TIER_PRIMARY_FDW_USERNAME"),
      primary_fdw_password: secret_env("SERVICERADAR_COLD_TIER_PRIMARY_FDW_PASSWORD"),
      export_lag_hours: max(parse_int_env("SERVICERADAR_COLD_EXPORT_LAG_HOURS", 48), 1),
      quarantine_attempts: max(parse_int_env("SERVICERADAR_COLD_QUARANTINE_ATTEMPTS", 5), 1),
      run_chunk_budget: max(parse_int_env("SERVICERADAR_COLD_RUN_CHUNK_BUDGET", 24), 1),
      cold_windows:
        Enum.reject(
          [
            logs: cold_window("SERVICERADAR_COLD_WINDOW_LOGS_DAYS"),
            traces: cold_window("SERVICERADAR_COLD_WINDOW_TRACES_DAYS"),
            otel_metrics: cold_window("SERVICERADAR_COLD_WINDOW_OTEL_METRICS_DAYS"),
            otel_metric_points: cold_window("SERVICERADAR_COLD_WINDOW_OTEL_METRIC_POINTS_DAYS"),
            timeseries: cold_window("SERVICERADAR_COLD_WINDOW_TIMESERIES_DAYS"),
            events: cold_window("SERVICERADAR_COLD_WINDOW_EVENTS_DAYS"),
            flows: cold_window("SERVICERADAR_COLD_WINDOW_FLOWS_DAYS")
          ],
          fn {_class, days} -> is_nil(days) end
        )
    ]
  end

  @type s3 :: %{
          bucket_url: String.t(),
          endpoint: String.t() | nil,
          region: String.t(),
          url_style: String.t(),
          use_ssl: boolean(),
          access_key_id: String.t() | nil,
          secret_access_key: String.t() | nil
        }

  @typedoc """
  The single cold-tier activation state (review F09). Every cold consumer —
  the retention fence, the exporter, and the pruner — keys off this so they
  can never disagree:

    * `:disabled` — no cold-tier intent (enable flag off or bucket absent).
      The OSS default: archive work is disabled; existing boundary residue
      still fences retention (see `ServiceRadar.ColdTier.RetentionFence.fenced?/1`).
    * `:enabled` — fully configured, with CNPG as the telemetry backend.
    * `:cnpg_backfill` — fully configured, with StarRocks as the telemetry
      backend. Existing CNPG chunks still export and remain retention-fenced;
      warehouse data is NOT archived by this pipeline.
    * `:misconfigured` — cold tier is INTENDED but the config is incomplete.
      This is the dangerous middle the reviewer caught: fencing retention here
      while the exporter cannot run would hold data hot forever and fill the
      primary. So incomplete configuration does not establish a new fence;
      existing boundary residue remains protected by `RetentionFence.fenced?/1`,
      and the retention worker alerts.
  """
  @type state :: :disabled | :enabled | :cnpg_backfill | :misconfigured

  @doc "The single activation state all cold consumers key off (review F09)."
  @spec state() :: state()
  def state do
    cond do
      not ServiceRadar.ColdTier.Registry.enabled?() -> :disabled
      not fully_configured?() -> :misconfigured
      warehouse_backend?() -> :cnpg_backfill
      true -> :enabled
    end
  end

  @spec enabled?() :: boolean()
  def enabled?, do: state() in [:enabled, :cnpg_backfill]

  @doc "Whether incoming telemetry is served by the warehouse, independent of cold intent."
  @spec warehouse_backend?() :: boolean()
  def warehouse_backend?, do: ServiceRadar.Analytics.StarRocks.Readers.enabled?()

  @doc "True when the cold tier is intended (enable flag + bucket), regardless of completeness."
  @spec intended?() :: boolean()
  def intended?, do: ServiceRadar.ColdTier.Registry.enabled?()

  @doc "Which required cold-tier config pieces are missing (empty when fully configured)."
  @spec misconfiguration_reasons() :: [atom()]
  def misconfiguration_reasons do
    [
      {:analytics_head, match?({:ok, _}, head_opts())},
      {:object_store, match?({:ok, _}, s3())},
      {:primary_fdw, match?({:ok, _}, primary_fdw())}
    ]
    |> Enum.reject(fn {_piece, present?} -> present? end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc "Postgrex connection opts for the analytics head, or :disabled."
  @spec head_opts() :: {:ok, keyword()} | :disabled
  def head_opts do
    cfg = config()
    host = cfg[:head_host]

    if is_binary(host) and host != "" do
      {:ok,
       [
         hostname: host,
         port: cfg[:head_port] || 5432,
         database: cfg[:head_database] || "serviceradar",
         username: cfg[:head_username] || "serviceradar",
         password: cfg[:head_password] || "",
         ssl: cfg[:head_ssl] || false,
         connect_timeout: 5_000,
         # Exports are non-preemptible (spike 0.3): the exporter session runs
         # with statement_timeout=0 and is discarded after use; interactive
         # timeouts are the ColdRepo's concern, not this connection's.
         parameters: [statement_timeout: "0", application_name: "sr_cold_exporter"],
         pool_size: 1
       ]}
    else
      :disabled
    end
  end

  @doc "Object-store settings, or :disabled."
  @spec s3() :: {:ok, s3()} | :disabled
  def s3 do
    cfg = config()
    bucket_url = cfg[:bucket_url]

    if is_binary(bucket_url) and bucket_url != "" do
      {:ok,
       %{
         bucket_url: String.trim_trailing(bucket_url, "/"),
         endpoint: cfg[:s3_endpoint],
         region: cfg[:s3_region] || "us-east-1",
         url_style: cfg[:s3_url_style] || "path",
         use_ssl: Keyword.get(config(), :s3_use_ssl, true),
         access_key_id: cfg[:s3_access_key_id],
         secret_access_key: cfg[:s3_secret_access_key]
       }}
    else
      :disabled
    end
  end

  @doc "Primary-connection facts the head's FDW server needs."
  @spec primary_fdw() :: {:ok, map()} | :disabled
  def primary_fdw do
    cfg = config()
    host = cfg[:primary_host]

    if is_binary(host) and host != "" do
      {:ok,
       %{
         host: host,
         port: cfg[:primary_port] || 5432,
         dbname: cfg[:primary_database] || "serviceradar",
         username: cfg[:primary_fdw_username] || "cold_reader",
         password: cfg[:primary_fdw_password] || ""
       }}
    else
      :disabled
    end
  end

  @doc """
  S3 endpoint as reachable from THIS runtime (the BEAM), for pruning and
  reconciliation. The `s3_endpoint` in `s3/0` is the analytics head's
  perspective (DuckDB secrets); in local dev the two differ (container DNS
  vs host ports). Falls back to `s3_endpoint` when unset.
  """
  @spec runtime_s3_endpoint() :: String.t() | nil
  def runtime_s3_endpoint do
    config()[:s3_endpoint_runtime] || config()[:s3_endpoint]
  end

  @doc "Hours a chunk must be closed before initial export (frontier lag)."
  @spec export_lag_hours() :: pos_integer()
  def export_lag_hours, do: positive(config()[:export_lag_hours], 48)

  @doc "Failed attempts before a chunk is quarantined."
  @spec quarantine_attempts() :: pos_integer()
  def quarantine_attempts, do: positive(config()[:quarantine_attempts], 5)

  @doc "Max chunks exported per run (paced backfill)."
  @spec run_chunk_budget() :: pos_integer()
  def run_chunk_budget, do: positive(config()[:run_chunk_budget], 24)

  defp fully_configured? do
    match?({:ok, _}, head_opts()) and match?({:ok, _}, s3()) and match?({:ok, _}, primary_fdw())
  end

  defp config, do: Application.get_env(:serviceradar_core, ServiceRadar.ColdTier, [])

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp parse_int_env(name, default) do
    case System.get_env(name) do
      value when value in [nil, ""] ->
        default

      value ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> default
        end
    end
  end

  defp secret_env(name) do
    case System.get_env(name <> "_FILE") do
      nil -> System.get_env(name)
      path -> path |> File.read!() |> String.trim()
    end
  end

  defp cold_window(name) do
    case System.get_env(name) do
      value when value in [nil, ""] ->
        nil

      value ->
        case Integer.parse(value) do
          {days, _} -> max(days, 1)
          :error -> nil
        end
    end
  end
end
