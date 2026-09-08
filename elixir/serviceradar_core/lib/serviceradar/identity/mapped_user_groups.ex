defmodule ServiceRadar.Identity.MappedUserGroups do
  @moduledoc """
  Turns identity-provider group mappings into `UserGroup` rows.

  A mapping can grant a role or profile without naming a `user_group_id`.
  Those IdP groups still need a ServiceRadar group of the same name so the
  User Groups settings page, dashboard sharing, and membership sync all see
  the same list the operator already configured.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.IdpGroupMemberships
  alias ServiceRadar.Identity.RoleMappingSupport
  alias ServiceRadar.Identity.UserAuthEvent
  alias ServiceRadar.Identity.UserGroup

  require Ash.Query
  require Logger

  @type ash_opts :: keyword()
  @type resolution :: %{optional(atom()) => term(), optional(String.t()) => term()}

  @doc """
  Group ids a resolution should sync, including groups implied by mapping values.
  """
  @spec ids_for_resolution(resolution(), ash_opts()) :: [String.t()]
  def ids_for_resolution(resolution, opts \\ []) when is_map(resolution) do
    actor = actor(opts)

    explicit = list(get(resolution, :user_group_ids))
    matched = list(get(resolution, :matched))

    (explicit ++ Enum.flat_map(matched, &ids_for_mapping(&1, actor)))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Ensures a `UserGroup` exists for every groups mapping, then reconciles
  IdP memberships from the latest role-mapping events.
  """
  @spec reconcile(ash_opts()) :: :ok
  def reconcile(opts \\ []) do
    actor = actor(opts)
    ensure_from_settings(actor: actor)
    reconcile_memberships(actor)
    :ok
  end

  @doc """
  Creates any missing `UserGroup` named by a groups mapping value.
  """
  @spec ensure_from_settings(ash_opts()) :: :ok
  def ensure_from_settings(opts \\ []) do
    actor = actor(opts)

    case AuthorizationSettings.get_settings(actor: actor) do
      {:ok, %{role_mappings: mappings}} when is_list(mappings) ->
        Enum.each(mappings, &ensure_mapping_group(&1, actor))
        :ok

      _ ->
        :ok
    end
  end

  defp ids_for_mapping(mapping, actor) when is_map(mapping) do
    case mapping_user_group_id(mapping) do
      id when is_binary(id) -> [id]
      _ -> ensure_mapping_group(mapping, actor)
    end
  end

  defp ids_for_mapping(_mapping, _actor), do: []

  defp ensure_mapping_group(mapping, actor) when is_map(mapping) do
    cond do
      not is_nil(mapping_user_group_id(mapping)) ->
        []

      not groups_source?(mapping) ->
        []

      true ->
        case ensure_group(RoleMappingSupport.get_key(mapping, "value"), actor) do
          {:ok, group} -> [group.id]
          :error -> []
        end
    end
  end

  defp ensure_mapping_group(_mapping, _actor), do: []

  defp mapping_user_group_id(mapping) do
    mapping
    |> RoleMappingSupport.get_key("user_group_id")
    |> stringify()
    |> RoleMappingSupport.presence()
  end

  defp ensure_group(name, actor) do
    case RoleMappingSupport.presence(stringify(name)) do
      nil -> :error
      name -> fetch_or_create_group(name, actor)
    end
  end

  defp fetch_or_create_group(name, actor) do
    case fetch_group(name, actor) do
      {:ok, %UserGroup{} = group} ->
        {:ok, group}

      {:ok, nil} ->
        create_group(name, actor)

      {:error, reason} ->
        Logger.warning("Could not read user group #{name}: #{inspect(reason)}")
        :error
    end
  end

  defp fetch_group(name, actor) do
    UserGroup
    |> Ash.Query.filter(name == ^name)
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: actor)
  end

  defp create_group(name, actor) do
    attrs = %{
      name: name,
      description: "Identity-provider group",
      metadata: %{"source" => "idp_mapping"}
    }

    case UserGroup.create_group(attrs, actor: actor) do
      {:ok, group} ->
        {:ok, group}

      {:error, reason} ->
        case fetch_group(name, actor) do
          {:ok, %UserGroup{} = group} ->
            {:ok, group}

          _ ->
            Logger.warning("Could not create user group #{name}: #{inspect(reason)}")
            :error
        end
    end
  end

  defp reconcile_memberships(actor) do
    case latest_role_mapping_events(actor) do
      {:ok, events} ->
        Enum.each(events, &sync_event_memberships(&1, actor))

      {:error, reason} ->
        Logger.warning(
          "Could not read role-mapping events for group reconcile: #{inspect(reason)}"
        )
    end
  end

  defp sync_event_memberships(event, actor) do
    metadata = event.metadata || %{}
    matched = metadata["matched"]

    if is_list(matched) and matched != [] do
      ids =
        ids_for_resolution(
          %{user_group_ids: list(metadata["user_group_ids"]), matched: matched},
          actor: actor
        )

      IdpGroupMemberships.sync(event.user_id, ids, actor: actor)
    end
  end

  defp latest_role_mapping_events(actor) do
    case UserAuthEvent
         |> Ash.Query.filter(event_type == "role_mapping")
         |> Ash.Query.sort(inserted_at: :desc)
         |> Ash.Query.limit(2000)
         |> Ash.read(actor: actor) do
      {:ok, events} ->
        {:ok, Enum.uniq_by(events, & &1.user_id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp groups_source?(mapping) do
    # Authorization settings treat a blank source as "groups" (the form default).
    # Older rows can omit source entirely; those still imply a user group.
    case mapping
         |> RoleMappingSupport.get_key("source")
         |> stringify()
         |> RoleMappingSupport.presence() do
      nil -> true
      "groups" -> true
      _other -> false
    end
  end

  defp actor(opts) when is_list(opts) do
    Keyword.get(opts, :actor) || actor_from_scope(Keyword.get(opts, :scope)) ||
      SystemActor.system(:mapped_user_groups)
  end

  defp actor(_opts), do: SystemActor.system(:mapped_user_groups)

  defp actor_from_scope(%{user: user}) when not is_nil(user), do: user
  defp actor_from_scope(_scope), do: nil

  defp get(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp list(nil), do: []
  defp list(values) when is_list(values), do: values
  defp list(_value), do: []

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: to_string(value)
end
