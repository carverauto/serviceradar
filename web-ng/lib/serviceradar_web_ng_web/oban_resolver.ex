defmodule ServiceRadarWebNGWeb.ObanResolver do
  @moduledoc """
  Resolver for Oban Web dashboard authentication and authorization.
  """

  @behaviour Oban.Web.Resolver
  alias ServiceRadarWebNG.Accounts.Scope

  @impl true
  def resolve_user(conn) do
    Map.get(conn.assigns, :current_scope)
  end

  @impl true
  def resolve_access(%Scope{} = scope) do
    if oban_access?(scope), do: :all, else: {:forbidden, "/analytics"}
  end

  def resolve_access(_user), do: {:forbidden, "/users/log-in"}

  @impl true
  def resolve_instances(_user), do: :all

  @impl true
  def resolve_refresh(_user), do: 5

  defp oban_access?(%Scope{} = scope) do
    platform_tenant?(scope.active_tenant) || tenant_admin?(scope)
  end

  defp oban_access?(_), do: false

  defp platform_tenant?(%{is_platform_tenant: true}), do: true
  defp platform_tenant?(_), do: false

  defp tenant_admin?(%Scope{user: %{role: role}} = scope) do
    admin_role?(role) || membership_admin?(scope.active_tenant, scope.tenant_memberships)
  end

  defp tenant_admin?(_), do: false

  defp admin_role?(role), do: role in [:admin, :super_admin]

  defp membership_admin?(%{id: tenant_id}, memberships) do
    Enum.any?(memberships || [], fn membership ->
      to_string(membership.tenant_id) == to_string(tenant_id) and
        membership.role in [:admin, :owner]
    end)
  end

  defp membership_admin?(_, _), do: false
end
