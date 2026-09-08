defmodule ServiceRadar.Plugins.Changes.NormalizeRepoUrl do
  @moduledoc """
  Normalizes a plugin repository's URL before it is persisted.

  `plugin_repositories` has a unique index on `repo_url`, which only prevents
  duplicates if the stored value is canonical -- otherwise
  `https://github.com/acme/plugins`, `.../plugins.git` and `.../plugins/` are
  three rows for one repository, each with its own trusted key.

  Applied in both the atomic and non-atomic paths because it reads only the
  submitted value, never stored data, so there is nothing to load and no reason
  to force the action non-atomic.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Plugins.RepoUrl

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, :repo_url) do
      {:ok, value} when is_binary(value) ->
        Ash.Changeset.force_change_attribute(changeset, :repo_url, RepoUrl.normalize(value))

      _ ->
        changeset
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
