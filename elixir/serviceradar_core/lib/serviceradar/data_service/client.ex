defmodule ServiceRadar.DataService.Client do
  @moduledoc """
  gRPC client for the datasvc KV service.

  Used to push configuration to datasvc where Go/Rust services can read it.

  ## Configuration

      config :serviceradar_core, ServiceRadar.DataService.Client,
        host: "datasvc",
        port: 50057,
        ssl: true,
        cert_dir: "/path/to/certs",
        cert_name: "core", # uses core.pem, core-key.pem
        connect_timeout_ms: 5000,
        reconnect_base_ms: 1000,
        reconnect_max_ms: 30000

  ## Environment Variables

  - `DATASVC_HOST` - hostname (default: "datasvc")
  - `DATASVC_PORT` - port (default: 50057)
  - `DATASVC_SSL` - enable SSL/TLS (default: false)
  - `DATASVC_CERT_DIR` - directory containing certs for mTLS
  - `DATASVC_CERT_NAME` - cert name prefix (default: "core", uses core.pem/core-key.pem)
  - `DATASVC_CONNECT_TIMEOUT_MS` - gRPC connect timeout in ms (default: 5000)
  - `DATASVC_RECONNECT_BASE_MS` - base reconnect backoff in ms (default: 1000)
  - `DATASVC_RECONNECT_MAX_MS` - max reconnect backoff in ms (default: 30000)
  - `DATASVC_SERVER_NAME` - TLS server name for SNI (default: "datasvc.serviceradar")

  ## Usage

      # Put a config value
      :ok = ServiceRadar.DataService.Client.put("sync/sources/123", Jason.encode!(config))

      # Get a value
      {:ok, value} = ServiceRadar.DataService.Client.get("sync/sources/123")

      # Delete a value
      :ok = ServiceRadar.DataService.Client.delete("sync/sources/123")
  """

  use GenServer

  require Logger

  @default_host "datasvc"
  @default_port 50_057
  @default_timeout 10_000
  @default_connect_timeout 5_000
  @default_reconnect_base 1_000
  @default_reconnect_max 30_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Put a key-value pair in the KV store.
  """
  @spec put(String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def put(key, value, opts \\ []) do
    GenServer.call(__MODULE__, {:put, key, value, opts}, opts[:timeout] || @default_timeout)
  end

  @doc """
  Get a value from the KV store.
  """
  @spec get(String.t(), keyword()) :: {:ok, binary()} | {:error, :not_found | term()}
  def get(key, opts \\ []) do
    GenServer.call(__MODULE__, {:get, key, opts}, opts[:timeout] || @default_timeout)
  end

  @doc """
  Delete a key from the KV store.
  """
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(key, opts \\ []) do
    GenServer.call(__MODULE__, {:delete, key, opts}, opts[:timeout] || @default_timeout)
  end

  @doc """
  List keys matching a prefix.
  """
  @spec list_keys(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def list_keys(prefix, opts \\ []) do
    GenServer.call(__MODULE__, {:list_keys, prefix, opts}, opts[:timeout] || @default_timeout)
  end

  @doc """
  Put multiple key-value pairs atomically.
  """
  @spec put_many([{String.t(), binary()}], keyword()) :: :ok | {:error, term()}
  def put_many(entries, opts \\ []) do
    GenServer.call(__MODULE__, {:put_many, entries, opts}, opts[:timeout] || @default_timeout)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    config = build_config(opts)

    state = %{
      channel: nil,
      config: config,
      reconnecting: false,
      backoff: ServiceRadar.Backoff.new(base_ms: config.reconnect_base_ms, max_ms: config.reconnect_max_ms),
      connect_task: nil
    }

    # Connect asynchronously
    send(self(), :connect)

    {:ok, state}
  end

  @impl true
  def handle_info(:connect, %{channel: channel} = state) when channel != nil do
    # Already connected, ignore stale :connect message
    {:noreply, %{state | reconnecting: false}}
  end

  def handle_info(:connect, %{connect_task: {_pid, _ref}} = state) do
    {:noreply, state}
  end

  def handle_info(:connect, state) do
    {:noreply, start_connect_task(state)}
  end

  def handle_info({:connect_result, {:ok, channel}}, state) do
    state = clear_connect_task(state)
    Logger.info("Connected to datasvc at #{state.config.host}:#{state.config.port}")

    {:noreply,
     %{
       state
       | channel: channel,
         reconnecting: false,
         backoff: ServiceRadar.Backoff.reset(state.backoff)
     }}
  end

  def handle_info({:connect_result, {:error, reason}}, state) do
    state = clear_connect_task(state)
    {:noreply, schedule_reconnect(state, reason)}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{connect_task: {pid, ref}} = state) do
    state = clear_connect_task(state)
    {:noreply, schedule_reconnect(state, reason)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  # Handle gun connection down - reconnect (only if not already reconnecting)
  def handle_info({:gun_down, _pid, _protocol, _reason, _streams}, %{reconnecting: true} = state) do
    # Already reconnecting, ignore duplicate gun_down events
    {:noreply, state}
  end

  def handle_info({:gun_down, _pid, _protocol, reason, _streams}, state) do
    state = %{state | channel: nil}
    {:noreply, schedule_reconnect(state, reason)}
  end

  # Handle gun connection up
  def handle_info({:gun_up, _pid, _protocol}, state) do
    {:noreply, state}
  end

  # Handle any other gun messages (only if not already reconnecting)
  def handle_info({:gun_error, _pid, _reason}, %{reconnecting: true} = state) do
    # Already reconnecting, ignore duplicate gun_error events
    {:noreply, state}
  end

  def handle_info({:gun_error, _pid, reason}, state) do
    state = %{state | channel: nil}
    {:noreply, schedule_reconnect(state, reason)}
  end

  def handle_info(msg, state) do
    Logger.debug("DataService.Client received unknown message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call({:put, key, value, opts}, _from, state) do
    case ensure_connected(state) do
      {:ok, state} ->
        result = do_put(state.channel, key, value, opts)
        {:reply, result, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:get, key, opts}, _from, state) do
    case ensure_connected(state) do
      {:ok, state} ->
        result = do_get(state.channel, key, opts)
        {:reply, result, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:delete, key, opts}, _from, state) do
    case ensure_connected(state) do
      {:ok, state} ->
        result = do_delete(state.channel, key, opts)
        {:reply, result, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:list_keys, prefix, opts}, _from, state) do
    case ensure_connected(state) do
      {:ok, state} ->
        result = do_list_keys(state.channel, prefix, opts)
        {:reply, result, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:put_many, entries, opts}, _from, state) do
    case ensure_connected(state) do
      {:ok, state} ->
        result = do_put_many(state.channel, entries, opts)
        {:reply, result, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:get_channel, _from, state) do
    case ensure_connected(state) do
      {:ok, state} ->
        {:reply, {:ok, state.channel}, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  # Private helpers

  defp build_config(opts) do
    app_config = Application.get_env(:serviceradar_core, __MODULE__, [])

    %{
      host: opts[:host] || get_env("DATASVC_HOST") || app_config[:host] || @default_host,
      port: opts[:port] || get_env_int("DATASVC_PORT") || app_config[:port] || @default_port,
      ssl: opts[:ssl] || get_env_bool("DATASVC_SSL") || app_config[:ssl] || false,
      cert_dir: opts[:cert_dir] || get_env("DATASVC_CERT_DIR") || app_config[:cert_dir],
      cert_name: opts[:cert_name] || get_env("DATASVC_CERT_NAME") || app_config[:cert_name] || "core",
      connect_timeout_ms:
        opts[:connect_timeout_ms] ||
          get_env_int("DATASVC_CONNECT_TIMEOUT_MS") ||
          app_config[:connect_timeout_ms] ||
          @default_connect_timeout,
      reconnect_base_ms:
        opts[:reconnect_base_ms] ||
          get_env_int("DATASVC_RECONNECT_BASE_MS") ||
          app_config[:reconnect_base_ms] ||
          @default_reconnect_base,
      reconnect_max_ms:
        opts[:reconnect_max_ms] ||
          get_env_int("DATASVC_RECONNECT_MAX_MS") ||
          app_config[:reconnect_max_ms] ||
          @default_reconnect_max,
      server_name:
        opts[:server_name] ||
          get_env("DATASVC_SERVER_NAME") ||
          app_config[:server_name] ||
          "datasvc.serviceradar"
    }
  end

  defp get_env(key) do
    case System.get_env(key) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp get_env_int(key) do
    case System.get_env(key) do
      nil -> nil
      "" -> nil
      value ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> nil
        end
    end
  end

  defp get_env_bool(key) do
    case System.get_env(key) do
      nil -> nil
      value when value in ["true", "1", "yes"] -> true
      _ -> false
    end
  end

  defp connect(config) do
    endpoint = "#{config.host}:#{config.port}"

    cred_opts =
      case {config.ssl, config.cert_dir} do
        {true, cert_dir} when is_binary(cert_dir) ->
          # mTLS with client certificates
          cert_name = config.cert_name
          cert_file = Path.join(cert_dir, "#{cert_name}.pem")
          key_file = Path.join(cert_dir, "#{cert_name}-key.pem")
          ca_file = Path.join(cert_dir, "root.pem")

          Logger.info("Connecting to datasvc with mTLS: cert=#{cert_file}")

          ssl_opts = [
            cacertfile: String.to_charlist(ca_file),
            certfile: String.to_charlist(cert_file),
            keyfile: String.to_charlist(key_file),
            verify: :verify_peer,
            server_name_indication: String.to_charlist(config.server_name)
          ]

          [cred: GRPC.Credential.new(ssl: ssl_opts)]

        {true, _} ->
          # SSL without client certs
          [cred: GRPC.Credential.new(ssl: [])]

        _ ->
          # No SSL
          []
      end

    connect_opts =
      cred_opts
      |> Keyword.put(:adapter_opts, [connect_timeout: config.connect_timeout_ms])

    GRPC.Stub.connect(endpoint, connect_opts)
  end

  defp start_connect_task(state) do
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        send(parent, {:connect_result, connect(state.config)})
      end)

    ref = Process.monitor(pid)
    %{state | connect_task: {pid, ref}}
  end

  defp clear_connect_task(%{connect_task: nil} = state), do: state

  defp clear_connect_task(%{connect_task: {_pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    %{state | connect_task: nil}
  end

  defp schedule_reconnect(state, reason) do
    {delay_ms, backoff} = ServiceRadar.Backoff.next(state.backoff)

    Logger.warning(
      "Failed to connect to datasvc (#{inspect(reason)}), retrying in #{delay_ms}ms..."
    )

    Process.send_after(self(), :connect, delay_ms)
    %{state | reconnecting: true, backoff: backoff}
  end

  defp ensure_connected(%{channel: nil} = state) do
    {:error, {:not_connected, state}}
  end

  defp ensure_connected(state), do: {:ok, state}

  defp do_put(channel, key, value, opts) do
    timeout = opts[:timeout] || @default_timeout
    ttl = opts[:ttl_seconds] || 0

    request = %Proto.PutRequest{
      key: key,
      value: value,
      ttl_seconds: ttl
    }

    case Proto.KVService.Stub.put(channel, request, timeout: timeout) do
      {:ok, _response} ->
        :ok

      {:error, %GRPC.RPCError{} = error} ->
        Logger.error("gRPC error putting key #{key}: #{GRPC.RPCError.message(error)}")
        {:error, error}

      {:error, reason} ->
        Logger.error("Error putting key #{key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_get(channel, key, opts) do
    timeout = opts[:timeout] || @default_timeout

    request = %Proto.GetRequest{key: key}

    case Proto.KVService.Stub.get(channel, request, timeout: timeout) do
      {:ok, %Proto.GetResponse{found: true, value: value}} ->
        {:ok, value}

      {:ok, %Proto.GetResponse{found: false}} ->
        {:error, :not_found}

      {:error, %GRPC.RPCError{} = error} ->
        Logger.error("gRPC error getting key #{key}: #{GRPC.RPCError.message(error)}")
        {:error, error}

      {:error, reason} ->
        Logger.error("Error getting key #{key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_delete(channel, key, opts) do
    timeout = opts[:timeout] || @default_timeout

    request = %Proto.DeleteRequest{key: key}

    case Proto.KVService.Stub.delete(channel, request, timeout: timeout) do
      {:ok, _response} ->
        :ok

      {:error, %GRPC.RPCError{} = error} ->
        Logger.error("gRPC error deleting key #{key}: #{GRPC.RPCError.message(error)}")
        {:error, error}

      {:error, reason} ->
        Logger.error("Error deleting key #{key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_list_keys(channel, prefix, opts) do
    timeout = opts[:timeout] || @default_timeout

    request = %Proto.ListKeysRequest{prefix: prefix}

    case Proto.KVService.Stub.list_keys(channel, request, timeout: timeout) do
      {:ok, %Proto.ListKeysResponse{keys: keys}} ->
        {:ok, keys}

      {:error, %GRPC.RPCError{} = error} ->
        Logger.error(
          "gRPC error listing keys with prefix #{prefix}: #{GRPC.RPCError.message(error)}"
        )

        {:error, error}

      {:error, reason} ->
        Logger.error("Error listing keys with prefix #{prefix}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_put_many(channel, entries, opts) do
    timeout = opts[:timeout] || @default_timeout
    ttl = opts[:ttl_seconds] || 0

    kv_entries =
      Enum.map(entries, fn {key, value} ->
        %Proto.KeyValueEntry{key: key, value: value}
      end)

    request = %Proto.PutManyRequest{
      entries: kv_entries,
      ttl_seconds: ttl
    }

    case Proto.KVService.Stub.put_many(channel, request, timeout: timeout) do
      {:ok, _response} ->
        :ok

      {:error, %GRPC.RPCError{} = error} ->
        Logger.error("gRPC error putting many keys: #{GRPC.RPCError.message(error)}")
        {:error, error}

      {:error, reason} ->
        Logger.error("Error putting many keys: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
