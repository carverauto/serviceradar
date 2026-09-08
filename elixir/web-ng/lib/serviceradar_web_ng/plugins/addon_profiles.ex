defmodule ServiceRadarWebNG.Plugins.AddonProfiles do
  @moduledoc """
  Context module for query-driven native add-on profiles.
  """

  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonProfile

  require Ash.Query

  @default_limit 100
  @max_limit 500

  @spec list(map(), keyword()) :: [AddonProfile.t()]
  def list(filters \\ %{}, opts \\ []) do
    scope = Keyword.get(opts, :scope)
    limit = normalize_limit(Map.get(filters, :limit) || Map.get(filters, "limit"))

    AddonProfile
    |> Ash.Query.for_read(:read)
    |> maybe_filter_package_id(filters)
    |> maybe_filter_enabled(filters)
    |> Ash.Query.limit(limit)
    |> Ash.Query.sort(priority: :asc, inserted_at: :desc)
    |> read(scope)
  end

  @spec get(String.t(), keyword()) ::
          {:ok, AddonProfile.t()} | {:error, :not_found} | {:error, term()}
  def get(id, opts \\ [])

  def get(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)

    case read_one(id, scope) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, profile} -> {:ok, profile}
      {:error, error} -> {:error, error}
    end
  end

  def get(_id, _opts), do: {:error, :not_found}

  @spec create(map(), keyword()) :: {:ok, AddonProfile.t()} | {:error, term()}
  def create(attrs, opts \\ [])

  def create(attrs, opts) when is_map(attrs) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)

    AddonProfile
    |> Ash.Changeset.for_create(:create, drop_nil_values(attrs))
    |> Ash.create(ash_opts(scope, actor))
  end

  def create(_attrs, _opts), do: {:error, :invalid_attributes}

  @spec update(String.t(), map(), keyword()) :: {:ok, AddonProfile.t()} | {:error, term()}
  def update(id, attrs, opts \\ []) when is_binary(id) and is_map(attrs) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)

    with {:ok, profile} <- get(id, scope: scope) do
      profile
      |> Ash.Changeset.for_update(:update, drop_nil_values(attrs))
      |> Ash.update(ash_opts(scope, actor))
    end
  end

  @spec delete(String.t(), keyword()) :: {:ok, AddonProfile.t()} | {:error, term()}
  def delete(id, opts \\ [])

  def delete(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)

    with {:ok, profile} <- get(id, scope: scope),
         :ok <- destroy_profile_assignments(profile, scope, actor) do
      profile
      |> Ash.Changeset.for_destroy(:destroy)
      |> Ash.destroy(ash_opts(scope, actor))
      |> case do
        :ok -> {:ok, profile}
        {:ok, _destroyed} -> {:ok, profile}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def delete(_id, _opts), do: {:error, :invalid_attributes}

  @spec reconcile(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(id, opts \\ [])

  def reconcile(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor) || scope_actor(scope)

    safe_run_action(fn ->
      AddonProfile
      |> Ash.ActionInput.for_action(:reconcile_now, %{id: id})
      |> Ash.run_action(ash_opts(scope, actor))
    end)
  end

  def reconcile(_id, _opts), do: {:error, :invalid_attributes}

  @spec preview(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def preview(id, opts \\ [])

  def preview(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor) || scope_actor(scope)
    sample_limit = Keyword.get(opts, :sample_limit, 10)

    safe_run_action(fn ->
      AddonProfile
      |> Ash.ActionInput.for_action(:preview, %{id: id, sample_limit: sample_limit})
      |> Ash.run_action(ash_opts(scope, actor))
    end)
  end

  def preview(_id, _opts), do: {:error, :invalid_attributes}

  defp destroy_profile_assignments(profile, scope, actor) do
    AddonAssignment
    |> Ash.Query.for_read(:by_profile, %{addon_profile_id: profile.id})
    |> read(scope)
    |> Enum.reduce_while(:ok, fn assignment, :ok ->
      case assignment
           |> Ash.Changeset.for_destroy(:destroy)
           |> Ash.destroy(ash_opts(scope, actor)) do
        :ok -> {:cont, :ok}
        {:ok, _destroyed} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp read(query, nil), do: Ash.read!(query)
  defp read(query, scope), do: Ash.read!(query, ash_opts(scope, nil))

  defp read_one(id, nil) do
    AddonProfile |> Ash.Query.for_read(:read) |> Ash.Query.filter(id == ^id) |> Ash.read_one()
  end

  defp read_one(id, scope) do
    AddonProfile
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(ash_opts(scope, nil))
  end

  defp maybe_filter_package_id(query, filters) do
    package_id = Map.get(filters, :addon_package_id) || Map.get(filters, "addon_package_id")

    if is_binary(package_id) and package_id != "" do
      Ash.Query.filter(query, addon_package_id == ^package_id)
    else
      query
    end
  end

  defp maybe_filter_enabled(query, filters) do
    case Map.get(filters, :enabled) || Map.get(filters, "enabled") do
      value when is_boolean(value) -> Ash.Query.filter(query, enabled == ^value)
      _ -> query
    end
  end

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

  defp safe_run_action(fun) when is_function(fun, 0) do
    fun.()
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    kind, reason -> {:error, {kind, reason}}
  end

  defp drop_nil_values(attrs) do
    attrs
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
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
