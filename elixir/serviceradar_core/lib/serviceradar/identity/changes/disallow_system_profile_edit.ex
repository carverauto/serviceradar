defmodule ServiceRadar.Identity.Changes.DisallowSystemProfileEdit do
  @moduledoc """
  Prevents updates or deletes of system role profiles by non-system actors.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, context) do
    if system_profile?(changeset) && not system_actor?(context) do
      Ash.Changeset.add_error(changeset,
        field: :system,
        message: "system profiles are read-only; clone to customize"
      )
    else
      changeset
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp system_profile?(changeset) do
    Ash.Changeset.get_attribute(changeset, :system) ||
      Map.get(changeset.data, :system, false)
  end

  defp system_actor?(%{actor: %{role: :system}}), do: true
  defp system_actor?(_), do: false
end
