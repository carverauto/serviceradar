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
  alias ServiceRadar.Security.Lockouts
  alias ServiceRadarWebNG.Audit.UserAuthEvents
  alias ServiceRadarWebNG.Auth.Hooks
  alias ServiceRadarWebNGWeb.Auth.OIDCClient
  alias ServiceRadarWebNGWeb.Auth.OIDCStrategy
  alias ServiceRadarWebNGWeb.Auth.SSOProvisioning
  alias ServiceRadarWebNGWeb.ClientIP
  alias ServiceRadarWebNGWeb.UserAuth

  require Logger

  plug :fetch_session

  # Rate limiting for the callback happens at the
  # `:rate_limit_auth_oidc` pipeline (router.ex).

  defp get_client_ip(conn) do
    ClientIP.get(conn)
  end

  @doc """
  Initiates OIDC authentication by redirecting to the IdP.

  Stores state, nonce, and PKCE verifier in session for validation on callback.
  """
  def request(conn, _params) do
    if OIDCStrategy.enabled?() do
      case OIDCClient.authorize_url() do
        {:ok, url, session} ->
          conn
          |> put_oidc_session(session)
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
    stored_verifier = get_session(conn, :oidc_code_verifier)
    pkce? = get_session(conn, :oidc_pkce) == true

    # Consume login secrets before any token request so a replay cannot reuse them.
    conn = clear_oidc_session(conn)

    cond do
      not valid_oidc_callback_session?(state, stored_state, stored_nonce) ->
        reject_callback_session(conn, :invalid_state)

      pkce? and not valid_pkce_verifier?(stored_verifier) ->
        reject_callback_session(conn, :missing_pkce_verifier)

      true ->
        handle_code_exchange(conn, code, stored_nonce, pkce_verifier(pkce?, stored_verifier))
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
    |> clear_oidc_session()
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
    |> clear_oidc_session()
    |> put_flash(:error, "Authentication failed. Please try again.")
    |> redirect(to: ~p"/users/log-in")
  end

  # Private functions

  defp valid_oidc_callback_session?(state, stored_state, stored_nonce)
       when is_binary(state) and is_binary(stored_state) and is_binary(stored_nonce) do
    Plug.Crypto.secure_compare(state, stored_state)
  end

  defp valid_oidc_callback_session?(_state, _stored_state, _stored_nonce), do: false

  defp valid_pkce_verifier?(verifier) when is_binary(verifier) and verifier != "", do: true
  defp valid_pkce_verifier?(_verifier), do: false

  defp pkce_verifier(true, verifier), do: verifier
  defp pkce_verifier(_pkce?, _verifier), do: nil

  defp put_oidc_session(conn, session) do
    conn
    |> put_session(:oidc_state, session.state)
    |> put_session(:oidc_nonce, session.nonce)
    |> put_session(:oidc_code_verifier, session.code_verifier)
    |> put_session(:oidc_pkce, session.pkce?)
  end

  defp clear_oidc_session(conn) do
    conn
    |> delete_session(:oidc_state)
    |> delete_session(:oidc_nonce)
    |> delete_session(:oidc_code_verifier)
    |> delete_session(:oidc_pkce)
  end

  defp reject_callback_session(conn, reason) do
    Logger.warning("OIDC callback rejected reason=#{inspect(reason)}")

    Hooks.on_auth_failed(reason, %{
      method: :oidc,
      ip: get_client_ip(conn),
      user_agent: conn |> get_req_header("user-agent") |> List.first()
    })

    conn
    |> put_flash(:error, "Authentication failed: invalid state. Please try again.")
    |> redirect(to: ~p"/users/log-in")
  end

  defp handle_code_exchange(conn, code, nonce, code_verifier) do
    case exchange_and_verify(code, nonce, code_verifier) do
      {:ok, claims, tokens} -> complete_oidc_login(conn, claims, tokens)
      {:error, reason} -> reject_oidc_pre_verify(conn, reason)
    end
  end

  defp exchange_and_verify(code, nonce, code_verifier) do
    exchange_opts =
      if is_binary(code_verifier) and code_verifier != "" do
        [code_verifier: code_verifier]
      else
        []
      end

    with {:ok, tokens} <- OIDCClient.exchange_code(code, exchange_opts),
         {:ok, claims} <- OIDCClient.verify_id_token(tokens["id_token"], nonce: nonce) do
      {:ok, claims, tokens}
    end
  end

  # Failures before the ID token verifies — we don't have a
  # trusted actor identifier yet, so do not feed lockouts.
  defp reject_oidc_pre_verify(conn, reason) do
    Logger.error("OIDC authentication failed: #{inspect(reason)}")

    Hooks.on_auth_failed(reason, %{method: :oidc, ip: get_client_ip(conn)})

    conn
    |> put_flash(:error, "Authentication failed. Please try again.")
    |> redirect(to: ~p"/users/log-in")
  end

  defp complete_oidc_login(conn, claims, tokens) do
    # We have verified claims; any failure from here is a
    # validated-identity failure that should feed lockouts.
    email = claims["email"]
    actor = SystemActor.system(:oidc_auth)

    with {:ok, user_info} <- OIDCClient.extract_user_info(claims),
         {:ok, user} <- find_or_create_user(user_info, claims),
         {:ok, user} <- SSOProvisioning.record_successful_authentication(user, :oidc, actor) do
      session_claims = Map.put(claims, "service_radar_auth_method", "oidc")

      # Trigger auth hooks
      Hooks.on_user_authenticated(user, claims)

      _ = UserAuthEvents.record_login(conn, user, :oidc)

      conn
      |> put_flash(:info, "Signed in successfully via SSO.")
      |> UserAuth.log_in_user(user, %{
        "identity_claims" => session_claims,
        "mcp_idp_refresh" => tokens["refresh_token"] || tokens[:refresh_token]
      })
    else
      {:error, :unsafe_account_linking} ->
        Logger.warning("OIDC authentication rejected implicit email-based account linking")
        record_validated_failure(conn, email, :unsafe_account_linking)

        conn
        |> put_flash(
          :error,
          "An existing account with that email cannot be linked automatically. Please contact your administrator."
        )
        |> redirect(to: ~p"/users/log-in")

      {:error, :no_local_account} ->
        Logger.warning("OIDC authentication denied: no local account and JIT provisioning disabled")
        record_validated_failure(conn, email, :no_local_account)

        conn
        |> put_flash(
          :error,
          "No account is provisioned for this identity. Contact your administrator."
        )
        |> redirect(to: ~p"/users/log-in")

      {:error, :user_creation_failed} ->
        Logger.error("Failed to create/update user from OIDC")
        record_validated_failure(conn, email, :user_creation_failed)

        conn
        |> put_flash(:error, "Failed to create user account. Please contact your administrator.")
        |> redirect(to: ~p"/users/log-in")

      {:error, reason} ->
        Logger.error("OIDC authentication failed: #{inspect(reason)}")
        record_validated_failure(conn, email, reason)

        conn
        |> put_flash(:error, "Authentication failed. Please try again.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  defp record_validated_failure(conn, email, reason) do
    Hooks.on_auth_failed(reason, %{method: :oidc, ip: get_client_ip(conn)})

    if is_binary(email) and email != "" do
      Lockouts.record_failed_login(email, %{
        ip: get_client_ip(conn),
        route: conn.request_path,
        method: "oidc",
        reason: to_string(reason)
      })
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
