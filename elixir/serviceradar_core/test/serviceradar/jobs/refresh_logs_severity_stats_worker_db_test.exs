defmodule ServiceRadar.Jobs.RefreshLogsSeverityStatsWorkerDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Jobs.RefreshLogsSeverityStatsWorker
  alias ServiceRadar.Repo

  # Connection-local stand-ins shadow the unqualified `logs` and
  # `logs_severity_stats_5m` names the coverage snapshot reads, so the real
  # hypertable and continuous aggregate are never touched. The sandbox
  # transaction pins now(), which fixes the clock for the whole test.
  setup do
    Repo.query!("CREATE TEMP TABLE logs (timestamp timestamptz NOT NULL) ON COMMIT DROP")

    Repo.query!(
      "CREATE TEMP TABLE logs_severity_stats_5m (bucket timestamptz NOT NULL) ON COMMIT DROP"
    )

    :ok
  end

  test "the coverage snapshot starts at the bucket that holds the window start" do
    # The raw window starts mid-bucket; that bucket covers its first minutes.
    Repo.query!("INSERT INTO logs (timestamp) VALUES (now() - INTERVAL '24 hours')")

    Repo.query!("""
    INSERT INTO logs_severity_stats_5m (bucket)
    SELECT time_bucket(INTERVAL '5 minutes', now() - INTERVAL '24 hours') + step * INTERVAL '5 minutes'
    FROM generate_series(0, 3) AS step
    """)

    %{rows: [[first_bucket, window_start]]} =
      Repo.query!("""
      SELECT time_bucket(INTERVAL '5 minutes', now() - INTERVAL '24 hours'),
             now() - INTERVAL '24 hours'
      """)

    # On an exact bucket boundary there is no partial bucket to drop.
    assert DateTime.before?(first_bucket, window_start)

    %{rows: [[raw_min, rollup_min, _last_refresh]]} =
      Repo.query!(RefreshLogsSeverityStatsWorker.coverage_snapshot_sql(), [
        RefreshLogsSeverityStatsWorker.coverage_watermark_key()
      ])

    assert DateTime.compare(raw_min, window_start) == :eq
    assert DateTime.compare(rollup_min, first_bucket) == :eq
  end
end
