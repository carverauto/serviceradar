defmodule ServiceRadar.Plugins.Changes.SetAssignmentAddonId do
  @moduledoc """
  Copies the package addon ID onto add-on assignments for database invariants.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    package_id =
      Ash.Changeset.get_attribute(changeset, :addon_package_id) ||
        Map.get(changeset.data, :addon_package_id)

    case load_addon_id(package_id) do
      {:ok, addon_id} when is_binary(addon_id) ->
        Ash.Changeset.change_attribute(changeset, :addon_id, addon_id)

      _ ->
        changeset
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp load_addon_id(nil), do: {:error, :missing_package}

  defp load_addon_id(package_id) do
    actor = SystemActor.system(:addon_assignment_addon_id)

    AddonPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^package_id)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, %AddonPackage{addon_id: addon_id}} -> {:ok, addon_id}
      {:ok, nil} -> {:error, :package_not_found}
      {:error, error} -> {:error, error}
    end
  end
end
