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
  The two `_catalog` views carry what JDBC cannot: an interface's address array
  and the metadata-derived device aliases, flattened to text rows.
  """

  @catalog "cnpg_platform"
  @schema "platform"
  @sql_literal ~r/'(?:\\.|''|[^'\\])*'/
  @native_call ~r/\b#{@catalog}\.native_query\s*\(/i

  @allowed_tables ~w(
    ocsf_devices
    device_alias_states
    device_identifiers
    discovered_interfaces
    device_interface_addresses_catalog
    device_inventory_aliases_catalog
    netflow_exporter_cache
    netflow_interface_cache
    netflow_local_cidrs_catalog
    ip_geo_enrichment_cache
    ip_threat_intel_cache
    threat_intel_indicators
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

  @spec native_query?(String.t()) :: boolean()
  def native_query?(sql) when is_binary(sql) do
    Regex.match?(@native_call, sql_syntax(sql))
  end

  @spec assert_sql_allowlisted(String.t()) :: :ok | {:error, term()}
  def assert_sql_allowlisted(sql) when is_binary(sql) do
    with :ok <- assert_native_queries(sql) do
      ~r/#{@catalog}\.#{@schema}\.([A-Za-z0-9_]+)/i
      |> Regex.scan(sql_syntax(sql))
      |> Enum.reduce_while(:ok, fn [_, table], _acc ->
        check_table(table)
      end)
    end
  end

  # native_query embeds PostgreSQL SQL in a StarRocks string literal, so its
  # relations cannot be found by the external-catalog qualifier scan above.
  # Accept only single SELECTs on explicitly qualified current-state relations;
  # the column-scoped CNPG reader grants remain the database authorization.
  defp assert_native_queries(sql) do
    @native_call
    |> Regex.scan(sql_syntax(sql), return: :index)
    |> Enum.reduce_while(:ok, fn [{offset, _length}], _acc ->
      call = binary_part(sql, offset, byte_size(sql) - offset)

      case Regex.run(~r/^#{@catalog}\.native_query\s*\(\s*'((?:\\.|''|[^'\\])*)'\s*\)/i, call) do
        [_, encoded] ->
          query = encoded |> String.replace("''", "'") |> String.replace("\\\\", "\\")

          case assert_native_select(query) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end

        _ ->
          {:halt, {:error, :invalid_starrocks_native_query}}
      end
    end)
  end

  defp sql_syntax(sql) do
    Regex.replace(@sql_literal, sql, fn literal -> String.duplicate(" ", byte_size(literal)) end)
  end

  defp assert_native_select(query) do
    # PostgreSQL standard-conforming literals use doubled quotes. Mask values
    # before inspecting syntax so a feed name cannot become a relation or verb.
    syntax = Regex.replace(~r/'(?:''|[^'])*'/, query, "''")

    relations =
      Regex.scan(~r/\b(?:FROM|JOIN)\s+([A-Za-z_][A-Za-z0-9_.]*)/i, syntax)

    if Regex.match?(~r/^\s*SELECT\b/i, syntax) and relations != [] and
         not Regex.match?(
           ~r/;|--|\/\*|\b(?:WITH|INSERT|UPDATE|DELETE|MERGE|COPY|CALL|INTO)\b/i,
           syntax
         ) do
      Enum.reduce_while(relations, :ok, fn [_, relation], _acc ->
        case String.split(String.downcase(relation), ".") do
          [@schema, table] -> check_table(table)
          _ -> {:halt, {:error, {:not_allowlisted, relation}}}
        end
      end)
    else
      {:error, :invalid_starrocks_native_query}
    end
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
