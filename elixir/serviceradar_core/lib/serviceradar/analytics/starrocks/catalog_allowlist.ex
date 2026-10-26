defmodule ServiceRadar.Analytics.StarRocks.CatalogAllowlist do
  @moduledoc """
  Allowlisted CNPG current-state tables for the StarRocks JDBC catalog.

  Used for query-time enrichment joins. The catalog is read-only, opt-in, and
  off until Helm `analytics.starrocks.catalog.enabled` is true. Telemetry
  hypertables and secrets are never join targets.

  A table belongs here only while the compiler can actually join it and the
  reader is granted SELECT on it. Attributed flows read persisted pid/comm and
  prefix tags off the warehouse observation row rather than joining CNPG
  current-state through the catalog, so there is no attribution catalog target
  (the former `flow_process_attribution_current` table was dropped); likewise
  `prefix_tags_catalog` is not a target.

  `device_identifiers` and `discovered_interfaces` are here because a log row
  carries no device uid: `device_id:` on logs resolves the uid to the addresses
  and names the inventory knows, and CNPG reads those two relations to do it.
  The `_catalog` views carry what JDBC cannot: an interface's address array,
  the metadata-derived device aliases, and the exposure device attributes and
  tags, flattened to text rows. The exposure views are the only CNPG relations
  exposure queries join; the assessment, package, advisory, dictionary, agent
  and alert tables stay off this list.
  """

  @catalog "cnpg_platform"
  @schema "platform"
  @sql_literal ~r/'(?:\\.|''|[^'\\])*'/

  @allowed_tables ~w(
    ocsf_devices
    device_alias_states
    device_identifiers
    discovered_interfaces
    device_interface_addresses_catalog
    device_inventory_aliases_catalog
    exposure_device_catalog
    exposure_device_tags_catalog
    netflow_exporter_cache
    netflow_interface_cache
    netflow_local_cidrs_catalog
    ip_geo_enrichment_cache
    ip_threat_intel_cache
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
    if Regex.match?(~r/\b#{@catalog}\s*\./i, sql_syntax(sql)) and not enabled?() do
      {:error, {:starrocks_catalog_disabled, @catalog}}
    else
      assert_sql_allowlisted(sql)
    end
  end

  @spec assert_sql_allowlisted(String.t()) :: :ok | {:error, term()}
  def assert_sql_allowlisted(sql) when is_binary(sql) do
    ~r/#{@catalog}\.#{@schema}\.([A-Za-z0-9_]+)/i
    |> Regex.scan(sql_syntax(sql))
    |> Enum.reduce_while(:ok, fn [_, table], _acc ->
      check_table(table)
    end)
  end

  defp sql_syntax(sql) do
    Regex.replace(@sql_literal, sql, fn literal -> String.duplicate(" ", byte_size(literal)) end)
  end

  defp check_table(table) do
    table = String.downcase(table)

    if allowed?(table) do
      {:cont, :ok}
    else
      {:halt, {:error, {:not_allowlisted, table}}}
    end
  end
end
