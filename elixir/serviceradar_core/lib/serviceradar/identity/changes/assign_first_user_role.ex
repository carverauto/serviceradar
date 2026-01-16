defmodule ServiceRadar.Identity.Changes.AssignFirstUserRole do
  @moduledoc """
  Assigns super_admin role to the first user registered.

  When a user registers and is the first user, they are automatically granted
  super_admin role. Subsequent users get the default viewer role.

  This ensures every deployment has at least one super_admin who can manage
  the users and settings.

  DB connection's search_path determines the schema.
  """

  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    # Only apply during create actions
    if changeset.action_type != :create do
      changeset
    else
      # Check if role is already explicitly set
      case Ash.Changeset.get_attribute(changeset, :role) do
        nil ->
          maybe_assign_super_admin(changeset)

        :viewer ->
          # Default was applied, check if we should override
          maybe_assign_super_admin(changeset)

        _other_role ->
          # Role was explicitly set, don't override
          changeset
      end
    end
  end

  defp maybe_assign_super_admin(changeset) do
    # DB connection's search_path determines the schema
    if first_user?() do
      Logger.info("Assigning super_admin role to first user")
      Ash.Changeset.force_change_attribute(changeset, :role, :super_admin)
    else
      changeset
    end
  end

  # Check if this is the first user in the current schema.
  # The database connection's search_path determines which schema to query.
  defp first_user? do
    count = count_users_in_current_schema()
    count == 0
  end

  defp count_users_in_current_schema do
    import Ecto.Query

    query =
      from(u in {"ng_users", ServiceRadar.Identity.User},
        select: count(u.id)
      )

    # DB connection's search_path determines the schema
    case ServiceRadar.Repo.one(query) do
      nil -> 0
      count -> count
    end
  rescue
    _ -> 0
  end
end
