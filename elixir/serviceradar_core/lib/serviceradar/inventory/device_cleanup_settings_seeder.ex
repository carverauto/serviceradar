defmodule ServiceRadar.Inventory.DeviceCleanupSettingsSeeder do
  @moduledoc """
  Seeds default device cleanup settings on startup and schedules cleanup.
  """

  use GenServer

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.{DeviceCleanupSettings, DeviceCleanupWorker}

  @seed_delay_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :seed, @seed_delay_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:seed, state) do
    seed_defaults()
    {:noreply, state}
  end

  defp seed_defaults do
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
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("Failed to seed device cleanup settings: #{inspect(reason)}")
    end
  end

  defp not_found?(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
  end

  defp not_found?(_), do: false

  defp repo_enabled? do
    Application.get_env(:serviceradar_core, :repo_enabled, true) &&
      is_pid(Process.whereis(ServiceRadar.Repo))
  end
end
