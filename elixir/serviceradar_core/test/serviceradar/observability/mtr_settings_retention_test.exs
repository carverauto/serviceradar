defmodule ServiceRadar.Observability.MtrSettingsRetentionTest do
  use ExUnit.Case, async: true

  @settings_path Path.expand("../../../lib/serviceradar/observability/mtr_settings.ex", __DIR__)
  @external_resource @settings_path

  test "save retention converts regular MTR tables before attaching policies" do
    source = File.read!(@settings_path)

    assert source =~ "create_hypertable"
    assert source =~ "migrate_data => true"
    assert source =~ "if_not_exists => true"
    assert source =~ "pg_total_relation_size"
    assert source =~ "@max_automatic_migration_bytes 268_435_456"
    assert source =~ "failed to convert % to a TimescaleDB hypertable"
    assert source =~ "TimescaleDB extension is required for MTR retention policies"
    assert source =~ "add_retention_policy"
    refute source =~ "EXCEPTION\n        WHEN others"
    refute source =~ "IF ts_schema IS NULL THEN\n        RETURN;"
  end

  test "retention status distinguishes missing hypertables from missing policies" do
    source = File.read!(@settings_path)

    assert source =~ "read_hypertable_names"
    assert source =~ "hypertable?: false"
    assert source =~ "hypertable?: true"
  end
end
