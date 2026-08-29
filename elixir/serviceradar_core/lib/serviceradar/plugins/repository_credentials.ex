defmodule ServiceRadar.Plugins.RepositoryCredentials do
  @moduledoc """
  Binds a GitHub PAT to a `PluginRepository` through the credential store.

  The token is deliberately not an attribute on the repository. It lives in a
  `NetworkCredentialSecret` (`credential_kind: :api_token`), which already has
  AshCloak encryption, paper trail, rotation state and resolution auditing --
  all of which an encrypted column on the repository row would have to
  reimplement. `IntegrationSource` binds its credentials the same way.

  Two consequences worth stating, because they are the reason for this module
  rather than inline calls:

    * **Nothing here returns the token except `fetch_token/2`**, which is called
      at fetch time by the importer. Repository reads expose only
      `credential_attached?`, so a token cannot leak through a list view, a
      calculation, or an audit record.

    * **Resolution goes through `SecretBroker`**, not through hand-decryption,
      so every read of the token is recorded in
      `CredentialSecretResolutionAudit` like every other credential in the
      platform.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.SecretBroker
  alias ServiceRadar.Plugins.PluginRepository

  @provider "github"

  @doc """
  Stores `token` for `repository`, replacing any token already bound.

  Replacement updates the existing secret rather than creating a second one, so
  a repository never accumulates orphaned credentials and the rotation history
  on the secret stays continuous.
  """
  @spec put_token(PluginRepository.t(), String.t(), keyword()) ::
          {:ok, PluginRepository.t()} | {:error, term()}
  def put_token(repository, token, opts \\ [])

  def put_token(%PluginRepository{} = repository, token, opts) when is_binary(token) do
    token = String.trim(token)
    actor = actor(opts)

    cond do
      token == "" ->
        {:error, :empty_token}

      is_binary(repository.credential_secret_id) ->
        update_secret(repository, token, actor)

      true ->
        create_secret_and_attach(repository, token, actor)
    end
  end

  def put_token(_repository, _token, _opts), do: {:error, :invalid_token}

  @doc """
  Detaches the repository's credential and destroys the secret behind it.

  Detach-and-destroy rather than detach-only: a secret bound to nothing is a
  live credential no surface lists, which is a worse outcome than removing it.
  """
  @spec clear_token(PluginRepository.t(), keyword()) ::
          {:ok, PluginRepository.t()} | {:error, term()}
  def clear_token(repository, opts \\ [])

  def clear_token(%PluginRepository{credential_secret_id: nil} = repository, _opts),
    do: {:ok, repository}

  def clear_token(%PluginRepository{} = repository, opts) do
    actor = actor(opts)
    secret_id = repository.credential_secret_id

    with {:ok, repository} <- detach(repository, actor) do
      # Order matters: the FK is cleared first so a failure to destroy leaves an
      # unreferenced secret rather than a repository pointing at a missing row.
      _ = destroy_secret(secret_id, actor)
      {:ok, repository}
    end
  end

  def clear_token(_repository, _opts), do: {:error, :invalid_repository}

  @doc """
  Resolves the repository's PAT for an outbound GitHub request.

  Returns `{:ok, nil}` when no credential is bound -- a public repository is not
  an error. Called at fetch time only.
  """
  @spec fetch_token(PluginRepository.t(), keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def fetch_token(repository, opts \\ [])

  def fetch_token(%PluginRepository{credential_secret_id: nil}, _opts), do: {:ok, nil}

  def fetch_token(%PluginRepository{credential_secret_id: secret_id}, opts) do
    case SecretBroker.resolve_network_credential_secret(secret_id, actor: actor(opts)) do
      {:ok, %{value: value}} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _resolved} -> {:error, :empty_credential}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_token(_repository, _opts), do: {:ok, nil}

  defp create_secret_and_attach(repository, token, actor) do
    attrs = %{
      name: secret_name(repository),
      description: "GitHub access token for plugin repository #{repository.repo_url}",
      provider: @provider,
      credential_kind: :api_token,
      source_type: :internal_encrypted,
      secret_payload: token,
      metadata: %{"plugin_repository_id" => repository.id}
    }

    with {:ok, secret} <-
           NetworkCredentialSecret
           |> Ash.Changeset.for_create(:create, attrs, actor: actor)
           |> Ash.create() do
      attach(repository, secret.id, actor)
    end
  end

  defp update_secret(repository, token, actor) do
    with {:ok, secret} <-
           NetworkCredentialSecret.get_by_id(repository.credential_secret_id, actor: actor),
         {:ok, _secret} <-
           secret
           |> Ash.Changeset.for_update(:update, %{secret_payload: token}, actor: actor)
           |> Ash.update() do
      {:ok, repository}
    end
  end

  defp attach(repository, secret_id, actor) do
    repository
    |> Ash.Changeset.for_update(:update, %{credential_secret_id: secret_id}, actor: actor)
    |> Ash.update()
  end

  defp detach(repository, actor) do
    repository
    |> Ash.Changeset.for_update(:update, %{credential_secret_id: nil}, actor: actor)
    |> Ash.update()
  end

  defp destroy_secret(secret_id, actor) do
    with {:ok, secret} <- NetworkCredentialSecret.get_by_id(secret_id, actor: actor) do
      Ash.destroy(secret, actor: actor)
    end
  end

  defp secret_name(repository), do: "plugin-repository-#{repository.id}"

  defp actor(opts),
    do: Keyword.get(opts, :actor) || SystemActor.system(:plugin_repository_credentials)
end
