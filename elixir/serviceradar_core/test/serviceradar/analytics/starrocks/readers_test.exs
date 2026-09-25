defmodule ServiceRadar.Analytics.StarRocks.ReadersTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.Readers

  @moduletag :db_free

  test "ordinary installations keep CNPG as the serving authority" do
    assert Readers.mode_for(:metrics) == nil
    assert Readers.backend(:metrics) == :cnpg
    assert Readers.backend(:logs) == :cnpg
    assert Readers.backend(:events) == :cnpg
  end

  # NetFlow has no CNPG serving path. Routing it to CNPG when the warehouse is
  # not cut over produces a second, divergent answer to the same question, so
  # the router refuses instead.
  test "flows refuse to serve until the dataset is cut over" do
    assert Readers.mode_for(:flows) == {:error, :starrocks_required}
    assert Readers.mode_for("flows") == {:error, :starrocks_required}
    assert Readers.mode_for("attributed_flows") == {:error, :starrocks_required}
    assert Readers.backend(:flows) == {:error, :starrocks_required}

    assert Readers.fetch(:flows, %{
             cnpg: fn -> flunk("flows must never read CNPG") end,
             starrocks: fn -> :starrocks_branch end
           }) == {:error, :starrocks_required}
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

  # With the warehouse enabled the CNPG MTR tables stop receiving rows, so MTR
  # SRQL must read StarRocks then, and only CNPG when it is off -- never both.
  test "MTR SRQL reads StarRocks with the warehouse enabled and CNPG without it" do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    try do
      Application.put_env(
        :serviceradar_core,
        StarRocks,
        prev |> Keyword.put(:enabled, true) |> Keyword.put(:cutover_datasets, [])
      )

      for entity <- ["mtr_traces", "mtr_hops", "MTR_HOPS", "mtr_hop_stats"] do
        assert Readers.mode_for(entity) == "starrocks"
        assert Readers.backend(entity) == :starrocks
      end

      query = "in:mtr_hops time:last_24h stats:count() as n by addr"
      assert query |> Readers.entity_for_query() |> Readers.mode_for() == "starrocks"

      assert Readers.fetch(:mtr, %{
               cnpg: fn -> flunk("MTR must not read CNPG with the warehouse enabled") end,
               starrocks: fn -> :starrocks_branch end
             }) == :starrocks_branch

      Application.put_env(:serviceradar_core, StarRocks, Keyword.put(prev, :enabled, false))

      for entity <- ["mtr_traces", "mtr_hops", "mtr_hop_stats"] do
        assert Readers.mode_for(entity) == nil
        assert Readers.backend(entity) == :cnpg
      end

      assert Readers.fetch(:mtr, %{
               cnpg: fn -> :cnpg_branch end,
               starrocks: fn -> flunk("MTR must not read StarRocks when disabled") end
             }) == :cnpg_branch
    after
      Application.put_env(:serviceradar_core, StarRocks, prev)
    end
  end

  test "enabled? is the global backend switch, independent of the cutover list" do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    try do
      Application.put_env(:serviceradar_core, StarRocks, Keyword.put(prev, :enabled, false))
      refute Readers.enabled?()

      # A cutover list without the switch does not make the warehouse the backend.
      Application.put_env(
        :serviceradar_core,
        StarRocks,
        prev |> Keyword.put(:enabled, false) |> Keyword.put(:cutover_datasets, [:flows])
      )

      refute Readers.enabled?()

      Application.put_env(
        :serviceradar_core,
        StarRocks,
        prev |> Keyword.put(:enabled, true) |> Keyword.put(:cutover_datasets, [])
      )

      assert Readers.enabled?()

      # Only a real boolean enables it; a stray string from hand-written config does not.
      Application.put_env(:serviceradar_core, StarRocks, Keyword.put(prev, :enabled, "true"))
      refute Readers.enabled?()

      Application.put_env(:serviceradar_core, StarRocks, [])
      refute Readers.enabled?()
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
      assert Readers.mode_for("flows") == {:error, :starrocks_required}

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
