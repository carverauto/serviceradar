defmodule ServiceRadar.ColdTier.Config do
  @moduledoc """
  Typed access to the deployment-supplied cold-tier configuration
  (`config :serviceradar_core, ServiceRadar.ColdTier` — populated from
  SERVICERADAR_COLD_* environment variables in runtime.exs).

  Absent or incomplete configuration means the cold tier is disabled;
  callers must treat `head_opts/0` / `s3/0` returning `:disabled` as the
  signal to do nothing.
  """

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
      The OSS default: nothing fences retention, nothing runs.
    * `:enabled` — fully configured (intent + analytics head + primary FDW +
      object store). Everything runs.
    * `:misconfigured` — cold tier is INTENDED but the config is incomplete.
      This is the dangerous middle the reviewer caught: fencing retention here
      while the exporter cannot run would hold data hot forever and fill the
      primary. So a misconfigured deployment does NOT fence — normal retention
      proceeds (identical to no cold tier) — and the retention worker alerts.
  """
  @type state :: :disabled | :enabled | :misconfigured

  @doc "The single activation state all cold consumers key off (review F09)."
  @spec state() :: state()
  def state do
    cond do
      not ServiceRadar.ColdTier.Registry.enabled?() -> :disabled
      fully_configured?() -> :enabled
      true -> :misconfigured
    end
  end

  @spec enabled?() :: boolean()
  def enabled?, do: state() == :enabled

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
end
