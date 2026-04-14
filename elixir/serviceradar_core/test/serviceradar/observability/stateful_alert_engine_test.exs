defmodule ServiceRadar.Observability.StatefulAlertEngineTest do
  @moduledoc """
  In the single-deployment architecture, tests run against the single schema
  determined by PostgreSQL search_path.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Ash.Page
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Monitoring.OcsfEvent
  alias ServiceRadar.Observability.StatefulAlertEngine
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Observability.StatefulAlertRuleHistory
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = %{id: "system", role: :admin}
    reset_engine()
    on_exit(&reset_engine/0)
    {:ok, actor: actor}
  end

  test "fires and resolves alerts based on bucketed counts", %{actor: actor} do
    {:ok, rule} =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "sync-failures",
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

    base_time = DateTime.utc_now()

    event = fn timestamp ->
      %{
        id: Ash.UUID.generate(),
        time: timestamp,
        severity_id: OCSF.severity_high(),
        severity: OCSF.severity_name(OCSF.severity_high()),
        message: "sync failed",
        log_name: "sync",
        log_provider: "sync",
        unmapped: %{
          "log_attributes" => %{
            "serviceradar" => %{
              "sync" => %{
                "integration_source_id" => "source-1"
              }
            }
          }
        }
      }
    end

    events = [event.(base_time), event.(base_time)]

    # In single-deployment mode, schema is determined by search_path
    assert :ok = StatefulAlertEngine.evaluate_events(events)

    events =
      OcsfEvent
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.read!()
      |> Page.unwrap!()

    threshold_event =
      Enum.find(events, fn event ->
        event.log_name == "alert.rule.threshold" and
          metadata_value(event.metadata, ["serviceradar", "rule_id"]) == to_string(rule.id)
      end)

    assert threshold_event

    alert =
      Alert
      |> Ash.Query.for_read(:active, %{}, actor: actor)
      |> Ash.read!()
      |> Page.unwrap!()
      |> Enum.find(fn alert ->
        metadata_value(alert.metadata, ["event_id"]) == to_string(threshold_event.id)
      end)

    assert alert
    assert alert.status in [:pending, :acknowledged, :escalated]

    later = DateTime.add(base_time, 180, :second)
    assert :ok = StatefulAlertEngine.evaluate_events([event.(later)])

    {:ok, resolved} = Alert.get_by_id(alert.id, actor: actor)
    assert resolved.status == :resolved

    {:ok, history} =
      rule.id |> StatefulAlertRuleHistory.list_by_rule(actor: actor) |> Page.unwrap()

    assert Enum.any?(history, &(&1.event_type == :fired))
    assert Enum.any?(history, &(&1.event_type == :recovered))
  end

  test "deduplicates repeated event bursts into one active incident and rolls over after cooldown gap",
       %{actor: actor} do
    unique = System.unique_integer([:positive])
    subject = "falco.test.#{unique}"
    title = "Falco Security Incident #{unique}"
    rule_name = "Drop and execute new binary in container #{unique}"

    {:ok, rule} =
      StatefulAlertRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "falco-incident-#{unique}",
          enabled: true,
          signal: :event,
          match: %{
            "subject_prefix" => subject,
            "severity_number_min" => OCSF.severity_critical()
          },
          group_by: ["rule", "hostname"],
          threshold: 1,
          window_seconds: 300,
          bucket_seconds: 60,
          cooldown_seconds: 300,
          renotify_seconds: 3600,
          event: %{
            "log_name" => "alert.security.falco.incident",
            "message" => "Falco security incident detected"
          },
          alert: %{
            "title" => title,
            "severity" => "critical"
          }
        },
        actor: actor
      )
      |> Ash.create()

    base_time = DateTime.utc_now()

    event = fn timestamp ->
      %{
        id: Ash.UUID.generate(),
        time: timestamp,
        severity_id: OCSF.severity_critical(),
        severity: OCSF.severity_name(OCSF.severity_critical()),
        message: "Drop and execute new binary in container",
        log_name: subject,
        log_provider: "falco",
        metadata: %{
          "subject" => subject,
          "rule" => rule_name,
          "hostname" => "core-elx"
        },
        unmapped: %{
          "rule" => rule_name,
          "hostname" => "core-elx"
        }
      }
    end

    assert :ok = StatefulAlertEngine.evaluate_events([event.(base_time)])

    assert :ok =
             StatefulAlertEngine.evaluate_events([event.(DateTime.add(base_time, 30, :second))])

    assert :ok =
             StatefulAlertEngine.evaluate_events([event.(DateTime.add(base_time, 90, :second))])

    alerts =
      Alert
      |> Ash.Query.for_read(:active, %{}, actor: actor)
      |> Ash.read!()
      |> Page.unwrap!()
      |> Enum.filter(fn alert -> alert.title == title end)

    assert [active_alert] = alerts
    assert active_alert.metadata["incident_rule_id"] == to_string(rule.id)

    assert active_alert.metadata["incident_group_values"] == %{
             "hostname" => "core-elx",
             "rule" => rule_name
           }

    assert active_alert.metadata["incident_occurrence_count"] == 3

    history =
      rule.id
      |> StatefulAlertRuleHistory.list_by_rule(actor: actor)
      |> Page.unwrap!()

    assert Enum.count(Enum.filter(history, &(&1.event_type == :fired))) == 1
    refute Enum.any?(history, &(&1.event_type == :cooldown))

    rollover_time = DateTime.add(base_time, 420, :second)
    assert :ok = StatefulAlertEngine.evaluate_events([event.(rollover_time)])

    active_alerts_after_rollover =
      Alert
      |> Ash.Query.for_read(:active, %{}, actor: actor)
      |> Ash.read!()
      |> Page.unwrap!()
      |> Enum.filter(fn alert -> alert.title == title end)

    assert [replacement_alert] = active_alerts_after_rollover
    refute replacement_alert.id == active_alert.id
    assert replacement_alert.metadata["incident_occurrence_count"] == 1

    {:ok, resolved_original_alert} = Alert.get_by_id(active_alert.id, actor: actor)
    assert resolved_original_alert.status == :resolved

    rollover_history =
      rule.id
      |> StatefulAlertRuleHistory.list_by_rule(actor: actor)
      |> Page.unwrap!()

    assert Enum.count(Enum.filter(rollover_history, &(&1.event_type == :fired))) == 2
    assert Enum.any?(rollover_history, &(&1.event_type == :recovered))
  end

  defp reset_engine do
    case ProcessRegistry.lookup(:stateful_alert_engine) do
      [{pid, _}] ->
        _ = ProcessRegistry.terminate_child(pid)
        Process.sleep(25)
        :ok

      _ ->
        :ok
    end
  end

  defp metadata_value(data, [key]), do: metadata_value(data, key)

  defp metadata_value(data, [key | rest]) when is_map(data) do
    case metadata_value(data, key) do
      %{} = nested -> metadata_value(nested, rest)
      _ -> nil
    end
  end

  defp metadata_value(data, key) when is_map(data) and is_binary(key) do
    Map.get(data, key) || Map.get(data, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(data, key)
  end

  defp metadata_value(data, key) when is_map(data) and is_atom(key) do
    Map.get(data, key) || Map.get(data, Atom.to_string(key))
  end

  defp metadata_value(_, _), do: nil
end
