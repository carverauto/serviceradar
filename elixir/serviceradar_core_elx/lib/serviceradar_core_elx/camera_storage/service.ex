defmodule ServiceRadarCoreElx.CameraStorage.Service do
  @moduledoc """
  Isolated storage entry point for the core-elx release's `eval` command.

  This supervisor is never a child of core-elx. It starts no repository,
  recorder, distributed node or provider provisioning client.
  """
  use Supervisor

  alias ServiceRadar.Camera.ArchiveAuthorityConfig
  alias ServiceRadar.Camera.ArchiveStorageConfig, as: Config
  alias ServiceRadarCoreElx.CameraStorage.LongshoreSession
  alias ServiceRadarCoreElx.CameraStorage.ReadLongshoreSession
  alias ServiceRadarCoreElx.CameraStorage.ReadRouter
  alias ServiceRadarCoreElx.CameraStorage.ReadSession
  alias ServiceRadarCoreElx.CameraStorage.Router
  alias ServiceRadarCoreElx.CameraStorage.Session
  alias ServiceRadarObjectStorage.Session, as: ObjectStorageSession

  @read_buffer_bytes 4_194_304

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
         :ok <- validate_provider(config.provider),
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
         :ok <- validate_provider(config.provider),
         {:ok, _} <- Application.ensure_all_started(:req),
         {:ok, _} <- Application.ensure_all_started(:bandit) do
      Supervisor.start_link(__MODULE__, {:read, config}, name: ServiceRadarCoreElx.CameraStorage.ReadService)
    end
  end

  @impl true
  def init({:read, config}) do
    {longshore_children, config} =
      longshore_children(config, @read_buffer_bytes, ReadLongshoreSession)

    children =
      longshore_children ++
        [
          {Task.Supervisor, name: ServiceRadarCoreElx.CameraStorage.ReadTasks},
          {ReadSession, config},
          {ReadRouter, config.listener}
        ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  def init(config) do
    limits = Map.new(config.purposes, fn {kind, desired} -> {kind, desired.limits["max_operation_ms"]} end)
    buffer_bytes = writer_buffer_bytes(config.purposes)
    {longshore_children, config} = longshore_children(config, buffer_bytes, LongshoreSession)

    children =
      longshore_children ++
        [
          {Task.Supervisor, name: ServiceRadarCoreElx.CameraStorage.Tasks},
          {Session, config},
          {Router, Map.put(config.listener, :operation_limits, limits)}
        ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp longshore_children(config, buffer_bytes, session_name) do
    case Map.get(config.provider, :transport, :http) do
      :longshore ->
        {:ok, ls_config} = build_longshore_config(config.provider, buffer_bytes)
        child = {ObjectStorageSession, [config: ls_config, name: session_name]}
        provider = Map.put(config.provider, :longshore_session, session_name)
        {[child], %{config | provider: provider}}

      :http ->
        {[], config}
    end
  end

  defp writer_buffer_bytes(purposes) do
    purposes
    |> Enum.map(fn {kind, desired} -> ArchiveAuthorityConfig.byte_limit(kind, desired.limits) end)
    |> Enum.max()
    |> max(8192)
    |> min(16_777_216)
  end

  defp validate_provider(provider) when is_map(provider) do
    case Map.get(provider, :transport, :http) do
      :http ->
        :ok

      :longshore ->
        with :ok <- validate_longshore_proxy(provider),
             :ok <- validate_longshore_trust(provider),
             {:ok, _} <- build_longshore_config(provider, @read_buffer_bytes) do
          :ok
        end

      _ ->
        {:error, :invalid_provider_transport}
    end
  end

  defp validate_provider(_), do: {:error, :invalid_provider_transport}

  defp validate_longshore_proxy(%{proxy: nil}), do: :ok
  defp validate_longshore_proxy(_), do: {:error, :unsupported_provider_proxy}

  defp validate_longshore_trust(provider) do
    case Map.fetch(provider, :longshore_loopback_peer) do
      {:ok, {ip, port}} when is_binary(ip) and is_integer(port) and port in 1..65_535 ->
        :ok

      {:ok, _} ->
        {:error, :invalid_longshore_loopback_peer}

      :error ->
        if Map.get(provider, :cacerts) == :public_key.cacerts_get() do
          :ok
        else
          {:error, :unsupported_provider_cacerts}
        end
    end
  end

  defp build_longshore_config(provider, buffer_size) do
    destination = provider.destination
    credential = provider.credential

    with {:ok, host, port, tls} <- longshore_target(provider, destination),
         bucket when is_binary(bucket) and bucket != "" <- destination["bucket"],
         region when is_binary(region) and region != "" <- destination["region"],
         access_key when is_binary(access_key) and access_key != "" <- credential["access_key_id"],
         secret_key when is_binary(secret_key) and secret_key != "" <- credential["secret_access_key"] do
      {:ok,
       %{
         host: host,
         port: port,
         region: region,
         bucket: bucket,
         access_key: access_key,
         secret_key: secret_key,
         session_token: nil,
         tls: tls,
         concurrency: 1,
         buffer_size: buffer_size
       }}
    else
      _ -> {:error, :invalid_longshore_configuration}
    end
  end

  defp longshore_target(provider, destination) do
    case Map.fetch(provider, :longshore_loopback_peer) do
      {:ok, {ip, port}} when is_binary(ip) and is_integer(port) and port in 1..65_535 ->
        {:ok, ip, port, false}

      :error ->
        longshore_https_target(destination["endpoint"])

      _ ->
        {:error, :invalid_longshore_loopback_peer}
    end
  end

  defp longshore_https_target(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: "https", host: host, port: port, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) and host != "" and is_integer(port) and port in 1..65_535 ->
        {:ok, host, port, true}

      _ ->
        {:error, :invalid_longshore_endpoint}
    end
  end

  defp longshore_https_target(_), do: {:error, :invalid_longshore_endpoint}

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
