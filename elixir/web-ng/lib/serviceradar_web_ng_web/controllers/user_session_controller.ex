defmodule ServiceRadarWebNGWeb.UserSessionController do
  @moduledoc """
  Controller for user session management.

  Login is handled by AuthController using Guardian JWT tokens.
  This controller handles logout and password updates.
  """
  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Accounts
  alias ServiceRadarWebNGWeb.Auth.TokenRevocation
  alias ServiceRadarWebNGWeb.UserAuth

  @doc """
  Updates the user's password.

  Requires the user to be in sudo mode (recently authenticated).
  Revokes all tokens for the user after password change.
  """
  def update_password(conn, %{"user" => user_params}) do
    user = conn.assigns.current_scope.user
    sudo_at_unix = get_session(conn, "sudo_authenticated_at")
    sudo_at = sudo_at_unix && DateTime.from_unix!(sudo_at_unix)

    if Accounts.sudo_mode?(user, sudo_at) do
      case Accounts.update_user_password(user, user_params) do
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
    else
      conn
      |> put_flash(:error, "Sudo mode required. Please re-authenticate.")
      |> redirect(to: ~p"/settings/profile")
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
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, fn message -> "#{field}: #{message}" end)
    end)
    |> Enum.join("; ")
  end

  defp format_password_error(other) do
    case other do
      {:http_error, status, body} -> "HTTP #{status}: #{inspect(body)}"
      _ -> "unexpected error"
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
