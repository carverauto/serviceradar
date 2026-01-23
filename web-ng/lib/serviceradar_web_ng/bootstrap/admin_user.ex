defmodule ServiceRadarWebNG.Bootstrap.AdminUser do
  @moduledoc """
  Bootstraps the default admin user for self-hosted deployments.

  Reads admin credentials from environment or a mounted file and creates
  the admin user once if no admin exists.
  """

  require Logger
  require Ash.Query

  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.Users

  @default_email "root@localhost"
  @default_display_name "admin"

  def ensure_admin_user do
    try do
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
  end

  defp maybe_bootstrap_admin(email, password) do
    case Users.get_by_email(email, authorize?: false) do
      %User{} ->
        Logger.info("[bootstrap] Admin user #{email} already exists; skipping")
        :ok

      nil ->
        if admin_exists?() do
          Logger.info("[bootstrap] Admin user already present; skipping #{email}")
          :ok
        else
          create_admin_user(email, password)
        end
    end
  end

  defp create_admin_user(email, password) do
    actor = system_actor()

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
    System.get_env("SERVICERADAR_ADMIN_EMAIL")
    |> blank_to_nil()
    |> Kernel.||(@default_email)
  end

  defp admin_password do
    case System.get_env("SERVICERADAR_ADMIN_PASSWORD") |> blank_to_nil() do
      nil ->
        System.get_env("SERVICERADAR_ADMIN_PASSWORD_FILE")
        |> blank_to_nil()
        |> read_password_file()

      password ->
        password
    end
  end

  defp read_password_file(nil), do: nil

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

  defp system_actor do
    %{
      id: "bootstrap",
      email: "system@serviceradar.local",
      role: :system
    }
  end
end
