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
    assert RefreshLogsSeverityStatsWorker.refresh_sql() =~ "INTERVAL '30 minutes'"

    assert RefreshLogsSeverityStatsWorker.bootstrap_watermark_key() ==
             "logs_severity_stats_5m_v2_bootstrap"
  end

  test "uses a bounded but upgrade-safe bootstrap timeout" do
    Application.delete_env(:serviceradar_core, RefreshLogsSeverityStatsWorker)

    assert RefreshLogsSeverityStatsWorker.refresh_timeout_ms() == 30_000
    assert RefreshLogsSeverityStatsWorker.bootstrap_timeout_ms() == 600_000

    Application.put_env(:serviceradar_core, RefreshLogsSeverityStatsWorker,
      refresh_timeout_ms: 45_000,
      bootstrap_timeout_ms: 900_000
    )

    assert RefreshLogsSeverityStatsWorker.refresh_timeout_ms() == 45_000
    assert RefreshLogsSeverityStatsWorker.bootstrap_timeout_ms() == 900_000
  end
end
