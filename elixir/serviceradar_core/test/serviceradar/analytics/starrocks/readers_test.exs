defmodule ServiceRadar.Analytics.StarRocks.ReadersTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.Readers

  @moduletag :db_free

  test "ordinary installations keep CNPG as the serving authority" do
    assert Readers.mode_for(:flows) == nil
    assert Readers.mode_for("flows") == nil
    assert Readers.mode_for(:metrics) == nil
    assert "srql in:flows" in Readers.switched_readers(:flows)
    assert "dashboard NetFlow map" in Readers.switched_readers(:flows)
    assert "exporter cache" in Readers.switched_readers(:flows)
    assert "topology" in Readers.switched_readers(:flows)
    assert "attribution" in Readers.switched_readers(:flows)
    assert "threat queries" in Readers.switched_readers(:flows)
    assert Readers.remaining_readers(:flows) == []
    assert Readers.backend(:flows) == :cnpg
    assert Readers.backend(:metrics) == :cnpg
    assert "srql timeseries/cpu/memory/disk/process/snmp" in Readers.switched_readers(:metrics)
    assert "device charts" in Readers.switched_readers(:metrics)
    assert "ICMP sparklines" in Readers.switched_readers(:metrics)
    assert "thresholds" in Readers.switched_readers(:metrics)
    assert "anomaly/capacity" in Readers.switched_readers(:metrics)
    assert "topology nonnumeric facts" in Readers.switched_readers(:metrics)
    assert Readers.remaining_readers(:metrics) == []
    assert "srql in:logs" in Readers.switched_readers(:logs)
    assert "logs rollup status" in Readers.switched_readers(:logs)
    assert Readers.remaining_readers(:logs) == []

    assert "srql in:events / security_findings / scan / dns activity" in Readers.switched_readers(
             :events
           )

    assert "dashboard event window" in Readers.switched_readers(:events)
    assert "dns-policy prefix tags" in Readers.switched_readers(:events)
    assert "anomaly ingest silence (2004 rows)" in Readers.switched_readers(:events)
    assert Readers.remaining_readers(:events) == []
    assert Readers.backend(:logs) == :cnpg
    assert Readers.backend(:events) == :cnpg
  end

  test "cutover_datasets selects starrocks mode for the matching entity" do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:flows])
    )

    try do
      assert Readers.mode_for("flows") == "starrocks"
      assert Readers.mode_for("attributed_flows") == "starrocks"
      assert Readers.backend(:flows) == :starrocks

      assert Readers.fetch(:flows, %{
               cnpg: fn -> :cnpg_branch end,
               starrocks: fn -> :starrocks_branch end
             }) == :starrocks_branch

      assert Readers.mode_for("devices") == nil
      assert Readers.mode_for("timeseries_metrics") == nil
    after
      Application.put_env(:serviceradar_core, StarRocks, prev)
    end
  end

  test "cutover_datasets selects starrocks for metrics entities" do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:metrics])
    )

    try do
      assert Readers.mode_for("timeseries_metrics") == "starrocks"
      assert Readers.mode_for("cpu_metrics") == "starrocks"
      assert Readers.mode_for("snmp") == "starrocks"
      assert Readers.backend(:metrics) == :starrocks
      assert Readers.mode_for("flows") == nil
    after
      Application.put_env(:serviceradar_core, StarRocks, prev)
    end
  end

  test "cutover_datasets selects starrocks for logs and events entities" do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:logs, :events])
    )

    try do
      assert Readers.mode_for("logs") == "starrocks"
      assert Readers.mode_for("events") == "starrocks"
      assert Readers.mode_for("security_findings") == "starrocks"
      assert Readers.mode_for("dns_activity") == "starrocks"
      assert Readers.backend(:logs) == :starrocks
      assert Readers.backend(:events) == :starrocks
      assert Readers.mode_for("alerts") == nil
      assert Readers.backend(:alerts) == :cnpg
    after
      Application.put_env(:serviceradar_core, StarRocks, prev)
    end
  end
end
