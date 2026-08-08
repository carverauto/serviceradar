defmodule ServiceRadarWebNG.Plugins.AddonAssignments do
  @moduledoc """
  Context module for native add-on (feature set) assignments (issue 3425).

  Wraps the serviceradar_core ServiceRadar.Plugins.AddonAssignment Ash resource.
  The UI supplies agent_uid, addon_package_id, optional edge_site_id, params, and
  args — addon_id is denormalized server-side by the SetAssignmentAddonId change.
  No secret-ref or service-state handling is needed (those are Wasm-plugin
  specific).
  """

  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonRolloutCoordinator

  require Ash.Query

  @default_limit 200
  @max_limit 500

  @spec list(map(), keyword()) :: [AddonAssignment.t()]
  def list(filters \\ %{}, opts \\ []) do
    scope = Keyword.get(opts, :scope)
    limit = normalize_limit(Map.get(filters, :limit) || Map.get(filters, "limit"))

    AddonAssignment
    |> Ash.Query.for_read(:read)
    |> maybe_filter_agent_uid(filters)
    |> maybe_filter_package_id(filters)
    |> maybe_filter_addon_id(filters)
    |> Ash.Query.limit(limit)
    |> Ash.Query.sort(inserted_at: :desc)
    |> read(scope)
  end

  @spec get(String.t(), keyword()) ::
          {:ok, AddonAssignment.t()} | {:error, :not_found} | {:error, term()}
  def get(id, opts \\ [])

  def get(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)

    case read_one(id, scope) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, assignment} -> {:ok, assignment}
      {:error, error} -> {:error, error}
    end
  end

  def get(_id, _opts), do: {:error, :not_found}

  @spec create(map(), keyword()) :: {:ok, AddonAssignment.t()} | {:error, term()}
  def create(attrs, opts \\ [])

  def create(attrs, opts) when is_map(attrs) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)
    attrs = drop_nil_values(attrs)

    AddonAssignment
    |> Ash.Changeset.for_create(:create, attrs)
    |> create_with_scope(scope, actor)
  end

  def create(_attrs, _opts), do: {:error, :invalid_attributes}

  @spec update(String.t(), map(), keyword()) :: {:ok, AddonAssignment.t()} | {:error, term()}
  def update(id, attrs, opts \\ [])

  def update(id, attrs, opts) when is_binary(id) and is_map(attrs) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)
    # `edge_site_id: nil` is meaningful: the UI uses it to move an existing
    # direct-leaf assignment back to the default gateway-relay path.
    attrs = attrs |> drop_nil_values([:edge_site_id, "edge_site_id"]) |> drop_update_only_values()

    with {:ok, assignment} <- get(id, scope: scope) do
      assignment
      |> Ash.Changeset.for_update(:update, attrs)
      |> update_with_scope(scope, actor)
    end
  end

  def update(_id, _attrs, _opts), do: {:error, :invalid_attributes}

  @doc """
  Re-pushing an add-on that an agent already has must not collide with the
  one-enabled-assignment-per-(agent, add-on) invariant. Resolve the existing
  assignment for `agent_uid` + `addon_id` (the denormalized dedup key) and update
  it in place — re-enabling and accepting the new package/params/args, which also
  covers upgrading to a newer package version of the same add-on — otherwise
  create a fresh assignment.
  """
  @spec upsert(String.t(), map(), keyword()) ::
          {:ok, AddonAssignment.t()} | {:error, term()}
  def upsert(addon_id, attrs, opts \\ [])

  def upsert(addon_id, attrs, opts) when is_binary(addon_id) and is_map(attrs) do
    scope = Keyword.get(opts, :scope)
    agent_uid = Map.get(attrs, :agent_uid) || Map.get(attrs, "agent_uid")

    case existing_assignment(agent_uid, addon_id, scope) do
      %AddonAssignment{id: id} = assignment ->
        # agent_uid is the assignment identity, not a mutable field, so the :update action
        # rejects it. Drop it (the existing row already carries it) and pass only the
        # mutable attrs when upgrading/re-enabling the existing assignment in place.
        if rollout_upgrade?(assignment, attrs) do
          start_rollout_upgrade(assignment, attrs, opts)
        else
          update(id, attrs |> Map.drop([:agent_uid, "agent_uid"]) |> Map.put(:enabled, true), opts)
        end

      nil ->
        create(attrs, opts)
    end
  end

  def upsert(_addon_id, _attrs, _opts), do: {:error, :invalid_attributes}

  defp existing_assignment(agent_uid, addon_id, _scope) when not is_binary(agent_uid) or not is_binary(addon_id), do: nil

  defp existing_assignment(agent_uid, addon_id, scope) do
    %{agent_uid: agent_uid, addon_id: addon_id}
    |> list(scope: scope)
    |> List.first()
  end

  defp rollout_upgrade?(assignment, attrs) do
    package_id = Map.get(attrs, :addon_package_id) || Map.get(attrs, "addon_package_id")
    is_binary(package_id) and package_id != assignment.addon_package_id
  end

  defp start_rollout_upgrade(assignment, attrs, opts) do
    scope = Keyword.get(opts, :scope)
    package_id = Map.get(attrs, :addon_package_id) || Map.get(attrs, "addon_package_id")
    actor = Keyword.get(opts, :actor) || scope_actor(scope)

    policy_attrs =
      Map.take(attrs, [
        :update_policy,
        "update_policy",
        :explicit_version_pin,
        "explicit_version_pin",
        :release_channel,
        "release_channel",
        :capability_ceiling,
        "capability_ceiling",
        :rollout_policy,
        "rollout_policy"
      ])

    with {:ok, updated_assignment} <- update(assignment.id, policy_attrs, opts),
         {:ok, %AddonPackage{} = candidate} <- read_package(package_id, scope),
         {:ok, _rollout} <-
           AddonRolloutCoordinator.start(updated_assignment, candidate,
             actor: actor,
             trigger: :manual
           ) do
      {:ok, updated_assignment}
    end
  end

  defp read_package(id, nil) do
    AddonPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one()
  end

  defp read_package(id, scope) do
    AddonPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(ash_opts(scope, nil))
  end

  @spec delete(String.t(), keyword()) :: {:ok, AddonAssignment.t()} | :ok | {:error, term()}
  def delete(id, opts \\ [])

  def delete(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)

    with {:ok, assignment} <- get(id, scope: scope) do
      assignment
      |> Ash.Changeset.for_destroy(:destroy)
      |> destroy_with_scope(scope, actor)
      |> case do
        :ok -> {:ok, assignment}
        other -> other
      end
    end
  end

  def delete(_id, _opts), do: {:error, :invalid_attributes}

  defp read(query, nil), do: Ash.read!(query)
  defp read(query, scope), do: Ash.read!(query, ash_opts(scope, nil))

  defp read_one(id, nil) do
    AddonAssignment |> Ash.Query.for_read(:read) |> Ash.Query.filter(id == ^id) |> Ash.read_one()
  end

  defp read_one(id, scope) do
    AddonAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(ash_opts(scope, nil))
  end

  defp create_with_scope(changeset, scope, actor), do: Ash.create(changeset, ash_opts(scope, actor))

  defp update_with_scope(changeset, scope, actor), do: Ash.update(changeset, ash_opts(scope, actor))

  defp destroy_with_scope(changeset, scope, actor), do: Ash.destroy(changeset, ash_opts(scope, actor))

  defp ash_opts(scope, actor) when not is_nil(scope) do
    maybe_put_actor([scope: scope], actor || scope_actor(scope))
  end

  defp ash_opts(_scope, actor) when not is_nil(actor), do: [actor: actor]
  defp ash_opts(_scope, _actor), do: []

  defp maybe_put_actor(opts, nil), do: opts
  defp maybe_put_actor(opts, actor), do: Keyword.put(opts, :actor, actor)

  defp scope_actor(%{user: user, permissions: %MapSet{} = permissions}) when not is_nil(user) do
    user
    |> Map.take([:id, :email, :role, :role_profile_id])
    |> Map.put(:permissions, permissions)
  end

  defp scope_actor(%{user: user}) when not is_nil(user), do: user
  defp scope_actor(_scope), do: nil

  defp maybe_filter_agent_uid(query, filters) do
    agent_uid = Map.get(filters, :agent_uid) || Map.get(filters, "agent_uid")

    if is_binary(agent_uid) and agent_uid != "" do
      Ash.Query.filter(query, agent_uid == ^agent_uid)
    else
      query
    end
  end

  defp maybe_filter_package_id(query, filters) do
    package_id = Map.get(filters, :addon_package_id) || Map.get(filters, "addon_package_id")

    if is_binary(package_id) and package_id != "" do
      Ash.Query.filter(query, addon_package_id == ^package_id)
    else
      query
    end
  end

  defp maybe_filter_addon_id(query, filters) do
    addon_id = Map.get(filters, :addon_id) || Map.get(filters, "addon_id")

    cond do
      is_binary(addon_id) and addon_id != "" ->
        Ash.Query.filter(query, addon_id == ^addon_id)

      is_list(addon_id) and addon_id != [] ->
        Ash.Query.filter(query, addon_id in ^addon_id)

      true ->
        query
    end
  end

  defp drop_nil_values(attrs, preserve_keys \\ []) do
    attrs
    |> Enum.reject(fn {key, value} -> is_nil(value) and key not in preserve_keys end)
    |> Map.new()
  end

  defp drop_update_only_values(attrs) do
    Map.drop(attrs, [:agent_uid, "agent_uid", :addon_id, "addon_id"])
  end

  defp normalize_limit(nil), do: @default_limit
  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {parsed, ""} -> normalize_limit(parsed)
      _ -> @default_limit
    end
  end

  defp normalize_limit(_), do: @default_limit
end
