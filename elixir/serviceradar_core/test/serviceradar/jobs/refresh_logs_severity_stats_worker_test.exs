defmodule ServiceRadar.Jobs.RefreshLogsSeverityStatsWorkerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Jobs.RefreshLogsSeverityStatsWorker

  setup do
    original_config = Application.get_env(:serviceradar_core, RefreshLogsSeverityStatsWorker)

    on_exit(fn ->
      if is_nil(original_config) do
        Application.delete_env(:serviceradar_core, RefreshLogsSeverityStatsWorker)
      else
        Application.put_env(:serviceradar_core, RefreshLogsSeverityStatsWorker, original_config)
      end
    end)
  end

  test "bootstraps the card's 24-hour window before recurring refreshes" do
    assert RefreshLogsSeverityStatsWorker.bootstrap_sql() =~ "INTERVAL '24 hours'"
    assert RefreshLogsSeverityStatsWorker.bootstrap_sql() =~ "force => true"
    assert RefreshLogsSeverityStatsWorker.refresh_sql() =~ "INTERVAL '30 minutes'"
    assert RefreshLogsSeverityStatsWorker.coverage_snapshot_sql() =~ "INTERVAL '24 hours'"

    assert RefreshLogsSeverityStatsWorker.bootstrap_watermark_key() ==
             "logs_severity_stats_5m_v3_critical_as_error"

    assert RefreshLogsSeverityStatsWorker.coverage_watermark_key() ==
             "logs_severity_stats_5m_coverage"
  end

  test "uses a bounded but upgrade-safe bootstrap timeout" do
    Application.delete_env(:serviceradar_core, RefreshLogsSeverityStatsWorker)

    assert RefreshLogsSeverityStatsWorker.refresh_timeout_ms() == 30_000
    assert RefreshLogsSeverityStatsWorker.bootstrap_timeout_ms() == 600_000
    assert RefreshLogsSeverityStatsWorker.coverage_grace_seconds() == 300
    assert RefreshLogsSeverityStatsWorker.min_24h_interval_seconds() == 3_600
    assert RefreshLogsSeverityStatsWorker.preventive_24h_interval_seconds() == 21_600

    Application.put_env(:serviceradar_core, RefreshLogsSeverityStatsWorker,
      refresh_timeout_ms: 45_000,
      bootstrap_timeout_ms: 900_000,
      coverage_grace_seconds: 120,
      min_24h_interval_seconds: 1_800,
      preventive_24h_interval_seconds: 7_200
    )

    assert RefreshLogsSeverityStatsWorker.refresh_timeout_ms() == 45_000
    assert RefreshLogsSeverityStatsWorker.bootstrap_timeout_ms() == 900_000
    assert RefreshLogsSeverityStatsWorker.coverage_grace_seconds() == 120
    assert RefreshLogsSeverityStatsWorker.min_24h_interval_seconds() == 1_800
    assert RefreshLogsSeverityStatsWorker.preventive_24h_interval_seconds() == 7_200
  end

  test "refills 24 hours when the rollup start lags raw logs" do
    now = ~U[2026-08-18 12:00:00Z]
    last = DateTime.add(now, -2 * 3_600, :second)

    assert RefreshLogsSeverityStatsWorker.needs_24h_refresh?(
             raw_min: ~U[2026-08-17 12:00:00Z],
             rollup_min: ~U[2026-08-17 13:52:00Z],
             last_refresh_at: last,
             now: now,
             coverage_grace_seconds: 300,
             min_interval_seconds: 3_600,
             preventive_interval_seconds: 21_600
           )

    refute RefreshLogsSeverityStatsWorker.needs_24h_refresh?(
             raw_min: ~U[2026-08-17 12:00:00Z],
             rollup_min: ~U[2026-08-17 12:02:00Z],
             last_refresh_at: DateTime.add(now, -10 * 60, :second),
             now: now,
             coverage_grace_seconds: 300,
             min_interval_seconds: 3_600,
             preventive_interval_seconds: 21_600
           )
  end

  test "refills an empty rollup and a stale 24-hour window" do
    now = ~U[2026-08-18 12:00:00Z]

    assert RefreshLogsSeverityStatsWorker.needs_24h_refresh?(
             raw_min: ~U[2026-08-17 12:00:00Z],
             rollup_min: nil,
             last_refresh_at: DateTime.add(now, -2 * 3_600, :second),
             now: now
           )

    assert RefreshLogsSeverityStatsWorker.needs_24h_refresh?(
             raw_min: ~U[2026-08-17 12:00:00Z],
             rollup_min: ~U[2026-08-17 12:00:00Z],
             last_refresh_at: DateTime.add(now, -7 * 3_600, :second),
             now: now,
             coverage_grace_seconds: 300,
             min_interval_seconds: 3_600,
             preventive_interval_seconds: 21_600
           )

    refute RefreshLogsSeverityStatsWorker.needs_24h_refresh?(
             raw_min: nil,
             rollup_min: nil,
             last_refresh_at: nil,
             now: now
           )
  end
end
