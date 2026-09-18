defmodule ServiceRadar.Analytics.StarRocks.CatalogAllowlistTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.Catalog
  alias ServiceRadar.Analytics.StarRocks.CatalogAllowlist
  alias ServiceRadar.Analytics.StarRocks.Env

  @moduletag :db_free

  test "catalog stays off and names the CNPG platform catalog" do
    assert CatalogAllowlist.catalog_name() == "cnpg_platform"
    assert CatalogAllowlist.schema_name() == "platform"
    refute CatalogAllowlist.enabled?()
  end

  test "allowlist is enrichment current-state only" do
    assert "prefix_tags_catalog" in CatalogAllowlist.allowed_tables()
    refute "prefix_tags" in CatalogAllowlist.allowed_tables()
    assert "ocsf_devices" in CatalogAllowlist.allowed_tables()

    assert {:ok, "cnpg_platform.platform.device_alias_states"} =
             CatalogAllowlist.qualify("device_alias_states")

    assert {:ok, "cnpg_platform.platform.netflow_exporter_cache"} =
             CatalogAllowlist.qualify("netflow_exporter_cache")

    # Attributed flows read persisted pid/comm off the observation row, so the
    # compiler never joins current-state attribution and the reader is granted
    # nothing on it. Allowlisting it would let a re-enable reach the Frontend
    # and fail there with permission denied instead of failing here.
    refute CatalogAllowlist.allowed?("flow_process_attribution_current")

    assert {:error, :not_allowlisted} ==
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
        "LEFT JOIN cnpg_platform.platform.ocsf_devices AS dev " <>
        "ON dev.uid = f.device_uid"

    assert {:error, {:starrocks_catalog_disabled, "cnpg_platform"}} =
             CatalogAllowlist.assert_sql_executable(sql)
  end

  test "SQL naming a forbidden CNPG table is rejected even if the catalog is on" do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    try do
      Application.put_env(
        :serviceradar_core,
        StarRocks,
        Keyword.put(prev, :catalog_enabled, true)
      )

      sql =
        "SELECT 1 FROM cnpg_platform.platform.network_credential_secrets"

      assert {:error, {:not_allowlisted, "network_credential_secrets"}} =
               CatalogAllowlist.assert_sql_executable(sql)
    after
      Application.put_env(:serviceradar_core, StarRocks, prev)
    end
  end

  test "CREATE CATALOG SQL uses a file driver and omits password by default" do
    sql = Catalog.create_sql()
    assert sql =~ "CREATE EXTERNAL CATALOG IF NOT EXISTS cnpg_platform"
    assert sql =~ ~s("type" = "jdbc")
    assert sql =~ ~s("driver_url" = "file:///opt/starrocks/jdbc/postgresql.jar")
    refute sql =~ "password"
    refute sql =~ "repo1.maven.org"
    refute sql =~ "network_credential_secrets"
  end

  test "env config stays off and mint-no atoms from unknown dataset names" do
    keys = [
      "SERVICERADAR_STARROCKS_ENABLED",
      "SERVICERADAR_STARROCKS_CATALOG_ENABLED",
      "SERVICERADAR_STARROCKS_CUTOVER_DATASETS",
      "SERVICERADAR_STARROCKS_SHADOW_DATASETS",
      "SERVICERADAR_STARROCKS_FE_HTTP"
    ]

    previous = Map.new(keys, fn key -> {key, System.get_env(key)} end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    Enum.each(keys, &System.delete_env/1)
    cfg = Env.config()
    refute cfg[:enabled]
    refute cfg[:catalog_enabled]
    assert cfg[:cutover_datasets] == []
    assert cfg[:shadow_datasets] == []
    assert cfg[:fe_http] == "http://127.0.0.1:8030"

    System.put_env("SERVICERADAR_STARROCKS_ENABLED", "true")
    cfg = Env.config()
    assert cfg[:enabled]
    assert cfg[:shadow_datasets] == [:flows, :flow_attribution, :metrics, :logs, :events]

    System.put_env("SERVICERADAR_STARROCKS_CATALOG_ENABLED", "true")
    System.put_env("SERVICERADAR_STARROCKS_CUTOVER_DATASETS", "flows,not_a_dataset,metrics")
    System.put_env("SERVICERADAR_STARROCKS_SHADOW_DATASETS", "logs")
    System.put_env("SERVICERADAR_STARROCKS_FE_HTTP", "http://lab-fe-service.starrocks.svc:8030")
    cfg = Env.config()
    assert cfg[:catalog_enabled]
    assert cfg[:cutover_datasets] == [:flows, :metrics]
    assert cfg[:shadow_datasets] == [:logs]
    assert cfg[:fe_http] == "http://lab-fe-service.starrocks.svc:8030"
  end

  test "catalog_enabled application env does not default on" do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    try do
      Application.put_env(
        :serviceradar_core,
        StarRocks,
        Keyword.put(prev, :catalog_enabled, true)
      )

      assert CatalogAllowlist.enabled?()

      Application.put_env(:serviceradar_core, StarRocks, Keyword.delete(prev, :catalog_enabled))
      refute CatalogAllowlist.enabled?()
    after
      Application.put_env(:serviceradar_core, StarRocks, prev)
    end
  end
end
