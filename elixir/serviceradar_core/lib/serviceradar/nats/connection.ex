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
  def get, do: get(@connection_name)

  @doc """
  Gets the PID of a NAMED NATS connection.

  The edge publishers each own a separate connection so that a saturated lane cannot consume
  another lane's socket or Gnat mailbox; see `ServiceRadar.Edge.PublisherLane`. Resolution is
  per call rather than cached, because `Gnat.ConnectionSupervisor` re-registers the name across
  a reconnect and a held PID would go stale exactly when NATS was least healthy.
  """
  @spec get(atom() | pid()) :: {:ok, pid()} | {:error, term()}
  def get(pid) when is_pid(pid) do
    # A caller that resolved the connection EARLIER and is holding that pid: it wants this exact
    # connection, not whatever currently owns the name. That distinction is what stops a publish
    # from crossing a lane restart -- see JetStreamPublisher.
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :connection_dead}
  end

  def get(name) when is_atom(name) do
    case Process.whereis(name) do
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
    opts = put_trace_context(opts)

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
  Sends a NATS request and waits for a single reply.

  This is the request/reply primitive used for a JetStream publish that must
  observe the server's `PubAck` (durable acknowledgement) rather than
  fire-and-forget like `publish/3`. The reply body carries the JetStream
  `PubAck` JSON (`{"stream", "seq", "duplicate"}`) or an error object.

  Returns `{:ok, %Gnat.Message{}}` on a reply, `{:error, :timeout}` when no
  reply arrives within `:receive_timeout`, or `{:error, reason}` otherwise.

  ## Examples

      {:ok, %{body: body}} =
        Connection.request("sr.edge.v1.sweep.bulk.p07.v1", payload,
          headers: headers, receive_timeout: 5_000)
  """
  @spec request(String.t(), String.t() | binary(), keyword()) ::
          {:ok, Gnat.Message.t()} | {:error, term()}
  def request(subject, payload, opts \\ []) do
    request(@connection_name, subject, payload, opts)
  end

  @doc """
  Sends a request on a NAMED connection.

  Deliberately has NO default for `opts`: with one, this would also define a 3-arity clause
  `(conn, subject, payload)` that collides with `request/3`'s `(subject, payload, opts)`, and the
  two are indistinguishable at the call site -- three positional terms where the first is either a
  connection or a subject. Requiring `opts` keeps the arity unambiguous.
  """
  @spec request(atom() | pid(), String.t(), String.t() | binary(), keyword()) ::
          {:ok, Gnat.Message.t()} | {:error, term()}
  def request(conn_name, subject, payload, opts) when is_atom(conn_name) or is_pid(conn_name) do
    opts = put_trace_context(opts)

    case get(conn_name) do
      {:ok, conn} ->
        try do
          Gnat.request(conn, subject, payload, opts)
        catch
          :exit, reason ->
            Logger.warning("NATS request failed (connection died): #{inspect(reason)}")
            {:error, {:nats_connection_died, reason}}
        end

      {:error, reason} ->
        {:error, {:nats_not_connected, reason}}
    end
  end

  # Injects W3C trace context (traceparent/tracestate) into the outbound
  # message headers when a span is active, so NATS consumers can join the
  # publisher's trace. No-op (and no headers key added) when there is no
  # active span context and no pre-existing headers.
  defp put_trace_context(opts) do
    headers = Keyword.get(opts, :headers, [])

    case ServiceRadar.Otel.Propagation.inject_headers(headers) do
      ^headers -> opts
      injected -> Keyword.put(opts, :headers, injected)
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
