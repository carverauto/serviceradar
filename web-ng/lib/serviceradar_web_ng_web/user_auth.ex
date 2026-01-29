defmodule ServiceRadarWebNGWeb.UserAuth do
  @moduledoc """
  Authentication helpers using Guardian JWT tokens.

  Handles session management, current user loading, and LiveView authentication
  using Guardian JWT tokens stored in the session.

  This is a single-deployment UI. Schema context is implicit from the database
  connection's search_path, so we only need to track the authenticated user.
  """

  use ServiceRadarWebNGWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Auth.Guardian

  @doc """
  Logs the user in by creating a Guardian session token.

  Stores the token in the session and sets up the live socket ID for
  broadcasting disconnects on logout.
  """
  def log_in_user(conn, user, params \\ %{}) do
    return_to = get_session(conn, :user_return_to) || params["return_to"] || ~p"/analytics"

    case Guardian.create_access_token(user) do
      {:ok, token, _claims} ->
        conn
        |> put_session("user_token", token)
        |> delete_session(:user_return_to)
        |> put_session(:live_socket_id, "users_sessions:#{user.id}")
        |> configure_session(renew: true)
        |> assign(:current_user, user)
        |> redirect(to: return_to)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Unable to complete sign-in. Please try again.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

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
  Authenticates the user by verifying the Guardian JWT token in the session.

  The token is stored under "user_token" key by `log_in_user/3`.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    with token when is_binary(token) <- get_session(conn, "user_token"),
         {:ok, user, _claims} <- Guardian.verify_token(token, token_type: "access") do
      assign(conn, :current_scope, Scope.for_user(user))
    else
      _ ->
        assign(conn, :current_scope, Scope.for_user(nil))
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
      to socket assigns based on the Guardian JWT token, or nil if
      there's no token or no matching user.

    * `:require_authenticated` - Authenticates the user from the session,
      and assigns the current_scope to socket assigns based
      on the Guardian JWT token.
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

  # Sudo mode is not implemented with Guardian JWT tokens.
  # For now, this just requires authentication. In the future, this could
  # verify a recent authentication timestamp in the JWT claims.
  def on_mount(:require_sudo_mode, params, session, socket) do
    on_mount(:require_authenticated, params, session, socket)
  end

  defp mount_current_scope(socket, session) do
    socket
    |> Phoenix.Component.assign_new(:current_scope, fn ->
      user =
        with token when is_binary(token) <- session["user_token"],
             {:ok, user, _claims} <- Guardian.verify_token(token, token_type: "access") do
          user
        else
          _ -> nil
        end

      Scope.for_user(user)
    end)
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

  Access is allowed for admin users.
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

      oban_access?(scope) and oban_running?() ->
        conn

      oban_access?(scope) ->
        conn
        |> put_flash(:error, "Oban is not running on this node.")
        |> redirect(to: ~p"/admin/jobs")
        |> halt()

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

  # In a single-deployment UI, Oban access is granted to admin users
  defp oban_access?(%Scope{user: %{role: role}}) do
    role in [:admin]
  end

  defp oban_access?(_), do: false

  defp oban_running? do
    case Oban.Registry.whereis(Oban) do
      pid when is_pid(pid) -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
