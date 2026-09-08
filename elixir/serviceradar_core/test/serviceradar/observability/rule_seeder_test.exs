defmodule ServiceRadar.Observability.RuleSeederTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.RuleSeeder
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  defp get_stateful_rule(name, actor) do
    query =
      StatefulAlertRule
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(name == ^name)

    assert {:ok, [rule]} = Ash.read(query, actor: actor)
    rule
  end

  defp update_stateful_rule!(rule, attrs, actor) do
    rule
    |> Ash.Changeset.for_update(:update, attrs, actor: actor)
    |> Ash.update!()
  end

  test "seeds the endpoint inventory vulnerability stateful alert rule" do
    actor = SystemActor.system(:test)

    assert :ok = RuleSeeder.seed_all()

    query =
      StatefulAlertRule
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(name == "endpoint_inventory_vulnerability")

    assert {:ok, [rule]} = Ash.read(query, actor: actor)
    assert rule.enabled
    assert rule.signal == :event

    assert rule.match["subject_prefix"] ==
             "signals.analytics.inventory.vulnerability_assessment"

    assert rule.match["attribute_equals"] == %{
             "signal_type" => "inventory",
             "event_type" => "vulnerability_assessment",
             "assessment_status" => "active",
             "assessment" => "confirmed",
             "disposition" => "affected",
             "finding_status" => "open"
           }

    assert rule.match["recovery"] == %{
             "subject_prefix" => "signals.analytics.inventory.vulnerability_assessment",
             "attribute_equals" => %{
               "signal_type" => "inventory",
               "event_type" => "vulnerability_assessment",
               "finding_status" => "resolved"
             }
           }

    assert rule.group_by == ["device", "package.identity_key", "cve_id"]
    assert rule.threshold == 1
    assert rule.event["log_name"] == "alert.security.endpoint_inventory.vulnerability"
    assert rule.alert["severity"] == "critical"
  end

  test "seeds the causal prediction health stateful alert rule" do
    actor = SystemActor.system(:test)

    assert :ok = RuleSeeder.seed_all()

    query =
      StatefulAlertRule
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(name == "causal_prediction_health_finding")

    assert {:ok, [rule]} = Ash.read(query, actor: actor)
    assert rule.enabled
    assert rule.signal == :event
    assert rule.match["subject_prefix"] == "signals.analytics.predictions"

    assert rule.match["attribute_equals"] == %{
             "signal_type" => "prediction",
             "event_type" => ["anomaly", "anomaly_detection"],
             "anomaly.state" => [
               "anomaly_open",
               "anomaly_update",
               "anomaly_drift_open",
               "anomaly_drift_update",
               "open",
               "anomalous"
             ]
           }

    assert rule.match["recovery"]["attribute_equals"]["anomaly.state"] == [
             "anomaly_clear",
             "anomaly_drift_clear",
             "clear",
             "cleared",
             "inactive"
           ]

    assert rule.group_by == ["device", "anomaly.series_key"]
    assert rule.threshold == 1
    assert rule.event["log_name"] == "alert.health.causal_prediction"
    assert rule.alert["severity_from"] == "source"
  end

  test "seeds the capacity forecast health stateful alert rule" do
    actor = SystemActor.system(:test)

    assert :ok = RuleSeeder.seed_all()

    query =
      StatefulAlertRule
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(name == "causal_capacity_health_finding")

    assert {:ok, [rule]} = Ash.read(query, actor: actor)
    assert rule.enabled
    assert rule.signal == :event
    assert rule.match["subject_prefix"] == "signals.analytics.predictions"

    assert rule.match["attribute_equals"] == %{
             "signal_type" => "prediction",
             "event_type" => "capacity_forecast",
             "capacity_forecast.status" => "projected"
           }

    assert rule.match["recovery"]["attribute_equals"]["capacity_forecast.status"] == [
             "inactive",
             "skipped"
           ]

    assert rule.group_by == ["device", "capacity_forecast.resource_key"]
    assert rule.threshold == 1
    assert rule.event["log_name"] == "alert.health.capacity_forecast"
    assert rule.alert["severity_from"] == "source"
  end

  test "stamps managed template metadata on freshly seeded stateful rules" do
    actor = SystemActor.system(:test)

    assert :ok = RuleSeeder.seed_all()

    for %{name: name, template_version: version} <- RuleSeeder.default_stateful_rules() do
      rule = get_stateful_rule(name, actor)

      assert rule.managed
      assert rule.template_version == version
      assert is_binary(rule.template_fingerprint)
    end
  end

  test "reconciles a managed rule stamped at an older template version" do
    actor = SystemActor.system(:test)

    assert :ok = RuleSeeder.seed_all()

    rule = get_stateful_rule("causal_prediction_health_finding", actor)

    legacy_match =
      rule.match
      |> Map.put("subject_prefix", "signals.causal.predictions")
      |> put_in(["recovery", "subject_prefix"], "signals.causal.predictions")

    # Simulate a pre-marker row after the contract-repair migration stamp:
    # managed at version 0 with no fingerprint.
    update_stateful_rule!(
      rule,
      %{match: legacy_match, managed: true, template_version: 0, template_fingerprint: nil},
      actor
    )

    assert :ok = RuleSeeder.seed_all()

    reconciled = get_stateful_rule("causal_prediction_health_finding", actor)

    assert reconciled.match["subject_prefix"] == "signals.analytics.predictions"
    assert reconciled.match["recovery"]["subject_prefix"] == "signals.analytics.predictions"
    assert reconciled.managed
    assert reconciled.template_version == 2
    assert is_binary(reconciled.template_fingerprint)
  end

  test "preserves operator-tunable knobs when reconciling a managed rule" do
    actor = SystemActor.system(:test)

    assert :ok = RuleSeeder.seed_all()

    rule = get_stateful_rule("causal_capacity_health_finding", actor)

    update_stateful_rule!(
      rule,
      %{
        enabled: false,
        renotify_seconds: 3_600,
        managed: true,
        template_version: 0,
        template_fingerprint: nil
      },
      actor
    )

    assert :ok = RuleSeeder.seed_all()

    reconciled = get_stateful_rule("causal_capacity_health_finding", actor)

    refute reconciled.enabled
    assert reconciled.renotify_seconds == 3_600
    assert reconciled.template_version == 1
  end

  test "leaves an unmanaged seeded-name rule untouched" do
    actor = SystemActor.system(:test)

    assert :ok = RuleSeeder.seed_all()

    rule = get_stateful_rule("causal_prediction_health_finding", actor)
    operator_match = Map.put(rule.match, "subject_prefix", "operator.custom")

    update_stateful_rule!(
      rule,
      %{match: operator_match, managed: false, template_version: 0, template_fingerprint: nil},
      actor
    )

    assert :ok = RuleSeeder.seed_all()

    untouched = get_stateful_rule("causal_prediction_health_finding", actor)

    assert untouched.match["subject_prefix"] == "operator.custom"
    refute untouched.managed
    assert untouched.template_version == 0
  end

  test "leaves an operator-customized falco rule left unstamped by the migration untouched" do
    actor = SystemActor.system(:test)

    assert :ok = RuleSeeder.seed_all()

    rule = get_stateful_rule("falco_critical_incident", actor)
    operator_match = Map.put(rule.match, "severity_number_min", 3)

    # The contract-repair migration leaves non-contract seeded names
    # unstamped: managed stays false with no template metadata.
    update_stateful_rule!(
      rule,
      %{match: operator_match, managed: false, template_version: nil, template_fingerprint: nil},
      actor
    )

    assert :ok = RuleSeeder.seed_all()

    untouched = get_stateful_rule("falco_critical_incident", actor)

    assert untouched.match["severity_number_min"] == 3
    refute untouched.managed
    assert is_nil(untouched.template_version)
    assert is_nil(untouched.template_fingerprint)
  end

  test "does not apply the nil-fingerprint one-time reconcile to a customized falco rule" do
    actor = SystemActor.system(:test)

    assert :ok = RuleSeeder.seed_all()

    rule = get_stateful_rule("falco_critical_incident", actor)
    operator_match = Map.put(rule.match, "severity_number_min", 3)

    # Even if a falco rule somehow carries the v0/no-fingerprint marker, the
    # one-time reconcile is scoped to the two contract-repair rules only.
    update_stateful_rule!(
      rule,
      %{match: operator_match, managed: true, template_version: 0, template_fingerprint: nil},
      actor
    )

    assert :ok = RuleSeeder.seed_all()

    untouched = get_stateful_rule("falco_critical_incident", actor)

    assert untouched.match["severity_number_min"] == 3
    assert untouched.managed
    assert untouched.template_version == 0
  end

  test "adopts a pristine unmanaged falco rule matching the current template without content change" do
    actor = SystemActor.system(:test)

    assert :ok = RuleSeeder.seed_all()

    rule = get_stateful_rule("falco_critical_incident", actor)
    original_match = rule.match

    update_stateful_rule!(
      rule,
      %{managed: false, template_version: nil, template_fingerprint: nil},
      actor
    )

    assert :ok = RuleSeeder.seed_all()

    adopted = get_stateful_rule("falco_critical_incident", actor)

    assert adopted.managed
    assert adopted.template_version == 1
    assert is_binary(adopted.template_fingerprint)
    assert adopted.match == original_match
  end

  test "leaves a managed rule whose seeder-owned fields diverged from the last template" do
    actor = SystemActor.system(:test)

    assert :ok = RuleSeeder.seed_all()

    rule = get_stateful_rule("causal_prediction_health_finding", actor)
    operator_match = Map.put(rule.match, "subject_prefix", "operator.custom")

    update_stateful_rule!(
      rule,
      %{
        match: operator_match,
        managed: true,
        template_version: 0,
        template_fingerprint: "fingerprint-of-a-prior-template"
      },
      actor
    )

    assert :ok = RuleSeeder.seed_all()

    untouched = get_stateful_rule("causal_prediction_health_finding", actor)

    assert untouched.match["subject_prefix"] == "operator.custom"
    assert untouched.managed
    assert untouched.template_version == 0
  end
end
