defmodule ServiceRadarAgentGateway.TenantScopeTest do
  @moduledoc """
  Tests for tenant slug validation on pushed service statuses.

  In the tenant-instance architecture, each tenant has their own deployment.
  The tenant_slug is used only for routing purposes (e.g., NATS subject prefixing),
  not for multi-tenant isolation within a shared database.
  """

  use ExUnit.Case, async: true

  alias ServiceRadarAgentGateway.TenantScope

  defp assert_rpc_error(expected_status, fun) do
    error = assert_raise GRPC.RPCError, fun
    assert error.status == expected_status
  end

  test "allows matching tenant slug" do
    service = %{tenant_slug: "alpha"}
    metadata = %{tenant_slug: "alpha"}

    assert :ok == TenantScope.validate_service_tenant!(service, metadata)
  end

  test "allows empty service tenant slug" do
    service = %{tenant_slug: nil}
    metadata = %{tenant_slug: "alpha"}

    assert :ok == TenantScope.validate_service_tenant!(service, metadata)
  end

  test "allows blank service tenant slug" do
    service = %{tenant_slug: ""}
    metadata = %{tenant_slug: "alpha"}

    assert :ok == TenantScope.validate_service_tenant!(service, metadata)
  end

  test "rejects missing tenant identity in metadata" do
    service = %{}
    metadata = %{tenant_slug: nil}

    assert_rpc_error(:unauthenticated, fn ->
      TenantScope.validate_service_tenant!(service, metadata)
    end)
  end

  test "rejects tenant_slug mismatch" do
    service = %{tenant_slug: "beta"}
    metadata = %{tenant_slug: "alpha"}

    assert_rpc_error(:permission_denied, fn ->
      TenantScope.validate_service_tenant!(service, metadata)
    end)
  end
end
