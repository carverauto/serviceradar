defmodule ServiceRadarWebNGWeb.UserAuth do
  @moduledoc """
  Authentication helpers using Ash JWT tokens.

  Handles session management, current user loading, and LiveView authentication
  using AshAuthentication JWT tokens stored in the session by
  `AshAuthentication.Phoenix.Controller.store_in_session/2`.

  This is a tenant instance UI - each instance serves ONE tenant. The tenant
  context is implicit from the database connection's search_path, so we only
  need to track the authenticated user.
  """

  use ServiceRadarWebNGWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias ServiceRadarWebNG.Accounts.Scope

  @doc """
  Logs the user out.

  Clears the session and broadcasts disconnect to LiveViews.
  """
  def log_out_user(conn) do
    if live_socket_id = get_session(conn, :live_socket_id) do
      ServiceRadarWebNGWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> clear_session()
    |> configure_session(renew: true)
    |> redirect(to: ~p"/")
  end

  @doc """
  Authenticates the user by verifying the Ash JWT token in the session.

  When `require_token_presence_for_authentication?` is true in the User resource's
  token config, the token is stored under "user_token" key by AshAuthentication.
  Otherwise it would be stored under :user as a subject string.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    # AshAuthentication stores under "user_token" when require_token_presence_for_authentication? is true
    with token when is_binary(token) <- get_session(conn, "user_token"),
         {:ok, user, _claims} <- verify_token(token) do
      assign(conn, :current_scope, Scope.for_user(user))
    else
      _ ->
        assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  # Verify an Ash JWT token and load the user
  # Tenant context comes from database search_path, not from token claims
  defp verify_token(token) do
    # Use :serviceradar_web_ng as otp_app since that's where the signing_secret is configured
    # Jwt.verify returns {:ok, claims, resource} - we need to load the user from the subject claim
    case AshAuthentication.Jwt.verify(token, :serviceradar_web_ng) do
      {:ok, claims, resource} ->
        with subject when is_binary(subject) <- claims["sub"],
             {:ok, user} <- AshAuthentication.subject_to_user(subject, resource) do
          {:ok, user, claims}
        else
          _ -> {:error, :invalid_token}
        end

      {:error, _reason} ->
        {:error, :invalid_token}

      :error ->
        {:error, :invalid_token}
    end
  end

  @doc """
  Disconnects existing sockets for the given user IDs.
  """
  def disconnect_sessions(user_ids) when is_list(user_ids) do
    Enum.each(user_ids, fn user_id ->
      ServiceRadarWebNGWeb.Endpoint.broadcast("users_sessions:#{user_id}", "disconnect", %{})
    end)
  end

  @doc """
  Handles mounting and authenticating the current_scope in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - Assigns current_scope
      to socket assigns based on the Ash JWT token, or nil if
      there's no token or no matching user.

    * `:require_authenticated` - Authenticates the user from the session,
      and assigns the current_scope to socket assigns based
      on the Ash JWT token.
      Redirects to login page if there's no logged user.

    * `:require_platform_admin` - Requires the user to be a platform admin
      (super_admin role). Used for infrastructure-level views like agent
      gateways, cluster nodes, and platform configuration. Redirects to
      analytics with an error if the user lacks permission.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the `current_scope`:

      defmodule ServiceRadarWebNGWeb.PageLive do
        use ServiceRadarWebNGWeb, :live_view

        on_mount {ServiceRadarWebNGWeb.UserAuth, :mount_current_scope}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{ServiceRadarWebNGWeb.UserAuth, :require_authenticated}] do
        live "/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  # Sudo mode is not implemented with Ash JWT tokens.
  # For now, this just requires authentication. In the future, this could
  # verify a recent authentication timestamp in the JWT claims.
  def on_mount(:require_sudo_mode, params, session, socket) do
    on_mount(:require_authenticated, params, session, socket)
  end

  # Requires the user to be a platform admin (super_admin role).
  # Used for infrastructure-level views like agent gateways, cluster nodes,
  # and platform configuration that should not be visible to regular tenant users.
  def on_mount(:require_platform_admin, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    cond do
      socket.assigns.current_scope == nil or socket.assigns.current_scope.user == nil ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
          |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

        {:halt, socket}

      Scope.platform_admin?(socket.assigns.current_scope) ->
        {:cont, socket}

      true ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You don't have permission to access this page.")
          |> Phoenix.LiveView.redirect(to: ~p"/analytics")

        {:halt, socket}
    end
  end

  defp mount_current_scope(socket, session) do
    socket
    |> Phoenix.Component.assign_new(:current_scope, fn ->
      # Token is stored under "user_token" key when require_token_presence_for_authentication? is true
      user =
        with token when is_binary(token) <- session["user_token"],
             {:ok, user, _claims} <- verify_token(token) do
          user
        else
          _ -> nil
        end

      Scope.for_user(user)
    end)
  end
  end

  @doc "Returns the path to redirect to after log in."
  # the user was already logged in, redirect to analytics
  def signed_in_path(%Plug.Conn{assigns: %{current_scope: %Scope{user: %{id: _}}}}) do
    ~p"/analytics"
  end

  def signed_in_path(_), do: ~p"/"

  @doc """
  Plug for routes that require the user to be authenticated.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end

  @doc """
  Plug for routes that require Oban Web access.

  Access is allowed for admin users (admin or super_admin role).
  """
  def require_oban_access(conn, _opts) do
    scope = conn.assigns[:current_scope]

    cond do
      scope == nil or scope.user == nil ->
        conn
        |> put_flash(:error, "You must log in to access this page.")
        |> maybe_store_return_to()
        |> redirect(to: ~p"/users/log-in")
        |> halt()

      oban_access?(scope) ->
        conn

      true ->
        conn
        |> put_flash(:error, "You don't have permission to access this page.")
        |> redirect(to: ~p"/analytics")
        |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  # In a tenant instance UI, Oban access is granted to admin users
  defp oban_access?(%Scope{user: %{role: role}}) do
    role in [:admin, :super_admin]
  end

  defp oban_access?(_), do: false
end
