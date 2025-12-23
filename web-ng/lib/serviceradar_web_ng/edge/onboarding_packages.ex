defmodule ServiceRadarWebNG.Edge.OnboardingPackages do
  @moduledoc """
  Context module for edge onboarding package operations.

  Provides CRUD operations for managing edge onboarding packages, including
  token generation, delivery, revocation, and soft-delete.
  """

  import Ecto.Query
  alias ServiceRadarWebNG.Repo
  alias ServiceRadarWebNG.Edge.OnboardingPackage
  alias ServiceRadarWebNG.Edge.OnboardingEvents
  alias ServiceRadarWebNG.Edge.Crypto

  @default_limit 100
  @default_join_token_ttl_seconds 86_400
  @default_download_token_ttl_seconds 86_400

  @type filter :: %{
          optional(:status) => [String.t()],
          optional(:component_type) => [String.t()],
          optional(:poller_id) => String.t(),
          optional(:component_id) => String.t(),
          optional(:parent_id) => String.t(),
          optional(:limit) => pos_integer()
        }

  @doc """
  Lists edge onboarding packages with optional filters.

  ## Options

    * `:status` - List of status values to filter by (e.g., ["issued", "delivered"])
    * `:component_type` - List of component types to filter by (e.g., ["poller", "checker"])
    * `:poller_id` - Filter by poller_id
    * `:component_id` - Filter by component_id
    * `:parent_id` - Filter by parent_id
    * `:limit` - Maximum number of results (default: 100)

  ## Examples

      iex> list(%{status: ["issued"], limit: 10})
      [%OnboardingPackage{}, ...]

  """
  @spec list(filter()) :: [OnboardingPackage.t()]
  def list(filters \\ %{}) do
    limit = Map.get(filters, :limit, @default_limit)

    OnboardingPackage
    |> apply_filters(filters)
    |> order_by([p], desc: p.created_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Gets a single package by ID.

  Returns `{:ok, package}` or `{:error, :not_found}`.
  """
  @spec get(String.t()) :: {:ok, OnboardingPackage.t()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    case Repo.get(OnboardingPackage, id) do
      nil -> {:error, :not_found}
      package -> {:ok, package}
    end
  end

  def get(_), do: {:error, :not_found}

  @doc """
  Gets a single package by ID, raising if not found.
  """
  @spec get!(String.t()) :: OnboardingPackage.t()
  def get!(id), do: Repo.get!(OnboardingPackage, id)

  @doc """
  Creates a new edge onboarding package with tokens.

  ## Options

    * `:join_token_ttl_seconds` - TTL for join token (default: 86400)
    * `:download_token_ttl_seconds` - TTL for download token (default: 86400)
    * `:actor` - User/system creating the package
    * `:source_ip` - IP address of the creator

  ## Returns

      {:ok, %{package: package, join_token: token, download_token: token}}

  """
  @spec create(map(), keyword()) ::
          {:ok,
           %{package: OnboardingPackage.t(), join_token: String.t(), download_token: String.t()}}
          | {:error, Ecto.Changeset.t()}
  def create(attrs, opts \\ []) do
    join_ttl = Keyword.get(opts, :join_token_ttl_seconds, @default_join_token_ttl_seconds)

    download_ttl =
      Keyword.get(opts, :download_token_ttl_seconds, @default_download_token_ttl_seconds)

    actor = Keyword.get(opts, :actor)
    source_ip = Keyword.get(opts, :source_ip)

    # Generate tokens
    join_token = Crypto.generate_token()
    download_token = Crypto.generate_token()

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    join_expires = DateTime.add(now, join_ttl, :second)
    download_expires = DateTime.add(now, download_ttl, :second)

    # Encrypt join token and hash download token
    join_token_ciphertext = Crypto.encrypt(join_token)
    download_token_hash = Crypto.hash_token(download_token)

    token_attrs = %{
      join_token_ciphertext: join_token_ciphertext,
      join_token_expires_at: join_expires,
      download_token_hash: download_token_hash,
      download_token_expires_at: download_expires
    }

    changeset =
      %OnboardingPackage{}
      |> OnboardingPackage.create_changeset(attrs)
      |> OnboardingPackage.token_changeset(token_attrs)

    case Repo.insert(changeset) do
      {:ok, package} ->
        # Record creation event
        OnboardingEvents.record(package.id, "created", actor: actor, source_ip: source_ip)

        {:ok,
         %{
           package: package,
           join_token: join_token,
           download_token: download_token
         }}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Delivers a package to a client, verifying the download token.

  Returns the decrypted join token and bundle if the download token is valid.

  ## Errors

    * `:not_found` - Package does not exist
    * `:invalid_token` - Download token does not match
    * `:expired` - Download token has expired
    * `:already_delivered` - Package was already delivered
    * `:revoked` - Package was revoked

  """
  @spec deliver(String.t(), String.t(), keyword()) ::
          {:ok,
           %{package: OnboardingPackage.t(), join_token: String.t(), bundle_pem: String.t() | nil}}
          | {:error, atom()}
  def deliver(package_id, download_token, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    source_ip = Keyword.get(opts, :source_ip)

    with {:ok, package} <- get(package_id),
         :ok <- verify_deliverable(package),
         :ok <- verify_download_token(package, download_token) do
      # Decrypt join token
      join_token = Crypto.decrypt(package.join_token_ciphertext)

      # Decrypt bundle if present
      bundle_pem =
        if package.bundle_ciphertext do
          Crypto.decrypt(package.bundle_ciphertext)
        end

      # Update package status to delivered
      {:ok, updated_package} =
        package
        |> OnboardingPackage.deliver_changeset()
        |> Repo.update()

      # Record delivery event
      OnboardingEvents.record(package_id, "delivered", actor: actor, source_ip: source_ip)

      {:ok,
       %{
         package: updated_package,
         join_token: join_token,
         bundle_pem: bundle_pem
       }}
    end
  end

  @doc """
  Revokes a package, preventing further delivery or activation.
  """
  @spec revoke(String.t(), keyword()) :: {:ok, OnboardingPackage.t()} | {:error, atom()}
  def revoke(package_id, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    source_ip = Keyword.get(opts, :source_ip)
    reason = Keyword.get(opts, :reason)

    with {:ok, package} <- get(package_id),
         :ok <- verify_not_revoked(package) do
      {:ok, updated_package} =
        package
        |> OnboardingPackage.revoke_changeset(%{deleted_reason: reason})
        |> Repo.update()

      # Record revocation event
      OnboardingEvents.record(package_id, "revoked",
        actor: actor,
        source_ip: source_ip,
        details: %{reason: reason}
      )

      {:ok, updated_package}
    end
  end

  @doc """
  Soft-deletes a package.
  """
  @spec delete(String.t(), keyword()) :: {:ok, OnboardingPackage.t()} | {:error, atom()}
  def delete(package_id, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    source_ip = Keyword.get(opts, :source_ip)
    reason = Keyword.get(opts, :reason)

    with {:ok, package} <- get(package_id) do
      {:ok, updated_package} =
        package
        |> OnboardingPackage.delete_changeset(%{deleted_by: actor, deleted_reason: reason})
        |> Repo.update()

      # Record deletion event
      OnboardingEvents.record(package_id, "deleted",
        actor: actor,
        source_ip: source_ip,
        details: %{reason: reason}
      )

      {:ok, updated_package}
    end
  end

  @doc """
  Returns default selectors and metadata for package creation.
  """
  @spec defaults() :: %{selectors: [String.t()], metadata: map(), security_mode: String.t()}
  def defaults do
    %{
      selectors: default_selectors(),
      metadata: default_metadata(),
      security_mode: configured_security_mode()
    }
  end

  @doc """
  Returns the configured security mode from the environment.
  Defaults to "mtls" for docker deployments.
  """
  @spec configured_security_mode() :: String.t()
  def configured_security_mode do
    Application.get_env(:serviceradar_web_ng, :security_mode, "mtls")
  end

  # Private functions

  defp apply_filters(query, filters) do
    query
    |> filter_by_status(Map.get(filters, :status))
    |> filter_by_component_type(Map.get(filters, :component_type))
    |> filter_by_poller_id(Map.get(filters, :poller_id))
    |> filter_by_component_id(Map.get(filters, :component_id))
    |> filter_by_parent_id(Map.get(filters, :parent_id))
    |> exclude_deleted()
  end

  defp filter_by_status(query, nil), do: query
  defp filter_by_status(query, []), do: query

  defp filter_by_status(query, statuses) when is_list(statuses) do
    where(query, [p], p.status in ^statuses)
  end

  defp filter_by_component_type(query, nil), do: query
  defp filter_by_component_type(query, []), do: query

  defp filter_by_component_type(query, types) when is_list(types) do
    where(query, [p], p.component_type in ^types)
  end

  defp filter_by_poller_id(query, nil), do: query
  defp filter_by_poller_id(query, ""), do: query

  defp filter_by_poller_id(query, poller_id) do
    where(query, [p], p.poller_id == ^poller_id)
  end

  defp filter_by_component_id(query, nil), do: query
  defp filter_by_component_id(query, ""), do: query

  defp filter_by_component_id(query, component_id) do
    where(query, [p], p.component_id == ^component_id)
  end

  defp filter_by_parent_id(query, nil), do: query
  defp filter_by_parent_id(query, ""), do: query

  defp filter_by_parent_id(query, parent_id) do
    where(query, [p], p.parent_id == ^parent_id)
  end

  defp exclude_deleted(query) do
    where(query, [p], is_nil(p.deleted_at))
  end

  defp verify_deliverable(package) do
    cond do
      OnboardingPackage.revoked?(package) -> {:error, :revoked}
      OnboardingPackage.deleted?(package) -> {:error, :deleted}
      OnboardingPackage.delivered?(package) -> {:error, :already_delivered}
      true -> :ok
    end
  end

  defp verify_download_token(package, token) do
    now = DateTime.utc_now()

    cond do
      DateTime.compare(now, package.download_token_expires_at) == :gt ->
        {:error, :expired}

      not Crypto.verify_token(token, package.download_token_hash) ->
        {:error, :invalid_token}

      true ->
        :ok
    end
  end

  defp verify_not_revoked(package) do
    if OnboardingPackage.revoked?(package) do
      {:error, :already_revoked}
    else
      :ok
    end
  end

  defp default_selectors do
    Application.get_env(:serviceradar_web_ng, :edge_onboarding, [])
    |> Keyword.get(:default_selectors, [])
  end

  defp default_metadata do
    Application.get_env(:serviceradar_web_ng, :edge_onboarding, [])
    |> Keyword.get(:default_metadata, %{})
  end
end
