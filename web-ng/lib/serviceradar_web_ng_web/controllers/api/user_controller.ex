defmodule ServiceRadarWebNG.Api.UserController do
  @moduledoc """
  JSON API controller for admin user management.

  Provides endpoints for listing users, creating users, updating roles,
  and deactivating/reactivating accounts.
  """

  use ServiceRadarWebNGWeb, :controller

  use Permit.Phoenix.Controller,
    authorization_module: ServiceRadarWebNG.Authorization,
    resource_module: ServiceRadar.Identity.User

  require Ash.Query

  alias ServiceRadar.Identity.User

  action_fallback ServiceRadarWebNG.Api.FallbackController

  @doc """
  GET /api/admin/users

  Lists users with optional filters.
  """
  def index(conn, params) do
    scope = conn.assigns.current_scope
    limit = parse_int(params["limit"]) || 100

    query =
      User
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(limit)
      |> maybe_filter_role(params["role"])
      |> maybe_filter_status(params["status"])

    case Ash.read(query, scope: scope) do
      {:ok, users} -> json(conn, Enum.map(users, &user_to_json/1))
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  GET /api/admin/users/:id

  Returns a single user.
  """
  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case Ash.get(User, id, scope: scope) do
      {:ok, user} -> json(conn, user_to_json(user))
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  POST /api/admin/users

  Creates a new user.
  """
  def create(conn, params) do
    scope = conn.assigns.current_scope

    case normalize_role(params["role"]) do
      {:ok, role} ->
        attrs = %{
          email: params["email"],
          display_name: params["display_name"]
        }

        attrs =
          if is_nil(role) do
            attrs
          else
            Map.put(attrs, :role, role)
          end

        attrs =
          if password = params["password"] do
            Map.put(attrs, :password, password)
          else
            attrs
          end

        attrs =
          case normalize_profile_id(params["role_profile_id"]) do
            nil -> attrs
            profile_id -> Map.put(attrs, :role_profile_id, profile_id)
          end

        case User
             |> Ash.Changeset.for_create(:create, attrs, scope: scope)
             |> Ash.create(scope: scope) do
          {:ok, user} ->
            conn
            |> put_status(:created)
            |> json(user_to_json(user))

          {:error, error} ->
            {:error, error}
        end

      {:error, :invalid_role} ->
        return_error(conn, :bad_request, "role must be one of: viewer, operator, admin")
    end
  end

  @doc """
  PATCH /api/admin/users/:id

  Updates a user role or display name.
  """
  def update(conn, %{"id" => id} = params) do
    scope = conn.assigns.current_scope
    role = params["role"]

    case normalize_role(role) do
      {:error, :invalid_role} ->
        return_error(conn, :bad_request, "role must be one of: viewer, operator, admin")

      {:ok, role_atom} ->
        case Ash.get(User, id, scope: scope) do
          {:ok, user} ->
            update_user(user, params, role_atom, scope, conn)

          {:error, error} ->
            {:error, error}
        end
    end
  end

  @doc """
  POST /api/admin/users/:id/deactivate

  Deactivates a user.
  """
  def deactivate(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case Ash.get(User, id, scope: scope) do
      {:ok, user} ->
        user
        |> Ash.Changeset.for_update(:deactivate, %{}, scope: scope)
        |> Ash.update(scope: scope)
        |> case do
          {:ok, updated} -> json(conn, user_to_json(updated))
          {:error, error} -> {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  POST /api/admin/users/:id/reactivate

  Reactivates a user.
  """
  def reactivate(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case Ash.get(User, id, scope: scope) do
      {:ok, user} ->
        user
        |> Ash.Changeset.for_update(:reactivate, %{}, scope: scope)
        |> Ash.update(scope: scope)
        |> case do
          {:ok, updated} -> json(conn, user_to_json(updated))
          {:error, error} -> {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp update_user(user, params, role, scope, conn) do
    display_name = params["display_name"]
    role_profile_id = normalize_profile_id(params["role_profile_id"])

    with {:ok, user} <- maybe_update_role(user, role, scope),
         {:ok, user} <- maybe_update_role_profile(user, role_profile_id, scope),
         {:ok, user} <- maybe_update_display_name(user, display_name, scope) do
      json(conn, user_to_json(user))
    else
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_update_role(user, nil, _scope), do: {:ok, user}

  defp maybe_update_role(user, role, scope) do
    user
    |> Ash.Changeset.for_update(:update_role, %{role: role}, scope: scope)
    |> Ash.update(scope: scope)
  end

  defp maybe_update_role_profile(user, nil, _scope), do: {:ok, user}

  defp maybe_update_role_profile(user, role_profile_id, scope) do
    user
    |> Ash.Changeset.for_update(:update_role_profile, %{role_profile_id: role_profile_id},
      scope: scope
    )
    |> Ash.update(scope: scope)
  end

  defp maybe_update_display_name(user, nil, _scope), do: {:ok, user}
  defp maybe_update_display_name(user, "", _scope), do: {:ok, user}

  defp maybe_update_display_name(user, display_name, scope) do
    user
    |> Ash.Changeset.for_update(:update, %{display_name: display_name}, scope: scope)
    |> Ash.update(scope: scope)
  end

  defp maybe_filter_role(query, nil), do: query
  defp maybe_filter_role(query, ""), do: query

  defp maybe_filter_role(query, role) do
    case normalize_role(role) do
      {:ok, role_atom} -> Ash.Query.filter(query, role == ^role_atom)
      {:error, :invalid_role} -> query
    end
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status) do
    case status do
      "active" -> Ash.Query.filter(query, status == :active)
      "inactive" -> Ash.Query.filter(query, status == :inactive)
      _ -> query
    end
  end

  defp normalize_role(nil), do: {:ok, nil}
  defp normalize_role(""), do: {:ok, nil}
  defp normalize_role("viewer"), do: {:ok, :viewer}
  defp normalize_role("operator"), do: {:ok, :operator}
  defp normalize_role("admin"), do: {:ok, :admin}
  defp normalize_role(_), do: {:error, :invalid_role}

  defp normalize_profile_id(nil), do: nil
  defp normalize_profile_id(""), do: nil
  defp normalize_profile_id(value), do: value

  @impl true
  def skip_preload do
    [:index, :show, :create, :update, :deactivate, :reactivate]
  end

  @impl true
  def fetch_subject(%{assigns: %{current_scope: %{user: user}}}) when not is_nil(user), do: user
  def fetch_subject(_conn), do: :anonymous

  @impl true
  def handle_unauthorized(_action, conn) do
    conn
    |> put_status(:forbidden)
    |> put_view(json: ServiceRadarWebNGWeb.ErrorJSON)
    |> render(:"403")
    |> halt()
  end

  defp user_to_json(user) do
    %{
      id: user.id,
      email: user.email,
      display_name: user.display_name,
      role: user.role,
      role_profile_id: user.role_profile_id,
      status: user.status,
      confirmed_at: format_datetime(user.confirmed_at),
      last_login_at: format_datetime(user.last_login_at),
      last_auth_method: user.last_auth_method,
      authenticated_at: format_datetime(user.authenticated_at),
      inserted_at: format_datetime(user.inserted_at),
      updated_at: format_datetime(user.updated_at)
    }
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp return_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end
