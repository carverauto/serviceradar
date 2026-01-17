defmodule ServiceRadar.Edge.TenantCA.Generator do
  @moduledoc """
  Stub module for TenantCA certificate generation.

  In the new single-tenant-per-deployment architecture, certificate generation
  is handled by external infrastructure (SPIFFE/SPIRE, cert-manager, etc.).

  This module provides stub implementations that return errors, indicating that
  the legacy TenantCA-based certificate generation is no longer available.
  """

  @doc """
  Generate a component certificate.

  Returns an error indicating that TenantCA is not available in the new architecture.
  Certificate generation should be handled by external PKI infrastructure.
  """
  @spec generate_component_cert(map(), String.t(), atom(), String.t(), keyword()) ::
          {:error, :tenant_ca_not_available}
  def generate_component_cert(_ca_data, _component_id, _component_type, _partition_id, _opts \\ []) do
    {:error, :tenant_ca_not_available}
  end
end
