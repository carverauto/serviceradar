defmodule ServiceRadarWebNG.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `ServiceRadarWebNG.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use as authorization, or to
  ensure specific code paths can only be access for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.
  """

  alias ServiceRadar.Identity.User

  defstruct user: nil, active_tenant: nil, tenant_memberships: []

  @doc """
  Creates a scope for the given user.

  Preloads the tenant relationship for display in the UI.
  Returns nil if no user is given.
  """
  # Function header for default values
  def for_user(user, opts \\ [])

  def for_user(%User{} = user, opts) do
    active_tenant_id = Keyword.get(opts, :active_tenant_id)

    # Preload tenant and memberships for navbar display.
    # Note: We don't use a specific read action because Ash.Query.for_read()
    # breaks relationship loading in some versions. Just load directly.
    user_with_data =
      Ash.load!(
        user,
        [
          :tenant,
          memberships: [:tenant]
        ],
        authorize?: false
      )

    # Determine active tenant: from opts, or user's default tenant
    active_tenant =
      if active_tenant_id do
        find_tenant_by_id(user_with_data.memberships, active_tenant_id) ||
          user_with_data.tenant
      else
        user_with_data.tenant
      end

    %__MODULE__{
      user: user_with_data,
      active_tenant: active_tenant,
      tenant_memberships: user_with_data.memberships || []
    }
  end

  # Also accept map-like users (for backwards compatibility during transition)
  def for_user(%{id: _, email: _} = user, _opts) do
    %__MODULE__{user: user, active_tenant: nil, tenant_memberships: []}
  end

  def for_user(nil, _opts), do: %__MODULE__{user: nil, active_tenant: nil, tenant_memberships: []}

  @doc """
  Returns the active tenant ID for use in Ash queries.
  """
  def tenant_id(%__MODULE__{active_tenant: %{id: id}}), do: id
  def tenant_id(%__MODULE__{user: %{tenant_id: id}}), do: id
  def tenant_id(_), do: nil

  @doc """
  Returns true if the user is a platform admin viewing the platform tenant.

  Platform admin access requires BOTH:
  1. User has super_admin role
  2. Active tenant is the platform tenant (is_platform_tenant: true)

  This ensures platform-level views (cluster nodes, agent gateways) are only
  visible when actively managing the platform, not when switched to a
  regular tenant context.
  """
  def platform_admin?(%__MODULE__{
        user: %{role: :super_admin},
        active_tenant: %{is_platform_tenant: true}
      }),
      do: true

  def platform_admin?(_), do: false

  defp find_tenant_by_id(memberships, tenant_id) when is_list(memberships) do
    Enum.find_value(memberships, fn membership ->
      if to_string(membership.tenant_id) == to_string(tenant_id) do
        membership.tenant
      end
    end)
  end

  defp find_tenant_by_id(_, _), do: nil
end
