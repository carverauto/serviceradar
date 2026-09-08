defmodule ServiceRadar.Identity.Changes.AssignFirstUserRole do
  @moduledoc """
  Assigns admin role to the first user registered.

  When a user registers and is the first user, they are automatically granted
  admin role. Subsequent users get the default viewer role.

  This ensures every deployment has at least one admin who can manage
  the users and settings.

  DB connection's search_path determines the schema.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Repo

  require Logger

  @first_user_lock_key 20_260_328

  @impl true
  def change(changeset, _opts, _context) do
    if changeset.action_type == :create and should_determine_role?(changeset) do
      Ash.Changeset.before_action(changeset, &maybe_assign_admin/1)
    else
      changeset
    end
  end

  defp maybe_assign_admin(changeset) do
    case assign_first_user_role(changeset) do
      {:ok, true} ->
        Logger.info("Assigning admin role to first user")
        Ash.Changeset.force_change_attribute(changeset, :role, :admin)

      {:ok, false} ->
        changeset

      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :role,
          message: "could not determine initial admin role",
          vars: [reason: inspect(reason)]
        )
    end
  end

  defp should_determine_role?(changeset) do
    case Ash.Changeset.get_attribute(changeset, :role) do
      nil -> true
      :viewer -> true
      _other_role -> false
    end
  end

  defp assign_first_user_role(_changeset) do
    with {:ok, _} <- Repo.query("SELECT pg_advisory_xact_lock($1)", [@first_user_lock_key]),
         {:ok, count} <- count_users_in_current_schema() do
      {:ok, count == 0}
    end
  end

  defp count_users_in_current_schema do
    import Ecto.Query

    query =
      from(u in {"ng_users", ServiceRadar.Identity.User},
        select: count(u.id)
      )

    case Repo.one(query) do
      nil -> {:ok, 0}
      count -> {:ok, count}
    end
  end
end
