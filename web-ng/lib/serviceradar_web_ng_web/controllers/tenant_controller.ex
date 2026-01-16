defmodule ServiceRadarWebNGWeb.TenantController do
  @moduledoc """
  Placeholder controller for tenant operations.

  In a single-tenant instance UI, tenant switching is not applicable.
  The tenant is implicit from the PostgreSQL search_path configuration.
  """
  use ServiceRadarWebNGWeb, :controller

  @doc """
  Tenant switching is not supported in a single-tenant instance.
  Returns an error indicating this operation is not available.
  """
  def switch(conn, _params) do
    conn
    |> put_flash(:error, "Tenant switching is not available in this deployment")
    |> redirect(to: ~p"/analytics")
  end
end
