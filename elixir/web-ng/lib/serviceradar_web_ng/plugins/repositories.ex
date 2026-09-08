defmodule ServiceRadarWebNG.Plugins.Repositories do
  @moduledoc """
  Resolves plugin catalog repositories for the UI and the importer.

  This is the layer that turns a `ServiceRadar.Plugins.PluginRepository` row into
  the trust material an import needs: the access token for a private source and
  the ed25519 key its bundles must verify against.

  It deliberately sits *above* `FirstPartyImporter` rather than inside it. The
  importer is a transport-and-verification function parameterized by trust
  material, with no database dependency -- which is what lets its test suite stay
  `:db_free`. Pushing the lookup down would have converted a unit suite into a
  database suite for no gain.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.PluginRepository
  alias ServiceRadar.Plugins.RepositoryCredentials
  alias ServiceRadar.Plugins.RepoUrl

  require Ash.Query
  require Logger

  @doc "Every repository, for the settings surface."
  @spec list(keyword()) :: [PluginRepository.t()]
  def list(opts \\ []) do
    PluginRepository
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(builtin: :desc, name: :asc)
    |> read(opts)
  end

  @doc "Repositories eligible for import and recurring sync."
  @spec list_enabled(keyword()) :: [PluginRepository.t()]
  def list_enabled(opts \\ []) do
    PluginRepository
    |> Ash.Query.for_read(:enabled)
    |> Ash.Query.sort(builtin: :desc, name: :asc)
    |> read(opts)
  end

  @doc "The repository preselected in the catalog picker."
  @spec default(keyword()) :: {:ok, PluginRepository.t()} | {:error, :not_found}
  def default(opts \\ []) do
    case PluginRepository |> Ash.Query.for_read(:default) |> read_one(opts) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, repository} -> {:ok, repository}
      other -> other
    end
  end

  @doc "Looks a repository up by its (normalized) URL."
  @spec get_by_repo_url(String.t(), keyword()) :: {:ok, PluginRepository.t()} | {:error, :not_found}
  def get_by_repo_url(repo_url, opts \\ []) when is_binary(repo_url) do
    normalized = RepoUrl.normalize(repo_url)

    case PluginRepository
         |> Ash.Query.for_read(:by_repo_url, %{repo_url: normalized})
         |> read_one(opts) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, repository} -> {:ok, repository}
      other -> other
    end
  end

  @doc """
  Import attributes for `repository`: its URL, index asset, trusted signing key
  and -- for a private source -- its access token.

  The token is resolved here, at the point of use, and is never stored on the
  repository struct that the rest of the system passes around.
  """
  @spec import_attrs(PluginRepository.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import_attrs(%PluginRepository{} = repository, opts \\ []) do
    with {:ok, token} <- RepositoryCredentials.fetch_token(repository, opts) do
      {:ok,
       %{
         "repo_url" => repository.repo_url,
         "index_asset_name" => repository.index_asset_name,
         "github_token" => token,
         "trusted_upload_signing_keys" => trusted_keys(repository)
       }}
    end
  end

  @doc """
  The single trusted key for a repository, in the shape `UploadSignature`
  expects.

  One key per repository rather than a map of many: a catalog has one publisher,
  and accepting a set invites the question of which member signed a given bundle
  -- which is exactly the ambiguity that made a single global map wrong.
  """
  @spec trusted_keys(PluginRepository.t()) :: %{String.t() => String.t()}
  def trusted_keys(%PluginRepository{signing_key_id: key_id, signing_public_key: key})
      when is_binary(key_id) and is_binary(key), do: %{key_id => key}

  def trusted_keys(_repository), do: %{}

  defp read(query, opts) do
    case Ash.read(query, actor: actor(opts)) do
      {:ok, records} ->
        records

      {:error, error} ->
        Logger.error("Failed to read plugin repositories: #{inspect(error)}")
        []
    end
  end

  defp read_one(query, opts) do
    case Ash.read_one(query, actor: actor(opts)) do
      {:ok, record} -> {:ok, record}
      {:error, error} -> {:error, error}
    end
  end

  defp actor(opts) do
    Keyword.get(opts, :actor) ||
      case Keyword.get(opts, :scope) do
        %{user: user} when not is_nil(user) -> user
        _ -> SystemActor.system(:plugin_repository_reader)
      end
  end
end
