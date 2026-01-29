defmodule ServiceRadarWebNGWeb.AuthController do
  @moduledoc """
  Controller for authentication callbacks.

  Handles password authentication and SSO callbacks using Guardian for JWT tokens.

  ## Token Storage

  Guardian JWT tokens are stored in the session under the "user_token" key.
  The token can be verified using `ServiceRadarWebNG.Auth.Guardian.verify_token/2`.

  ## Schema Context

  In a single-deployment UI, schema context is implicit from the PostgreSQL search_path
  configured for the instance. No deployment identifier needs to be stored in the session
  or JWT claims.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNGWeb.Auth.Hooks
  alias ServiceRadarWebNGWeb.UserAuth

  plug :fetch_session

  @doc """
  Handles password login form submission.

  Authenticates the user with email and password, then creates a Guardian JWT token.
  """
  def create(conn, %{"user" => %{"email" => email, "password" => password}}) do
    actor = SystemActor.system(:auth_controller)

    case User.authenticate(email, password, actor: actor) do
      {:ok, user} ->
        # Record authentication timestamp for sudo mode
        User.record_authentication(user, actor: actor)

        # Trigger auth hooks
        Hooks.on_user_authenticated(user, %{"method" => "password"})

        conn
        |> put_flash(:info, "Signed in successfully.")
        |> UserAuth.log_in_user(user)

      {:error, _} ->
        conn
        |> put_flash(:error, "Invalid email or password.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  @doc """
  Handles sign out.

  Clears the session and redirects to the home page.
  """
  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Signed out successfully.")
    |> UserAuth.log_out_user()
  end

  @doc """
  Initiates password reset flow.

  Sends a password reset email with a Guardian token.
  """
  def request_reset(conn, %{"user" => %{"email" => email}}) do
    actor = SystemActor.system(:auth_controller)

    # Always show the same message to prevent email enumeration
    case User.get_by_email(email, actor: actor) do
      {:ok, user} ->
        # Generate a password reset token
        case Guardian.create_access_token(user, token_type: "reset", ttl: {1, :hour}) do
          {:ok, token, _claims} ->
            # Send the reset email
            reset_url = url(~p"/auth/password-reset/#{token}")
            ServiceRadarWebNG.Accounts.UserNotifier.deliver_reset_password_instructions(user, reset_url)
            :ok

          {:error, _} ->
            :ok
        end

      {:error, _} ->
        # Don't reveal whether the email exists
        :ok
    end

    conn
    |> put_flash(:info, "If your email is in our system, you will receive instructions to reset your password.")
    |> redirect(to: ~p"/users/log-in")
  end

  @doc """
  Shows the password reset form.

  Verifies the token is valid before showing the form.
  """
  def show_reset_form(conn, %{"token" => token}) do
    case Guardian.verify_token(token, token_type: "reset") do
      {:ok, _user, _claims} ->
        render(conn, :reset_password, token: token)

      {:error, _} ->
        conn
        |> put_flash(:error, "Reset password link is invalid or has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  @doc """
  Handles password reset form submission.

  Updates the user's password and signs them in.
  """
  def reset_password(conn, %{"token" => token, "user" => %{"password" => password, "password_confirmation" => password_confirmation}}) do
    actor = SystemActor.system(:auth_controller)

    with {:ok, user, _claims} <- Guardian.verify_token(token, token_type: "reset"),
         {:ok, user} <- User.change_password(user, %{
           password: password,
           password_confirmation: password_confirmation
         }, actor: actor) do
      conn
      |> put_flash(:info, "Password reset successfully.")
      |> UserAuth.log_in_user(user)
    else
      {:error, %Ash.Error.Invalid{} = error} ->
        errors = Ash.Error.to_error_class(error)
        error_message = errors |> inspect()

        conn
        |> put_flash(:error, "Failed to reset password: #{error_message}")
        |> redirect(to: ~p"/auth/password-reset/#{token}")

      {:error, _} ->
        conn
        |> put_flash(:error, "Reset password link is invalid or has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  @doc """
  Handles user registration form submission.

  Creates a new user with password and signs them in.
  """
  def register(conn, %{"user" => user_params}) do
    actor = SystemActor.system(:auth_controller)

    case User.register_with_password(user_params, actor: actor) do
      {:ok, user} ->
        # Trigger auth hooks
        Hooks.on_user_created(user, :password)

        conn
        |> put_flash(:info, "Account created successfully.")
        |> UserAuth.log_in_user(user)

      {:error, %Ash.Error.Invalid{} = error} ->
        errors = Ash.Error.to_error_class(error)
        error_message = errors |> inspect()

        conn
        |> put_flash(:error, "Failed to create account: #{error_message}")
        |> redirect(to: ~p"/users/register")
    end
  end
end
