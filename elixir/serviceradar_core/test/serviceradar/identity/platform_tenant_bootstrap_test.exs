defmodule ServiceRadar.Identity.PlatformTenantBootstrapTest do
  @moduledoc """
  Integration coverage for platform tenant bootstrap.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  require Ash.Query
  import Ash.Expr

  alias ServiceRadar.Edge.OnboardingPackage
  alias ServiceRadar.Edge.PlatformServiceCertificates
  alias ServiceRadar.Identity.Tenant
  alias ServiceRadar.Integrations.SyncService

  @zero_uuid "00000000-0000-0000-0000-000000000000"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:serviceradar_core)
    :ok
  end

  test "bootstrap creates platform tenant, sync service, and sync package metadata" do
    platform_slug = Application.get_env(:serviceradar_core, :platform_tenant_slug, "platform")

    tenant_query =
      Tenant
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(expr(is_platform_tenant == true))
      |> Ash.Query.select([:id, :slug, :is_platform_tenant])

    assert {:ok, [tenant]} = Ash.read(tenant_query, authorize?: false)
    assert tenant.slug == platform_slug
    assert to_string(tenant.id) != @zero_uuid

    actor = %{
      id: "system",
      email: "bootstrap@serviceradar",
      role: :admin,
      tenant_id: tenant.id
    }

    sync_query =
      SyncService
      |> Ash.Query.for_read(:platform, %{}, actor: actor, tenant: tenant.id, authorize?: false)
      |> Ash.Query.limit(1)

    assert {:ok, [service]} = Ash.read(sync_query, authorize?: false)
    assert service.is_platform_sync == true
    assert service.component_id == PlatformServiceCertificates.platform_sync_component_id()

    assert {:ok, package} = PlatformServiceCertificates.ensure_platform_sync_certificate(tenant.id)

    expected_gateway_addr =
      config_value(:gateway_addr, "SERVICERADAR_GATEWAY_ADDR", "agent-gateway:50052")

    expected_listen_addr =
      config_value(:sync_listen_addr, "SERVICERADAR_SYNC_LISTEN_ADDR", ":50058")

    assert package.metadata_json["gateway_addr"] == expected_gateway_addr
    assert package.metadata_json["listen_addr"] == expected_listen_addr
    assert package.metadata_json["platform_service"] == true

    package_query =
      OnboardingPackage
      |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: tenant.id, authorize?: false)
      |> Ash.Query.filter(
        expr(
          component_type == :sync and component_id == ^service.component_id and
            status in [:issued, :delivered, :activated]
        )
      )
      |> Ash.Query.limit(1)

    assert {:ok, [_package]} = Ash.read(package_query, authorize?: false)
  end

  defp config_value(key, env_var, fallback) do
    value = Application.get_env(:serviceradar_core, key, System.get_env(env_var) || fallback)

    case value do
      nil -> fallback
      value ->
        trimmed = String.trim(to_string(value))
        if trimmed == "", do: fallback, else: trimmed
    end
  end
end
