defmodule ServiceRadarWebNGWeb.Settings.RbacLive.PolicyData do
  @moduledoc false

  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadarWebNG.RBAC, as: WebRBAC

  require Ash.Query

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @load_permissions ["settings.rbac.manage", "identity.user_groups.view"]
  @query_config :rbac_policy_data_query

  @spec load_group_profiles(map()) ::
          {:ok,
           %{
             groups: list(),
             profiles: list(),
             group_tokens: %{String.t() => String.t()},
             profile_tokens: %{String.t() => String.t()}
           }}
          | {:error, term()}
  # This local query/2 dispatches to parameterized Ash reads. Sobelow mistakes
  # the authorization scope argument for raw SQL because of the function name.
  @sobelow_skip ["SQL.Query"]
  def load_group_profiles(scope) do
    with {:ok, current_scope} <- WebRBAC.authorize_current(scope, @load_permissions),
         {:ok, groups} <- query(:groups, current_scope),
         {:ok, profiles} <- query(:profiles, current_scope) do
      {:ok, build_group_profiles(groups, profiles)}
    end
  end

  @doc false
  def build_group_profiles(groups, profiles) when is_list(groups) and is_list(profiles) do
    %{
      groups: groups,
      profiles: profiles,
      group_tokens: opaque_tokens(groups),
      profile_tokens: opaque_tokens(profiles)
    }
  end

  @doc false
  def accept_generation(generation, %{generation: generation} = data), do: {:ok, data}
  def accept_generation(_generation, _data), do: :ignore

  @doc false
  def resolve_assignment(data, generation, params) when is_map(params) do
    with {:ok, current} <- accept_generation(generation, data),
         group_token when is_binary(group_token) <- Map.get(params, "group-token"),
         profile_token when is_binary(profile_token) <- Map.get(params, "profile-token"),
         {:ok, group_id} <- Map.fetch(current.group_tokens, group_token),
         {:ok, profile_id} <- Map.fetch(current.profile_tokens, profile_token) do
      {:ok, {group_id, profile_id}}
    else
      _ -> {:error, :stale}
    end
  end

  def resolve_assignment(_data, _generation, _params), do: {:error, :stale}

  @doc false
  def resolve_clear(data, generation, params) when is_map(params) do
    with {:ok, current} <- accept_generation(generation, data),
         group_token when is_binary(group_token) <- Map.get(params, "group-token"),
         {:ok, group_id} <- Map.fetch(current.group_tokens, group_token) do
      {:ok, {group_id, nil}}
    else
      _ -> {:error, :stale}
    end
  end

  def resolve_clear(_data, _generation, _params), do: {:error, :stale}

  defp query(kind, scope) do
    query_fun = Application.get_env(:serviceradar_web_ng, @query_config, &default_query/2)

    result =
      if is_function(query_fun, 2) do
        query_fun.(kind, scope)
      else
        {:error, :invalid_query_configuration}
      end

    case result do
      {:ok, records} when is_list(records) -> {:ok, records}
      {:error, reason} -> {:error, {kind, reason}}
      other -> {:error, {kind, {:invalid_query_result, other}}}
    end
  rescue
    error -> {:error, {kind, {:exception, error}}}
  catch
    caught_kind, reason -> {:error, {kind, {caught_kind, reason}}}
  end

  defp default_query(:groups, scope) do
    UserGroup
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.sort(name: :asc, id: :asc)
    |> Ash.read(scope: scope)
  end

  defp default_query(:profiles, scope) do
    RoleProfile
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.sort(system: :desc, name: :asc, id: :asc)
    |> Ash.read(scope: scope)
  end

  defp opaque_tokens(records) do
    Map.new(records, fn record -> {opaque_token(), to_string(record.id)} end)
  end

  defp opaque_token do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
