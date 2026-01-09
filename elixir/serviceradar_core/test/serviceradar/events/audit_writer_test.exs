defmodule ServiceRadar.Events.AuditWriterTest do
  @moduledoc """
  Integration coverage for audit event writes.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    %{tenant_id: tenant_id, tenant_slug: tenant_slug} =
      TestSupport.create_tenant_schema!("audit")

    on_exit(fn ->
      TestSupport.drop_tenant_schema!(tenant_slug)
    end)

    {:ok, tenant_id: tenant_id}
  end

  test "writes audit events with UUID fields", %{tenant_id: tenant_id} do
    resource_id = Ecto.UUID.generate()

    assert :ok =
             AuditWriter.write(
               tenant_id: tenant_id,
               action: :create,
               resource_type: "integration_source",
               resource_id: resource_id,
               resource_name: "source-1",
               actor: %{id: "user-1", email: "user@example.com"},
               details: %{endpoint: "https://example.net"}
             )

    schema = TenantSchemas.schema_for_id(to_string(tenant_id))

    assert %Postgrex.Result{rows: [[count]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT COUNT(*) FROM #{schema}.ocsf_events",
               []
             )

    assert count > 0
  end
end
