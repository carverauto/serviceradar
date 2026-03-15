defmodule ServiceRadar.Identity.RoleProfileSeeder do
  @moduledoc """
  Seeds built-in role profiles and keeps them in sync with the RBAC catalog.
  """

  use ServiceRadar.DelayedSeeder

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.RBAC.Catalog
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Repo

  def seed do
    if role_profiles_table_exists?() do
      actor = SystemActor.system(:role_profile_seeder)
      opts = [actor: actor]

      Catalog.system_profiles()
      |> Enum.each(fn profile ->
        ensure_profile(profile, opts)
      end)
    else
      Logger.warning("Skipping role profile seed: platform.role_profiles table missing")
      :ok
    end
  end

  defp role_profiles_table_exists? do
    case Ecto.Adapters.SQL.query(Repo, "SELECT to_regclass('platform.role_profiles')", []) do
      {:ok, %{rows: [[value]]}} when not is_nil(value) -> true
      _ -> false
    end
  end

  defp ensure_profile(
         %{system_name: system_name, name: name, description: description, role: role},
         opts
       ) do
    permissions = Catalog.permissions_for_role(role)

    attrs = %{
      system_name: system_name,
      name: name,
      description: description,
      permissions: permissions
    }

    case RoleProfile.get_by_system_name(system_name, opts) do
      {:ok, nil} ->
        create_profile(attrs, opts)

      {:ok, profile} ->
        maybe_update_profile(profile, attrs, opts)

      {:error, reason} ->
        Logger.warning("Failed to load role profile #{system_name}: #{inspect(reason)}")
        :ok
    end
  end

  defp create_profile(attrs, opts) do
    case RoleProfile.create_system_profile(attrs, opts) do
      {:ok, _profile} ->
        Logger.info("Created role profile #{attrs.system_name}")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to create role profile #{attrs.system_name}: #{inspect(reason)}")
        :ok
    end
  end

  defp maybe_update_profile(profile, attrs, opts) do
    update_attrs = Map.take(attrs, [:name, :description, :permissions])

    if profile.permissions != update_attrs.permissions or profile.name != update_attrs.name or
         profile.description != update_attrs.description do
      case RoleProfile.update_profile(profile, update_attrs, opts) do
        {:ok, _profile} ->
          Logger.info("Updated role profile #{attrs.system_name}")
          :ok

        {:error, reason} ->
          Logger.warning("Failed to update role profile #{attrs.system_name}: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end
end
