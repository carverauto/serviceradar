defmodule ServiceRadarCoreElx.CameraStorage.Service do
  @moduledoc """
  Isolated storage entry point for the core-elx release's `eval` command.

  This supervisor is never a child of core-elx. It starts no repository,
  recorder, distributed node or provider provisioning client.
  """
  use Supervisor

  alias ServiceRadar.Camera.ArchiveStorageConfig, as: Config
  alias ServiceRadarCoreElx.CameraStorage.ReadRouter
  alias ServiceRadarCoreElx.CameraStorage.ReadSession
  alias ServiceRadarCoreElx.CameraStorage.Router
  alias ServiceRadarCoreElx.CameraStorage.Session

  def main do
    Logger.configure(level: :none)

    with :ok <- isolated(),
         {:ok, _} <- Application.ensure_all_started(:ssl),
         {:ok, config} <- Config.load(System.get_env("VMS_INIT_STORAGE_CONFIG")),
         {:ok, _pid} <- start_link(config) do
      IO.puts(~s({"status":"listening","recording_readiness":"unavailable","archive_readiness":"unavailable"}))
      Process.sleep(:infinity)
    else
      _ ->
        IO.puts(~s({"status":"unavailable","reason":"isolated_storage_startup_failed"}))
        System.halt(1)
    end
  end

  def start_link(config) do
    with :ok <- isolated(),
         {:ok, _} <- Application.ensure_all_started(:req),
         {:ok, _} <- Application.ensure_all_started(:bandit) do
      Supervisor.start_link(__MODULE__, config, name: __MODULE__)
    end
  end

  def main_read do
    Logger.configure(level: :none)

    with :ok <- isolated(),
         {:ok, _} <- Application.ensure_all_started(:ssl),
         {:ok, config} <- Config.load_read_storage(System.get_env("VMS_ARCHIVE_READ_STORAGE_CONFIG")),
         {:ok, _pid} <- start_read_link(config) do
      IO.puts(~s({"status":"listening","archive_readiness":"unavailable"}))
      Process.sleep(:infinity)
    else
      _ ->
        IO.puts(~s({"status":"unavailable","reason":"isolated_archive_read_startup_failed"}))
        System.halt(1)
    end
  end

  def start_read_link(config) do
    with :ok <- isolated(),
         {:ok, _} <- Application.ensure_all_started(:req),
         {:ok, _} <- Application.ensure_all_started(:bandit) do
      Supervisor.start_link(__MODULE__, {:read, config}, name: ServiceRadarCoreElx.CameraStorage.ReadService)
    end
  end

  @impl true
  def init({:read, config}) do
    Supervisor.init(
      [
        {Task.Supervisor, name: ServiceRadarCoreElx.CameraStorage.ReadTasks},
        {ReadSession, config},
        {ReadRouter, config.listener}
      ],
      strategy: :one_for_all
    )
  end

  def init(config) do
    limits = Map.new(config.purposes, fn {kind, desired} -> {kind, desired.limits["max_operation_ms"]} end)

    children = [
      {Task.Supervisor, name: ServiceRadarCoreElx.CameraStorage.Tasks},
      {Session, config},
      {Router, Map.put(config.listener, :operation_limits, limits)}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp isolated do
    started = Enum.map(Application.started_applications(), &elem(&1, 0))

    core_running? =
      Enum.any?(
        [ServiceRadar.Supervisor, ServiceRadarCoreElx.Supervisor, ServiceRadarCoreElx.CameraRecording.Supervisor],
        &(Process.whereis(&1) != nil)
      )

    if Node.alive?() or core_running? or Enum.any?([:serviceradar_core, :serviceradar_core_elx], &(&1 in started)) do
      {:error, :storage_isolation_required}
    else
      :ok
    end
  end
end
