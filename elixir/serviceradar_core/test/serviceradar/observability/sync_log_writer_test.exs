defmodule ServiceRadar.Observability.SyncLogWriterTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Monitoring.OcsfEvent
  alias ServiceRadar.Observability.{Log, SyncLogWriter}
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    tenant = TestSupport.create_tenant_schema!("sync-log")

    on_exit(fn ->
      TestSupport.drop_tenant_schema!(tenant.tenant_slug)
    end)

    schema = TenantSchemas.schema_for_id(tenant.tenant_id)
    actor = %{id: "system", role: :admin, tenant_id: tenant.tenant_id}

    {:ok, tenant: tenant, schema: schema, actor: actor}
  end

  test "writes sync lifecycle logs without creating OCSF events", %{
    tenant: tenant,
    schema: schema,
    actor: actor
  } do
    source = %IntegrationSource{
      id: Ash.UUID.generate(),
      tenant_id: tenant.tenant_id,
      name: "Armis",
      source_type: :armis,
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default"
    }

    assert :ok = SyncLogWriter.write_start(source, device_count: 3)

    assert :ok =
             SyncLogWriter.write_finish(source,
               result: :failed,
               device_count: 3,
               error_message: "boom"
             )

    logs =
      Log
      |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: schema)
      |> Ash.read!()

    sync_logs =
      Enum.filter(logs, fn log ->
        get_in(log.attributes, ["serviceradar", "sync", "integration_source_id"]) ==
          to_string(source.id)
      end)

    assert Enum.any?(sync_logs, fn log ->
             get_in(log.attributes, ["serviceradar", "sync", "stage"]) == "started"
           end)

    assert Enum.any?(sync_logs, fn log ->
             get_in(log.attributes, ["serviceradar", "sync", "stage"]) == "finished" and
               get_in(log.attributes, ["serviceradar", "sync", "result"]) == "failed" and
               get_in(log.attributes, ["serviceradar", "sync", "error_message"]) == "boom"
           end)

    events =
      OcsfEvent
      |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: schema)
      |> Ash.read!()

    assert events == []
  end
end
