defmodule ServiceRadar.AgentConfig.Changes.IncrementVersion do
  @moduledoc """
  Increments the version number when config is created or updated.

  For creates, sets version to 1.
  For updates, increments the current version.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case changeset.action.type do
      :create ->
        Ash.Changeset.change_attribute(changeset, :version, 1)

      :update ->
        current_version = Ash.Changeset.get_attribute(changeset, :version) || 0
        Ash.Changeset.change_attribute(changeset, :version, current_version + 1)

      _ ->
        changeset
    end
  end
end
