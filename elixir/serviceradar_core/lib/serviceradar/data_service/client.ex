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
  - `DATASVC_SEC_MODE` - security mode: spiffe|mtls|tls|plaintext (optional)
  - `DATASVC_SSL` - enable SSL/TLS (default: false)
  - `DATASVC_CERT_DIR` - directory containing certs for mTLS
  - `DATASVC_SPIFFE_CERT_DIR` - directory containing SPIFFE SVID files (optional)
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

  alias GRPC.Client.Adapters.Gun
  alias Proto.KVService.Stub

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
    safe_call({:put, key, value, opts}, opts[:timeout] || @default_timeout)
  end

  @doc """
  Returns true if the datasvc channel is connected and alive.
  """
  @spec connected?() :: boolean()
  def connected? do
    if safe_call(:connected?, 1_000) do
      true
    else
      false
    end
  end

  @doc """
  Gets the current datasvc gRPC channel from the supervised client.
  """
  @spec get_channel(keyword()) :: {:ok, GRPC.Channel.t()} | {:error, term()}
  def get_channel(opts \\ []) do
    safe_call(:get_channel, opts[:timeout] || @default_timeout)
  end

  @doc """
  Executes fun with an active datasvc gRPC channel.

  Falls back to a direct connection when the supervised client is unavailable.
  """
  @spec with_channel((GRPC.Channel.t() -> result), keyword()) :: result | {:error, term()}
        when result: term()
  def with_channel(fun, opts \\ []) when is_function(fun, 1) do
    timeout = opts[:timeout] || @default_timeout

    case get_channel(timeout: timeout) do
      {:ok, channel} ->
        fun.(channel)

      {:error, reason} ->
        Logger.warning(
          "DataService.Client unavailable for channel request (#{inspect(reason)}), opening direct datasvc connection"
        )

        with_direct_channel(fun, Keyword.put_new(opts, :connect_timeout_ms, timeout))
    end
  end

  @doc """
  Executes fun with a one-off direct datasvc connection.

  Use this for isolated long-lived streaming calls so concurrent callers do not
  contend on the supervised shared connection.
  """
  @spec with_direct_channel((GRPC.Channel.t() -> result), keyword()) :: result | {:error, term()}
        when result: term()
  def with_direct_channel(fun, opts \\ []) when is_function(fun, 1) do
    with {:ok, channel} <- connect(opts) do
      try do
        fun.(channel)
      after
        _ = disconnect_direct_channel(channel)
      end
    end
  end

  @doc """
  Get a value from the KV store.
  """
  @spec get(String.t(), keyword()) :: {:ok, binary()} | {:error, :not_found | term()}
  def get(key, opts \\ []) do
    safe_call({:get, key, opts}, opts[:timeout] || @default_timeout)
  end

  @doc """
  Get a value and revision from the KV store.
  """
  @spec get_with_revision(String.t(), keyword()) ::
          {:ok, binary(), non_neg_integer()} | {:error, :not_found | term()}
  def get_with_revision(key, opts \\ []) do
    safe_call({:get_with_revision, key, opts}, opts[:timeout] || @default_timeout)
  end

  @doc """
  Delete a key from the KV store.
  """
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(key, opts \\ []) do
    safe_call({:delete, key, opts}, opts[:timeout] || @default_timeout)
  end

  @doc """
  List keys matching a prefix.
  """
  @spec list_keys(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def list_keys(prefix, opts \\ []) do
    safe_call({:list_keys, prefix, opts}, opts[:timeout] || @default_timeout)
  end

  @doc """
  Put multiple key-value pairs atomically.
  """
  @spec put_many([{String.t(), binary()}], keyword()) :: :ok | {:error, term()}
  def put_many(entries, opts \\ []) do
    safe_call({:put_many, entries, opts}, opts[:timeout] || @default_timeout)
  end

  @doc """
  Opens a one-off datasvc gRPC channel using the configured runtime settings.
  """
  @spec connect(keyword()) :: {:ok, GRPC.Channel.t()} | {:error, term()}
  def connect(opts \\ []) do
    opts
    |> build_config()
    |> open_direct_channel()
  end

  defp safe_call(msg, timeout) do
    GenServer.call(__MODULE__, msg, timeout)
  catch
    :exit, {:timeout, _} ->
      {:error, :timeout}

    :exit, {:noproc, _} ->
      {:error, :not_started}

    :exit, reason ->
      {:error, {:call_failed, reason}}
  end

  # Server callbacks

  @impl true
  def init(opts) do
    config = build_config(opts)

    state = %{
      channel: nil,
      channel_ref: nil,
      config: config,
      reconnecting: false,
      backoff:
        ServiceRadar.Backoff.new(
          base_ms: config.reconnect_base_ms,
          max_ms: config.reconnect_max_ms
        ),
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
     state
     |> set_channel(channel)
     |> Map.put(:reconnecting, false)
     |> Map.put(:backoff, ServiceRadar.Backoff.reset(state.backoff))}
  end

  def handle_info({:connect_result, {:error, reason}}, state) do
    state = clear_connect_task(state)
    {:noreply, schedule_reconnect(state, reason)}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{connect_task: {pid, ref}} = state) do
    state = clear_connect_task(state)
    {:noreply, schedule_reconnect(state, reason)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{channel_ref: ref} = state) do
    state = clear_channel(state)

    case reason do
      :normal ->
        Logger.debug("Datasvc gRPC connection closed: #{inspect(reason)}")
        {:noreply, reconnect_after_clean_close(state)}

      :shutdown ->
        Logger.debug("Datasvc gRPC connection closed: #{inspect(reason)}")
        {:noreply, reconnect_after_clean_close(state)}

      _ ->
        Logger.warning("Datasvc gRPC connection down: #{inspect(reason)}")
        {:noreply, schedule_reconnect(state, reason)}
    end
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
    state = clear_channel(state)

    case reason do
      :normal ->
        Logger.debug("Datasvc gRPC connection closed: #{inspect(reason)}")
        {:noreply, reconnect_after_clean_close(state)}

      :shutdown ->
        Logger.debug("Datasvc gRPC connection closed: #{inspect(reason)}")
        {:noreply, reconnect_after_clean_close(state)}

      _ ->
        {:noreply, schedule_reconnect(state, reason)}
    end
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
    {result, state} = call_with_channel(state, &do_put(&1, key, value, opts))
    {:reply, result, state}
  end

  def handle_call({:get, key, opts}, _from, state) do
    {result, state} = call_with_channel(state, &do_get(&1, key, opts))
    {:reply, result, state}
  end

  def handle_call({:get_with_revision, key, opts}, _from, state) do
    {result, state} = call_with_channel(state, &do_get_with_revision(&1, key, opts))
    {:reply, result, state}
  end

  def handle_call({:delete, key, opts}, _from, state) do
    {result, state} = call_with_channel(state, &do_delete(&1, key, opts))
    {:reply, result, state}
  end

  def handle_call({:list_keys, prefix, opts}, _from, state) do
    {result, state} = call_with_channel(state, &do_list_keys(&1, prefix, opts))
    {:reply, result, state}
  end

  def handle_call({:put_many, entries, opts}, _from, state) do
    {result, state} = call_with_channel(state, &do_put_many(&1, entries, opts))
    {:reply, result, state}
  end

  def handle_call(:get_channel, _from, state) do
    case ensure_connected(state) do
      {:ok, state} ->
        {:reply, {:ok, state.channel}, state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:connected?, _from, state) do
    if channel_alive?(state) do
      {:reply, true, state}
    else
      {:reply, false, state |> clear_channel() |> maybe_start_connect()}
    end
  end

  # Private helpers

  defp build_config(opts) do
    app_config = Application.get_env(:serviceradar_core, __MODULE__, [])

    %{
      host: config_value(opts, app_config, :host, "DATASVC_HOST", @default_host),
      port: config_value_int(opts, app_config, :port, "DATASVC_PORT", @default_port),
      sec_mode: config_value(opts, app_config, :sec_mode, "DATASVC_SEC_MODE"),
      ssl: config_value_bool(opts, app_config, :ssl, "DATASVC_SSL", false),
      cert_dir: config_value(opts, app_config, :cert_dir, "DATASVC_CERT_DIR"),
      spiffe_cert_dir:
        config_value(opts, app_config, :spiffe_cert_dir, "DATASVC_SPIFFE_CERT_DIR"),
      cert_name: config_value(opts, app_config, :cert_name, "DATASVC_CERT_NAME", "core"),
      connect_timeout_ms:
        config_value_int(
          opts,
          app_config,
          :connect_timeout_ms,
          "DATASVC_CONNECT_TIMEOUT_MS",
          @default_connect_timeout
        ),
      reconnect_base_ms:
        config_value_int(
          opts,
          app_config,
          :reconnect_base_ms,
          "DATASVC_RECONNECT_BASE_MS",
          @default_reconnect_base
        ),
      reconnect_max_ms:
        config_value_int(
          opts,
          app_config,
          :reconnect_max_ms,
          "DATASVC_RECONNECT_MAX_MS",
          @default_reconnect_max
        ),
      server_name:
        config_value(
          opts,
          app_config,
          :server_name,
          "DATASVC_SERVER_NAME",
          "datasvc.serviceradar"
        )
    }
  end

  defp config_value(opts, app_config, key, env_key, default \\ nil) do
    opts[key] || get_env(env_key) || app_config[key] || default
  end

  defp config_value_int(opts, app_config, key, env_key, default) do
    opts[key] || get_env_int(env_key) || app_config[key] || default
  end

  defp config_value_bool(opts, app_config, key, env_key, default) do
    opts[key] || get_env_bool(env_key) || app_config[key] || default
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
      nil ->
        nil

      "" ->
        nil

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

  defp open_channel(config) do
    endpoint = "#{config.host}:#{config.port}"

    case build_cred_opts(config) do
      {:ok, cred_opts} ->
        connect_opts =
          Keyword.put(cred_opts, :adapter_opts, connect_timeout: config.connect_timeout_ms)

        GRPC.Stub.connect(endpoint, connect_opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open_direct_channel(config) do
    with {:ok, cred_opts} <- build_cred_opts(config) do
      channel = %GRPC.Channel{
        host: config.host,
        port: config.port,
        scheme: direct_channel_scheme(config),
        cred: Keyword.get(cred_opts, :cred),
        adapter: Gun
      }

      Gun.connect(
        channel,
        connect_timeout: config.connect_timeout_ms
      )
    end
  end

  defp build_cred_opts(config) do
    case normalize_sec_mode(config) do
      :spiffe ->
        spiffe_cert_dir = config.spiffe_cert_dir || config.cert_dir

        case ServiceRadar.SPIFFE.client_ssl_opts(cert_dir: spiffe_cert_dir) do
          {:ok, ssl_opts} ->
            Logger.debug("Connecting to datasvc with SPIFFE mTLS")
            {:ok, [cred: GRPC.Credential.new(ssl: ssl_opts)]}

          {:error, reason} ->
            Logger.error("SPIFFE mTLS not available for datasvc: #{inspect(reason)}")
            {:error, {:spiffe_unavailable, reason}}
        end

      :mtls ->
        cert_dir = config.cert_dir

        if is_binary(cert_dir) do
          cert_name = config.cert_name
          cert_file = Path.join(cert_dir, "#{cert_name}.pem")
          key_file = Path.join(cert_dir, "#{cert_name}-key.pem")
          ca_file = Path.join(cert_dir, "root.pem")

          Logger.debug("Connecting to datasvc with mTLS: cert=#{cert_file}")

          ssl_opts = [
            cacertfile: String.to_charlist(ca_file),
            certfile: String.to_charlist(cert_file),
            keyfile: String.to_charlist(key_file),
            verify: :verify_peer,
            server_name_indication: String.to_charlist(config.server_name)
          ]

          {:ok, [cred: GRPC.Credential.new(ssl: ssl_opts)]}
        else
          {:error, :mtls_cert_dir_missing}
        end

      :tls ->
        {:ok, [cred: GRPC.Credential.new(ssl: [])]}

      :plaintext ->
        {:ok, []}
    end
  end

  defp normalize_sec_mode(%{sec_mode: sec_mode, ssl: ssl} = config) do
    normalize_sec_mode_value(sec_mode, ssl, config)
  end

  defp normalize_sec_mode_value(nil, ssl, config), do: default_sec_mode(ssl, config)
  defp normalize_sec_mode_value("", ssl, config), do: default_sec_mode(ssl, config)

  defp normalize_sec_mode_value(value, ssl, config) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "spiffe" -> :spiffe
      "mtls" -> :mtls
      "tls" -> :tls
      "plaintext" -> :plaintext
      "none" -> :plaintext
      _ -> default_sec_mode(ssl, config)
    end
  end

  defp normalize_sec_mode_value(_value, ssl, config), do: default_sec_mode(ssl, config)

  defp default_sec_mode(true, config) do
    if is_binary(config.cert_dir), do: :mtls, else: :tls
  end

  defp default_sec_mode(false, _config), do: :plaintext

  defp direct_channel_scheme(config) do
    if normalize_sec_mode(config) == :plaintext, do: "http", else: "https"
  end

  defp disconnect_direct_channel(%GRPC.Channel{adapter: adapter} = channel)
       when is_atom(adapter) do
    if function_exported?(adapter, :disconnect, 1) do
      adapter.disconnect(channel)
    else
      :ok
    end
  end

  defp disconnect_direct_channel(_channel), do: :ok

  defp start_connect_task(state) do
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        send(parent, {:connect_result, open_channel(state.config)})
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

  defp reconnect_after_clean_close(state) do
    state
    |> Map.put(:reconnecting, false)
    |> maybe_start_connect()
  end

  defp ensure_connected(%{channel: nil} = state) do
    {:error, :not_connected, maybe_start_connect(state)}
  end

  defp ensure_connected(state), do: {:ok, state}

  defp call_with_channel(state, fun) do
    case ensure_connected(state) do
      {:ok, state} ->
        result = fun.(state.channel)

        if retryable_channel_result?(result) do
          retry_state = state |> clear_channel() |> maybe_start_connect()
          {with_direct_channel(fun), retry_state}
        else
          {result, state}
        end

      {:error, reason, new_state} ->
        {{:error, reason}, new_state}
    end
  end

  defp retryable_channel_result?({:error, reason}), do: retryable_channel_error?(reason)
  defp retryable_channel_result?(_result), do: false

  defp retryable_channel_error?(%GRPC.RPCError{status: status, message: message}) do
    status in [
      GRPC.Status.unavailable(),
      GRPC.Status.deadline_exceeded(),
      GRPC.Status.cancelled()
    ] or channel_down_message?(message)
  end

  defp retryable_channel_error?({:down, _reason}), do: true
  defp retryable_channel_error?({:shutdown, _reason}), do: true
  defp retryable_channel_error?(:not_connected), do: true
  defp retryable_channel_error?(:noproc), do: true
  defp retryable_channel_error?(_reason), do: false

  defp channel_down_message?(message) when is_binary(message) do
    String.contains?(message, [":down", ":noproc", "closed"])
  end

  defp channel_down_message?(_message), do: false

  defp channel_alive?(%{channel: nil}), do: false

  defp channel_alive?(%{channel: channel}) do
    conn_pid = channel.adapter_payload.conn_pid
    Process.alive?(conn_pid)
  end

  defp maybe_start_connect(%{connect_task: nil} = state), do: start_connect_task(state)
  defp maybe_start_connect(state), do: state

  defp set_channel(state, channel) do
    state
    |> clear_channel()
    |> Map.put(:channel, channel)
    |> Map.put(:channel_ref, monitor_channel(channel))
  end

  defp clear_channel(%{channel_ref: nil} = state), do: %{state | channel: nil}

  defp clear_channel(%{channel_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    %{state | channel: nil, channel_ref: nil}
  end

  defp monitor_channel(channel) do
    conn_pid = channel.adapter_payload.conn_pid
    Process.monitor(conn_pid)
  end

  defp do_put(channel, key, value, opts) do
    timeout = opts[:timeout] || @default_timeout
    ttl = opts[:ttl_seconds] || 0

    request = %Proto.PutRequest{
      key: key,
      value: value,
      ttl_seconds: ttl
    }

    case Stub.put(channel, request, timeout: timeout) do
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

    case Stub.get(channel, request, timeout: timeout) do
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

  defp do_get_with_revision(channel, key, opts) do
    timeout = opts[:timeout] || @default_timeout

    request = %Proto.GetRequest{key: key}

    case Stub.get(channel, request, timeout: timeout) do
      {:ok, %Proto.GetResponse{found: true, value: value, revision: revision}} ->
        {:ok, value, revision}

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

    case Stub.delete(channel, request, timeout: timeout) do
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

    case Stub.list_keys(channel, request, timeout: timeout) do
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

    case Stub.put_many(channel, request, timeout: timeout) do
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
