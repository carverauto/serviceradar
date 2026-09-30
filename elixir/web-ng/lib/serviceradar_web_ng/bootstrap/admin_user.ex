defmodule ServiceRadarWebNG.Bootstrap.AdminUser do
  @moduledoc """
  Bootstraps the default admin user for self-hosted deployments.

  Reads admin credentials from environment or a mounted file and creates
  the admin user once if no admin exists.

  When the operator opts in via `SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC`,
  the secret stays authoritative for ROTATION only: bootstrap compares the
  stored password against the secret and the secret against the fingerprint it
  last applied (`ServiceRadar.Identity.AdminSecretMarker`). The stored
  hash is reset only when the secret itself rotated since the last apply;
  a password the operator set through the UI or a reset flow survives
  restarts and upgrades instead of silently reverting on every boot.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AdminSecretMarker
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.Users
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @default_email "root@localhost"
  @default_display_name "admin"

  def ensure_admin_user do
    case admin_password() do
      nil ->
        Logger.warning("[bootstrap] Admin password not set; skipping admin user bootstrap")
        :ok

      password ->
        email = admin_email()
        maybe_bootstrap_admin(email, password)
    end
  rescue
    error ->
      Logger.error("[bootstrap] Admin user bootstrap failed: #{Exception.message(error)}")
      :error
  end

  defp maybe_bootstrap_admin(email, password) do
    case Users.get_by_email(email, authorize?: false) do
      %User{} = user ->
        maybe_sync_admin_password(user, password)

      nil ->
        if admin_exists?() do
          Logger.info("[bootstrap] Admin user already present; skipping #{email}")
          :ok
        else
          create_admin_user(email, password)
        end
    end
  end

  defp maybe_sync_admin_password(%User{email: email} = user, password) do
    cond do
      not force_password_sync?() ->
        Logger.info("[bootstrap] Admin user #{email} already exists; skipping")
        :ok

      Users.valid_password?(user, password) ->
        Logger.info("[bootstrap] Admin user #{email} already exists and password matches; skipping")

        # Refresh the marker so a later rotation of this same secret is still
        # detected (also self-heals deployments that predate the marker).
        record_applied_secret(email, password)
        :ok

      secret_rotated_since_last_apply?(email, password) ->
        reset_admin_password(user, password)

      true ->
        Logger.info(
          "[bootstrap] Admin user #{email} password was changed outside the secret and " <>
            "the secret is unchanged; keeping the operator-set password"
        )

        :ok
    end
  end

  defp reset_admin_password(%User{email: email} = user, password) do
    actor = SystemActor.system(:bootstrap)

    result =
      Repo.transaction(fn ->
        with {:ok, _updated_user, notifications} <-
               User.admin_set_password(user, %{password: password}, actor: actor, return_notifications?: true),
             :ok <- record_applied_secret(email, password) do
          notifications
        else
          error -> Repo.rollback(error)
        end
      end)

    case result do
      {:ok, notifications} ->
        Ash.Notifier.notify(notifications)

        Logger.warning(
          "[bootstrap] Admin user #{email} password reset from " <>
            "SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC=true (bootstrap secret rotated)"
        )

        :ok

      {:error, error} ->
        Logger.error("[bootstrap] Failed to reset admin password: #{inspect(error)}")
        :error
    end
  end

  # Existing installations have no history: remember the current secret without
  # touching the user's password. Only a recorded change authorizes a reset.
  defp secret_rotated_since_last_apply?(email, password) do
    actor = SystemActor.system(:bootstrap)

    case AdminSecretMarker.get_by_admin_email(email, actor: actor, not_found_error?: false) do
      {:ok, %AdminSecretMarker{secret_digest: digest}} ->
        not Bcrypt.verify_pass(marker_digest(password), digest)

      {:ok, nil} ->
        record_applied_secret(email, password)
        false

      {:error, error} ->
        Logger.warning("[bootstrap] Cannot read admin secret marker: #{inspect(error)}")
        false
    end
  end

  defp record_applied_secret(email, password) do
    actor = SystemActor.system(:bootstrap)

    case AdminSecretMarker.record(
           %{admin_email: email, secret_digest: Bcrypt.hash_pwd_salt(marker_digest(password))},
           actor: actor
         ) do
      {:ok, _marker} ->
        :ok

      {:error, error} ->
        Logger.warning("[bootstrap] Failed to record admin secret marker: #{inspect(error)}")
        :error
    end
  end

  # A salted, slow fingerprint survives endpoint key rotation and avoids keeping
  # a cheap password verifier in the database. Prehashing covers the full secret
  # even when it exceeds bcrypt's 72-byte input limit.
  defp marker_digest(password) do
    :sha256
    |> :crypto.hash(password)
    |> Base.encode64()
  end

  defp force_password_sync? do
    case "SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC" |> System.get_env() |> blank_to_nil() do
      nil -> false
      value -> String.downcase(value) in ~w(1 true yes on)
    end
  end

  defp create_admin_user(email, password) do
    actor = SystemActor.system(:bootstrap)

    with {:ok, user} <-
           Users.register_with_password(
             %{
               email: email,
               display_name: @default_display_name,
               password: password,
               password_confirmation: password
             },
             actor: actor,
             authorize?: true
           ),
         {:ok, user} <- ensure_admin_role(user, actor),
         {:ok, _} <- Users.confirm(user, actor: actor) do
      Logger.info("[bootstrap] Created admin user #{email}")
      record_applied_secret(email, password)
      :ok
    else
      {:error, error} ->
        Logger.error("[bootstrap] Failed to create admin user: #{inspect(error)}")
        :error
    end
  end

  defp ensure_admin_role(%User{role: :admin} = user, _actor), do: {:ok, user}

  defp ensure_admin_role(user, actor) do
    Users.update_role(user, :admin, actor: actor)
  end

  defp admin_exists? do
    query =
      User
      |> Ash.Query.for_read(:admins, %{}, authorize?: false)
      |> Ash.Query.limit(1)

    case Ash.read(query) do
      {:ok, %Ash.Page.Keyset{results: results}} -> results != []
      {:ok, results} when is_list(results) -> results != []
      {:error, _} -> false
    end
  end

  defp admin_email do
    "SERVICERADAR_ADMIN_EMAIL"
    |> System.get_env()
    |> blank_to_nil()
    |> Kernel.||(@default_email)
  end

  defp admin_password do
    case "SERVICERADAR_ADMIN_PASSWORD" |> System.get_env() |> blank_to_nil() do
      nil ->
        "SERVICERADAR_ADMIN_PASSWORD_FILE"
        |> System.get_env()
        |> blank_to_nil()
        |> read_password_file()

      password ->
        password
    end
  end

  defp read_password_file(nil), do: nil

  @sobelow_skip ["Traversal.FileModule"]
  defp read_password_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.trim()
        |> blank_to_nil()

      {:error, reason} ->
        Logger.error("[bootstrap] Failed to read admin password file #{path}: #{inspect(reason)}")
        nil
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp blank_to_nil(_), do: nil
end
