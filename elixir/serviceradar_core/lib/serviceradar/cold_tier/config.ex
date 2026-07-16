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

  @spec enabled?() :: boolean()
  def enabled?, do: ServiceRadar.ColdTier.Registry.enabled?() and head_configured?()

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

  @doc "Hours a chunk must be closed before initial export (frontier lag)."
  @spec export_lag_hours() :: pos_integer()
  def export_lag_hours, do: positive(config()[:export_lag_hours], 48)

  @doc "Failed attempts before a chunk is quarantined."
  @spec quarantine_attempts() :: pos_integer()
  def quarantine_attempts, do: positive(config()[:quarantine_attempts], 5)

  @doc "Max chunks exported per run (paced backfill)."
  @spec run_chunk_budget() :: pos_integer()
  def run_chunk_budget, do: positive(config()[:run_chunk_budget], 24)

  defp head_configured? do
    match?({:ok, _}, head_opts()) and match?({:ok, _}, s3()) and match?({:ok, _}, primary_fdw())
  end

  defp config, do: Application.get_env(:serviceradar_core, ServiceRadar.ColdTier, [])

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end
