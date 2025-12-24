defmodule ServiceRadarWebNGWeb.AuthController do
  @moduledoc """
  Controller for AshAuthentication callbacks.

  Handles authentication callbacks from password, magic link, and OAuth strategies.
  Uses the AshAuthentication.Phoenix.Controller behavior for standard auth flows.
  """

  use ServiceRadarWebNGWeb, :controller
  use AshAuthentication.Phoenix.Controller

  @doc """
  Called on successful authentication.

  Signs the user into the session and redirects to the return path
  or the default analytics page.
  """
  def success(conn, _activity, user, _token) do
    return_to = get_session(conn, :user_return_to) || ~p"/analytics"

    conn
    |> delete_session(:user_return_to)
    |> store_in_session(user)
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

  Clears the session and redirects to the home page.
  """
  def sign_out(conn, _params) do
    return_to = get_session(conn, :user_return_to) || ~p"/"

    conn
    |> clear_session(:serviceradar_web_ng)
    |> put_flash(:info, "Signed out successfully.")
    |> redirect(to: return_to)
  end
end
