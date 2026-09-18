defmodule ServiceRadar.Analytics.StarRocks.CatalogAllowlist do
  @moduledoc """
  Allowlisted CNPG current-state tables for the StarRocks JDBC catalog.

  Used for query-time enrichment joins. The catalog is read-only, opt-in, and
  off until Helm `analytics.starrocks.catalog.enabled` is true. Telemetry
  hypertables and secrets are never join targets.

  A table belongs here only while the compiler can actually join it and the
  reader is granted SELECT on it. Attributed flows read persisted pid/comm off
  the observation row rather than joining current-state attribution, so
  `flow_process_attribution_current` is not a catalog target.
  """

  @catalog "cnpg_platform"
  @schema "platform"

  @allowed_tables ~w(
    prefix_tags_catalog
    ocsf_devices
    device_alias_states
    netflow_exporter_cache
    netflow_local_cidrs_catalog
  )

  @forbidden_tables ~w(
    network_credential_secrets
    network_credential_rules
    users
    oban_jobs
    logs
    ocsf_events
    ocsf_network_activity
    timeseries_metrics
    alerts
  )

  @spec catalog_name() :: String.t()
  def catalog_name, do: @catalog

  @spec schema_name() :: String.t()
  def schema_name, do: @schema

  @spec allowed_tables() :: [String.t()]
  def allowed_tables, do: @allowed_tables

  @spec enabled?() :: boolean()
  def enabled? do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.Analytics.StarRocks, [])
    |> Keyword.get(:catalog_enabled, false) == true
  end

  @spec allowed?(String.t()) :: boolean()
  def allowed?(table) when is_binary(table) do
    table in @allowed_tables and table not in @forbidden_tables
  end

  @spec qualify(String.t()) :: {:ok, String.t()} | {:error, :not_allowlisted}
  def qualify(table) when is_binary(table) do
    if allowed?(table) do
      {:ok, "#{@catalog}.#{@schema}.#{table}"}
    else
      {:error, :not_allowlisted}
    end
  end

  @spec assert_sql_executable(String.t()) :: :ok | {:error, term()}
  def assert_sql_executable(sql) when is_binary(sql) do
    if String.contains?(sql, @catalog) and not enabled?() do
      {:error, {:starrocks_catalog_disabled, @catalog}}
    else
      assert_sql_allowlisted(sql)
    end
  end

  @spec assert_sql_allowlisted(String.t()) :: :ok | {:error, term()}
  def assert_sql_allowlisted(sql) when is_binary(sql) do
    ~r/#{@catalog}\.#{@schema}\.([A-Za-z0-9_]+)/
    |> Regex.scan(sql)
    |> Enum.reduce_while(:ok, fn [_, table], _acc ->
      if allowed?(table) do
        {:cont, :ok}
      else
        {:halt, {:error, {:not_allowlisted, table}}}
      end
    end)
  end
end
