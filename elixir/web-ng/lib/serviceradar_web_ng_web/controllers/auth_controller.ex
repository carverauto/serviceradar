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

  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.Users
  alias ServiceRadar.Security.Lockouts
  alias ServiceRadarWebNG.Audit.UserAuthEvents
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.Auth.Hooks
  alias ServiceRadarWebNGWeb.Auth.ConfigCache
  alias ServiceRadarWebNGWeb.Auth.LoginPolicy
  alias ServiceRadarWebNGWeb.AuthURL
  alias ServiceRadarWebNGWeb.ClientIP
  alias ServiceRadarWebNGWeb.UserAuth

  # Shown on a server-side local-login deny. Intentionally generic so it is not an
  # account-enumeration oracle (the bcrypt verify already ran before this point).
  require Logger

  @sso_required_flash "This account must sign in via your organization's SSO."

  plug :fetch_session

  @doc """
  Shows the password reset request form.

  This lets tenant users initiate account recovery without any control-plane
  backdoor or operator involvement.
  """
  def new_reset_request(conn, _params) do
    render(conn, :request_reset)
  end

  @doc """
  Handles password login form submission.

  Authenticates the user with email and password, then creates a Guardian JWT token.
  """
  def create(conn, %{"user" => %{"email" => email, "password" => password}}) do
    # Rate limiting + lockout short-circuit happen at the
    # `:rate_limit_auth_local` pipeline (router.ex). By the time we
    # reach the controller the actor is unlocked and the IP is under
    # its window — we only need to do the credential check.
    actor = SystemActor.system(:auth_controller)

    case User.authenticate(email, password, actor: actor) do
      {:ok, user} ->
        # Credentials are valid; the bcrypt verify already ran. Now enforce
        # local-login-vs-SSO server-side (fail closed) before creating a session.
        case enforce_local_login(user) do
          {:allow, _settings} ->
            case record_successful_auth(conn, user, :password, break_glass?: LoginPolicy.force_local_login?()) do
              {:ok, user} ->
                conn
                |> put_flash(:info, "Signed in successfully.")
                |> UserAuth.log_in_user(user)

              {:error, reason} ->
                login_recording_failed(conn, user, reason, ~p"/users/log-in")
            end

          {:deny, settings} ->
            deny_local_login(conn, user.email, settings)
        end

      {:error, _} ->
        Lockouts.record_failed_login(email, %{
          ip: ClientIP.get(conn),
          route: conn.request_path,
          method: "password"
        })

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
  Handles local admin sign-in with rate limiting.

  This is the "backdoor" for administrators when SSO/proxy auth is primary.
  Rate limited to 5 attempts per minute per IP.
  """
  def local_sign_in(conn, %{"user" => %{"email" => email, "password" => password}}) do
    # Rate limiting + lockout short-circuit happen at the
    # `:rate_limit_auth_local` pipeline (router.ex).
    client_ip = ClientIP.get(conn)
    actor = SystemActor.system(:auth_controller)

    case User.authenticate(email, password, actor: actor) do
      {:ok, user} ->
        # The /auth/local backdoor must honor the same server-side policy as the
        # main login — a valid password is not sufficient when SSO is enforced.
        case enforce_local_login(user) do
          {:allow, _settings} ->
            Logger.info("Successful local admin login for #{email} from IP: #{client_ip}")

            case record_successful_auth(conn, user, :password,
                   hook_method: "local_password",
                   break_glass?: LoginPolicy.force_local_login?()
                 ) do
              {:ok, user} ->
                conn
                |> put_flash(:info, "Signed in successfully.")
                |> UserAuth.log_in_user(user)

              {:error, reason} ->
                login_recording_failed(conn, user, reason, ~p"/auth/local")
            end

          {:deny, settings} ->
            Logger.warning("Local admin login denied by policy (SSO-enforced) for #{email} from IP: #{client_ip}")

            deny_local_login(conn, user.email, settings)
        end

      {:error, _} ->
        Logger.warning("Failed local admin login attempt for #{email} from IP: #{client_ip}")

        Lockouts.record_failed_login(email, %{
          ip: client_ip,
          route: conn.request_path,
          method: "local_password"
        })

        conn
        |> put_flash(:error, "Invalid email or password.")
        |> redirect(to: ~p"/auth/local")
    end
  end

  @doc """
  Initiates password reset flow.

  Sends a password reset email with a Guardian token.
  """
  def request_reset(conn, %{"user" => %{"email" => email}}) do
    # Rate limiting happens at the `:rate_limit_password_reset`
    # pipeline (router.ex).
    actor = SystemActor.system(:auth_controller)

    # Always show the same message to prevent email enumeration.
    :ok = maybe_send_password_reset(email, actor)

    conn
    |> put_flash(
      :info,
      "If your email is in our system, you will receive instructions to reset your password."
    )
    |> redirect(to: ~p"/users/log-in")
  end

  defp maybe_send_password_reset(email, actor) do
    with {:ok, user} <- User.get_by_email(email, actor: actor),
         :ok <- enforce_password_recovery(user),
         {:ok, token, _claims} <-
           Guardian.create_access_token(user, token_type: "reset", ttl: {1, :hour}) do
      reset_url = AuthURL.password_reset_url(token)

      ServiceRadarWebNG.Accounts.UserNotifier.deliver_reset_password_instructions(
        user,
        reset_url
      )
    end

    :ok
  end

  defp enforce_password_recovery(user) do
    settings =
      case ConfigCache.get_settings() do
        {:ok, settings} -> settings
        {:error, _reason} -> nil
      end

    if LoginPolicy.password_recovery_allowed?(user, settings),
      do: :ok,
      else: {:error, :password_recovery_denied}
  end

  # Resolves AuthSettings (fail closed on error) and applies the server-side
  # local-login policy. Returns `{:allow, settings}` or `{:deny, settings}`.
  defp enforce_local_login(user) do
    settings =
      case ConfigCache.get_settings() do
        {:ok, settings} -> settings
        # Fail closed: do NOT fall back to a password_only default on error. With
        # nil settings only the per-account flag or the env break-glass can permit.
        {:error, _} -> nil
      end

    if LoginPolicy.local_login_allowed?(user, settings) do
      {:allow, settings}
    else
      {:deny, settings}
    end
  end

  # Generic deny: no session, generic flash (no enumeration oracle), redirect toward
  # the SSO entry. The bcrypt verify already ran, so timing is uniform.
  defp deny_local_login(conn, email, settings) do
    Logger.info("Local login denied by policy (SSO-enforced) for #{email}")

    conn
    |> put_flash(:error, @sso_required_flash)
    |> redirect(to: LoginPolicy.sso_entry_path(settings))
  end

  # Persist the authentication method before creating a browser session. In
  # particular, a password login must immediately replace a historical OIDC or
  # SAML value so downstream authorization cannot mistake it for the current
  # authentication method. Hooks and audit enrichment remain best-effort async
  # work after that security-relevant write succeeds.
  defp record_successful_auth(conn, user, auth_method, opts) do
    hook_method = Keyword.get(opts, :hook_method, Atom.to_string(auth_method))
    break_glass? = Keyword.get(opts, :break_glass?, false)
    ip = ClientIP.get(conn)
    user_agent = conn |> Plug.Conn.get_req_header("user-agent") |> List.first()
    actor = SystemActor.system(:auth_controller)

    with {:ok, user} <- Users.record_login(user, auth_method, actor: actor) do
      task = fn ->
        _ = User.record_authentication(user, actor: actor)
        _ = Hooks.on_user_authenticated(user, %{"method" => hook_method})
        _ = UserAuthEvents.record_login_context(user, auth_method, ip, user_agent)

        if break_glass? do
          Logger.warning(
            "[break-glass] Local login permitted by SERVICERADAR_AUTH_FORCE_LOCAL_LOGIN " <>
              "for #{user.email} from IP: #{ip}"
          )

          _ = UserAuthEvents.record_login_context(user, :break_glass_local_login, ip, user_agent)
        end

        :ok
      end

      case Task.Supervisor.start_child(ServiceRadarWebNG.TaskSupervisor, task) do
        {:ok, _pid} -> :ok
        {:error, reason} -> Logger.warning("Unable to start auth audit task: #{inspect(reason)}")
      end

      {:ok, user}
    end
  end

  defp login_recording_failed(conn, user, reason, redirect_path) do
    Logger.error(
      "Refusing login because the authentication method could not be persisted " <>
        "for user_id=#{user.id}: #{inspect(reason)}"
    )

    conn
    |> put_flash(:error, "Unable to sign in. Please try again.")
    |> redirect(to: redirect_path)
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
  def reset_password(conn, %{
        "token" => token,
        "user" => %{"password" => password, "password_confirmation" => password_confirmation}
      }) do
    actor = SystemActor.system(:auth_controller)

    with :ok <- validate_reset_password_confirmation(password, password_confirmation),
         {:ok, user, _claims} <- Guardian.verify_token(token, token_type: "reset"),
         :ok <- enforce_password_recovery(user),
         {:ok, user} <-
           user
           |> Ash.Changeset.for_update(
             :admin_set_password,
             %{password: password},
             actor: actor
           )
           |> Ash.update(),
         {:ok, user} <-
           record_successful_auth(conn, user, :password,
             hook_method: "password_reset",
             break_glass?: false
           ) do
      conn
      |> put_flash(:info, "Password reset successfully.")
      |> UserAuth.log_in_user(user)
    else
      {:error, %Invalid{} = error} ->
        errors = Ash.Error.to_error_class(error)
        error_message = inspect(errors)

        conn
        |> put_flash(:error, "Failed to reset password: #{error_message}")
        |> redirect(to: ~p"/auth/password-reset/#{token}")

      {:error, _} ->
        conn
        |> put_flash(:error, "Reset password link is invalid or has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  defp validate_reset_password_confirmation(password, password_confirmation) when password == password_confirmation,
    do: :ok

  defp validate_reset_password_confirmation(_password, _password_confirmation) do
    {:error, :password_confirmation_mismatch}
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

      {:error, %Invalid{} = error} ->
        errors = Ash.Error.to_error_class(error)
        error_message = inspect(errors)

        conn
        |> put_flash(:error, "Failed to create account: #{error_message}")
        |> redirect(to: ~p"/users/log-in")
    end
  end
end
