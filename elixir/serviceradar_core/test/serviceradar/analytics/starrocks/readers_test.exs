defmodule ServiceRadar.Analytics.StarRocks.ReadersTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.Readers

  @moduletag :db_free

  test "ordinary installations keep CNPG as the serving authority" do
    assert Readers.mode_for(:flows) == nil
    assert Readers.mode_for("flows") == nil
    assert Readers.mode_for(:metrics) == nil
    assert Readers.backend(:flows) == :cnpg
    assert Readers.backend(:metrics) == :cnpg
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
      assert Readers.mode_for("snmp") == "starrocks"
      assert Readers.mode_for("rperf_metrics") == "starrocks"
      assert Readers.backend(:metrics) == :starrocks
      assert Readers.mode_for("flows") == nil

      # EventWriter mirrors CNPG timeseries_metrics only; the sysmon families
      # have their own CNPG tables, so a metrics cutover must not divert them.
      for sysmon <- ~w(cpu_metrics memory_metrics disk_metrics process_metrics) do
        assert Readers.mode_for(sysmon) == nil
        assert Readers.backend(sysmon) == :cnpg
      end
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
      assert Readers.backend(:logs) == :starrocks
      assert Readers.backend(:events) == :starrocks
      assert Readers.mode_for("alerts") == nil
      assert Readers.backend(:alerts) == :cnpg

      # Backend routing happens on the raw entity string, so every spelling the
      # SRQL parser accepts for a warehouse-served event entity has to reach the
      # same backend. A missing alias serves one spelling from StarRocks and
      # another from CNPG, over different retention windows, with no error.
      event_aliases = ~w(
        events activity
        security_findings security_finding findings finding
        scan_activity scan_activities security_scans scanner_activity
        dns_activity dns_activities dns_security_activity powerdns pdns
      )

      for spelling <- event_aliases do
        assert Readers.mode_for(spelling) == "starrocks",
               "#{spelling} did not route to the warehouse"
      end

      # BMP events share the events permission but not the warehouse table.
      for spelling <- ~w(bmp_events bmp_event bmp_routing_events) do
        assert Readers.mode_for(spelling) == nil
        assert Readers.backend(spelling) == :cnpg
      end
    after
      Application.put_env(:serviceradar_core, StarRocks, prev)
    end
  end
end
