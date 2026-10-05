defmodule ServiceRadar.Identity.Changes.SetHomepage do
  @moduledoc """
  Writes the `:homepage` argument, canonicalized by
  `ServiceRadar.Identity.Homepage.normalize/1`, into a homepage attribute.

  Homepage writes go through an argument rather than an accepted attribute so
  that the value is always available to `ServiceRadar.Identity.Validations.HomepageTarget`
  on atomic updates, where accepted attributes move into `changeset.atomics`.

  ## Options

    * `:attribute` - the attribute to write (default `:homepage`)
  """

  use Ash.Resource.Change

  alias ServiceRadar.Identity.Homepage

  @impl true
  def change(changeset, opts, _context) do
    attribute = Keyword.get(opts, :attribute, :homepage)

    case Homepage.normalize(Ash.Changeset.get_argument(changeset, :homepage)) do
      {:ok, homepage} ->
        Ash.Changeset.force_change_attribute(changeset, attribute, homepage)

      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :homepage, message: message)
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
