defmodule ServiceRadar.Inventory.DeviceCleanupSettingsSeeder do
  @moduledoc """
  Seeds default device cleanup settings on startup and schedules cleanup.
  """

  use ServiceRadar.DelayedSeeder, callback: :seed_defaults

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.{DeviceCleanupSettings, DeviceCleanupWorker}

  def seed_defaults do
    if repo_enabled?() do
      actor = SystemActor.system(:device_cleanup_settings_seeder)
      opts = [actor: actor]

      ensure_settings(opts)
      _ = DeviceCleanupWorker.ensure_scheduled()
    end
  end

  defp ensure_settings(opts) do
    case DeviceCleanupSettings.get_settings(opts) do
      {:ok, %DeviceCleanupSettings{}} ->
        :ok

      {:ok, nil} ->
        create_default(opts)

      {:error, reason} ->
        handle_settings_error(reason, opts)
    end
  end

  defp handle_settings_error(reason, opts) do
    if not_found?(reason) do
      create_default(opts)
    else
      Logger.warning("Failed to load device cleanup settings: #{inspect(reason)}")
    end
  end

  defp create_default(opts) do
    case DeviceCleanupSettings.create_settings(%{}, opts) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to seed device cleanup settings: #{inspect(reason)}")
    end
  end

  defp not_found?(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
  end

  defp not_found?(_), do: false
end
