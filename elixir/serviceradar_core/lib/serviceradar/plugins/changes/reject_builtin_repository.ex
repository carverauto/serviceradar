defmodule ServiceRadar.Plugins.Changes.RejectBuiltinRepository do
  @moduledoc """
  Blocks edits to and deletion of the seeded built-in plugin repository.

  This is a property of the record rather than of the caller: an admin holding
  every permission still must not be able to repoint the first-party trust
  anchor at another source, or delete the row every default install imports
  from. Disabling it stays available, because "stop importing from upstream" is
  a legitimate operator decision -- see the `:enable`/`:disable` actions, which
  do not run this guard.

  Mirrors `ServiceRadar.Identity.Changes.DisallowSystemProfileEdit`, including
  its `atomic/3` returning `:ok`: the check needs the stored `builtin` flag, so
  it runs in `change/3` where the record is loaded.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    if builtin?(changeset) do
      Ash.Changeset.add_error(changeset,
        field: :builtin,
        message: "the built-in repository cannot be edited or removed; disable it instead"
      )
    else
      changeset
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp builtin?(%Ash.Changeset{data: %{builtin: true}}), do: true
  defp builtin?(_changeset), do: false
end
