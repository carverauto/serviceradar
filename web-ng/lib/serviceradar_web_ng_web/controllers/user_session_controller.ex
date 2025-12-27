defmodule ServiceRadarWebNGWeb.UserSessionController do
  @moduledoc """
  Controller for user session management.

  Login and registration are handled by AshAuthentication.Phoenix via AuthController.
  This controller handles logout and password updates.
  """
  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Accounts
  alias ServiceRadarWebNGWeb.UserAuth

  @doc """
  Updates the user's password.

  Requires the user to be in sudo mode (recently authenticated).
  """
  def update_password(conn, %{"user" => user_params}) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.update_user_password(user, user_params) do
      {:ok, _user} ->
        # After password change, user should re-authenticate
        # Broadcast disconnect to any other LiveView sessions
        UserAuth.disconnect_sessions([user.id])

        conn
        |> put_flash(:info, "Password updated successfully! Please sign in again.")
        |> UserAuth.log_out_user()

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Failed to update password.")
        |> redirect(to: ~p"/users/settings")
    end
  end

  @doc """
  Logs the user out.
  """
  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
