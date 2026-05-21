defmodule ServiceRadar.Plugins.Changes.SetAssignmentPluginId do
  @moduledoc """
  Copies the package plugin ID onto plugin assignments for database invariants.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.PluginPackage

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    package_id =
      Ash.Changeset.get_attribute(changeset, :plugin_package_id) ||
        Map.get(changeset.data, :plugin_package_id)

    case load_plugin_id(package_id) do
      {:ok, plugin_id} when is_binary(plugin_id) ->
        Ash.Changeset.change_attribute(changeset, :plugin_id, plugin_id)

      _ ->
        changeset
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp load_plugin_id(nil), do: {:error, :missing_package}

  defp load_plugin_id(package_id) do
    actor = SystemActor.system(:plugin_assignment_plugin_id)

    PluginPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^package_id)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, %PluginPackage{plugin_id: plugin_id}} -> {:ok, plugin_id}
      {:ok, nil} -> {:error, :package_not_found}
      {:error, error} -> {:error, error}
    end
  end
end
