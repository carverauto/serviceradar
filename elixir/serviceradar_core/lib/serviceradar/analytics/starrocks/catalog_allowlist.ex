defmodule ServiceRadar.Analytics.StarRocks.CatalogAllowlist do
  @moduledoc """
  Allowlisted CNPG current-state tables for the StarRocks JDBC catalog.

  Used for query-time flow attribution and enrichment joins. The catalog is
  read-only, opt-in, and off until Helm `analytics.starrocks.catalog.enabled`
  is true. Telemetry hypertables and secrets are never join targets.
  """

  @catalog "cnpg_platform"
  @schema "platform"

  @allowed_tables ~w(
    flow_process_attribution_current
    prefix_tags
    ocsf_devices
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
end
