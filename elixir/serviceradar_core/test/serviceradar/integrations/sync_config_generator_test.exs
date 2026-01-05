defmodule ServiceRadar.Integrations.SyncConfigGeneratorTest do
  @moduledoc """
  Integration tests for sync config generation and tenant isolation.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  require Ash.Query
  import Ash.Expr

  alias ServiceRadar.Identity.Tenant
  alias ServiceRadar.Integrations.{IntegrationSource, SyncConfigGenerator, SyncService}

  setup_all do
    {:ok, _} = Application.ensure_all_started(:serviceradar_core)
    :ok
  end

  test "tenant sync config only includes tenant sources and rejects mismatched tenant" do
    tenant_a = create_tenant!("tenant-a")
    tenant_b = create_tenant!("tenant-b")

    service_a = create_sync_service!(tenant_a, "sync-a")
    service_b = create_sync_service!(tenant_b, "sync-b")

    source_a = create_source!(tenant_a, service_a, "source-a")
    source_b = create_source!(tenant_b, service_b, "source-b")

    assert {:ok, payload} =
             SyncConfigGenerator.get_config_if_changed(
               service_a.component_id,
               to_string(tenant_a.id),
               ""
             )

    config = Jason.decode!(payload.config_json)
    sources = config["sources"]

    assert config["scope"] == "tenant"
    assert Map.has_key?(sources, source_a.name)
    refute Map.has_key?(sources, source_b.name)
    assert sources[source_a.name]["tenant_id"] == to_string(tenant_a.id)

    assert {:error, :tenant_mismatch} =
             SyncConfigGenerator.get_config_if_changed(
               service_a.component_id,
               to_string(tenant_b.id),
               ""
             )
  end

  test "platform sync config includes sources across tenants with tenant prefixes" do
    platform_tenant = platform_tenant!()
    platform_service = platform_sync_service!(platform_tenant)

    tenant_a = create_tenant!("platform-a")
    tenant_b = create_tenant!("platform-b")

    source_a = create_source!(tenant_a, platform_service, "platform-source-a")
    source_b = create_source!(tenant_b, platform_service, "platform-source-b")

    assert {:ok, payload} =
             SyncConfigGenerator.get_config_if_changed(
               platform_service.component_id,
               to_string(platform_tenant.id),
               ""
             )

    config = Jason.decode!(payload.config_json)
    sources = config["sources"]

    tenant_a_slug = to_string(tenant_a.slug)
    tenant_b_slug = to_string(tenant_b.slug)

    assert config["scope"] == "platform"
    assert Map.has_key?(sources, "#{tenant_a_slug}/#{source_a.name}")
    assert Map.has_key?(sources, "#{tenant_b_slug}/#{source_b.name}")
    assert sources["#{tenant_a_slug}/#{source_a.name}"]["tenant_id"] == to_string(tenant_a.id)
    assert sources["#{tenant_b_slug}/#{source_b.name}"]["tenant_id"] == to_string(tenant_b.id)

    assert {:error, :tenant_mismatch} =
             SyncConfigGenerator.get_config_if_changed(
               platform_service.component_id,
               to_string(tenant_a.id),
               ""
             )
  end

  defp create_tenant!(slug_prefix) do
    suffix = System.unique_integer([:positive])
    slug = "#{slug_prefix}-#{suffix}"
    name = "#{slug_prefix}-name-#{suffix}"

    Tenant
    |> Ash.Changeset.for_create(:create, %{name: name, slug: slug}, authorize?: false)
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, tenant} -> tenant
      {:error, reason} -> raise "failed to create tenant: #{inspect(reason)}"
    end
  end

  defp create_sync_service!(tenant, component_prefix) do
    suffix = System.unique_integer([:positive])
    component_id = "#{component_prefix}-#{suffix}"
    name = "#{component_prefix}-name-#{suffix}"
    actor = system_actor(tenant.id)

    SyncService
    |> Ash.Changeset.for_create(
      :create,
      %{
        component_id: component_id,
        name: name,
        service_type: :on_prem,
        status: :offline,
        is_platform_sync: false,
        capabilities: []
      },
      actor: actor,
      tenant: tenant.id,
      authorize?: false
    )
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, service} -> service
      {:error, reason} -> raise "failed to create sync service: #{inspect(reason)}"
    end
  end

  defp create_source!(tenant, sync_service, name) do
    endpoint = "https://example.invalid/#{System.unique_integer([:positive])}"
    actor = system_actor(tenant.id)

    IntegrationSource
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        source_type: :armis,
        endpoint: endpoint,
        sync_service_id: sync_service.id
      },
      actor: actor,
      tenant: tenant.id,
      authorize?: false
    )
    |> Ash.Changeset.set_argument(:credentials, %{token: "secret"})
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, source} -> source
      {:error, reason} -> raise "failed to create integration source: #{inspect(reason)}"
    end
  end

  defp platform_tenant! do
    query =
      Tenant
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(expr(is_platform_tenant == true))
      |> Ash.Query.select([:id, :slug])
      |> Ash.Query.limit(1)

    case Ash.read(query, authorize?: false) do
      {:ok, [tenant]} -> tenant
      {:ok, []} -> raise "platform tenant not found"
      {:error, reason} -> raise "failed to load platform tenant: #{inspect(reason)}"
    end
  end

  defp platform_sync_service!(tenant) do
    actor = system_actor(tenant.id)

    query =
      SyncService
      |> Ash.Query.for_read(:platform, %{}, actor: actor, tenant: tenant.id, authorize?: false)
      |> Ash.Query.limit(1)

    case Ash.read(query, authorize?: false) do
      {:ok, [service]} -> service
      {:ok, []} -> raise "platform sync service not found"
      {:error, reason} -> raise "failed to load platform sync service: #{inspect(reason)}"
    end
  end

  defp system_actor(tenant_id) do
    %{
      id: "system",
      email: "system@serviceradar",
      role: :admin,
      tenant_id: tenant_id
    }
  end
end
