defmodule ServiceRadar.NATS.Connection do
  @moduledoc """
  NATS connection API for ServiceRadar.

  Provides a simple API for publishing messages to NATS. The actual connection
  is managed by `ServiceRadar.NATS.Supervisor` which uses `Gnat.ConnectionSupervisor`
  for fault-tolerant connection handling with automatic reconnection.

  ## Configuration

  Configure in runtime.exs:

      config :serviceradar_core, ServiceRadar.NATS.Connection,
        host: "localhost",
        port: 4222,
        name: :serviceradar_nats,
        tls: true,
        creds_file: "/etc/serviceradar/creds/platform.creds"

  ## Usage

      # Publish to a subject
      :ok = ServiceRadar.NATS.Connection.publish("sr.infra.events", payload)

      # Check connection status
      if ServiceRadar.NATS.Connection.connected?() do
        # ...
      end
  """

  require Logger

  @connection_name :serviceradar_nats

  @doc """
  Gets the NATS connection PID.

  Returns `{:ok, pid}` if connected, `{:error, reason}` otherwise.
  """
  @spec get() :: {:ok, pid()} | {:error, term()}
  def get do
    case Process.whereis(@connection_name) do
      nil ->
        {:error, :not_connected}

      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          {:error, :connection_dead}
        end
    end
  end

  @doc """
  Gets the NATS connection PID, raising on error.
  """
  @spec get!() :: pid()
  def get! do
    case get() do
      {:ok, conn} -> conn
      {:error, reason} -> raise "NATS connection error: #{inspect(reason)}"
    end
  end

  @doc """
  Publishes a message to a NATS subject.

  Uses the supervised connection managed by `ServiceRadar.NATS.Supervisor`.

  ## Examples

      :ok = Connection.publish("events.user.created", Jason.encode!(payload))
      {:error, :not_connected} = Connection.publish("events", "msg")
  """
  @spec publish(String.t(), String.t() | binary(), keyword()) :: :ok | {:error, term()}
  def publish(subject, payload, opts \\ []) do
    case get() do
      {:ok, conn} ->
        try do
          Gnat.pub(conn, subject, payload, opts)
        catch
          :exit, reason ->
            Logger.warning("NATS publish failed (connection died): #{inspect(reason)}")
            {:error, {:nats_connection_died, reason}}
        end

      {:error, reason} ->
        {:error, {:nats_not_connected, reason}}
    end
  end

  @doc """
  Checks if the NATS connection is available.
  """
  @spec connected?() :: boolean()
  def connected? do
    case get() do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Returns connection status for health checks.
  """
  @spec status() :: map()
  def status do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    host = Keyword.get(config, :host, "localhost")
    port = Keyword.get(config, :port, 4222)

    case get() do
      {:ok, pid} ->
        %{
          connected: true,
          host: host,
          port: port,
          name: @connection_name,
          pid: pid,
          last_error: nil
        }

      {:error, reason} ->
        %{
          connected: false,
          host: host,
          port: port,
          name: @connection_name,
          pid: nil,
          last_error: reason
        }
    end
  end

  @doc """
  Returns the registered connection name.
  """
  @spec connection_name() :: atom()
  def connection_name, do: @connection_name

  # Legacy API - these functions existed for compatibility but are no longer needed
  # since the connection is now managed by Gnat.ConnectionSupervisor

  @doc false
  def start_link(_opts \\ []) do
    # This is a no-op now - the supervisor starts the connection
    # Kept for API compatibility during transition
    :ignore
  end

  @doc false
  def reconnect(_server \\ __MODULE__) do
    # Gnat.ConnectionSupervisor handles reconnection automatically
    :ok
  end
end
