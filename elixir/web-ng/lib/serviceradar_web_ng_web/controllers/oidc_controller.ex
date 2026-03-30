defmodule ServiceRadarWebNGWeb.OIDCController do
  @moduledoc """
  Controller for OIDC authentication flow.

  Handles:
  - `/auth/oidc` - Initiates OIDC login by redirecting to IdP
  - `/auth/oidc/callback` - Handles callback from IdP, exchanges code for tokens

  ## Security

  - State parameter is used for CSRF protection
  - Nonce parameter prevents replay attacks
  - Both are stored in session and validated on callback
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.Audit.UserAuthEvents
  alias ServiceRadarWebNG.Auth.Hooks
  alias ServiceRadarWebNGWeb.Auth.OIDCClient
  alias ServiceRadarWebNGWeb.Auth.OIDCStrategy
  alias ServiceRadarWebNGWeb.Auth.RateLimiter
  alias ServiceRadarWebNGWeb.Auth.SSOProvisioning
  alias ServiceRadarWebNGWeb.ClientIP
  alias ServiceRadarWebNGWeb.UserAuth

  require Logger

  plug :fetch_session
  plug :check_rate_limit when action == :callback

  # Rate limit: 20 attempts per minute per IP for callbacks
  @callback_rate_limit 20
  @callback_rate_window 60

  defp check_rate_limit(conn, _opts) do
    client_ip = get_client_ip(conn)

    case RateLimiter.check_rate_limit_and_record("oidc_callback", client_ip,
           limit: @callback_rate_limit,
           window_seconds: @callback_rate_window
         ) do
      :ok ->
        conn

      {:error, retry_after} ->
        Logger.warning("OIDC callback rate limited for IP: #{client_ip}")

        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_flash(
          :error,
          "Too many authentication attempts. Please wait #{retry_after} seconds."
        )
        |> redirect(to: ~p"/users/log-in")
        |> halt()
    end
  end

  defp get_client_ip(conn) do
    ClientIP.get(conn)
  end

  @doc """
  Initiates OIDC authentication by redirecting to the IdP.

  Stores state and nonce in session for validation on callback.
  """
  def request(conn, _params) do
    if OIDCStrategy.enabled?() do
      case OIDCClient.authorize_url() do
        {:ok, url, %{state: state, nonce: nonce}} ->
          conn
          |> put_session(:oidc_state, state)
          |> put_session(:oidc_nonce, nonce)
          |> redirect(external: url)

        {:error, reason} ->
          Logger.error("Failed to generate OIDC authorize URL: #{inspect(reason)}")

          conn
          |> put_flash(:error, "SSO configuration error. Please contact your administrator.")
          |> redirect(to: ~p"/users/log-in")
      end
    else
      conn
      |> put_flash(:error, "SSO is not enabled.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  @doc """
  Handles the callback from the OIDC IdP.

  Validates state, exchanges code for tokens, verifies ID token,
  and creates or updates the user (JIT provisioning).
  """
  def callback(conn, %{"code" => code, "state" => state}) do
    stored_state = get_session(conn, :oidc_state)
    stored_nonce = get_session(conn, :oidc_nonce)

    # Clear OIDC session data
    conn =
      conn
      |> delete_session(:oidc_state)
      |> delete_session(:oidc_nonce)

    if valid_oidc_callback_session?(state, stored_state, stored_nonce) do
      handle_code_exchange(conn, code, stored_nonce)
    else
      Logger.warning("OIDC callback state or nonce validation failed")

      Hooks.on_auth_failed(:invalid_state, %{
        method: :oidc,
        ip: get_client_ip(conn),
        user_agent: conn |> get_req_header("user-agent") |> List.first()
      })

      conn
      |> put_flash(:error, "Authentication failed: invalid state. Please try again.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def callback(conn, %{"error" => error, "error_description" => description}) do
    Logger.warning("OIDC callback error: #{error} - #{description}")

    Hooks.on_auth_failed(:idp_error, %{
      method: :oidc,
      error: error,
      description: description,
      ip: get_client_ip(conn)
    })

    conn
    |> delete_session(:oidc_state)
    |> delete_session(:oidc_nonce)
    |> put_flash(:error, "Authentication failed: #{description}")
    |> redirect(to: ~p"/users/log-in")
  end

  def callback(conn, %{"error" => error}) do
    Logger.warning("OIDC callback error: #{error}")

    Hooks.on_auth_failed(:idp_error, %{
      method: :oidc,
      error: error,
      ip: get_client_ip(conn)
    })

    conn
    |> delete_session(:oidc_state)
    |> delete_session(:oidc_nonce)
    |> put_flash(:error, "Authentication failed. Please try again.")
    |> redirect(to: ~p"/users/log-in")
  end

  # Private functions

  defp valid_oidc_callback_session?(state, stored_state, stored_nonce)
       when is_binary(state) and is_binary(stored_state) and is_binary(stored_nonce) do
    Plug.Crypto.secure_compare(state, stored_state)
  end

  defp valid_oidc_callback_session?(_state, _stored_state, _stored_nonce), do: false

  defp handle_code_exchange(conn, code, nonce) do
    with {:ok, tokens} <- OIDCClient.exchange_code(code),
         {:ok, claims} <- OIDCClient.verify_id_token(tokens["id_token"], nonce: nonce),
         {:ok, user_info} <- OIDCClient.extract_user_info(claims),
         {:ok, user} <- find_or_create_user(user_info, claims) do
      # Record authentication timestamp
      actor = SystemActor.system(:oidc_auth)
      User.record_authentication(user, actor: actor)

      # Trigger auth hooks
      Hooks.on_user_authenticated(user, claims)

      _ = UserAuthEvents.record_login(conn, user, :oidc)

      conn
      |> put_flash(:info, "Signed in successfully via SSO.")
      |> UserAuth.log_in_user(user)
    else
      {:error, :unsafe_account_linking} ->
        Logger.warning("OIDC authentication rejected implicit email-based account linking")

        Hooks.on_auth_failed(:unsafe_account_linking, %{
          method: :oidc,
          ip: get_client_ip(conn)
        })

        conn
        |> put_flash(
          :error,
          "An existing account with that email cannot be linked automatically. Please contact your administrator."
        )
        |> redirect(to: ~p"/users/log-in")

      {:error, :user_creation_failed} ->
        Logger.error("Failed to create/update user from OIDC")

        Hooks.on_auth_failed(:user_creation_failed, %{
          method: :oidc,
          ip: get_client_ip(conn)
        })

        conn
        |> put_flash(:error, "Failed to create user account. Please contact your administrator.")
        |> redirect(to: ~p"/users/log-in")

      {:error, reason} ->
        Logger.error("OIDC authentication failed: #{inspect(reason)}")

        Hooks.on_auth_failed(reason, %{
          method: :oidc,
          ip: get_client_ip(conn)
        })

        conn
        |> put_flash(:error, "Authentication failed. Please try again.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  defp find_or_create_user(%{email: email, name: name, external_id: external_id}, claims) do
    actor = SystemActor.system(:oidc_auth)

    SSOProvisioning.find_or_create_user(
      %{email: email, name: name, external_id: external_id},
      claims,
      :oidc,
      actor
    )
  end
end
