defmodule ServiceRadar.Catalog.RepositoryCredentials do
  @moduledoc """
  Binds and resolves a PAT (`NetworkCredentialSecret` with `credential_kind: :api_token`)
  for a `CatalogRepository` through `ServiceRadar.Credentials.SecretBroker`.

  Mirrors `ServiceRadar.Plugins.RepositoryCredentials`:
  - Plaintext tokens are resolved strictly at outbound HTTPS request time via
    `SecretBroker.resolve_network_credential_secret/2` so resolution is recorded in
    `CredentialSecretResolutionAudit` and never stored on repository structs or audits.
  - Replacing or clearing an attached secret rotates via `:disable_rotation` after
    detaching from the repository row.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Catalog.CatalogRepository
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.SecretBroker

  @lifecycle_actor SystemActor.system(:catalog_repository_credentials_lifecycle)

  @doc """
  Stores `token` in `NetworkCredentialSecret` (`:api_token`) and attaches it to
  `repository`, retiring any previously attached secret.
  """
  @spec put_token(CatalogRepository.t(), String.t(), keyword()) ::
          {:ok, CatalogRepository.t()} | {:error, term()}
  def put_token(repository, token, opts \\ [])

  def put_token(%CatalogRepository{} = repository, token, opts) when is_binary(token) do
    token = String.trim(token)
    actor = actor(opts)
    previous = repository.credential_secret_id

    cond do
      token == "" ->
        {:error, :empty_token}

      url_like?(token) ->
        {:error, :token_looks_like_url}

      String.contains?(token, [" ", "\t", "\n", "\r"]) ->
        {:error, :token_contains_whitespace}

      true ->
        with {:ok, updated} <- create_secret_and_attach(repository, token, actor) do
          _ = retire_secret(previous, actor)
          {:ok, updated}
        end
    end
  end

  def put_token(_repository, _token, _opts), do: {:error, :invalid_token}

  @doc """
  Detaches the repository's credential and retires the underlying secret.
  """
  @spec clear_token(CatalogRepository.t(), keyword()) ::
          {:ok, CatalogRepository.t()} | {:error, term()}
  def clear_token(repository, opts \\ [])

  def clear_token(%CatalogRepository{credential_secret_id: nil} = repository, _opts),
    do: {:ok, repository}

  def clear_token(%CatalogRepository{} = repository, opts) do
    actor = actor(opts)
    secret_id = repository.credential_secret_id

    with {:ok, updated} <- detach(repository, actor) do
      :ok = retire_secret(secret_id, actor)
      {:ok, updated}
    end
  end

  def clear_token(_repository, _opts), do: {:error, :invalid_repository}

  @doc """
  Resolves the repository's PAT via `SecretBroker` for an outbound HTTPS call.

  Returns `{:ok, nil}` when no credential is bound. Supports an injected
  `:token_resolver` callback `(secret_id -> {:ok, token} | {:error, reason})`
  for DB-free unit testing.
  """
  @spec fetch_token(CatalogRepository.t() | map(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def fetch_token(repository, opts \\ [])

  def fetch_token(%{credential_secret_id: nil}, _opts), do: {:ok, nil}

  def fetch_token(%{credential_secret_id: secret_id}, opts) when is_binary(secret_id) do
    case Keyword.get(opts, :token_resolver) do
      resolver when is_function(resolver, 1) ->
        resolver.(secret_id)

      _ ->
        case SecretBroker.resolve_network_credential_secret(secret_id, actor: actor(opts)) do
          {:ok, %{value: value}} when is_binary(value) and value != "" -> {:ok, value}
          {:ok, _resolved} -> {:error, :empty_credential}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def fetch_token(_repository, _opts), do: {:ok, nil}

  defp url_like?(token) do
    case URI.parse(token) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> true
      _ -> false
    end
  end

  defp create_secret_and_attach(repository, token, actor) do
    provider = Atom.to_string(repository.provider_type || :github)

    attrs = %{
      name: secret_name(repository),
      description: "Access token for catalog repository #{repository.repo_url}",
      provider: provider,
      credential_kind: :api_token,
      source_type: :internal_encrypted,
      secret_payload: token,
      metadata: %{"catalog_repository_id" => repository.id}
    }

    with {:ok, secret} <-
           NetworkCredentialSecret
           |> Ash.Changeset.for_create(:create, attrs, actor: actor)
           |> Ash.create(actor: actor) do
      attach(repository, secret.id, actor)
    end
  end

  defp attach(repository, secret_id, actor) do
    repository
    |> Ash.Changeset.for_update(:update, %{credential_secret_id: secret_id}, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp detach(repository, actor) do
    repository
    |> Ash.Changeset.for_update(:update, %{credential_secret_id: nil}, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp retire_secret(nil, _actor), do: :ok

  defp retire_secret(secret_id, actor) do
    with {:ok, secret} <- NetworkCredentialSecret.get_by_id(secret_id, actor: actor),
         {:ok, _retired} <-
           secret
           |> Ash.Changeset.for_update(:disable_rotation, %{}, actor: @lifecycle_actor)
           |> Ash.update(actor: @lifecycle_actor) do
      :ok
    end
  end

  defp secret_name(repository) do
    "catalog-repository-#{repository.id}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp actor(opts) do
    Keyword.get(opts, :actor) || SystemActor.system(:catalog_repository_credentials)
  end
end
