defmodule ServiceRadar.NATS.Connection do
  @moduledoc """
  NATS connection management for ServiceRadar.

  Manages connection to NATS server using the Gnat library.
  Supports reconnection, health checks, and JetStream publishing.

  ## Configuration

  Configure in runtime.exs:

      config :serviceradar_core, ServiceRadar.NATS.Connection,
        host: "localhost",
        port: 4222,
        name: :serviceradar_nats,
        user: "serviceradar",
        password: {:system, "NATS_PASSWORD"},
        creds_file: "/etc/serviceradar/creds/platform.creds"

  ## Usage

      # Get the connection for publishing
      {:ok, conn} = ServiceRadar.NATS.Connection.get()

      # Publish to a subject
      :ok = Gnat.pub(conn, "sr.infra.events", payload)
  """

  use GenServer

  require Logger

  @default_name :serviceradar_nats
  @reconnect_delay 5_000
  @health_check_interval 30_000

  defstruct [
    :conn,
    :host,
    :port,
    :name,
    :user,
    :password,
    :jwt,
    :nkey_seed,
    :creds_file,
    :tls,
    :connected,
    :last_error,
    :reconnect_timer
  ]

  # Client API

  @doc """
  Starts the NATS connection manager.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Gets the current NATS connection.

  Returns `{:ok, conn}` if connected, `{:error, reason}` otherwise.
  """
  @spec get(GenServer.server()) :: {:ok, pid()} | {:error, term()}
  def get(server \\ __MODULE__) do
    GenServer.call(server, :get_connection)
  end

  @doc """
  Gets the current NATS connection, raising on error.
  """
  @spec get!(GenServer.server()) :: pid()
  def get!(server \\ __MODULE__) do
    case get(server) do
      {:ok, conn} -> conn
      {:error, reason} -> raise "NATS connection error: #{inspect(reason)}"
    end
  end

  @doc """
  Publishes a message to a NATS subject.

  Convenience function that gets the connection and publishes in one call.
  """
  @spec publish(String.t(), String.t() | binary(), keyword()) :: :ok | {:error, term()}
  def publish(subject, payload, opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, {:nats_not_connected, :no_process}}

      _pid ->
        case get() do
          {:ok, conn} ->
            Gnat.pub(conn, subject, payload, opts)

          {:error, reason} ->
            {:error, {:nats_not_connected, reason}}
        end
    end
  end

  @doc """
  Checks if the NATS connection is healthy.
  """
  @spec connected?(GenServer.server()) :: boolean()
  def connected?(server \\ __MODULE__) do
    GenServer.call(server, :connected?)
  end

  @doc """
  Returns connection status for health checks.
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc """
  Forces a reconnection attempt.
  """
  @spec reconnect(GenServer.server()) :: :ok
  def reconnect(server \\ __MODULE__) do
    GenServer.cast(server, :reconnect)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    merged_opts = Keyword.merge(config, opts)
    creds_file = resolve_value(Keyword.get(merged_opts, :creds_file)) |> normalize()
    jwt = resolve_value(Keyword.get(merged_opts, :jwt)) |> normalize()
    nkey_seed = resolve_value(Keyword.get(merged_opts, :nkey_seed)) |> normalize()
    {jwt, nkey_seed} = load_creds(creds_file, jwt, nkey_seed)

    state = %__MODULE__{
      host: Keyword.get(merged_opts, :host, "localhost"),
      port: Keyword.get(merged_opts, :port, 4222),
      name: Keyword.get(merged_opts, :name, @default_name),
      user: resolve_value(Keyword.get(merged_opts, :user)),
      password: resolve_value(Keyword.get(merged_opts, :password)),
      jwt: jwt,
      nkey_seed: nkey_seed,
      creds_file: creds_file,
      tls: Keyword.get(merged_opts, :tls, false),
      connected: false,
      last_error: nil,
      conn: nil
    }

    # Start connection asynchronously
    send(self(), :connect)

    # Schedule health checks
    schedule_health_check()

    {:ok, state}
  end

  @impl true
  def handle_call(:get_connection, _from, %{connected: false, last_error: error} = state) do
    {:reply, {:error, error || :not_connected}, state}
  end

  def handle_call(:get_connection, _from, %{conn: conn} = state) do
    {:reply, {:ok, conn}, state}
  end

  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      connected: state.connected,
      host: state.host,
      port: state.port,
      name: state.name,
      last_error: state.last_error
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast(:reconnect, state) do
    state = cancel_reconnect_timer(state)
    send(self(), :connect)
    {:noreply, state}
  end

  @impl true
  def handle_info(:connect, state) do
    state = cancel_reconnect_timer(state)

    case connect(state) do
      {:ok, conn} ->
        Logger.info("NATS connected to #{state.host}:#{state.port}")
        :telemetry.execute([:serviceradar, :nats, :connected], %{count: 1}, %{host: state.host})
        {:noreply, %{state | conn: conn, connected: true, last_error: nil}}

      {:error, reason} ->
        Logger.warning("NATS connection failed: #{inspect(reason)}, retrying in #{@reconnect_delay}ms")
        :telemetry.execute([:serviceradar, :nats, :connection_failed], %{count: 1}, %{reason: reason})
        timer = Process.send_after(self(), :connect, @reconnect_delay)
        {:noreply, %{state | connected: false, last_error: reason, reconnect_timer: timer}}
    end
  end

  def handle_info(:health_check, state) do
    state =
      if state.connected and state.conn do
        case check_connection_health(state.conn) do
          :ok ->
            state

          {:error, reason} ->
            Logger.warning("NATS health check failed: #{inspect(reason)}")
            send(self(), :connect)
            %{state | connected: false, last_error: reason, conn: nil}
        end
      else
        state
      end

    schedule_health_check()
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{conn: conn} = state) when pid == conn do
    Logger.warning("NATS connection process died: #{inspect(reason)}")
    send(self(), :connect)
    {:noreply, %{state | connected: false, last_error: reason, conn: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp connect(state) do
    connection_settings = %{
      host: state.host,
      port: state.port
    }

    connection_settings =
      case apply_auth_settings(connection_settings, state) do
        {:ok, settings} -> settings
        {:error, reason} -> {:error, reason}
      end

    connection_settings = add_tls_settings(connection_settings, state.tls)

    case connection_settings do
      {:error, reason} ->
        {:error, reason}

      settings ->
        case Gnat.start_link(settings) do
          {:ok, conn} ->
            Process.monitor(conn)
            Process.unlink(conn)
            {:ok, conn}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl true
  def terminate(_reason, %{conn: conn}) when is_pid(conn) do
    if Process.alive?(conn) do
      _ = Gnat.stop(conn)
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp add_tls_settings(settings, tls) do
    case tls do
      true ->
        Map.put(settings, :tls, true)

      tls_opts when is_list(tls_opts) ->
        settings
        |> Map.put(:tls, true)
        |> Map.put(:ssl_opts, tls_opts)

      _ ->
        settings
    end
  end

  defp apply_auth_settings(settings, state) do
    jwt = normalize(state.jwt)
    nkey_seed = normalize(state.nkey_seed)
    user = normalize(state.user)

    cond do
      nkey_seed != nil ->
        settings =
          settings
          |> Map.put(:nkey_seed, nkey_seed)
          |> Map.put(:auth_required, true)

        settings =
          if jwt != nil do
            Map.put(settings, :jwt, jwt)
          else
            settings
          end

        {:ok, settings}

      jwt != nil ->
        {:error, :missing_nkey_seed}

      user != nil ->
        {:ok, Map.merge(settings, %{user: user, password: state.password})}

      true ->
        {:ok, settings}
    end
  end

  defp load_creds(nil, jwt, nkey_seed), do: {jwt, nkey_seed}
  defp load_creds("", jwt, nkey_seed), do: {jwt, nkey_seed}

  defp load_creds(creds_file, jwt, nkey_seed) do
    case ServiceRadar.NATS.Creds.read(creds_file) do
      {:ok, creds} ->
        {creds.jwt, creds.nkey_seed}

      {:error, reason} ->
        Logger.warning(
          "Failed to read NATS creds file #{creds_file}: #{inspect(reason)}"
        )

        {jwt, nkey_seed}
    end
  end

  defp check_connection_health(conn) do
    if Process.alive?(conn) do
      :ok
    else
      {:error, :connection_dead}
    end
  end

  defp resolve_value({:system, env_var}), do: System.get_env(env_var)
  defp resolve_value(value), do: value

  defp normalize(nil), do: nil

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(value), do: value

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
  end

  defp cancel_reconnect_timer(%{reconnect_timer: nil} = state), do: state

  defp cancel_reconnect_timer(%{reconnect_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | reconnect_timer: nil}
  end
end
