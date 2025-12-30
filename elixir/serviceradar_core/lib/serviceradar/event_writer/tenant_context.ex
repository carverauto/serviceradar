defmodule ServiceRadar.EventWriter.TenantContext do
  @moduledoc """
  Resolves tenant identity for EventWriter processing.

  Tenant IDs must come from process/Ash context only.
  """

  alias ServiceRadar.Cluster.TenantGuard

  @spec current_tenant() :: String.t() | atom() | nil
  def current_tenant do
    TenantGuard.get_process_tenant()
  end

  @spec resolve_tenant_id(map()) :: String.t() | nil
  def resolve_tenant_id(_message), do: current_tenant()

  @spec with_tenant(String.t() | nil, (() -> term())) :: {:ok, term()} | {:error, :missing_tenant_id}
  def with_tenant(nil, _fun), do: {:error, :missing_tenant_id}

  def with_tenant(tenant_id, fun) when is_binary(tenant_id) do
    previous = current_tenant()
    TenantGuard.set_process_tenant(tenant_id)

    try do
      {:ok, fun.()}
    after
      restore_tenant(previous)
    end
  end

  defp restore_tenant(nil), do: Process.delete(:serviceradar_tenant)
  defp restore_tenant(tenant_id), do: TenantGuard.set_process_tenant(tenant_id)
end
