defmodule ServiceRadar.Analytics.StarRocks.CatalogAllowlistTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.CatalogAllowlist

  @moduletag :db_free

  test "catalog stays off and names the CNPG platform catalog" do
    assert CatalogAllowlist.catalog_name() == "cnpg_platform"
    assert CatalogAllowlist.schema_name() == "platform"
    refute CatalogAllowlist.enabled?
  end

  test "allowlist is attribution and enrichment current-state only" do
    assert "flow_process_attribution_current" in CatalogAllowlist.allowed_tables()
    assert "prefix_tags" in CatalogAllowlist.allowed_tables()
    assert "ocsf_devices" in CatalogAllowlist.allowed_tables()

    assert {:ok, "cnpg_platform.platform.flow_process_attribution_current"} ==
             CatalogAllowlist.qualify("flow_process_attribution_current")
  end

  test "secrets, jobs, and telemetry hypertables are not join targets" do
    for table <-
          ~w(network_credential_secrets network_credential_rules users oban_jobs logs ocsf_events ocsf_network_activity timeseries_metrics alerts) do
      refute CatalogAllowlist.allowed?(table)
      assert {:error, :not_allowlisted} == CatalogAllowlist.qualify(table)
    end
  end

  test "compiled catalog SQL is refused while the Helm flag is off" do
    sql =
      "SELECT f.id FROM serviceradar.ocsf_network_activity AS f " <>
        "INNER JOIN cnpg_platform.platform.flow_process_attribution_current AS attr " <>
        "ON attr.local_ip = f.src_endpoint_ip"

    assert {:error, {:starrocks_catalog_disabled, "cnpg_platform"}} =
             CatalogAllowlist.assert_sql_executable(sql)
  end

  test "SQL naming a forbidden CNPG table is rejected even if the catalog is on" do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    try do
      Application.put_env(:serviceradar_core, StarRocks, Keyword.put(prev, :catalog_enabled, true))

      sql =
        "SELECT 1 FROM cnpg_platform.platform.network_credential_secrets"

      assert {:error, {:not_allowlisted, "network_credential_secrets"}} =
               CatalogAllowlist.assert_sql_executable(sql)
    after
      Application.put_env(:serviceradar_core, StarRocks, prev)
    end
  end

  test "catalog_enabled application env does not default on" do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    try do
      Application.put_env(:serviceradar_core, StarRocks, Keyword.put(prev, :catalog_enabled, true))
      assert CatalogAllowlist.enabled?

      Application.put_env(:serviceradar_core, StarRocks, Keyword.delete(prev, :catalog_enabled))
      refute CatalogAllowlist.enabled?
    after
      Application.put_env(:serviceradar_core, StarRocks, prev)
    end
  end
end
