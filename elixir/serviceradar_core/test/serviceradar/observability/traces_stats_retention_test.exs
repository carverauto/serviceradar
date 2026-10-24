defmodule ServiceRadar.Observability.TracesStatsRetentionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.ColdTier.RetentionFence
  alias ServiceRadar.Observability.DataRetentionWorker

  # Oracle: openspec add-cnpg-migration-table-retention. The fence widens
  # traces_stats_5m to 90 days. tracesStatsDays is outside defaultDays: the
  # target is the explicit value, or 14 days when unset. While the cold tier
  # is enabled, a shorter target is not written. An unset value leaves a
  # widened window in place. An explicit value may narrow or raise the window
  # once the tier is disabled, including 120 days above the fence target.
  # A catalog error is not "no policy": the wrong behavior writes a shorter
  # window and drop_chunks.
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

  test "the ceiling does not cap traces stats, and the tier skips a shorter target" do
    ceiling = [cnpg_telemetry_default_days: 7]

    assert DataRetentionWorker.traces_stats_retention_to_apply(
             ceiling,
             {:ok, %{rows: [[14.0]]}},
             false
           ) == 14

    assert DataRetentionWorker.traces_stats_retention_to_apply(ceiling, {:ok, %{rows: []}}, false) ==
             14

    assert DataRetentionWorker.traces_stats_retention_to_apply(
             [traces_stats_retention_days: 30] ++ ceiling,
             {:ok, %{rows: [[14.0]]}},
             true
           ) == :skip

    assert DataRetentionWorker.traces_stats_retention_to_apply(
             [traces_stats_retention_days: 30] ++ ceiling,
             {:ok, %{rows: [[14.0]]}},
             false
           ) == 30
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

  test "an explicit value above the fence target is written" do
    widened = {:ok, %{rows: [[90.0]]}}
    config = [traces_stats_retention_days: 120, cnpg_telemetry_default_days: 7]

    assert DataRetentionWorker.traces_stats_retention_to_apply(config, widened, false) == 120
    assert DataRetentionWorker.traces_stats_retention_to_apply(config, widened, true) == 120
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

  test "an explicit value at or below 14 days stays on the next run" do
    ceiling = [cnpg_telemetry_default_days: 7]

    for days <- [10, 14] do
      installed = {:ok, %{rows: [[days * 1.0]]}}

      assert DataRetentionWorker.traces_stats_retention_to_apply(
               [traces_stats_retention_days: days] ++ ceiling,
               installed,
               false
             ) == days

      assert DataRetentionWorker.traces_stats_retention_to_apply(
               [traces_stats_retention_days: days] ++ ceiling,
               installed,
               true
             ) == :skip
    end

    assert DataRetentionWorker.traces_stats_retention_to_apply(
             [traces_stats_retention_days: 10] ++ ceiling,
             {:ok, %{rows: [[90.0]]}},
             false
           ) == 10

    assert DataRetentionWorker.traces_stats_retention_to_apply(
             [traces_stats_retention_days: 8] ++ ceiling,
             {:ok, %{rows: [[10.0]]}},
             false
           ) == 8

    assert DataRetentionWorker.traces_stats_retention_to_apply(
             [traces_stats_retention_days: 8] ++ ceiling,
             {:ok, %{rows: [[10.0]]}},
             true
           ) == :skip
  end

  test "an unset window below 14 days returns to the migration default" do
    ceiling = [cnpg_telemetry_default_days: 7]

    assert DataRetentionWorker.traces_stats_retention_to_apply(
             ceiling,
             {:ok, %{rows: [[7.0]]}},
             false
           ) == 14

    assert DataRetentionWorker.traces_stats_retention_to_apply(
             ceiling,
             {:ok, %{rows: [[10.0]]}},
             false
           ) == 14
  end
end
