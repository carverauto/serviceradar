defmodule ServiceRadarWebNGWeb.TenantController do
  @moduledoc """
  Handles tenant switching for multi-tenant users.
  """
  use ServiceRadarWebNGWeb, :controller

  def switch(conn, %{"tenant_id" => tenant_id}) do
    # Validate the user has access to this tenant
    user = conn.assigns.current_scope.user

    if has_membership?(user, tenant_id) do
      conn
      |> put_session("active_tenant_id", tenant_id)
      |> put_flash(:info, "Switched tenant")
      |> redirect(to: ~p"/analytics")
    else
      conn
      |> put_flash(:error, "You don't have access to that tenant")
      |> redirect(to: ~p"/analytics")
    end
  end

  defp has_membership?(user, tenant_id) do
    # User always has access to their default tenant
    if to_string(user.tenant_id) == to_string(tenant_id) do
      true
    else
      # Check memberships
      user_with_memberships = Ash.load!(user, :memberships, authorize?: false)

      Enum.any?(user_with_memberships.memberships || [], fn m ->
        to_string(m.tenant_id) == to_string(tenant_id)
      end)
    end
  end
end
