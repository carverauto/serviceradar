defmodule ServiceRadar.CompositeChecks.Changes.DeriveSlug do
  @moduledoc """
  Derives the immutable `slug` from the check name at creation.

  The slug is the check's SRQL handle (`composite.<slug>`), so it must never
  change after creation: saved queries would break.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :name) do
      name when is_binary(name) and name != "" ->
        Ash.Changeset.force_change_attribute(changeset, :slug, slugify(name))

      _ ->
        changeset
    end
  end

  @doc false
  def slugify(name) do
    name
    |> String.normalize(:nfd)
    |> String.replace(~r/[^A-Za-z0-9\s-]/u, "")
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s_-]+/, "-")
    |> String.trim("-")
  end
end
