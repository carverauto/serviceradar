defmodule ServiceRadar.Observability.TracesStatsRetentionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.ColdTier.RetentionFence
  alias ServiceRadar.Observability.DataRetentionWorker

  # Oracle: openspec add-cnpg-migration-table-retention. The fence widens
  # traces_stats_5m to 90 days. Unset and the defaultDays ceiling leave that
  # window. An explicit tracesStatsDays of 30 narrows it only while the cold
  # tier is disabled, and the ceiling does not turn 30 into 7. The 14-day
  # migration interval still takes the ceiling. A catalog error is not "no
  # policy": the wrong behavior writes the shorter window and drop_chunks.
  @moduletag :db_free

  setup do
    assert RetentionFence.cagg_cold_window_days("traces_stats_5m") == 90
    :ok
  end

  test "a catalog error does not choose a retention to write" do
    assert DataRetentionWorker.traces_stats_retention_to_apply(
             [cnpg_telemetry_default_days: 7],
             {:error, :timeout},
             false
           ) == {:skip, :unreadable}

    assert DataRetentionWorker.traces_stats_retention_to_apply(
             [traces_stats_retention_days: 30, cnpg_telemetry_default_days: 7],
             {:error, :timeout},
             false
           ) == {:skip, :unreadable}

    assert DataRetentionWorker.traces_stats_retention_to_apply(
             [],
             {:ok, %{rows: [[%{unexpected: true}]]}},
             false
           ) == {:skip, :unreadable}
  end

  test "a missing policy still takes the 14-day migration default" do
    assert DataRetentionWorker.traces_stats_retention_to_apply([], {:ok, %{rows: []}}, false) ==
             14

    assert DataRetentionWorker.traces_stats_retention_to_apply(
             [],
             {:ok, %{rows: [[nil]]}},
             false
           ) == 14
  end

  test "the ceiling caps the migration interval and a missing policy" do
    config = [cnpg_telemetry_default_days: 7]

    assert DataRetentionWorker.traces_stats_retention_to_apply(
             config,
             {:ok, %{rows: [[14.0]]}},
             false
           ) == 7

    assert DataRetentionWorker.traces_stats_retention_to_apply(
             config,
             {:ok, %{rows: []}},
             false
           ) == 7

    assert DataRetentionWorker.traces_stats_retention_to_apply(
             [traces_stats_retention_days: 30, cnpg_telemetry_default_days: 7],
             {:ok, %{rows: [[14.0]]}},
             true
           ) == 7
  end

  test "unset and the ceiling leave a widened window, with the tier on or off" do
    widened = {:ok, %{rows: [[90.0]]}}
    config = [cnpg_telemetry_default_days: 7]

    assert DataRetentionWorker.traces_stats_retention_to_apply(config, widened, false) == :skip
    assert DataRetentionWorker.traces_stats_retention_to_apply(config, widened, true) == :skip
    assert DataRetentionWorker.traces_stats_retention_to_apply([], widened, false) == :skip
  end

  test "an explicit value narrows a widened window only while the tier is disabled" do
    widened = {:ok, %{rows: [[90.0]]}}

    assert DataRetentionWorker.traces_stats_retention_to_apply(
             [traces_stats_retention_days: 30],
             widened,
             true
           ) == :skip

    assert DataRetentionWorker.traces_stats_retention_to_apply(
             [traces_stats_retention_days: 30, cnpg_telemetry_default_days: 7],
             widened,
             false
           ) == 30
  end

  test "an explicit value above the widened window does not let the ceiling shrink it" do
    assert DataRetentionWorker.traces_stats_retention_to_apply(
             [traces_stats_retention_days: 120, cnpg_telemetry_default_days: 7],
             {:ok, %{rows: [[90.0]]}},
             false
           ) == :skip
  end

  test "an explicit narrow stays put on the next run instead of taking the ceiling" do
    config = [traces_stats_retention_days: 30, cnpg_telemetry_default_days: 7]
    installed = {:ok, %{rows: [[30.0]]}}

    assert DataRetentionWorker.traces_stats_retention_to_apply(config, installed, false) == 30

    assert DataRetentionWorker.traces_stats_retention_to_apply(
             [traces_stats_retention_days: 20, cnpg_telemetry_default_days: 7],
             installed,
             false
           ) == 20

    assert DataRetentionWorker.traces_stats_retention_to_apply(config, installed, true) == :skip
  end
end
