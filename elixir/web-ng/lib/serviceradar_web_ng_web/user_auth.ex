defmodule ServiceRadarWebNGWeb.UserAuth do
  @moduledoc """
  Authentication helpers using Guardian JWT tokens.

  Handles session management, current user loading, and LiveView authentication
  using Guardian JWT tokens stored in the session.

  This is a single-deployment UI. Schema context is implicit from the database
  connection's search_path, so we only need to track the authenticated user.
  """

  use ServiceRadarWebNGWeb, :verified_routes

  import Phoenix.Controller
  import Plug.Conn

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.Auth.TokenRevocation

  require Logger

  @default_absolute_timeout_seconds 30 * 24 * 60 * 60
  @session_started_key :session_started_at
  @user_token_key "user_token"
  @sudo_at_key "sudo_authenticated_at"

  @doc """
  Logs the user in by creating a Guardian session token.

  Stores the token in the session and sets up the live socket ID for
  broadcasting disconnects on logout.
  """
  def log_in_user(conn, user, params \\ %{}) do
    raw_return_to = get_session(conn, :user_return_to) || params["return_to"] || ~p"/analytics"
    return_to = sanitize_return_path(raw_return_to)
    session_started_at = DateTime.to_unix(DateTime.utc_now())
    max_age_seconds = session_absolute_timeout_seconds()

    case Guardian.create_access_token(user) do
      {:ok, token, _claims} ->
        conn
        |> put_session(@user_token_key, token)
        |> put_session(@session_started_key, session_started_at)
        |> put_session(@sudo_at_key, session_started_at)
        |> delete_session(:user_return_to)
        |> put_session(:live_socket_id, "users_sessions:#{user.id}")
        |> configure_session(renew: true, max_age: max_age_seconds)
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

  Revokes the JWT token, clears the session, and broadcasts disconnect to LiveViews.
  """
  def log_out_user(conn) do
    case conn.assigns |> Map.get(:current_scope) |> then(&(&1 && &1.user)) do
      nil ->
        :ok

      user ->
        _ =
          ServiceRadarWebNG.Audit.UserAuthEvents.record_logout(conn, user, user.last_auth_method)

        :ok
    end

    # Revoke the JWT token to prevent reuse
    revoke_current_token(conn)

    if live_socket_id = get_session(conn, :live_socket_id) do
      ServiceRadarWebNGWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> clear_session()
    |> configure_session(renew: true)
    |> redirect(to: ~p"/")
  end

  defp revoke_current_token(conn) do
    with token when is_binary(token) <- get_session(conn, @user_token_key),
         {:ok, claims} <- Guardian.decode_and_verify(token, %{}) do
      jti = Map.get(claims, "jti")
      user_id = extract_user_id(claims)

      if jti do
        TokenRevocation.revoke_token(jti,
          reason: :user_logout,
          user_id: user_id
        )
      end
    else
      _ -> :ok
    end
  end

  defp extract_user_id(%{"sub" => "user:" <> id}), do: id
  defp extract_user_id(_), do: nil

  defp refresh_session(conn, user, claims) do
    {conn, session_started_at} = ensure_session_started_at(conn, claims)
    now = System.system_time(:second)
    absolute_timeout_seconds = session_absolute_timeout_seconds()

    if now - session_started_at >= absolute_timeout_seconds do
      log_session_expired(conn, user, session_started_at, absolute_timeout_seconds)

      refreshed_conn =
        conn
        |> clear_session()
        |> configure_session(renew: true)

      {:error, refreshed_conn}
    else
      remaining_seconds = max(absolute_timeout_seconds - (now - session_started_at), 1)

      case Guardian.create_access_token(user) do
        {:ok, token, _claims} ->
          refreshed_conn =
            conn
            |> put_session(@user_token_key, token)
            |> configure_session(max_age: remaining_seconds)

          {:ok, refreshed_conn}

        {:error, reason} ->
          Logger.warning("Failed to refresh session token",
            reason: inspect(reason),
            user_id: user.id
          )

          refreshed_conn =
            conn
            |> clear_session()
            |> configure_session(renew: true)

          {:error, refreshed_conn}
      end
    end
  end

  defp ensure_session_started_at(conn, claims) do
    case get_session(conn, @session_started_key) do
      started_at when is_integer(started_at) ->
        {conn, started_at}

      started_at when is_binary(started_at) ->
        case Integer.parse(started_at) do
          {parsed, ""} ->
            {put_session(conn, @session_started_key, parsed), parsed}

          _ ->
            set_session_started_at(conn, claims)
        end

      _ ->
        set_session_started_at(conn, claims)
    end
  end

  defp set_session_started_at(conn, claims) do
    started_at = claim_issued_at(claims)
    {put_session(conn, @session_started_key, started_at), started_at}
  end

  defp claim_issued_at(claims) do
    case Map.get(claims, "iat") do
      iat when is_integer(iat) ->
        iat

      iat when is_float(iat) ->
        trunc(iat)

      iat when is_binary(iat) ->
        case Integer.parse(iat) do
          {parsed, ""} -> parsed
          _ -> DateTime.to_unix(DateTime.utc_now())
        end

      _ ->
        DateTime.to_unix(DateTime.utc_now())
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      ["bearer " <> token] -> {:ok, String.trim(token)}
      _ -> :error
    end
  end

  defp log_session_failure(conn, reason) do
    Logger.info("Session token rejected",
      reason: inspect(reason),
      path: conn.request_path,
      method: conn.method
    )
  end

  defp log_session_expired(conn, user, session_started_at, absolute_timeout_seconds) do
    Logger.info("Session expired due to absolute timeout",
      user_id: user.id,
      session_started_at: session_started_at,
      absolute_timeout_seconds: absolute_timeout_seconds,
      path: conn.request_path,
      method: conn.method
    )
  end

  defp session_config do
    Application.get_env(:serviceradar_web_ng, :session, [])
  end

  defp session_absolute_timeout_seconds do
    Keyword.get(session_config(), :absolute_timeout_seconds, @default_absolute_timeout_seconds)
  end

  @doc """
  Authenticates the user by verifying the Guardian JWT token in the session.

  The token is stored under "user_token" key by `log_in_user/3`.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    # If another plug (ex: gateway proxy auth) already established a user scope,
    # don't override it.
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) ->
        conn

      _ ->
        # In passive_proxy mode, an upstream gateway may inject an Authorization
        # header containing a non-Guardian JWT. Avoid treating that as a
        # ServiceRadar bearer token.
        if passive_proxy_mode?() do
          authenticate_from_session(conn)
        else
          authenticate_from_bearer_or_session(conn)
        end
    end
  end

  defp authenticate_from_session(conn) do
    token = get_session(conn, @user_token_key)

    if is_binary(token) do
      authenticate_with_token(conn, token, :session)
    else
      assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  defp authenticate_from_bearer_or_session(conn) do
    case bearer_token(conn) do
      {:ok, token} ->
        authenticate_with_token(conn, token, :bearer)

      :error ->
        authenticate_from_session(conn)
    end
  end

  defp passive_proxy_mode? do
    alias ServiceRadarWebNGWeb.Auth.ConfigCache

    case ConfigCache.get_settings() do
      {:ok, %{is_enabled: true, mode: :passive_proxy}} -> true
      _ -> false
    end
  end

  defp authenticate_with_token(conn, token, :session) do
    case Guardian.verify_token(token, token_type: "access") do
      {:ok, user, claims} ->
        refresh_and_assign_scope(conn, user, claims)

      {:error, reason} ->
        handle_session_failure(conn, reason)
    end
  end

  defp authenticate_with_token(conn, token, :bearer) do
    case Guardian.verify_token(token, token_type: "access") do
      {:ok, user, _claims} ->
        assign(conn, :current_scope, create_scope(user))

      {:error, reason} ->
        log_session_failure(conn, reason)
        assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  defp refresh_and_assign_scope(conn, user, claims) do
    case refresh_session(conn, user, claims) do
      {:ok, refreshed_conn} ->
        assign(refreshed_conn, :current_scope, create_scope(user))

      {:error, refreshed_conn} ->
        assign(refreshed_conn, :current_scope, Scope.for_user(nil))
    end
  end

  defp handle_session_failure(conn, reason) do
    log_session_failure(conn, reason)

    conn
    |> clear_session()
    |> configure_session(renew: true)
    |> assign(:current_scope, Scope.for_user(nil))
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

  def on_mount(:require_sudo_mode, _params, session, socket) do
    with token when is_binary(token) <- session[@user_token_key],
         {:ok, user, _claims} <- Guardian.verify_token(token, token_type: "access") do
      check_sudo_mode(socket, session, user)
    else
      _ -> {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/users/log-in")}
    end
  end

  defp check_sudo_mode(socket, session, user) do
    sudo_at_unix = session[@sudo_at_key]

    if sudo_at_unix &&
         ServiceRadarWebNG.Accounts.sudo_mode?(user, DateTime.from_unix!(sudo_at_unix)) do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(
          :error,
          "Session expired. Please sign in again to access account settings."
        )
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  @doc """
  Sets the sudo authentication timestamp in the session.
  """
  def put_sudo_mode(conn) do
    put_session(conn, @sudo_at_key, DateTime.to_unix(DateTime.utc_now()))
  end

  @doc """
  Clears the sudo authentication timestamp from the session.
  """
  def delete_sudo_mode(conn) do
    delete_session(conn, @sudo_at_key)
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      user =
        with token when is_binary(token) <- session[@user_token_key],
             {:ok, user, _claims} <- Guardian.verify_token(token, token_type: "access") do
          user
        else
          _ -> nil
        end

      create_scope(user)
    end)
  end

  defp create_scope(nil), do: Scope.for_user(nil)

  defp create_scope(user) do
    permissions = ServiceRadar.Identity.RBAC.permissions_for_user(user)
    Scope.for_user(user, permissions: permissions)
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
  Plug for API routes that require the user to be authenticated.

  Returns JSON errors instead of redirecting so API consumers don't need flash.
  """
  def require_authenticated_user_api(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "authentication_required"})
      |> halt()
    end
  end

  @doc """
  Plug for routes that require Oban Web access.

  Access is allowed for users with Jobs management permission.
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

  # In a single-deployment UI, Oban access is granted via RBAC, not base role.
  defp oban_access?(%Scope{} = scope) do
    ServiceRadarWebNG.RBAC.can?(scope, "settings.jobs.manage")
  end

  defp oban_access?(_), do: false

  # Validates that a return-to path is a safe, relative path within the application.
  # Prevents open redirect attacks via absolute URLs, protocol-relative URLs, or
  # data/javascript scheme URIs.
  @doc """
  Plug for routes that require the user to be in sudo mode (recently authenticated).
  """
  def require_sudo_mode(conn, _opts) do
    user = conn.assigns.current_scope && conn.assigns.current_scope.user
    sudo_at_unix = get_session(conn, @sudo_at_key)

    if user && sudo_at_unix &&
         ServiceRadarWebNG.Accounts.sudo_mode?(
           user,
           DateTime.from_unix!(sudo_at_unix)
         ) do
      conn
    else
      conn
      |> put_session(:user_return_to, conn.request_path)
      |> put_flash(:error, "Session expired. Please sign in again to access account settings.")
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end

  defp sanitize_return_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      # Must start with a single forward slash (relative path)
      not String.starts_with?(trimmed, "/") -> ~p"/analytics"
      # Block protocol-relative URLs (//evil.com)
      String.starts_with?(trimmed, "//") -> ~p"/analytics"
      # Block backslash variants (\\evil.com works in some browsers)
      String.contains?(trimmed, "\\") -> ~p"/analytics"
      # Safe relative path
      true -> trimmed
    end
  end

  defp sanitize_return_path(_), do: ~p"/analytics"

  defp oban_running? do
    case Oban.Registry.whereis(Oban) do
      pid when is_pid(pid) -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
