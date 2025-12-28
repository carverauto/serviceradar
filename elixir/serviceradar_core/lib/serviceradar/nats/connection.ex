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
        password: {:system, "NATS_PASSWORD"}

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
    case get() do
      {:ok, conn} ->
        Gnat.pub(conn, subject, payload, opts)

      {:error, _} = error ->
        error
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

    state = %__MODULE__{
      host: Keyword.get(merged_opts, :host, "localhost"),
      port: Keyword.get(merged_opts, :port, 4222),
      name: Keyword.get(merged_opts, :name, @default_name),
      user: resolve_value(Keyword.get(merged_opts, :user)),
      password: resolve_value(Keyword.get(merged_opts, :password)),
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
      port: state.port,
      tls: state.tls
    }

    connection_settings =
      if state.user do
        Map.merge(connection_settings, %{user: state.user, password: state.password})
      else
        connection_settings
      end

    case Gnat.start_link(connection_settings) do
      {:ok, conn} ->
        Process.monitor(conn)
        {:ok, conn}

      {:error, reason} ->
        {:error, reason}
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

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
  end

  defp cancel_reconnect_timer(%{reconnect_timer: nil} = state), do: state

  defp cancel_reconnect_timer(%{reconnect_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | reconnect_timer: nil}
  end
end
