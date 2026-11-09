defmodule ServiceRadar.Edge.EdgeLedgerRetentionWorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.DeliveryGrants
  alias ServiceRadar.Edge.EdgeLedgerRetentionWorker
  alias ServiceRadar.Edge.OutputGrants
  alias ServiceRadar.Edge.PipelineSettings
  alias ServiceRadar.EventWriter
  alias ServiceRadar.Jobs.CoreCrontab

  describe "retention_horizon_seconds/1" do
    test "derives retention horizon from stream max_age, dead-letter retention, output grants, and spool retry horizon" do
      components = EdgeLedgerRetentionWorker.retention_components()
      horizon = EdgeLedgerRetentionWorker.retention_horizon_seconds()

      primary_stream = EventWriter.Config.edge_record_stream()
      audit_stream = EventWriter.Config.edge_record_audit_stream()
      dead_letter_stream = EventWriter.Config.edge_record_dead_letter_stream()

      expected_stream_seconds =
        div(
          Enum.max([
            primary_stream.stream_max_age,
            Map.get(primary_stream, :stream_duplicate_window, 0),
            audit_stream.stream_max_age,
            Map.get(audit_stream, :stream_duplicate_window, 0)
          ]),
          1_000_000_000
        )

      expected_dead_letter_seconds =
        div(
          max(
            dead_letter_stream.stream_max_age,
            Map.get(dead_letter_stream, :stream_duplicate_window, 0)
          ),
          1_000_000_000
        )

      expected_output_grant_seconds = OutputGrants.max_lifetime_seconds()

      expected_spool_retry_seconds =
        max(
          expected_output_grant_seconds,
          PipelineSettings.default_max_horizon_seconds() +
            EdgeLedgerRetentionWorker.draining_epoch_lease_margin_seconds()
        ) + DeliveryGrants.ttl_seconds()

      assert components.edge_record_stream_max_age_seconds == expected_stream_seconds
      assert components.dead_letter_retention_seconds == expected_dead_letter_seconds
      assert components.output_grant_max_lifetime_seconds == expected_output_grant_seconds
      assert components.spool_retry_horizon_seconds == expected_spool_retry_seconds

      assert horizon >= components.edge_record_stream_max_age_seconds
      assert horizon >= components.dead_letter_retention_seconds
      assert horizon >= components.output_grant_max_lifetime_seconds
      assert horizon >= components.spool_retry_horizon_seconds
      assert horizon == Enum.max(Map.values(components))
    end

    test "expands when the configured sweep lease horizon ceiling exceeds the default" do
      custom_max_horizon = 60 * 86_400
      horizon = EdgeLedgerRetentionWorker.retention_horizon_seconds(custom_max_horizon)

      assert horizon ==
               custom_max_horizon +
                 EdgeLedgerRetentionWorker.draining_epoch_lease_margin_seconds() +
                 DeliveryGrants.ttl_seconds()
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
