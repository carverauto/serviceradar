defmodule ServiceRadar.Identity.Changes.DisallowLastAdminLockout do
  @moduledoc """
  Prevent actions that would remove the last active admin.

  This avoids situations where admins lock themselves out by deactivating
  the only remaining admin account or demoting it to a non-admin role.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      user = changeset.data

      if would_remove_admin?(changeset, user) and not other_active_admin_exists?(user, context) do
        Ash.Changeset.add_error(changeset,
          field: :role,
          message: "cannot remove the last active admin account"
        )
      else
        changeset
      end
    end)
  end

  defp would_remove_admin?(changeset, user) do
    current_role = Map.get(user, :role)
    current_status = Map.get(user, :status)

    new_role = Ash.Changeset.get_attribute(changeset, :role) || current_role
    new_status = Ash.Changeset.get_attribute(changeset, :status) || current_status

    would_lose_admin? = current_role == :admin and new_role != :admin
    would_deactivate? = current_role == :admin and new_status == :inactive

    would_lose_admin? or would_deactivate?
  end

  defp other_active_admin_exists?(user, context) do
    actor =
      case Map.get(context, :actor) do
        nil -> SystemActor.system(:admin_guardrails)
        actor -> actor
      end

    query =
      User
      |> Ash.Query.for_read(:admins, %{}, actor: actor)
      |> Ash.Query.filter(id != ^user.id)
      |> Ash.Query.limit(1)

    case Ash.read(query, actor: actor) do
      {:ok, %Ash.Page.Keyset{results: results}} -> results != []
      {:ok, results} when is_list(results) -> results != []
      {:error, _} -> false
    end
  end
end
