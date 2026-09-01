defmodule ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLive.CredentialManagement do
  @moduledoc false

  alias ServiceRadar.Credentials.CredentialRotation
  alias ServiceRadar.Credentials.CredentialUsage
  alias ServiceRadar.Credentials.CredentialUsage.Result
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Plugins.IntegrationCatalog
  alias ServiceRadarWebNG.RBAC

  @permission "settings.credentials.manage"
  @rotatable_states [:active, :rotation_due, :rotation_failed]

  @type operation :: :edit | :rotate | :delete

  @spec open(operation(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def open(operation, scope, secret_id, opts \\ [])

  def open(operation, scope, secret_id, opts) when operation in [:edit, :rotate, :delete] do
    dependencies = dependencies(opts)

    with {:ok, context} <- authorize_and_reload(scope, secret_id, dependencies) do
      open_operation(operation, context, dependencies)
    end
  end

  def open(_operation, _scope, _secret_id, _opts), do: {:error, :credential_action_invalid}

  @spec edit_details(map(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def edit_details(scope, secret_id, params, opts \\ [])

  def edit_details(scope, secret_id, params, opts) when is_map(params) do
    dependencies = dependencies(opts)

    with {:ok, %{scope: fresh_scope, secret: secret}} <-
           authorize_and_reload(scope, secret_id, dependencies),
         attrs = %{
           name: param(params, "name"),
           description: params |> param("description") |> blank_to_nil()
         },
         {:ok, updated} <- dependencies.edit_details.(secret, attrs, fresh_scope) do
      {:ok, updated}
    else
      {:error, :not_authorized} = error -> error
      {:error, :credential_not_found} = error -> error
      _other -> {:error, :credential_edit_failed}
    end
  rescue
    _error -> {:error, :credential_edit_failed}
  catch
    _kind, _reason -> {:error, :credential_edit_failed}
  end

  def edit_details(_scope, _secret_id, _params, _opts), do: {:error, :credential_edit_failed}

  @spec rotate(map(), String.t(), term(), keyword()) :: {:ok, map()} | {:error, atom() | tuple()}
  def rotate(scope, secret_id, submitted_values, opts \\ [])

  def rotate(scope, secret_id, submitted_values, opts) do
    dependencies = dependencies(opts)

    with {:ok, %{scope: fresh_scope, secret: secret}} <-
           authorize_and_reload(scope, secret_id, dependencies),
         {:ok, normalized_values} <- normalize_submitted_rotation_values(submitted_values),
         {:ok, rotated} <- dependencies.rotate.(secret, normalized_values, fresh_scope) do
      {:ok, rotated}
    else
      {:error, :not_authorized} = error -> error
      {:error, :credential_not_found} = error -> error
      {:error, reason} -> {:error, safe_rotation_error(reason)}
      _other -> {:error, :credential_rotation_failed}
    end
  rescue
    _error -> {:error, :credential_rotation_failed}
  catch
    _kind, _reason -> {:error, :credential_rotation_failed}
  end

  @spec delete(map(), String.t(), String.t(), keyword()) ::
          {:ok, term()}
          | {:error, :credential_in_use | :credential_usage_unavailable, map()}
          | {:error, atom()}
  def delete(scope, secret_id, confirmation_id, opts \\ []) do
    dependencies = dependencies(opts)

    with {:ok, %{scope: fresh_scope, secret: secret} = context} <-
           authorize_and_reload(scope, secret_id, dependencies),
         :ok <- exact_confirmation(secret, confirmation_id),
         {:ok, usage} <- load_usage_with_context(context, dependencies),
         :ok <- ensure_unused(usage, context) do
      destroy_with_context(
        dependencies,
        secret,
        to_string(confirmation_id),
        fresh_scope,
        context
      )
    else
      {:error, :not_authorized} = error ->
        error

      {:error, :credential_not_found} = error ->
        error

      {:error, :credential_confirmation_mismatch} = error ->
        error

      {:error, :credential_usage_unavailable, context} ->
        {:error, :credential_usage_unavailable, context}

      {:error, :credential_in_use, context} ->
        {:error, :credential_in_use, context}

      _other ->
        {:error, :credential_delete_failed}
    end
  rescue
    _error -> {:error, :credential_delete_failed}
  catch
    _kind, _reason -> {:error, :credential_delete_failed}
  end

  @spec usage_for_secrets(map(), [map()], keyword()) ::
          {:ok, map()} | {:error, :credential_usage_unavailable}
  def usage_for_secrets(scope, secrets, opts \\ [])

  def usage_for_secrets(scope, secrets, opts) when is_list(secrets) do
    dependencies = dependencies(opts)
    ids = Enum.map(secrets, &(&1 |> Map.fetch!(:id) |> to_string()))

    case dependencies.usage_for_secrets.(ids, scope) do
      {:ok, usage_by_id} when is_map(usage_by_id) -> {:ok, usage_by_id}
      _other -> {:error, :credential_usage_unavailable}
    end
  rescue
    _error -> {:error, :credential_usage_unavailable}
  catch
    _kind, _reason -> {:error, :credential_usage_unavailable}
  end

  def usage_for_secrets(_scope, _secrets, _opts), do: {:error, :credential_usage_unavailable}

  defp open_operation(:edit, context, _dependencies), do: {:ok, context}

  defp open_operation(:rotate, context, dependencies) do
    with :ok <- rotatable?(context.secret),
         {:ok, profile} <- dependencies.profile_for.(context.secret.provider),
         {:ok, method} <- descriptor_method(context.secret, profile) do
      {:ok, Map.put(context, :descriptor, %{profile: profile, method: method})}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :credential_descriptor_unavailable}
    end
  rescue
    _error -> {:error, :credential_descriptor_unavailable}
  end

  defp open_operation(:delete, context, dependencies) do
    case load_usage(context.secret.id, context.scope, dependencies) do
      {:ok, usage} -> {:ok, Map.put(context, :usage, usage)}
      {:error, :credential_usage_unavailable} -> {:ok, Map.put(context, :usage, :unavailable)}
    end
  end

  defp authorize_and_reload(scope, secret_id, dependencies) do
    with {:ok, fresh_scope} <- dependencies.authorize_current.(scope, @permission),
         {:ok, %{id: loaded_id} = secret} <- dependencies.load_secret.(secret_id, fresh_scope),
         true <- same_id?(loaded_id, secret_id) do
      {:ok, %{scope: fresh_scope, secret: secret}}
    else
      {:error, :permission_revoked} -> {:error, :not_authorized}
      {:error, :current_authority_denied} -> {:error, :not_authorized}
      _other -> {:error, :credential_not_found}
    end
  rescue
    _error -> {:error, :credential_not_found}
  catch
    _kind, _reason -> {:error, :credential_not_found}
  end

  defp load_usage(secret_id, scope, dependencies) do
    case dependencies.usage_for_secret.(to_string(secret_id), scope) do
      {:ok, %Result{} = usage} -> {:ok, usage}
      _other -> {:error, :credential_usage_unavailable}
    end
  rescue
    _error -> {:error, :credential_usage_unavailable}
  catch
    _kind, _reason -> {:error, :credential_usage_unavailable}
  end

  defp load_usage_with_context(%{secret: secret, scope: scope} = context, dependencies) do
    case load_usage(secret.id, scope, dependencies) do
      {:ok, usage} ->
        {:ok, usage}

      {:error, :credential_usage_unavailable} ->
        {:error, :credential_usage_unavailable, Map.put(context, :usage, :unavailable)}
    end
  end

  defp ensure_unused(%Result{consumers: [], live_grants: []}, _context), do: :ok

  defp ensure_unused(%Result{} = usage, context), do: {:error, :credential_in_use, Map.put(context, :usage, usage)}

  defp destroy_with_context(dependencies, secret, confirmation_id, scope, context) do
    case dependencies.destroy.(secret, confirmation_id, scope) do
      {:ok, deleted} ->
        {:ok, deleted}

      {:error, reason} ->
        cond do
          credential_usage_unavailable_error?(reason) ->
            {:error, :credential_usage_unavailable, Map.put(context, :usage, :unavailable)}

          credential_in_use_error?(reason) ->
            {:error, :credential_in_use}

          true ->
            {:error, :credential_delete_failed}
        end

      _other ->
        {:error, :credential_delete_failed}
    end
  end

  defp exact_confirmation(%{id: id}, confirmation_id) do
    if same_id?(id, confirmation_id),
      do: :ok,
      else: {:error, :credential_confirmation_mismatch}
  end

  defp rotatable?(%{source_type: :internal_encrypted, rotation_state: rotation_state})
       when rotation_state in @rotatable_states, do: :ok

  defp rotatable?(_secret), do: {:error, :credential_rotation_not_supported}

  defp descriptor_method(%{metadata: metadata, credential_kind: credential_kind}, %{"auth_methods" => methods})
       when is_map(metadata) and is_list(methods) do
    case {
      Map.fetch(metadata, "credential_descriptor"),
      Map.fetch(metadata, "auth_method")
    } do
      {{:ok, "package_manifest.v1"}, {:ok, auth_method}}
      when is_binary(auth_method) and auth_method != "" ->
        methods
        |> Enum.find(fn method ->
          to_string(method["id"]) == auth_method and
            descriptor_kind_matches?(method, credential_kind)
        end)
        |> descriptor_method_result()

      {:error, :error} ->
        methods
        |> Enum.filter(&descriptor_kind_matches?(&1, credential_kind))
        |> case do
          [method] -> {:ok, method}
          _none_or_ambiguous -> {:error, :credential_descriptor_unavailable}
        end

      _partial_or_stale ->
        {:error, :credential_descriptor_unavailable}
    end
  end

  defp descriptor_method(_secret, _profile), do: {:error, :credential_descriptor_unavailable}

  defp descriptor_method_result(%{} = method), do: {:ok, method}
  defp descriptor_method_result(_method), do: {:error, :credential_descriptor_unavailable}

  defp descriptor_kind_matches?(%{"credential_kind" => descriptor_kind}, credential_kind),
    do: to_string(descriptor_kind) == to_string(credential_kind)

  defp descriptor_kind_matches?(_method, _credential_kind), do: false

  defp dependencies(opts) when is_list(opts) do
    Map.merge(default_dependencies(), Keyword.get(opts, :dependencies, %{}))
  end

  defp dependencies(_opts), do: default_dependencies()

  defp default_dependencies do
    %{
      authorize_current: &RBAC.authorize_current/2,
      load_secret: &default_load_secret/2,
      profile_for: &default_profile_for/1,
      usage_for_secret: &default_usage_for_secret/2,
      usage_for_secrets: &default_usage_for_secrets/2,
      edit_details: &default_edit_details/3,
      rotate: &default_rotate/3,
      destroy: &default_destroy/3
    }
  end

  defp default_load_secret(secret_id, scope) do
    NetworkCredentialSecret.get_by_id(secret_id, scope: scope)
  end

  defp default_profile_for(provider), do: IntegrationCatalog.profile_for(provider)

  defp default_usage_for_secret(secret_id, scope) do
    CredentialUsage.for_secret(secret_id, scope: scope)
  end

  defp default_usage_for_secrets(secret_ids, scope) do
    CredentialUsage.for_secrets(secret_ids, scope: scope)
  end

  defp default_edit_details(secret, attrs, scope) do
    secret
    |> Ash.Changeset.for_update(:edit_details, attrs, scope: scope)
    |> Ash.update(scope: scope)
  end

  defp default_rotate(secret, submitted_values, scope) do
    CredentialRotation.rotate(secret, submitted_values, scope)
  end

  defp default_destroy(secret, confirmation_id, scope) do
    result =
      secret
      |> Ash.Changeset.for_destroy(
        :destroy_permanently,
        %{confirm_secret_id: confirmation_id},
        scope: scope
      )
      |> Ash.destroy(scope: scope)

    case result do
      :ok -> {:ok, :deleted}
      {:ok, _record} -> {:ok, :deleted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_rotation_error({reason, field})
       when reason in [:missing_credential_field, :invalid_credential_field] and is_binary(field) and
              byte_size(field) <= 128, do: {reason, field}

  defp safe_rotation_error(reason) when is_atom(reason), do: reason
  defp safe_rotation_error(_reason), do: :credential_rotation_failed

  defp normalize_submitted_rotation_values(values) when is_map(values) do
    if Enum.all?(values, fn {key, value} -> is_binary(key) and is_binary(value) end),
      do: {:ok, values},
      else: {:error, :credential_rotation_failed}
  end

  defp normalize_submitted_rotation_values(_values), do: {:error, :credential_rotation_failed}

  defp credential_in_use_error?(:credential_in_use), do: true

  defp credential_in_use_error?(error) when is_exception(error) do
    Exception.message(error) =~ "credential_in_use"
  rescue
    _error -> false
  end

  defp credential_in_use_error?(_reason), do: false

  defp credential_usage_unavailable_error?(:credential_usage_unavailable), do: true
  defp credential_usage_unavailable_error?({:credential_usage_unavailable, _source}), do: true

  defp credential_usage_unavailable_error?(error) when is_exception(error) do
    Exception.message(error) =~ "credential_usage_unavailable"
  rescue
    _error -> false
  end

  defp credential_usage_unavailable_error?(_reason), do: false

  defp param(params, key), do: Map.get(params, key) || Map.get(params, String.to_existing_atom(key))

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp same_id?(left, right), do: to_string(left) == to_string(right)
end
