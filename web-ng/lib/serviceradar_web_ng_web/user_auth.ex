defmodule ServiceRadarWebNGWeb.UserAuth do
  @moduledoc """
  Authentication helpers using Ash JWT tokens.

  Handles session management, current user loading, and LiveView authentication
  using AshAuthentication JWT tokens stored in the session by
  `AshAuthentication.Phoenix.Controller.store_in_session/2`.
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

  The token is stored under the `:user` key by AshAuthentication.Phoenix.Controller.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    with token when is_binary(token) <- get_session(conn, :user),
         {:ok, user, _claims} <- verify_token(token) do
      conn
      |> assign(:current_scope, Scope.for_user(user))
    else
      _ ->
        assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  # Verify an Ash JWT token and load the user
  defp verify_token(token) do
    # Use :serviceradar_web_ng as otp_app since that's where the signing_secret is configured
    # Jwt.verify returns {:ok, claims, resource} - we need to load the user from the subject claim
    case AshAuthentication.Jwt.verify(token, :serviceradar_web_ng) do
      {:ok, claims, resource} ->
        with subject when is_binary(subject) <- claims["sub"],
             {:ok, user} <- AshAuthentication.subject_to_user(subject, resource, authorize?: false) do
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

  defp mount_current_scope(socket, session) do
    socket
    |> Phoenix.Component.assign_new(:current_scope, fn ->
      # Token is stored under "user" key by AshAuthentication.Phoenix.Controller
      user =
        with token when is_binary(token) <- session["user"],
             {:ok, user, _claims} <- verify_token(token) do
          user
        else
          _ -> nil
        end

      Scope.for_user(user)
    end)
    |> maybe_set_ash_context()
  end

  # Set Ash actor and tenant in socket assigns for LiveView Ash operations
  defp maybe_set_ash_context(socket) do
    case socket.assigns[:current_scope] do
      %{user: user} when not is_nil(user) ->
        actor = %{
          id: user.id,
          tenant_id: user.tenant_id,
          role: user.role,
          email: user.email
        }

        socket
        |> Phoenix.Component.assign(:actor, actor)
        |> Phoenix.Component.assign(:tenant, user.tenant_id)

      _ ->
        socket
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

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
