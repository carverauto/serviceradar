defmodule ServiceRadarWebNGWeb.UserSessionController do
  @moduledoc """
  Controller for user session management.

  Login is handled by AuthController using Guardian JWT tokens.
  This controller handles logout and password updates.
  """
  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Identity.Constants
  alias ServiceRadarWebNG.Accounts
  alias ServiceRadarWebNG.Auth.TokenRevocation
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.UserAuth

  @password_manage_permission Constants.password_manage_permission()

  @doc """
  Updates the user's password.

  Requires the user to be in sudo mode (recently authenticated).
  Revokes all tokens for the user after password change.
  """
  def update_password(conn, %{"user" => user_params}) do
    scope = conn.assigns.current_scope
    user = scope.user
    sudo_at_unix = get_session(conn, "sudo_authenticated_at")
    sudo_at = sudo_at_unix && DateTime.from_unix!(sudo_at_unix)

    cond do
      not RBAC.can?(scope, @password_manage_permission) ->
        conn
        |> put_flash(:error, "You are not allowed to change the password for this account.")
        |> redirect(to: ~p"/settings/profile")

      not Accounts.sudo_mode?(user, sudo_at) ->
        conn
        |> put_flash(:error, "Sudo mode required. Please re-authenticate.")
        |> redirect(to: ~p"/settings/profile")

      true ->
        case Accounts.update_user_password(user, user_params, scope: scope) do
          {:ok, _user} ->
            # Revoke all tokens for this user - password change invalidates all sessions
            TokenRevocation.revoke_all_for_user(user.id, reason: :password_changed)

            # After password change, user should re-authenticate
            # Broadcast disconnect to any other LiveView sessions
            UserAuth.disconnect_sessions([user.id])

            conn
            |> put_flash(:info, "Password updated successfully! Please sign in again.")
            |> UserAuth.log_out_user()

          {:error, changeset} ->
            conn
            |> put_flash(:error, "Failed to update password: #{format_password_error(changeset)}")
            |> redirect(to: ~p"/settings/profile")
        end
    end
  end

  defp format_password_error(%Ash.Error.Invalid{} = error) do
    # Keep this user-facing and non-technical.
    Enum.map_join(error.errors, "; ", fn
      %{field: field, message: message} when not is_nil(field) ->
        "#{field}: #{message}"

      %{message: message} ->
        message

      _ ->
        "validation error"
    end)
  end

  defp format_password_error(%Ecto.Changeset{} = changeset) do
    changeset
    |> Map.get(:errors, [])
    |> Enum.map_join("; ", fn {field, {msg, opts}} ->
      rendered =
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)

      "#{field}: #{rendered}"
    end)
  end

  defp format_password_error(_other), do: "unexpected error"

  @doc """
  Logs the user out.
  """
  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
