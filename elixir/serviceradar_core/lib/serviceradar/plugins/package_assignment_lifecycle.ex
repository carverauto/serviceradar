defmodule ServiceRadar.Plugins.PackageAssignmentLifecycle do
  @moduledoc """
  Maintains assignment state when plugin packages leave service.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage

  require Ash.Query

  @spec disable_for_package(PluginPackage.t(), keyword()) :: :ok | {:error, term()}
  def disable_for_package(%PluginPackage{id: package_id}, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:plugin_package_assignment_disable))

    PluginAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(plugin_package_id == ^package_id and enabled == true)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, assignments} ->
        Enum.reduce_while(assignments, :ok, fn assignment, :ok ->
          assignment
          |> Ash.Changeset.for_update(:update, %{enabled: false}, actor: actor)
          |> Ash.update(actor: actor)
          |> case do
            {:ok, _updated} -> {:cont, :ok}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)

      {:error, error} ->
        {:error, error}
    end
  end
end
