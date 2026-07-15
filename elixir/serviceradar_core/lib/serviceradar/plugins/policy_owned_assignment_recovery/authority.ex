defmodule ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery.Authority do
  @moduledoc false

  # Reuse the callback authority source rather than treating a persisted role
  # or the worker's system actor as authorization evidence. Its system actor is
  # only a persistence reader; this module rebuilds a real human/service
  # principal with fresh current RBAC permissions before allowing recovery.
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.CallbackGrants.CurrentAuthorityAshSource
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Plugins.PluginTargetPolicy

  @persistence_actor SystemActor.system(:plugin_policy_assignment_recovery_authority_store)
  @plugin_permission "settings.plugins.manage"
  @credential_permission "settings.credentials.manage"

  @type identity :: %{
          required(:principal_type) => :human | :service_principal,
          required(:principal_id) => String.t(),
          optional(:principal_owner_id) => String.t() | nil
        }

  @type reauthorized_principal :: %{
          required(:identity) => identity(),
          required(:actor) => map(),
          required(:permissions) => MapSet.t(String.t())
        }

  @spec authorize_requester(map(), map()) :: {:ok, reauthorized_principal()} | {:error, atom()}
  def authorize_requester(actor, owner) when is_map(actor) and is_map(owner) do
    with {:ok, identity} <- identity_from_actor(actor),
         {:ok, principal} <- rebuild_current_principal(identity),
         :ok <- authorize_owner(principal, owner) do
      {:ok, principal}
    end
  end

  def authorize_requester(_actor, _owner), do: {:error, :initiating_principal_required}

  @spec reauthorize_request(map()) :: {:ok, reauthorized_principal()} | {:error, atom()}
  def reauthorize_request(request) when is_map(request) do
    with {:ok, identity} <- identity_from_request(request),
         {:ok, principal} <- rebuild_current_principal(identity),
         :ok <- authorize_owner(principal, request_owner(request)) do
      {:ok, principal}
    end
  end

  def reauthorize_request(_request), do: {:error, :initiating_principal_required}

  defp identity_from_actor(actor) do
    with false <- SystemActor.system_actor?(actor),
         {:ok, principal_type} <- principal_type(value(actor, :principal_type) || :human),
         {:ok, principal_id} <- stable_uuid(value(actor, :principal_id) || value(actor, :id)),
         {:ok, owner_id} <- owner_id_for(principal_type, actor) do
      {:ok,
       %{
         principal_type: principal_type,
         principal_id: principal_id,
         principal_owner_id: owner_id
       }}
    else
      true -> {:error, :initiating_principal_required}
      {:error, _reason} = error -> error
    end
  end

  defp identity_from_request(request) do
    with {:ok, principal_type} <- principal_type(value(request, :requested_by_principal_type)),
         {:ok, principal_id} <- stable_uuid(value(request, :requested_by_principal_id)),
         {:ok, owner_id} <- owner_id_for(principal_type, request) do
      {:ok,
       %{
         principal_type: principal_type,
         principal_id: principal_id,
         principal_owner_id: owner_id
       }}
    end
  end

  defp owner_id_for(:human, _source), do: {:ok, nil}

  defp owner_id_for(:service_principal, source) do
    source
    |> value(:requested_by_principal_owner_id)
    |> fallback(value(source, :service_principal_owner_id))
    |> fallback(value(source, :owner_id))
    |> stable_uuid()
  end

  @doc false
  @spec rebuild_current_principal(identity(), keyword()) ::
          {:ok, reauthorized_principal()} | {:error, atom()}
  def rebuild_current_principal(identity, opts \\ [])

  def rebuild_current_principal(identity, opts) when is_map(identity) and is_list(opts) do
    source = Keyword.get(opts, :source, CurrentAuthorityAshSource)
    permissions_loader = Keyword.get(opts, :permissions_loader, &fresh_permissions/1)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    rebuild_current_principal(identity, source, permissions_loader, now)
  end

  def rebuild_current_principal(_identity, _opts), do: {:error, :initiating_principal_required}

  defp rebuild_current_principal(
         %{principal_type: type, principal_id: id, principal_owner_id: owner_id} = identity,
         source,
         permissions_loader,
         %DateTime{} = now
       )
       when is_atom(source) and is_function(permissions_loader, 1) do
    with {:ok, %{principal: principal, owner: owner}} <-
           source.load_principal(type, id, owner_id),
         :ok <- active_owner(owner),
         :ok <- active_service_principal(type, principal, owner, owner_id, now),
         {:ok, permissions} <- load_permissions(permissions_loader, owner),
         {:ok, actor} <- authorization_actor(type, principal, owner, owner_id, permissions) do
      {:ok, %{identity: identity, actor: actor, permissions: permissions}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :initiating_principal_required}
    end
  end

  defp rebuild_current_principal(_identity, _source, _permissions_loader, _now),
    do: {:error, :initiating_principal_required}

  defp active_owner(%{status: status}) when status in [:active, "active"], do: :ok
  defp active_owner(_owner), do: {:error, :principal_disabled}

  defp active_service_principal(:human, _principal, _owner, _owner_id, _now), do: :ok

  defp active_service_principal(:service_principal, principal, owner, owner_id, now) do
    cond do
      value(principal, :enabled) != true ->
        {:error, :principal_disabled}

      not is_nil(value(principal, :revoked_at)) ->
        {:error, :principal_disabled}

      expired?(value(principal, :expires_at), now) ->
        {:error, :principal_disabled}

      to_string(value(principal, :user_id)) != to_string(value(owner, :id)) ->
        {:error, :principal_owner_changed}

      to_string(value(owner, :id)) != to_string(owner_id) ->
        {:error, :principal_owner_changed}

      not service_principal_write_scope?(principal) ->
        {:error, :service_principal_write_scope_required}

      true ->
        :ok
    end
  end

  defp fresh_permissions(owner) do
    permissions = RBAC.permissions_for_user(owner, fresh?: true, actor: @persistence_actor)

    if match?(%MapSet{}, permissions) do
      {:ok, permissions}
    else
      {:error, :current_authorization_unavailable}
    end
  rescue
    _ -> {:error, :current_authorization_unavailable}
  end

  defp load_permissions(loader, owner) do
    case loader.(owner) do
      {:ok, %MapSet{} = permissions} -> {:ok, permissions}
      %MapSet{} = permissions -> {:ok, permissions}
      _ -> {:error, :current_authorization_unavailable}
    end
  rescue
    _ -> {:error, :current_authorization_unavailable}
  end

  defp authorization_actor(:human, _principal, owner, _owner_id, permissions) do
    {:ok,
     %{
       id: to_string(value(owner, :id)),
       role: value(owner, :role),
       status: value(owner, :status),
       principal_type: :human,
       permissions: permissions
     }}
  end

  defp authorization_actor(:service_principal, principal, owner, owner_id, permissions) do
    {:ok,
     %{
       id: to_string(value(principal, :id)),
       role: value(owner, :role),
       status: value(owner, :status),
       principal_type: :service_principal,
       service_principal_owner_id: owner_id,
       owner_id: owner_id,
       permissions: permissions
     }}
  end

  defp authorize_owner(%{permissions: permissions, actor: actor}, %{
         kind: :plugin_target_policy,
         id: id
       }) do
    with :ok <- require_permission(permissions, @plugin_permission),
         {:ok, policy} <- PluginTargetPolicy.get_by_id(id, actor: actor),
         true <- not is_nil(policy) || {:error, :owner_not_found} do
      :ok
    else
      false -> {:error, :owner_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp authorize_owner(%{permissions: permissions, actor: actor}, %{
         kind: :credential_rule,
         id: id
       }) do
    with :ok <- require_permission(permissions, @plugin_permission),
         :ok <- require_permission(permissions, @credential_permission),
         {:ok, rule} <- NetworkCredentialRule.get_by_id(id, actor: actor),
         true <- not is_nil(rule) || {:error, :owner_not_found} do
      :ok
    else
      false -> {:error, :owner_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp authorize_owner(_principal, _owner), do: {:error, :owner_not_authoritative}

  defp require_permission(permissions, permission) do
    if MapSet.member?(permissions, permission),
      do: :ok,
      else: {:error, :current_permission_denied}
  end

  defp request_owner(request) do
    %{
      kind: value(request, :owner_kind),
      id: value(request, :owner_id),
      purpose: value(request, :owner_purpose)
    }
  end

  defp principal_type(type) when type in [:human, "human"], do: {:ok, :human}

  defp principal_type(type) when type in [:service_principal, "service_principal"],
    do: {:ok, :service_principal}

  defp principal_type(_type), do: {:error, :initiating_principal_required}

  defp stable_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :initiating_principal_required}
    end
  end

  defp stable_uuid(_value), do: {:error, :initiating_principal_required}

  defp service_principal_write_scope?(principal) do
    scopes = List.wrap(value(principal, :scopes))
    "write" in scopes or "admin" in scopes
  end

  defp expired?(nil, _now), do: false

  defp expired?(%DateTime{} = expires_at, %DateTime{} = now),
    do: DateTime.compare(expires_at, now) != :gt

  defp expired?(_expires_at, _now), do: true

  defp fallback(nil, fallback), do: fallback
  defp fallback("", fallback), do: fallback
  defp fallback(value, _fallback), do: value

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_map, _key), do: nil
end
