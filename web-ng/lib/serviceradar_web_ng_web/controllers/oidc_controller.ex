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

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNGWeb.Auth.Hooks
  alias ServiceRadarWebNGWeb.Auth.OIDCClient
  alias ServiceRadarWebNGWeb.Auth.OIDCStrategy
  alias ServiceRadarWebNGWeb.UserAuth

  plug :fetch_session

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

    cond do
      # Validate state (CSRF protection)
      state != stored_state ->
        Logger.warning("OIDC callback state mismatch")

        conn
        |> put_flash(:error, "Authentication failed: invalid state. Please try again.")
        |> redirect(to: ~p"/users/log-in")

      true ->
        handle_code_exchange(conn, code, stored_nonce)
    end
  end

  def callback(conn, %{"error" => error, "error_description" => description}) do
    Logger.warning("OIDC callback error: #{error} - #{description}")

    conn
    |> delete_session(:oidc_state)
    |> delete_session(:oidc_nonce)
    |> put_flash(:error, "Authentication failed: #{description}")
    |> redirect(to: ~p"/users/log-in")
  end

  def callback(conn, %{"error" => error}) do
    Logger.warning("OIDC callback error: #{error}")

    conn
    |> delete_session(:oidc_state)
    |> delete_session(:oidc_nonce)
    |> put_flash(:error, "Authentication failed. Please try again.")
    |> redirect(to: ~p"/users/log-in")
  end

  # Private functions

  defp handle_code_exchange(conn, code, nonce) do
    with {:ok, tokens} <- OIDCClient.exchange_code(code),
         {:ok, claims} <- OIDCClient.verify_id_token(tokens["id_token"], nonce: nonce),
         user_info <- OIDCClient.extract_user_info(claims),
         {:ok, user} <- find_or_create_user(user_info) do
      # Record authentication timestamp
      actor = SystemActor.system(:oidc_auth)
      User.record_authentication(user, actor: actor)

      # Trigger auth hooks
      Hooks.on_user_authenticated(user, claims)

      conn
      |> put_flash(:info, "Signed in successfully via SSO.")
      |> UserAuth.log_in_user(user)
    else
      {:error, :user_creation_failed} ->
        Logger.error("Failed to create/update user from OIDC")

        conn
        |> put_flash(:error, "Failed to create user account. Please contact your administrator.")
        |> redirect(to: ~p"/users/log-in")

      {:error, reason} ->
        Logger.error("OIDC authentication failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Authentication failed. Please try again.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  defp find_or_create_user(%{email: email, name: name, external_id: external_id}) do
    actor = SystemActor.system(:oidc_auth)

    # First, try to find by external_id
    case find_user_by_external_id(external_id, actor) do
      {:ok, user} ->
        # Update display name if changed
        maybe_update_user(user, name, actor)

      {:error, :not_found} ->
        # Try to find by email
        case User.get_by_email(email, actor: actor) do
          {:ok, user} ->
            # Link existing user to OIDC
            update_user_external_id(user, external_id, name, actor)

          {:error, _} ->
            # Create new user (JIT provisioning)
            create_sso_user(email, name, external_id, actor)
        end
    end
  end

  defp find_user_by_external_id(external_id, actor) do
    require Ash.Query

    query =
      User
      |> Ash.Query.filter(external_id == ^external_id)
      |> Ash.Query.limit(1)

    case Ash.read(query, actor: actor) do
      {:ok, [user]} -> {:ok, user}
      {:ok, []} -> {:error, :not_found}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp maybe_update_user(user, name, actor) do
    if user.display_name != name and name do
      case User.update(user, %{display_name: name}, actor: actor) do
        {:ok, updated} -> {:ok, updated}
        {:error, _} -> {:ok, user}
      end
    else
      {:ok, user}
    end
  end

  defp update_user_external_id(user, external_id, name, actor) do
    # Update the user with external_id
    changeset =
      user
      |> Ash.Changeset.for_update(:update, %{display_name: name || user.display_name})
      |> Ash.Changeset.force_change_attribute(:external_id, external_id)

    case Ash.update(changeset, actor: actor) do
      {:ok, updated} ->
        Logger.info("Linked existing user #{user.id} to OIDC external_id #{external_id}")
        {:ok, updated}

      {:error, error} ->
        Logger.error("Failed to link user to OIDC: #{inspect(error)}")
        # Return the existing user anyway
        {:ok, user}
    end
  end

  defp create_sso_user(email, name, external_id, actor) do
    params = %{
      email: email,
      display_name: name,
      external_id: external_id,
      provider: :oidc
    }

    case User.provision_sso_user(params, actor: actor) do
      {:ok, user} ->
        Logger.info("Created new user via OIDC JIT provisioning: #{user.id}")
        Hooks.on_user_created(user, :oidc)
        {:ok, user}

      {:error, error} ->
        Logger.error("Failed to create SSO user: #{inspect(error)}")
        {:error, :user_creation_failed}
    end
  end
end
