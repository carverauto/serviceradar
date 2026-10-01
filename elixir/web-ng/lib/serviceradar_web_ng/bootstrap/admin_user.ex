defmodule ServiceRadarWebNG.Bootstrap.AdminUser do
  @moduledoc """
  Bootstraps the default admin user for self-hosted deployments.

  Reads admin credentials from environment or a mounted file and creates
  the admin user once if no admin exists.

  Operator configuration is documented in `docs/docs/auth-configuration.md`
  under Bootstrap Admin Access. `ServiceRadar.Identity.AdminSecretMarker`
  documents the fingerprint safety contract used for rotation tracking.
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
    result =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ["bootstrap_admin_user"])

        user =
          User
          |> Ash.Query.for_read(:by_email, %{email: email}, authorize?: false)
          |> Ash.Query.lock(:for_update)
          |> Ash.read_one!()

        bootstrap_admin(user, email, password)
      end)

    case result do
      {:ok, notifications} ->
        Ash.Notifier.notify(notifications)
        :ok

      {:error, error} ->
        Logger.error("[bootstrap] Failed to bootstrap admin user: #{inspect(error)}")
        :error
    end
  end

  defp bootstrap_admin(user, email, password) do
    case user do
      %User{} = user ->
        maybe_sync_admin_password(user, password)

      nil ->
        if admin_exists?() do
          Logger.info("[bootstrap] Admin user already present; skipping #{email}")
          []
        else
          create_admin_user(email, password)
        end
    end
  end

  defp maybe_sync_admin_password(%User{email: email} = user, password) do
    cond do
      not force_password_sync?() ->
        Logger.info("[bootstrap] Admin user #{email} already exists; skipping")
        []

      Users.valid_password?(user, password) ->
        Logger.info("[bootstrap] Admin user #{email} already exists and password matches; skipping")

        # Refresh the marker so a later rotation of this same secret is still
        # detected (also self-heals deployments that predate the marker).
        record_applied_secret(email, password)
        []

      secret_rotated_since_last_apply?(email, password) ->
        reset_admin_password(user, password)

      true ->
        Logger.info(
          "[bootstrap] Admin user #{email} password was changed outside the secret and " <>
            "the secret is unchanged; keeping the operator-set password"
        )

        []
    end
  end

  defp reset_admin_password(%User{email: email} = user, password) do
    actor = SystemActor.system(:bootstrap)

    with {:ok, _updated_user, notifications} <-
           User.admin_set_password(user, %{password: password}, actor: actor, return_notifications?: true),
         :ok <- record_applied_secret(email, password) do
      Logger.warning(
        "[bootstrap] Admin user #{email} password reset from " <>
          "SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC=true (bootstrap secret rotated)"
      )

      notifications
    else
      error -> Repo.rollback(error)
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

    with {:ok, user, created_notifications} <-
           User.register_with_password(
             %{
               email: email,
               display_name: @default_display_name,
               password: password,
               password_confirmation: password
             },
             actor: actor,
             authorize?: true,
             return_notifications?: true
           ),
         {:ok, user, role_notifications} <- ensure_admin_role(user, actor),
         {:ok, _, confirmed_notifications} <-
           user
           |> Ash.Changeset.for_update(:update, %{}, actor: actor)
           |> Ash.Changeset.force_change_attribute(:confirmed_at, DateTime.truncate(DateTime.utc_now(), :second))
           |> Ash.update(return_notifications?: true),
         :ok <- record_applied_secret(email, password) do
      Logger.info("[bootstrap] Created admin user #{email}")
      created_notifications ++ role_notifications ++ confirmed_notifications
    else
      error ->
        Logger.error("[bootstrap] Failed to create admin user: #{inspect(error)}")
        Repo.rollback(error)
    end
  end

  defp ensure_admin_role(%User{role: :admin} = user, _actor), do: {:ok, user, []}

  defp ensure_admin_role(user, actor) do
    User.update_role(user, %{role: :admin}, actor: actor, return_notifications?: true)
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
