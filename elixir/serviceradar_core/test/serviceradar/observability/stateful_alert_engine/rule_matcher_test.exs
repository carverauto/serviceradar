defmodule ServiceRadar.Observability.StatefulAlertEngine.RuleMatcherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.RuleSeeder
  alias ServiceRadar.Observability.StatefulAlertEngine.Record
  alias ServiceRadar.Observability.StatefulAlertEngine.RuleMatcher

  defp seeded_rule(name) do
    rule = Enum.find(RuleSeeder.default_stateful_rules(), &(&1[:name] == name))
    assert rule, "expected RuleSeeder to seed #{name}"
    %{match: rule[:match]}
  end

  # Alert-evaluation row shape produced by
  # ServiceRadar.EventWriter.Processors.AnalyticsSignals for a v2 edge finding.
  defp anomaly_finding_row(state) do
    %{
      id: "0b6a5d9e-45f8-4c58-9d3e-1f2a7c9e4b21",
      class_uid: 2004,
      log_name:
        "signals.analytics.predictions." <>
          "v2|partition=70726f642d65617374|identity=sr:demo-device|metric=memory_used_percent",
      severity_id: 4,
      device: %{"uid" => "sr:demo-device"},
      unmapped: %{
        "signal_type" => "prediction",
        "event_type" => "anomaly",
        "anomaly" => %{
          "series_key" =>
            "v2|partition=prod-east|identity=sr:demo-device|metric=memory.used_percent",
          "metric_class" => "sysmon.memory",
          "state" => state
        }
      },
      metadata: %{"signal_type" => "prediction", "event_type" => "anomaly"}
    }
  end

  defp capacity_finding_row(status) do
    %{
      id: "4f0d1c2b-93a7-4b7e-8c11-6f5e2a8d7c30",
      class_uid: 2004,
      log_name:
        "signals.analytics.predictions." <>
          "v2|partition=70726f642d65617374|identity=sr:demo-device|metric=disk_used_percent",
      severity_id: 3,
      device: %{"uid" => "sr:demo-device"},
      unmapped: %{
        "signal_type" => "prediction",
        "event_type" => "capacity_forecast",
        "capacity_forecast" => %{
          "resource_key" =>
            "v2|partition=prod-east|identity=sr:demo-device|metric=disk.used_percent",
          "status" => status
        }
      },
      metadata: %{"signal_type" => "prediction", "event_type" => "capacity_forecast"}
    }
  end

  defp vulnerability_assessment_row(overrides \\ %{}) do
    attributes =
      Map.merge(
        %{
          "signal_type" => "inventory",
          "event_type" => "vulnerability_assessment",
          "assessment_status" => "active",
          "assessment" => "confirmed",
          "disposition" => "affected",
          "finding_status" => "open",
          "cve_id" => "CVE-2099-4251",
          "package" => %{"identity_key" => "host:starling-fetch"}
        },
        overrides
      )

    %{
      id: "20d58f80-e788-4eed-876d-6dfb79fc9b41",
      class_uid: 2002,
      log_name: "signals.analytics.inventory.vulnerability_assessment",
      severity_id: 4,
      device: %{"uid" => "sr:demo-device"},
      unmapped: attributes,
      metadata: %{"signal_type" => "inventory", "event_type" => "vulnerability_assessment"}
    }
  end

  # Row shape LogPromotion produces when the seeded event rule promotes a
  # `logs.internal.health` log: the log's attributes ride under
  # `unmapped.log_attributes`, which is where event matching and incident
  # grouping read from.
  defp core_health_event_row(new_state, entity_id \\ "seasonal-baseline-freshness") do
    %{
      id: "7d1c2a54-3f7e-4d0b-9b2e-6a1f0c9d8e21",
      class_uid: 1008,
      log_name: "health.core.state_change",
      severity_id: if(new_state == "unhealthy", do: 4, else: 1),
      unmapped: %{
        "log_attributes" => %{
          "serviceradar.ingest" => %{"subject" => "logs.internal.health"},
          "health" => %{
            "entity_type" => "core",
            "entity_id" => entity_id,
            "old_state" => if(new_state == "unhealthy", do: "healthy", else: "unhealthy"),
            "new_state" => new_state,
            "reason" => "health_check_failed"
          }
        },
        "log_resource_attributes" => %{},
        "rule_match" => %{}
      }
    }
  end

  # The stored log the seeded event rule promotes (attributes as the logs
  # processor persists them: the HealthWriter block plus ingest metadata).
  defp core_health_log(entity_type) do
    %{
      body: "Core seasonal-baseline-freshness changed from healthy to unhealthy",
      severity_text: "High",
      severity_number: 17,
      attributes: %{
        "serviceradar.ingest" => %{
          "subject" => "logs.internal.health",
          "source_kind" => "internal"
        },
        "health" => %{
          "entity_type" => entity_type,
          "entity_id" => "seasonal-baseline-freshness",
          "old_state" => "healthy",
          "new_state" => "unhealthy",
          "reason" => "health_check_failed"
        }
      }
    }
  end

  describe "seeded core health check rules" do
    test "the event rule promotes core health logs and only core ones" do
      rule =
        Enum.find(
          RuleSeeder.default_event_rules(),
          &(&1[:name] == "core_health_state_change_events")
        )

      assert rule, "expected RuleSeeder to seed core_health_state_change_events"
      assert rule[:event]["log_name"] == "health.core.state_change"
      assert rule[:event]["alert"] == false

      assert RuleMatcher.log_matches?(core_health_log("core"), rule[:match])
      refute RuleMatcher.log_matches?(core_health_log("agent"), rule[:match])
    end

    test "matches a core check going unhealthy" do
      rule = seeded_rule("core_health_check_unhealthy")

      assert RuleMatcher.rule_matches_event?(core_health_event_row("unhealthy"), rule)
    end

    test "recovers when the check returns to healthy" do
      rule = seeded_rule("core_health_check_unhealthy")

      assert RuleMatcher.rule_recovers_event?(core_health_event_row("healthy"), rule)
      refute RuleMatcher.rule_matches_event?(core_health_event_row("healthy"), rule)
    end

    test "each check is its own incident" do
      rule =
        Enum.find(
          RuleSeeder.default_stateful_rules(),
          &(&1[:name] == "core_health_check_unhealthy")
        )

      assert {:ok, "health.entity_id=seasonal-baseline-freshness", _values} =
               Record.build_group(rule[:group_by], core_health_event_row("unhealthy"))

      assert {:ok, "health.entity_id=anomaly-ingest-silence", _values} =
               Record.build_group(
                 rule[:group_by],
                 core_health_event_row("unhealthy", "anomaly-ingest-silence")
               )
    end
  end

  describe "seeded anomaly rule template" do
    test "matches a v2 anomaly_open finding" do
      rule = seeded_rule("causal_prediction_health_finding")

      assert RuleMatcher.rule_matches_event?(anomaly_finding_row("anomaly_open"), rule)
    end

    test "matches a v2 anomaly_drift_open finding" do
      rule = seeded_rule("causal_prediction_health_finding")

      assert RuleMatcher.rule_matches_event?(anomaly_finding_row("anomaly_drift_open"), rule)
    end

    test "recovers on a v2 anomaly_clear finding" do
      rule = seeded_rule("causal_prediction_health_finding")

      assert RuleMatcher.rule_recovers_event?(anomaly_finding_row("anomaly_clear"), rule)
      refute RuleMatcher.rule_matches_event?(anomaly_finding_row("anomaly_clear"), rule)
    end

    test "does not match findings from the retired causal subject family" do
      rule = seeded_rule("causal_prediction_health_finding")

      legacy_row =
        Map.put(
          anomaly_finding_row("anomaly_open"),
          :log_name,
          "signals.causal.predictions.v2|identity=sr:demo-device|metric=memory_used_percent"
        )

      refute RuleMatcher.rule_matches_event?(legacy_row, rule)
    end
  end

  describe "seeded capacity rule template" do
    test "matches a v2 projected capacity forecast finding" do
      rule = seeded_rule("causal_capacity_health_finding")

      assert RuleMatcher.rule_matches_event?(capacity_finding_row("projected"), rule)
    end

    test "recovers on inactive and skipped capacity forecast findings" do
      rule = seeded_rule("causal_capacity_health_finding")

      assert RuleMatcher.rule_recovers_event?(capacity_finding_row("inactive"), rule)
      assert RuleMatcher.rule_recovers_event?(capacity_finding_row("skipped"), rule)
      refute RuleMatcher.rule_matches_event?(capacity_finding_row("inactive"), rule)
    end
  end

  describe "seeded endpoint vulnerability rule template" do
    test "matches only active confirmed affected assessment findings" do
      rule = seeded_rule("endpoint_inventory_vulnerability")

      assert RuleMatcher.rule_matches_event?(vulnerability_assessment_row(), rule)

      for override <- [
            %{"assessment" => "candidate"},
            %{"disposition" => "fixed"},
            %{"disposition" => "not_affected"},
            %{"assessment_status" => "resolved"},
            %{"finding_status" => "resolved"}
          ] do
        refute RuleMatcher.rule_matches_event?(vulnerability_assessment_row(override), rule)
      end
    end

    test "recovers on the stable assessment finding's resolved transition" do
      rule = seeded_rule("endpoint_inventory_vulnerability")

      resolved =
        vulnerability_assessment_row(%{
          "assessment_status" => "resolved",
          "disposition" => "fixed",
          "finding_status" => "resolved"
        })

      assert RuleMatcher.rule_recovers_event?(resolved, rule)
      refute RuleMatcher.rule_matches_event?(resolved, rule)
    end

    test "groups each device, package identity, and CVE independently" do
      seeded =
        Enum.find(
          RuleSeeder.default_stateful_rules(),
          &(&1[:name] == "endpoint_inventory_vulnerability")
        )

      first = vulnerability_assessment_row()
      second = vulnerability_assessment_row(%{"cve_id" => "CVE-2099-4252"})

      third =
        vulnerability_assessment_row(%{
          "package" => %{"identity_key" => "host:moonbeam-parser"}
        })

      assert {:ok, first_key, _} = Record.build_group(seeded.group_by, first)
      assert {:ok, second_key, _} = Record.build_group(seeded.group_by, second)
      assert {:ok, third_key, _} = Record.build_group(seeded.group_by, third)

      assert MapSet.size(MapSet.new([first_key, second_key, third_key])) == 3
    end
  end
end
