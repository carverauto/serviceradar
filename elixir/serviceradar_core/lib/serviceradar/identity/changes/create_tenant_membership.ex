defmodule ServiceRadar.Identity.Changes.CreateTenantMembership do
  @moduledoc """
  Creates a tenant membership for newly registered users.

  This ensures that when a user signs up (via magic link or password registration),
  they automatically get a membership entry for their assigned tenant. This is
  critical for first-time installs where the first user needs access to the
  platform tenant.

  The membership role is determined by the user's role:
  - super_admin/admin users get :owner membership
  - Other users get :member membership

  This change is idempotent - if a membership already exists, it's a no-op.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.TenantMembership

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      try do
        create_membership_if_needed(user)
      rescue
        e ->
          Logger.error("[CreateTenantMembership] Unexpected error: #{Exception.message(e)}")
      end

      {:ok, user}
    end)
  end

  defp create_membership_if_needed(%{tenant_id: nil} = user) do
    Logger.warning(
      "[CreateTenantMembership] User #{user.id} has no tenant_id, skipping membership creation"
    )

    :ok
  end

  defp create_membership_if_needed(user) do
    membership_role = membership_role_for_user(user)

    user.id
    |> create_membership(user.tenant_id, membership_role)
    |> handle_create_result(user, membership_role)
  end

  defp handle_create_result({:ok, _membership}, user, membership_role) do
    Logger.info(
      "[CreateTenantMembership] Created #{membership_role} membership for user #{user.id} in tenant #{user.tenant_id}"
    )

    :ok
  end

  defp handle_create_result({:error, %Ash.Error.Invalid{errors: errors}}, user, _role) do
    if unique_constraint_error?(errors) do
      Logger.debug(
        "[CreateTenantMembership] Membership already exists for user #{user.id} in tenant #{user.tenant_id}"
      )
    else
      Logger.error("[CreateTenantMembership] Failed to create membership: #{inspect(errors)}")
    end

    :ok
  end

  defp handle_create_result({:error, reason}, _user, _role) do
    Logger.error("[CreateTenantMembership] Failed to create membership: #{inspect(reason)}")
    # Don't fail user creation if membership fails - user can be added manually
    :ok
  end

  defp membership_role_for_user(user) do
    case user.role do
      :super_admin -> :owner
      :admin -> :owner
      _ -> :member
    end
  end

  defp create_membership(user_id, tenant_id, role) do
    # Use platform actor since we're bootstrapping the first user
    actor = SystemActor.platform(:user_registration)

    TenantMembership
    |> Ash.Changeset.for_create(:create, %{
      user_id: user_id,
      tenant_id: tenant_id,
      role: role
    })
    |> Ash.create(actor: actor, tenant: tenant_id)
  end

  defp unique_constraint_error?(errors) do
    Enum.any?(errors, fn error ->
      case error do
        # AshPostgres wraps unique constraint violations in InvalidAttribute
        # with constraint_type: :unique in private_vars
        %Ash.Error.Changes.InvalidAttribute{private_vars: private_vars}
        when is_list(private_vars) ->
          Keyword.get(private_vars, :constraint_type) == :unique

        _ ->
          false
      end
    end)
  end
end
