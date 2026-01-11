defmodule ServiceRadarAgentGateway.TenantScopeTest do
  @moduledoc """
  Tests for tenant scoping validation on pushed service statuses.
  """

  use ExUnit.Case, async: true

  alias ServiceRadarAgentGateway.TenantScope

  defp assert_rpc_error(expected_status, fun) do
    error = assert_raise GRPC.RPCError, fun
    assert error.status == expected_status
  end

  test "allows matching tenant identity" do
    service = %{tenant_id: "tenant-1", tenant_slug: "alpha"}
    metadata = %{tenant_id: "tenant-1", tenant_slug: "alpha"}

    assert :ok == TenantScope.validate_service_tenant!(service, metadata)
  end

  test "allows empty service tenant fields" do
    service = %{tenant_id: nil, tenant_slug: ""}
    metadata = %{tenant_id: "tenant-1", tenant_slug: "alpha"}

    assert :ok == TenantScope.validate_service_tenant!(service, metadata)
  end

  test "rejects missing tenant identity" do
    service = %{}
    metadata = %{tenant_id: nil, tenant_slug: "alpha"}

    assert_rpc_error(:unauthenticated, fn ->
      TenantScope.validate_service_tenant!(service, metadata)
    end)
  end

  test "rejects tenant_id mismatch" do
    service = %{tenant_id: "tenant-2"}
    metadata = %{tenant_id: "tenant-1", tenant_slug: "alpha"}

    assert_rpc_error(:permission_denied, fn ->
      TenantScope.validate_service_tenant!(service, metadata)
    end)
  end

  test "rejects tenant_slug mismatch" do
    service = %{tenant_slug: "beta"}
    metadata = %{tenant_id: "tenant-1", tenant_slug: "alpha"}

    assert_rpc_error(:permission_denied, fn ->
      TenantScope.validate_service_tenant!(service, metadata)
    end)
  end
end
