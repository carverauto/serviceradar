defmodule ServiceRadarWebNGWeb.UserSessionController do
  @moduledoc """
  Controller for user session management.

  Login is handled by AuthController using Guardian JWT tokens.
  This controller handles logout and password updates.
  """
  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Identity.Constants
  alias ServiceRadar.Identity.User
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
      User.idp_managed_identity?(user) ->
        conn
        |> put_flash(:error, "Password for this account is managed by your identity provider.")
        |> redirect(to: ~p"/settings/profile")

      not RBAC.can?(scope, @password_manage_permission) ->
        conn
        |> put_flash(:error, "You are not allowed to change the password for this account.")
        |> redirect(to: ~p"/settings/profile")

      not Accounts.sudo_mode?(user, sudo_at) ->
        conn
        |> put_flash(:error, "Sudo mode required. Please re-authenticate.")
        |> redirect(to: ~p"/settings/profile")

      true ->
        user_params = normalize_password_params(user_params)

        case Accounts.change_user_password(user, user_params) do
          %Ecto.Changeset{valid?: false} = changeset ->
            conn
            |> put_flash(:error, "Failed to update password: #{format_password_error(changeset)}")
            |> redirect(to: ~p"/settings/profile")

          _changeset ->
            update_password(conn, user, scope, user_params)
        end
    end
  end

  defp update_password(conn, user, scope, user_params) do
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

  defp normalize_password_params(params) when is_map(params) do
    Map.take(params, ~w(current_password password password_confirmation))
  end

  defp normalize_password_params(_params), do: %{}

  defp format_password_error(%Ash.Error.Invalid{} = error) do
    # Keep this user-facing and non-technical.
    Enum.map_join(error.errors, "; ", fn
      %{field: field, message: message} = error when not is_nil(field) ->
        "#{field}: #{render_error_message(message, Map.get(error, :vars, []))}"

      %{message: message} = error ->
        render_error_message(message, Map.get(error, :vars, []))

      _ ->
        "validation error"
    end)
  end

  defp format_password_error(%Ecto.Changeset{} = changeset) do
    changeset
    |> Map.get(:errors, [])
    |> Enum.map_join("; ", fn {field, {msg, opts}} ->
      "#{field}: #{render_error_message(msg, opts)}"
    end)
  end

  defp format_password_error(_other), do: "unexpected error"

  defp render_error_message(message, vars) when is_binary(message) do
    Regex.replace(~r"%{(\w+)}", message, fn _, key ->
      vars
      |> keyword_get_string(key)
      |> to_string()
    end)
  end

  defp render_error_message(message, _vars), do: to_string(message)

  defp keyword_get_string(vars, key) when is_list(vars) do
    Enum.find_value(vars, key, fn
      {atom_key, value} when is_atom(atom_key) ->
        if Atom.to_string(atom_key) == key, do: value

      {binary_key, value} when is_binary(binary_key) ->
        if binary_key == key, do: value

      _ ->
        nil
    end)
  end

  defp keyword_get_string(_vars, key), do: key

  @doc """
  Logs the user out.
  """
  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
