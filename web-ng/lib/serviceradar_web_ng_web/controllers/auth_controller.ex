defmodule ServiceRadarWebNGWeb.AuthController do
  @moduledoc """
  Controller for AshAuthentication callbacks.

  Handles authentication callbacks from password, magic link, and OAuth strategies.
  Uses the AshAuthentication.Phoenix.Controller behavior for standard auth flows.

  ## Token Storage

  AshAuthentication stores JWT tokens in the session automatically via `store_in_session/2`.
  The token is stored under the subject name key (e.g., `:user`) and can be retrieved
  for verification using `AshAuthentication.Jwt.verify/2`.
  """

  use ServiceRadarWebNGWeb, :controller
  use AshAuthentication.Phoenix.Controller

  plug :fetch_session

  @doc """
  Called on successful authentication.

  Signs the user into the session using Ash JWT tokens and redirects to the return path
  or the default analytics page.
  """
  def success(conn, _activity, nil, _token) do
    conn
    |> put_flash(:info, "Check your email for the next step.")
    |> redirect(to: ~p"/users/log-in")
  end

  def success(conn, _activity, %_{} = user, _token) do
    return_to = get_session(conn, :user_return_to) || ~p"/analytics"

    conn
    |> delete_session(:user_return_to)
    |> store_in_session(user)
    |> put_session(:live_socket_id, "users_sessions:#{user.id}")
    |> configure_session(renew: true)
    |> assign(:current_user, user)
    |> put_flash(:info, "Signed in successfully.")
    |> redirect(to: return_to)
  end

  @doc """
  Called on authentication failure.

  Displays an error message and redirects to the login page.
  """
  def failure(conn, _activity, _reason) do
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
