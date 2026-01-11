defmodule ServiceRadar.Cluster.TenantSchemaIsolationIntegrationTest do
  @moduledoc """
  Integration tests for tenant schema selection and data isolation.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.Cluster.{TenantRegistry, TenantSchemas}
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    unique_id = System.unique_integer([:positive])
    tenant_a_id = Ash.UUID.generate()
    tenant_b_id = Ash.UUID.generate()
    tenant_a_slug = "schema-isolation-a-#{unique_id}"
    tenant_b_slug = "schema-isolation-b-#{unique_id}"

    TenantRegistry.register_slug(tenant_a_slug, tenant_a_id)
    TenantRegistry.register_slug(tenant_b_slug, tenant_b_id)

    {:ok, schema_a} = TenantSchemas.create_schema(tenant_a_slug)
    {:ok, schema_b} = TenantSchemas.create_schema(tenant_b_slug)

    on_exit(fn ->
      TenantSchemas.drop_schema(tenant_a_slug, cascade: true)
      TenantSchemas.drop_schema(tenant_b_slug, cascade: true)
    end)

    %{
      tenant_a_id: tenant_a_id,
      tenant_b_id: tenant_b_id,
      schema_a: schema_a,
      schema_b: schema_b
    }
  end

  test "writes land in the tenant schema and reads are isolated", context do
    device_a_uid = "device-a-#{System.unique_integer([:positive])}"
    device_b_uid = "device-b-#{System.unique_integer([:positive])}"

    {:ok, device_a} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{uid: device_a_uid, tenant_id: context.tenant_a_id},
        tenant: context.tenant_a_id,
        authorize?: false
      )
      |> Ash.create()

    {:ok, device_b} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{uid: device_b_uid, tenant_id: context.tenant_b_id},
        tenant: context.tenant_b_id,
        authorize?: false
      )
      |> Ash.create()

    assert device_a.uid == device_a_uid
    assert device_b.uid == device_b_uid

    assert {:ok, %Device{uid: ^device_a_uid}} =
             Device.get_by_uid(device_a_uid, tenant: context.tenant_a_id, authorize?: false)

    assert {:ok, %Device{uid: ^device_b_uid}} =
             Device.get_by_uid(device_b_uid, tenant: context.tenant_b_id, authorize?: false)

    assert {:error, %Ash.Error.Query.NotFound{}} =
             Device.get_by_uid(device_a_uid, tenant: context.tenant_b_id, authorize?: false)

    assert {:error, %Ash.Error.Query.NotFound{}} =
             Device.get_by_uid(device_b_uid, tenant: context.tenant_a_id, authorize?: false)

    assert count_devices(context.schema_a) == 1
    assert count_devices(context.schema_b) == 1
  end

  defp count_devices(schema) do
    {:ok, %{rows: [[count]]}} =
      Ecto.Adapters.SQL.query(Repo, "SELECT COUNT(*) FROM #{schema}.ocsf_devices", [])

    count
  end
end
