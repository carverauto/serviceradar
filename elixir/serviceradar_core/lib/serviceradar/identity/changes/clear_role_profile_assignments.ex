defmodule ServiceRadar.Identity.Changes.ClearRoleProfileAssignments do
  @moduledoc """
  Clears user role-profile assignments before a custom role profile is deleted.

  Users fall back to role defaults when their custom profile is removed.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User

  require Ash.Query

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      profile = changeset.data

      if Map.get(profile, :system, false) do
        changeset
      else
        clear_assignments(changeset, profile.id, context)
      end
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp clear_assignments(changeset, profile_id, context) do
    actor = Map.get(context, :actor) || SystemActor.system(:role_profile_delete)

    result =
      User
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(role_profile_id == ^profile_id)
      |> Ash.bulk_update(:update_role_profile, %{role_profile_id: nil},
        actor: actor,
        return_errors?: true,
        return_records?: false
      )

    case result do
      %Ash.BulkResult{status: :success} ->
        changeset

      %Ash.BulkResult{errors: errors} ->
        Ash.Changeset.add_error(changeset,
          field: :role_profile_id,
          message: "could not clear user role profile assignments: #{inspect(errors)}"
        )
    end
  end
end
