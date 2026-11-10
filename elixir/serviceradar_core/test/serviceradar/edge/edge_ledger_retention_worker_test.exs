defmodule ServiceRadar.Edge.EdgeLedgerRetentionWorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.EdgeLedgerRetentionWorker
  alias ServiceRadar.Jobs.CoreCrontab

  describe "retention_horizon_seconds/1" do
    @day 86_400

    test "derives the horizon from the dead-letter, output-grant and spool limits" do
      components = EdgeLedgerRetentionWorker.retention_components()

      # No source-stream expiry component: source streams have no MaxAge.
      refute Map.has_key?(components, :edge_record_stream_max_age_seconds)
      assert components.dead_letter_retention_seconds == 3 * @day
      assert components.output_grant_max_lifetime_seconds == 8 * @day + 300
      assert components.spool_retry_horizon_seconds == 30 * @day + 3_600 + 900

      assert EdgeLedgerRetentionWorker.retention_horizon_seconds() == 30 * @day + 3_600 + 900
    end

    test "expands when the configured sweep lease horizon ceiling exceeds the default" do
      assert EdgeLedgerRetentionWorker.retention_horizon_seconds(60 * @day) ==
               60 * @day + 3_600 + 900
    end
  end

  describe "shared crontab registration" do
    test "CoreCrontab includes EdgeLedgerRetentionWorker" do
      workers =
        fn _key, default -> default end
        |> CoreCrontab.cron_entries()
        |> Enum.map(fn
          {_expr, worker} -> worker
          {_expr, worker, _opts} -> worker
        end)

      assert EdgeLedgerRetentionWorker in workers
    end
  end
end
