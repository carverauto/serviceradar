defmodule ServiceRadarWebNGWeb.AuthController do
  @moduledoc """
  Controller for AshAuthentication callbacks.

  Handles authentication callbacks from password, magic link, and OAuth strategies.
  Uses the AshAuthentication.Phoenix.Controller behavior for standard auth flows.

  ## Token Storage

  AshAuthentication stores JWT tokens in the session automatically via `store_in_session/2`.
  The token is stored under the subject token key (e.g., `"user_token"`) and can be retrieved
  for verification using `AshAuthentication.Jwt.verify/2`.
  """

  use ServiceRadarWebNGWeb, :controller
  use AshAuthentication.Phoenix.Controller

  alias ServiceRadarWebNGWeb.TenantResolver

  plug :fetch_session

  @doc """
  Called on successful authentication.

  Signs the user into the session using Ash JWT tokens and redirects to the return path
  or the default analytics page.
  """
  def success(conn, _activity, nil, _token) do
    redirect_path =
      if Application.get_env(:serviceradar_web_ng, :dev_routes, false) ||
           Application.get_env(:serviceradar_web_ng, :local_mailer, false) do
        ~p"/dev/mailbox"
      else
        ~p"/users/log-in"
      end

    conn
    |> put_flash(:info, "Check your email for the next step.")
    |> redirect(to: redirect_path)
  end

  def success(conn, _activity, %_{} = user, _token) do
    return_to = get_session(conn, :user_return_to) || ~p"/analytics"
    tenant_id = user.tenant_id

    tenant_schema =
      case Map.fetch(user.__metadata__, :tenant) do
        {:ok, tenant} when is_binary(tenant) -> tenant
        _ -> TenantResolver.schema_for_tenant_id(tenant_id)
      end

    case AshAuthentication.Jwt.token_for_user(
           user,
           %{"tenant_id" => tenant_id},
           tenant: tenant_schema
         ) do
      {:ok, token, _claims} ->
        conn
        |> put_session("user_token", token)
        |> put_session("active_tenant_id", tenant_id)
        |> put_session("tenant", tenant_schema)
        |> delete_session(:user_return_to)
        |> put_session(:live_socket_id, "users_sessions:#{user.id}")
        |> configure_session(renew: true)
        |> assign(:current_user, user)
        |> put_flash(:info, "Signed in successfully.")
        |> redirect(to: return_to)

      :error ->
        conn
        |> put_flash(:error, "Unable to complete sign-in. Please try again.")
        |> redirect(to: ~p"/users/log-in")
        |> halt()
    end
  end

  @doc """
  Called on authentication failure.

  Displays an error message and redirects to the login page.
  """
  def failure(conn, activity, reason) do
    require Logger

    Logger.error(
      "Authentication failure: activity=#{inspect(activity)}, reason=#{inspect(reason)}"
    )

    conn
    |> put_flash(:error, "Authentication failed. Please try again.")
    |> redirect(to: ~p"/users/log-in")
  end

  @doc """
  Called when sign-out is requested.

  Clears the session (including revoking tokens) and redirects to the home page.
  """
  def sign_out(conn, _params) do
    conn
    |> clear_session(:serviceradar_web_ng)
    |> put_flash(:info, "Signed out successfully.")
    |> redirect(to: ~p"/")
  end
end
