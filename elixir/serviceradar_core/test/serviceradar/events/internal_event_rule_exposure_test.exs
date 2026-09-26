defmodule ServiceRadar.Events.InternalEventRuleExposureTest do
  # Internal events that used to be inserted directly were never evaluated
  # against stateful rules; published through EventWriter, they now are. This
  # proves that none of them starts matching a rule RuleSeeder installs.
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.RuleSeeder
  alias ServiceRadar.Observability.StatefulAlertEngine.Record
  alias ServiceRadar.Observability.StatefulAlertEngine.RuleMatcher

  # The fixed `log_name` of every event a migrated producer publishes. An event
  # rule matches only an event whose `log_name` starts with the rule's
  # `subject_prefix`, so a name no seeded prefix covers cannot match a seeded
  # rule, whatever its severity or attributes.
  @published_log_names [
    # Oban failure reporter
    "serviceradar.oban",
    # Bumblebee catalog refresh
    "bumblebee.catalog.refresh",
    # Camera relay health, analysis results, analysis-worker alerts
    "camera.relay.session.failed",
    "camera.relay.gateway.saturation_denied",
    "camera.relay.session.viewer_idle",
    "camera.relay.alert.failure_burst",
    "camera.relay.alert.gateway_saturation",
    "camera.relay.alert.viewer_idle_churn",
    "camera.analysis.detection",
    "camera.analysis.worker.alert",
    "camera.analysis.worker.alert.clear",
    # Sync failures, MTR causal signal, Armis northbound
    "serviceradar.sync",
    "internal.causal.mtr",
    "integrations.armis.northbound",
    # Composite checks, credentials
    "composite_check.verdict.changed",
    "credential.secret_provider.lifecycle",
    "credential.secret.lifecycle",
    "credential.secret_resolution",
    "credential.broker_grant.lifecycle",
    # Endpoint inventory scans, source-fact disagreements
    "endpoint_inventory.scan",
    "source_fact_disagreement"
  ]

  # Not listed above, each for a reason:
  #   * the stateful alert engine's own events (`alert.*`), which the engine
  #     refuses to evaluate -- asserted below;
  #   * northbound handler events, which carry no `log_name` -- asserted below;
  #   * camera plugin events and interface threshold events, whose `log_name`
  #     comes from a plugin or an operator-configured threshold. Like an event
  #     from any external source they are evaluated, and the operator's rule
  #     decides what they match;
  #   * the anomaly liveness probe, which the publisher never publishes.

  defp seeded_event_prefixes do
    RuleSeeder.default_stateful_rules()
    |> Enum.filter(&(&1.signal == :event))
    |> Enum.flat_map(fn %{match: match} ->
      [match | List.wrap(match["recovery"])]
    end)
  end

  test "RuleSeeder installs event rules to check against" do
    refute seeded_event_prefixes() == []
  end

  test "no event a migrated producer publishes matches a seeded rule's subject" do
    for log_name <- @published_log_names, match <- seeded_event_prefixes() do
      refute RuleMatcher.match_subject_prefix(log_name, match),
             "#{log_name} falls under seeded rule prefix #{inspect(match["subject_prefix"])}"
    end
  end

  test "a seeded rule's own subject does match, so the check above can fail" do
    for %{"subject_prefix" => prefix} = match when is_binary(prefix) <- seeded_event_prefixes() do
      assert RuleMatcher.match_subject_prefix(prefix <> ".probe", match)
    end
  end

  test "an event without a log_name, such as a northbound handler event, matches no seeded rule" do
    for match <- seeded_event_prefixes() do
      refute RuleMatcher.match_subject_prefix(nil, match)
    end
  end

  test "the stateful alert engine does not evaluate its own events" do
    event = %{
      log_name: "alert.health.core_check",
      metadata: %{"serviceradar" => %{"stateful_rule" => true}}
    }

    assert Record.skip_engine_event?(event)
  end
end
