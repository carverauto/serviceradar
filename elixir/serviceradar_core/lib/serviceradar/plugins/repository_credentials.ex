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

    * **A secret is never updated in place, and never deleted.** AshCloak's
      encryption of `secret_payload` is a non-atomic change and the resource has
      no primary read for Ash to atomically upgrade through, so any update that
      sets a payload fails with `MustBeAtomic`. The resource also has no destroy
      action -- deliberately: its retirement mechanism is the rotation state
      machine. Replacing a token therefore creates a new secret and retires the
      old one with `disable_rotation`; clearing retires it the same way.

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
  @lifecycle_actor SystemActor.system(:plugin_repository_credentials_lifecycle)

  @doc """
  Stores `token` for `repository`, replacing any token already bound.

  Replacement creates a new secret, moves the repository's reference to it, then
  retires the previous one. Nothing is left active and unreferenced.
  """
  @spec put_token(PluginRepository.t(), String.t(), keyword()) ::
          {:ok, PluginRepository.t()} | {:error, term()}
  def put_token(repository, token, opts \\ [])

  def put_token(%PluginRepository{} = repository, token, opts) when is_binary(token) do
    token = String.trim(token)
    actor = actor(opts)
    previous = repository.credential_secret_id

    cond do
      token == "" ->
        {:error, :empty_token}

      # A pasted URL is the mistake this catches. The field sits beside the
      # repository URL in the form, and anything non-empty used to be accepted,
      # so a mis-paste was stored, encrypted, and only surfaced later as GitHub
      # answering "Bad credentials" - a 401 that reads as an expired or
      # under-scoped token and sends you to regenerate a token that was never
      # wrong.
      #
      # Deliberately NOT a check against known ghp_/github_pat_ prefixes: those
      # change, and rejecting a valid future format would be worse than
      # accepting a bad one. A URL can never be a token, which is the whole
      # claim being made here.
      url_like?(token) ->
        {:error, :token_looks_like_url}

      String.contains?(token, [" ", "\t", "\n"]) ->
        {:error, :token_contains_whitespace}

      true ->
        with {:ok, repository} <- create_secret_and_attach(repository, token, actor) do
          # Retire the old secret only after the repository points at the new
          # one, so a failure here leaves a working credential rather than none.
          retire_secret(previous, actor)
          {:ok, repository}
        end
    end
  end

  def put_token(_repository, _token, _opts), do: {:error, :invalid_token}

  defp url_like?(token) do
    case URI.parse(token) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> true
      _other -> false
    end
  end

  @doc """
  Detaches the repository's credential and destroys the secret behind it.

  Retire rather than detach-only: a secret bound to nothing but still `:active`
  is a live credential no surface lists. The resource has no destroy action, so
  retiring means `disable_rotation`.
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
      # The result is checked, not swallowed: an earlier version ignored it,
      # which is how a secret that outlived its repository went unnoticed.
      :ok = retire_secret(secret_id, actor)
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

  # No destroy action exists on the resource; `disable_rotation` is its
  # retirement transition, and `WriteSecretLifecycleEvent` implements atomic/3
  # so it survives Ash's atomic upgrade.
  defp retire_secret(nil, _actor), do: :ok

  defp retire_secret(secret_id, actor) do
    with {:ok, secret} <- NetworkCredentialSecret.get_by_id(secret_id, actor: actor),
         {:ok, _secret} <-
           secret
           |> Ash.Changeset.for_update(:disable_rotation, %{}, actor: @lifecycle_actor)
           |> Ash.update(actor: @lifecycle_actor) do
      :ok
    end
  end

  # `identity :unique_provider_name, [:provider, :name]` means a name derived only
  # from the repository would collide the moment a token is replaced, since
  # replacement creates a new secret alongside the retired one. The suffix keeps
  # the repository recognisable while letting its credentials accumulate a
  # history.
  defp secret_name(repository),
    do: "plugin-repository-#{repository.id}-#{System.unique_integer([:positive, :monotonic])}"

  defp actor(opts),
    do: Keyword.get(opts, :actor) || SystemActor.system(:plugin_repository_credentials)
end
