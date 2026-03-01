defmodule ServiceRadar.Observability.StatefulAlertEngineTest do
  @moduledoc """
  In the single-deployment architecture, tests run against the single schema
  determined by PostgreSQL search_path.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Monitoring.{Alert, OcsfEvent}
  alias ServiceRadar.Observability.{StatefulAlertEngine, StatefulAlertRule}
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = %{id: "system", role: :admin}
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
    assert :ok = StatefulAlertEngine.evaluate_events(events, nil)

    events =
      OcsfEvent
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.read!()

    assert Enum.any?(events, fn event -> event.log_name == "alert.rule.threshold" end)

    alert =
      Alert
      |> Ash.Query.for_read(:active, %{}, actor: actor)
      |> Ash.read!()
      |> List.first()

    assert alert != nil
    assert alert.status in [:pending, :acknowledged, :escalated]

    later = DateTime.add(base_time, 180, :second)
    assert :ok = StatefulAlertEngine.evaluate_events([event.(later)], nil)

    {:ok, resolved} = Alert.get_by_id(alert.id, actor: actor)
    assert resolved.status == :resolved
  end
end
