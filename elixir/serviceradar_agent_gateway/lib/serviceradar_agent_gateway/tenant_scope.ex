defmodule ServiceRadarAgentGateway.TenantScope do
  @moduledoc false

  @spec validate_service_tenant!(map(), map()) :: :ok | no_return()
  def validate_service_tenant!(service, metadata) do
    tenant_id = normalize(Map.get(metadata, :tenant_id))
    tenant_slug = normalize(Map.get(metadata, :tenant_slug))

    if is_nil(tenant_id) do
      raise GRPC.RPCError, status: :unauthenticated, message: "tenant identity missing"
    end

    service_tenant_id = normalize(Map.get(service, :tenant_id))
    if service_tenant_id != nil and service_tenant_id != tenant_id do
      raise GRPC.RPCError, status: :permission_denied, message: "tenant_id mismatch"
    end

    service_tenant_slug = normalize(Map.get(service, :tenant_slug))
    if service_tenant_slug != nil and service_tenant_slug != tenant_slug do
      raise GRPC.RPCError, status: :permission_denied, message: "tenant_slug mismatch"
    end

    :ok
  end

  defp normalize(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize(_value), do: nil
end
