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
  alias ServiceRadar.Observability.StatefulAlertRuleHistory
  alias ServiceRadar.Observability.StatefulAlertRule
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

    {:ok, history} = StatefulAlertRuleHistory.list_by_rule(rule.id, actor: actor) |> Page.unwrap()
    assert Enum.any?(history, &(&1.event_type == :fired))
    assert Enum.any?(history, &(&1.event_type == :recovered))
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
