defmodule ServiceRadar.Observability.StatefulAlertEngineRulesLoadedTelemetryTest do
  @moduledoc """
  Asserts every engine shard reports its owned rule count via telemetry on a
  successful rule load, so a zero-rule shard (e.g. one Horde-placed on a
  repo-less node) is visible on dashboards.
  """
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Observability.StatefulAlertEngine
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.TestSupport

  @rules_loaded_event [:serviceradar, :stateful_alert_engine, :rules_loaded]

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    TestSupport.drain_stateful_alert_engines()
    on_exit(fn -> TestSupport.drain_stateful_alert_engines() end)

    handler_id = {__MODULE__, self()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      @rules_loaded_event,
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:rules_loaded, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, actor: %{id: "system", role: :admin}}
  end

  test "each shard reports its owned rule count on load", %{actor: actor} do
    {:ok, rule} =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "rules-loaded-telemetry",
          enabled: true,
          signal: :event,
          match: %{"always" => true},
          group_by: ["serviceradar.sync.integration_source_id"],
          threshold: 2,
          window_seconds: 120,
          bucket_seconds: 60,
          cooldown_seconds: 60,
          renotify_seconds: 3600
        },
        actor: actor
      )
      |> Ash.create()

    event = %{
      id: Ash.UUID.generate(),
      time: DateTime.utc_now(),
      severity_id: OCSF.severity_high(),
      severity: OCSF.severity_name(OCSF.severity_high()),
      message: "sync failed",
      log_name: "sync",
      log_provider: "sync",
      unmapped: %{
        "log_attributes" => %{
          "serviceradar" => %{
            "sync" => %{"integration_source_id" => "source-1"}
          }
        }
      }
    }

    # One event below threshold: exercises the load path on every shard
    # without firing the rule.
    assert :ok = StatefulAlertEngine.evaluate_events([event])

    shard_count = StatefulAlertEngine.shard_count()

    reports =
      for _ <- 1..shard_count, into: %{} do
        assert_receive {:rules_loaded, %{count: count}, %{shard: shard}}, 5_000
        {shard, count}
      end

    assert map_size(reports) == shard_count
    assert Map.fetch!(reports, StatefulAlertEngine.shard_for_rule_id(rule.id)) >= 1
  end
end
