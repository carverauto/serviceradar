defmodule ServiceRadarWebNG.AdminApi.Local do
  @moduledoc """
  Local admin API client for tests.

  Uses Ash resources directly instead of HTTP.
  """

  @behaviour ServiceRadarWebNG.AdminApi

  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.AdminApi.LocalParams

  require Ash.Query

  @not_provided :not_provided

  @impl true
  def list_users(scope, params) do
    role = params["role"]
    status = params["status"]
    limit = LocalParams.normalize_limit(params["limit"])

    query =
      User
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(limit)
      |> maybe_filter_role(role)
      |> maybe_filter_status(status)

    case Ash.read(query, scope: scope) do
      {:ok, users} -> {:ok, users}
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def get_user(scope, id) do
    Ash.get(User, id, scope: scope)
  end

  @impl true
  def create_user(scope, attrs) do
    User
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create(scope: scope)
  end

  @impl true
  def update_user(scope, id, attrs) do
    role = role_from_attrs(attrs)
    role_profile_id = role_profile_id_from_attrs(attrs)
    display_name = Map.get(attrs, :display_name) || Map.get(attrs, "display_name")

    [User]
    |> Ash.transaction(fn ->
      with {:ok, user} <- Ash.get(User, id, scope: scope),
           {:ok, user} <- maybe_update_role(user, role, scope),
           {:ok, user} <- maybe_update_role_profile(user, role_profile_id, scope),
           {:ok, user} <- maybe_update_display_name(user, display_name, scope) do
        user
      else
        {:error, reason} -> Ash.DataLayer.rollback([User], reason)
      end
    end)
    |> normalize_transaction_result()
  end

  @impl true
  def deactivate_user(scope, id) do
    with {:ok, user} <- Ash.get(User, id, scope: scope) do
      user
      |> Ash.Changeset.for_update(:deactivate, %{}, scope: scope)
      |> Ash.update(scope: scope)
    end
  end

  @impl true
  def reactivate_user(scope, id) do
    with {:ok, user} <- Ash.get(User, id, scope: scope) do
      user
      |> Ash.Changeset.for_update(:reactivate, %{}, scope: scope)
      |> Ash.update(scope: scope)
    end
  end

  @impl true
  def get_authorization_settings(scope) do
    case AuthorizationSettings
         |> Ash.Query.for_read(:get_singleton, %{}, scope: scope)
         |> Ash.read_one(scope: scope) do
      {:ok, nil} ->
        AuthorizationSettings
        |> Ash.Changeset.for_create(:create, %{}, scope: scope)
        |> Ash.create(scope: scope)

      {:ok, settings} ->
        {:ok, settings}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def update_authorization_settings(scope, attrs) do
    with {:ok, settings} <- get_authorization_settings(scope) do
      settings
      |> Ash.Changeset.for_update(:update, attrs, scope: scope)
      |> Ash.update(scope: scope)
    end
  end

  @impl true
  def list_role_profiles(scope) do
    query = Ash.Query.sort(RoleProfile, system: :desc, name: :asc)

    Ash.read(query, scope: scope)
  end

  @impl true
  def get_role_profile(scope, id) do
    Ash.get(RoleProfile, id, scope: scope)
  end

  @impl true
  def create_role_profile(scope, attrs) do
    RoleProfile
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create(scope: scope)
  end

  @impl true
  def update_role_profile(scope, id, attrs) do
    with {:ok, profile} <- Ash.get(RoleProfile, id, scope: scope) do
      profile
      |> Ash.Changeset.for_update(:update, attrs, scope: scope)
      |> Ash.update(scope: scope)
    end
  end

  @impl true
  def delete_role_profile(scope, id) do
    with {:ok, profile} <- Ash.get(RoleProfile, id, scope: scope) do
      case Ash.destroy(profile, scope: scope) do
        :ok -> {:ok, %{status: "deleted"}}
        {:ok, _} -> {:ok, %{status: "deleted"}}
        {:error, error} -> {:error, error}
      end
    end
  end

  @impl true
  def get_rbac_catalog(_scope) do
    {:ok, RBAC.catalog()}
  end

  defp maybe_filter_role(query, nil), do: query
  defp maybe_filter_role(query, ""), do: query

  defp maybe_filter_role(query, role) do
    case role do
      "viewer" -> Ash.Query.filter(query, role == :viewer)
      "operator" -> Ash.Query.filter(query, role == :operator)
      "admin" -> Ash.Query.filter(query, role == :admin)
      _ -> query
    end
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, ""), do: query

  defp maybe_filter_status(query, status) do
    case status do
      "active" -> Ash.Query.filter(query, status == :active)
      "inactive" -> Ash.Query.filter(query, status == :inactive)
      _ -> query
    end
  end

  defp role_from_attrs(%{role: role}), do: role
  defp role_from_attrs(%{"role" => role}), do: role
  defp role_from_attrs(_), do: nil

  defp role_profile_id_from_attrs(%{role_profile_id: role_profile_id}), do: normalize_profile_id(role_profile_id)

  defp role_profile_id_from_attrs(%{"role_profile_id" => role_profile_id}), do: normalize_profile_id(role_profile_id)

  defp role_profile_id_from_attrs(_), do: @not_provided

  defp maybe_update_display_name(user, nil, _scope), do: {:ok, user}
  defp maybe_update_display_name(user, "", _scope), do: {:ok, user}

  defp maybe_update_display_name(user, display_name, scope) do
    user
    |> Ash.Changeset.for_update(:update, %{display_name: display_name}, scope: scope)
    |> Ash.update(scope: scope)
  end

  defp maybe_update_role(user, nil, _scope), do: {:ok, user}

  defp maybe_update_role(user, role, scope) do
    user
    |> Ash.Changeset.for_update(:update_role, %{role: role}, scope: scope)
    |> Ash.update(scope: scope)
  end

  defp maybe_update_role_profile(user, @not_provided, _scope), do: {:ok, user}

  defp maybe_update_role_profile(user, role_profile_id, scope) do
    user
    |> Ash.Changeset.for_update(:update_role_profile, %{role_profile_id: role_profile_id}, scope: scope)
    |> Ash.update(scope: scope)
  end

  defp normalize_transaction_result({:ok, %User{} = user}), do: {:ok, user}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}
  defp normalize_transaction_result({:error, reason, _stacktrace}), do: {:error, reason}
  defp normalize_transaction_result(other), do: other

  defp normalize_profile_id(nil), do: nil
  defp normalize_profile_id(""), do: nil
  defp normalize_profile_id(value), do: value
end
