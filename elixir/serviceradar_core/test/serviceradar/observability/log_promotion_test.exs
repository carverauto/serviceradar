defmodule ServiceRadar.Observability.LogPromotionTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Observability.{LogPromotion, LogPromotionRule}
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    tenant = TestSupport.create_tenant_schema!("log-promote")

    on_exit(fn ->
      TestSupport.drop_tenant_schema!(tenant.tenant_slug)
    end)

    schema = TenantSchemas.schema_for_id(tenant.tenant_id)
    {:ok, tenant: tenant, schema: schema}
  end

  test "promotes log to event and creates alert", %{tenant: tenant, schema: schema} do
    actor = %{id: "system", role: :admin, tenant_id: tenant.tenant_id}

    {:ok, _rule} =
      LogPromotionRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "syslog-errors",
          match: %{"subject_prefix" => "logs.syslog", "severity_text" => "ERROR"},
          event: %{"log_name" => "syslog.promoted"}
        },
        actor: actor,
        tenant: schema
      )
      |> Ash.create()

    log = %{
      id: Ash.UUID.generate(),
      timestamp: DateTime.utc_now(),
      severity_text: "ERROR",
      severity_number: 17,
      body: "Disk failure detected",
      service_name: "syslog",
      attributes: %{"serviceradar.ingest" => %{"subject" => "logs.syslog.processed"}},
      resource_attributes: %{},
      tenant_id: tenant.tenant_id,
      created_at: DateTime.utc_now()
    }

    assert {:ok, 1} = LogPromotion.promote([log], tenant.tenant_id, schema)

    assert %Postgrex.Result{rows: [[1]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT COUNT(*) FROM #{schema}.ocsf_events WHERE log_name = $1",
               ["syslog.promoted"]
             )

    assert %Postgrex.Result{rows: [[alert_count]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT COUNT(*) FROM #{schema}.alerts WHERE event_id IS NOT NULL",
               []
             )

    assert alert_count > 0
  end
end
