defmodule ServiceRadar.Plugins.Validations.PackageApproved do
  @moduledoc """
  Ensures plugin assignments only reference approved packages.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.PluginPackage

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    package_id =
      Ash.Changeset.get_attribute(changeset, :plugin_package_id) ||
        Map.get(changeset.data, :plugin_package_id)

    if is_nil(package_id) do
      :ok
    else
      actor = SystemActor.system(:plugin_assignment_validation)

      PluginPackage
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^package_id)
      |> Ash.read_one(actor: actor)
      |> case do
        {:ok, %PluginPackage{status: :approved}} ->
          :ok

        {:ok, %PluginPackage{status: status}} ->
          {:error,
           field: :plugin_package_id,
           message: "plugin package must be approved (status: #{status})"}

        {:ok, nil} ->
          {:error, field: :plugin_package_id, message: "plugin package not found"}

        {:error, _error} ->
          {:error, field: :plugin_package_id, message: "plugin package lookup failed"}
      end
    end
  end
end
