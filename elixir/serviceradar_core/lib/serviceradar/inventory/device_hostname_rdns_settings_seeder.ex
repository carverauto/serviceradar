defmodule ServiceRadar.Inventory.DeviceHostnameRdnsSettingsSeeder do
  @moduledoc """
  Seeds the singleton reverse-DNS hostname settings row on startup.
  """

  use ServiceRadar.DelayedSeeder, callback: :seed_defaults

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.DeviceHostnameRdnsSettings

  require Logger

  def seed_defaults do
    if repo_enabled?() do
      actor = SystemActor.system(:device_hostname_rdns_settings_seeder)
      ensure_settings(actor: actor)
    end
  end

  defp ensure_settings(opts) do
    case DeviceHostnameRdnsSettings.get_settings(opts) do
      {:ok, %DeviceHostnameRdnsSettings{}} ->
        :ok

      {:ok, nil} ->
        create_default(opts)

      {:error, reason} ->
        if not_found?(reason) do
          create_default(opts)
        else
          Logger.warning("Failed to load device hostname rDNS settings: #{inspect(reason)}")
        end
    end
  end

  defp create_default(opts) do
    case DeviceHostnameRdnsSettings.create_settings(%{}, opts) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to seed device hostname rDNS settings: #{inspect(reason)}")
    end
  end

  defp not_found?(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
  end

  defp not_found?(_), do: false
end
