defmodule ServiceRadar.Plugins.Changes.ClearRetractionOnEnable do
  @moduledoc """
  Clears the retraction record when a disabled assignment is enabled again.

  `disabled_reason`, `disabled_by` and `disabled_at` describe why an assignment
  is currently off. Once a reconciler or an operator turns it back on, they no
  longer describe anything, and leaving them would make an enabled row look
  retracted.
  """

  use Ash.Resource.Change

  @retraction_fields [:disabled_reason, :disabled_by, :disabled_at]

  @impl true
  def change(changeset, _opts, _context) do
    if enabling?(changeset) do
      Enum.reduce(
        @retraction_fields,
        changeset,
        &Ash.Changeset.force_change_attribute(&2, &1, nil)
      )
    else
      changeset
    end
  end

  # Whether the row is being enabled depends on its stored state, which an
  # atomic update does not have.
  @impl true
  def atomic(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :enabled) do
      {:not_atomic, "clearing the retraction record needs the stored enabled state"}
    else
      :ok
    end
  end

  defp enabling?(%{data: %{enabled: false}} = changeset) do
    Ash.Changeset.get_attribute(changeset, :enabled) == true
  end

  defp enabling?(_changeset), do: false
end
