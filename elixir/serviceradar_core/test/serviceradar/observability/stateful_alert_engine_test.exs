defmodule ServiceRadar.Observability.StatefulAlertEngineTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Monitoring.{Alert, OcsfEvent}
  alias ServiceRadar.Observability.{StatefulAlertEngine, StatefulAlertRule}
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    tenant = TestSupport.create_tenant_schema!("stateful-alerts")

    on_exit(fn ->
      TestSupport.drop_tenant_schema!(tenant.tenant_slug)
    end)

    schema = TenantSchemas.schema_for_id(tenant.tenant_id)
    actor = %{id: "system", role: :admin, tenant_id: tenant.tenant_id}

    {:ok, tenant: tenant, schema: schema, actor: actor}
  end

  test "fires and resolves alerts based on bucketed counts", %{tenant: tenant, schema: schema, actor: actor} do
    {:ok, rule} =
      StatefulAlertRule
      |> Ash.Changeset.for_create(:create, %{
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
      }, tenant: schema, actor: actor)
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
        },
        tenant_id: tenant.tenant_id
      }
    end

    events = [event.(base_time), event.(base_time)]

    assert :ok = StatefulAlertEngine.evaluate_events(events, tenant.tenant_id, schema)

    events =
      OcsfEvent
      |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: schema)
      |> Ash.read!()

    assert Enum.any?(events, fn event -> event.log_name == "alert.rule.threshold" end)

    alert =
      Alert
      |> Ash.Query.for_read(:active, %{}, actor: actor, tenant: schema)
      |> Ash.read!()
      |> List.first()

    assert alert != nil
    assert alert.status in [:pending, :acknowledged, :escalated]

    later = DateTime.add(base_time, 180, :second)
    assert :ok = StatefulAlertEngine.evaluate_events([event.(later)], tenant.tenant_id, schema)

    {:ok, resolved} = Alert.get_by_id(alert.id, tenant: schema, actor: actor)
    assert resolved.status == :resolved
  end
end
