defmodule ServiceRadar.Plugins.Changes.SyncCheckDescriptors do
  @moduledoc """
  Stores normalized check descriptor metadata alongside plugin package versions.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Plugins.Manifest

  @empty_catalog %{"schema_version" => 1, "items" => []}

  @impl true
  def change(changeset, _opts, _context) do
    manifest =
      Ash.Changeset.get_attribute(changeset, :manifest) ||
        Map.get(changeset.data, :manifest) || %{}

    case Manifest.check_descriptor_catalog(manifest) do
      {:ok, catalog} ->
        Ash.Changeset.change_attribute(changeset, :check_descriptors, catalog)

      {:error, _errors} ->
        Ash.Changeset.change_attribute(changeset, :check_descriptors, @empty_catalog)
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
