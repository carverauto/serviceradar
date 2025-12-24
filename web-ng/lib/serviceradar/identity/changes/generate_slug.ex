defmodule ServiceRadar.Identity.Changes.GenerateSlug do
  @moduledoc """
  Ash change that generates a URL-safe slug from the name attribute.

  If slug is already provided, it is preserved. Otherwise, the name
  is converted to lowercase, non-alphanumeric characters are replaced
  with hyphens, and leading/trailing hyphens are trimmed.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_argument_or_attribute(changeset, :slug) do
      nil ->
        name = Ash.Changeset.get_argument_or_attribute(changeset, :name)

        if name do
          slug =
            name
            |> String.downcase()
            |> String.replace(~r/[^a-z0-9]+/, "-")
            |> String.trim("-")

          Ash.Changeset.change_attribute(changeset, :slug, slug)
        else
          changeset
        end

      _ ->
        changeset
    end
  end
end
