defmodule ServiceRadar.Credentials.CredentialRotation do
  @moduledoc """
  Executes write-only credential rotation against the current approved descriptor.

  The caller-supplied credential contributes only its identifier. The service
  refreshes human authority, reloads the public credential, and resolves the
  provider profile under a dedicated system actor before any lifecycle state is
  changed. Submitted material is passed only to the bounded credential builder
  and the secret-bearing completion action.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialSecretBuilder
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Identity.CurrentUserAuthority
  alias ServiceRadar.Plugins.IntegrationCatalog

  @permission "settings.credentials.manage"
  @catalog_actor SystemActor.system(:credential_rotation_catalog)
  @lifecycle_actor SystemActor.system(:credential_rotation_lifecycle)
  @completion_failure_code "rotation_complete_failed"
  @rotation_attributes [
    :secret_payload,
    :username,
    :public_fingerprint,
    :metadata,
    :next_rotation_due_at
  ]
  @safe_builder_errors [
    :credential_rotation_not_supported,
    :credential_rotation_not_allowed,
    :credential_descriptor_unavailable,
    :credential_auth_method_ambiguous,
    :credential_provider_mismatch,
    :credential_kind_mismatch,
    :credential_method_not_found,
    :undeclared_credential_field,
    :unsupported_credential_kind,
    :invalid_private_key,
    :invalid_credential_payload_encoding,
    :invalid_credential_descriptor,
    :invalid_credential_rotation
  ]

  @type rotation_error ::
          :credential_rotation_forbidden
          | :credential_not_found
          | :credential_descriptor_unavailable
          | :credential_rotation_start_failed
          | :credential_rotation_failed
          | :credential_rotation_recovery_failed
          | :credential_rotation_reload_failed
          | :invalid_credential_rotation
          | atom()
          | {atom(), String.t()}

  @doc """
  Replaces one credential's secret material through its explicit lifecycle.

  `scope_or_actor` identifies the logged-in human. Cached caller permissions are
  ignored by `CurrentUserAuthority`; the current user and permission set are
  reloaded before the credential is read or changed.
  """
  @spec rotate(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, rotation_error()}
  def rotate(secret, submitted_values, scope_or_actor, opts \\ [])

  def rotate(%{id: secret_id}, submitted_values, scope_or_actor, opts)
      when not is_nil(secret_id) and is_map(submitted_values) and is_map(scope_or_actor) and
             is_list(opts) do
    with {:ok, dependencies} <- dependencies(opts),
         {:ok, actor} <- authorize(dependencies, scope_or_actor),
         {:ok, current_secret} <- load_secret(dependencies, secret_id, actor),
         {:ok, profile} <- load_profile(dependencies, current_secret),
         {:ok, attrs} <- build_rotation(dependencies, current_secret, profile, submitted_values),
         {:ok, rotating_secret} <- start_rotation(dependencies, current_secret, actor) do
      complete_rotation(dependencies, rotating_secret, attrs, actor)
    end
  rescue
    _error -> {:error, :invalid_credential_rotation}
  catch
    _kind, _reason -> {:error, :invalid_credential_rotation}
  end

  def rotate(_secret, _submitted_values, _scope_or_actor, _opts),
    do: {:error, :invalid_credential_rotation}

  defp dependencies(opts) do
    if Keyword.keyword?(opts) do
      overrides = Keyword.get(opts, :dependencies, %{})

      if is_map(overrides) do
        dependencies =
          Map.merge(
            %{
              authorize: &CurrentUserAuthority.authorize/2,
              load_secret: &default_load_secret/2,
              profile_for: &default_profile_for/2,
              build_rotation: &CredentialSecretBuilder.build_rotation/4,
              start_rotation: &default_start_rotation/2,
              complete_rotation: &default_complete_rotation/3,
              fail_rotation: &default_fail_rotation/3,
              reload_secret: &default_load_secret/2
            },
            overrides
          )

        if valid_dependencies?(dependencies),
          do: {:ok, dependencies},
          else: {:error, :invalid_credential_rotation}
      else
        {:error, :invalid_credential_rotation}
      end
    else
      {:error, :invalid_credential_rotation}
    end
  end

  defp valid_dependencies?(dependencies) do
    is_function(dependencies.authorize, 2) and
      is_function(dependencies.load_secret, 2) and
      is_function(dependencies.profile_for, 2) and
      is_function(dependencies.build_rotation, 4) and
      is_function(dependencies.start_rotation, 2) and
      is_function(dependencies.complete_rotation, 3) and
      is_function(dependencies.fail_rotation, 3) and
      is_function(dependencies.reload_secret, 2)
  end

  defp authorize(dependencies, scope_or_actor) do
    case invoke(dependencies.authorize, [scope_or_actor, @permission]) do
      {:returned, {:ok, %{user: user, permissions: %MapSet{} = permissions}}}
      when is_map(user) ->
        {:ok, authorized_actor(user, permissions)}

      _other ->
        {:error, :credential_rotation_forbidden}
    end
  end

  defp authorized_actor(user, permissions) do
    user
    |> Map.take([:id, :email, :role, :role_profile_id, :status])
    |> Map.put(:permissions, permissions)
  end

  defp load_secret(dependencies, secret_id, actor) do
    case invoke(dependencies.load_secret, [secret_id, actor]) do
      {:returned, {:ok, %{id: loaded_id} = secret}} ->
        if same_id?(loaded_id, secret_id),
          do: {:ok, secret},
          else: {:error, :credential_not_found}

      _other ->
        {:error, :credential_not_found}
    end
  end

  defp load_profile(dependencies, %{provider: provider}) when is_binary(provider) do
    case invoke(dependencies.profile_for, [provider, @catalog_actor]) do
      {:returned, {:ok, profile}} when is_map(profile) -> {:ok, profile}
      _other -> {:error, :credential_descriptor_unavailable}
    end
  end

  defp load_profile(_dependencies, _secret), do: {:error, :credential_descriptor_unavailable}

  defp build_rotation(dependencies, secret, profile, submitted_values) do
    case invoke(dependencies.build_rotation, [secret, profile, submitted_values, []]) do
      {:returned, {:ok, attrs}} -> validate_rotation_attrs(attrs)
      {:returned, {:error, reason}} -> {:error, safe_builder_error(reason)}
      _other -> {:error, :invalid_credential_rotation}
    end
  end

  defp validate_rotation_attrs(attrs) when is_map(attrs) do
    keys_match? = Enum.sort(Map.keys(attrs)) == Enum.sort(@rotation_attributes)

    if keys_match? and is_binary(attrs.secret_payload) and
         (is_nil(attrs.username) or is_binary(attrs.username)) and
         (is_nil(attrs.public_fingerprint) or is_binary(attrs.public_fingerprint)) and
         is_map(attrs.metadata) and
         (is_nil(attrs.next_rotation_due_at) or
            is_struct(attrs.next_rotation_due_at, DateTime)) do
      {:ok, attrs}
    else
      {:error, :invalid_credential_rotation}
    end
  end

  defp validate_rotation_attrs(_attrs), do: {:error, :invalid_credential_rotation}

  defp safe_builder_error(reason) when reason in @safe_builder_errors, do: reason

  defp safe_builder_error({reason, field})
       when reason in [:missing_credential_field, :invalid_credential_field] and is_binary(field) and
              byte_size(field) <= 128,
       do: {reason, field}

  defp safe_builder_error(_reason), do: :invalid_credential_rotation

  defp start_rotation(dependencies, secret, _authorized_actor) do
    case invoke(dependencies.start_rotation, [secret, @lifecycle_actor]) do
      {:returned, {:ok, rotating_secret}} when is_map(rotating_secret) ->
        {:ok, rotating_secret}

      _other ->
        {:error, :credential_rotation_start_failed}
    end
  end

  defp complete_rotation(dependencies, rotating_secret, attrs, actor) do
    case invoke(dependencies.complete_rotation, [rotating_secret, attrs, @lifecycle_actor]) do
      {:returned, {:ok, _completed_secret}} ->
        reload_completed_secret(dependencies, rotating_secret.id, actor)

      _other ->
        case record_completion_failure(dependencies, rotating_secret) do
          :ok -> {:error, :credential_rotation_failed}
          :error -> {:error, :credential_rotation_recovery_failed}
        end
    end
  end

  defp reload_completed_secret(dependencies, secret_id, actor) do
    case invoke(dependencies.reload_secret, [secret_id, actor]) do
      {:returned, {:ok, %{id: loaded_id} = secret}} ->
        if same_id?(loaded_id, secret_id),
          do: {:ok, secret},
          else: {:error, :credential_rotation_reload_failed}

      _other ->
        {:error, :credential_rotation_reload_failed}
    end
  end

  defp record_completion_failure(dependencies, rotating_secret) do
    case invoke(dependencies.fail_rotation, [
           rotating_secret,
           @completion_failure_code,
           @lifecycle_actor
         ]) do
      {:returned, {:ok, _failed_secret}} -> :ok
      _other -> :error
    end
  end

  defp same_id?(left, right), do: to_string(left) == to_string(right)

  defp invoke(fun, args) do
    {:returned, apply(fun, args)}
  rescue
    _error -> :dependency_failed
  catch
    _kind, _reason -> :dependency_failed
  end

  defp default_load_secret(secret_id, actor) do
    NetworkCredentialSecret.get_by_id(secret_id, actor: actor)
  end

  defp default_profile_for(provider, actor) do
    IntegrationCatalog.profile_for(provider, actor: actor)
  end

  defp default_start_rotation(secret, actor) do
    secret
    |> Ash.Changeset.for_update(:start_rotation, %{}, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp default_complete_rotation(secret, attrs, actor) do
    secret
    |> Ash.Changeset.for_update(:complete_rotation, attrs, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp default_fail_rotation(secret, failure_code, actor) do
    secret
    |> Ash.Changeset.for_update(:fail_rotation, %{message: failure_code}, actor: actor)
    |> Ash.update(actor: actor)
  end
end
