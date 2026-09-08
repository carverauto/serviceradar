defmodule ServiceRadarWebNGWeb.Auth.LoginPolicy do
  @moduledoc """
  Server-side decision point for whether a password-authenticated user may complete
  a local (password) login, versus being required to sign in via SSO.

  This is the single authoritative gate. It is evaluated in the controller **after**
  `ServiceRadar.Identity.User.authenticate/3` has already verified the bcrypt hash, so
  timing is uniform and the deny path is not an account-enumeration oracle.

  ## Decision order (see `local_login_allowed?/2`)

  1. Break-glass env switch active -> allow. This is a **permit**, not a bypass: a
     valid password was still required for `authenticate` to succeed. It needs no
     database read and no IdP, so it recovers a deployment with broken AuthSettings.
  2. Account has no password hash -> deny (SSO-only account).
  3. Effective auth mode is `password_only` -> allow.
  4. Account's `local_login_enabled` flag is true -> allow.
  5. Otherwise -> deny.

  ## Fail-closed settings resolution

  `settings` is the resolved `AuthSettings` struct/map, or `nil` when it could not be
  resolved. A `nil` settings value does **not** match step 3, so only the per-account
  flag or the env break-glass can permit local login. Callers MUST resolve settings via
  the full config (e.g. `ConfigCache.get_settings/0`) and pass `nil` on error — they
  MUST NOT use a `:password_only`-on-error default (e.g. `ConfigCache.get_mode/0`),
  which would silently downgrade SSO-enforced deployments to "accept all".
  """

  @app :serviceradar_web_ng

  @doc """
  Returns `true` if the (already password-verified) `user` may complete a local login
  under the resolved `settings`, `false` otherwise. See the moduledoc for the order.
  """
  @spec local_login_allowed?(map() | struct(), map() | struct() | nil) :: boolean()
  def local_login_allowed?(user, settings) do
    cond do
      force_local_login?() -> true
      is_nil(hashed_password(user)) -> false
      password_only?(settings) -> true
      local_login_enabled?(user) -> true
      true -> false
    end
  end

  @doc """
  Returns whether public password recovery is valid for this current account.

  Recovery never creates a local credential for an SSO-provisioned identity.
  Unlike interactive break-glass login, the environment override is not a
  recovery authority. The account must already have a password and must be
  locally eligible under the persisted account/settings policy.
  """
  @spec password_recovery_allowed?(map() | struct(), map() | struct() | nil) :: boolean()
  def password_recovery_allowed?(user, settings) do
    not is_nil(hashed_password(user)) and
      (password_only?(settings) or local_login_enabled?(user))
  end

  @doc """
  Whether the break-glass env switch (`SERVICERADAR_AUTH_FORCE_LOCAL_LOGIN`) is active.

  When active, local login is permitted (still requires a valid password) and the
  sign-in form is always rendered.
  """
  @spec force_local_login?() :: boolean()
  def force_local_login?, do: auth_config(:force_local_login, false) == true

  @doc """
  Whether the SSO button should be hidden (`SERVICERADAR_AUTH_DISABLE_SSO`).
  """
  @spec disable_sso?() :: boolean()
  def disable_sso?, do: auth_config(:disable_sso, false) == true

  @doc """
  Path to send a denied local login toward. In an active SSO mode this is the SSO
  entry; otherwise it falls back to the main sign-in page.
  """
  @spec sso_entry_path(map() | struct() | nil) :: String.t()
  def sso_entry_path(settings) do
    if sso_mode?(settings) and not disable_sso?() do
      "/auth/oidc"
    else
      "/users/log-in"
    end
  end

  # Effective mode is password_only when SSO is disabled OR mode is password_only.
  defp password_only?(%{is_enabled: false}), do: true
  defp password_only?(%{mode: :password_only}), do: true
  defp password_only?(_), do: false

  defp sso_mode?(%{is_enabled: true, mode: mode}) when mode in [:active_sso, :passive_proxy], do: true
  defp sso_mode?(_), do: false

  defp hashed_password(%{hashed_password: hashed_password}), do: hashed_password
  defp hashed_password(_), do: nil

  defp local_login_enabled?(%{local_login_enabled: true}), do: true
  defp local_login_enabled?(_), do: false

  defp auth_config(key, default) do
    @app
    |> Application.get_env(:auth, [])
    |> Keyword.get(key, default)
  end
end
