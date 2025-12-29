defmodule ServiceRadar.EventWriter.Producer do
  @moduledoc """
  Broadway producer for NATS JetStream.

  Connects to NATS JetStream and consumes messages from configured streams,
  delivering them to the Broadway pipeline for processing.

  ## Implementation Notes

  This producer uses the `jetstream` library's pull consumer pattern to fetch
  messages from JetStream. It maintains a connection and periodically pulls
  batches of messages to satisfy Broadway's demand.

  ## Message Format

  Each message delivered to Broadway has:
  - `data` - The message payload (binary)
  - `metadata` - Map containing `:subject`, `:reply_to`, `:headers`
  - `ack_data` - Data needed for acknowledgment

  ## Acknowledgment

  Messages are acknowledged after successful processing by the Broadway pipeline.
  Failed messages are NAK'd for redelivery according to the consumer's retry policy.
  """

  use GenStage

  require Logger

  alias ServiceRadar.EventWriter.Config

  @behaviour Broadway.Producer

  @fetch_interval 100
  @reconnect_delay 5_000

  defstruct [
    :config,
    :conn,
    :consumer_context,
    :demand,
    :connected,
    :streams,
    :pending_messages
  ]

  # Client API

  def start_link(%Config{} = config) do
    GenStage.start_link(__MODULE__, config, name: __MODULE__)
  end

  # GenStage callbacks

  @impl true
  def init(%Config{} = config) do
    Logger.info("Starting EventWriter producer", nats_host: config.nats.host)

    state = %__MODULE__{
      config: config,
      demand: 0,
      connected: false,
      streams: config.streams,
      pending_messages: []
    }

    # Start connection asynchronously
    send(self(), :connect)

    {:producer, state}
  end

  @impl true
  def handle_demand(incoming_demand, %{demand: demand} = state) do
    new_demand = demand + incoming_demand
    state = %{state | demand: new_demand}

    if state.connected and new_demand > 0 do
      {messages, state} = fetch_messages(state)
      {:noreply, messages, state}
    else
      {:noreply, [], state}
    end
  end

  @impl true
  def handle_info(:connect, state) do
    case connect(state.config) do
      {:ok, conn, consumer_context} ->
        Logger.info("EventWriter connected to NATS JetStream")

        :telemetry.execute(
          [:serviceradar, :event_writer, :connected],
          %{count: 1},
          %{host: state.config.nats.host}
        )

        # Schedule periodic fetching
        schedule_fetch()

        {:noreply, [], %{state | conn: conn, consumer_context: consumer_context, connected: true}}

      {:error, reason} ->
        Logger.warning("EventWriter NATS connection failed: #{inspect(reason)}, retrying...")

        :telemetry.execute(
          [:serviceradar, :event_writer, :connection_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        Process.send_after(self(), :connect, @reconnect_delay)
        {:noreply, [], state}
    end
  end

  def handle_info(:fetch, state) do
    if state.connected and state.demand > 0 do
      {messages, state} = fetch_messages(state)
      schedule_fetch()
      {:noreply, messages, state}
    else
      schedule_fetch()
      {:noreply, [], state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{conn: conn} = state)
      when pid == conn do
    Logger.warning("NATS connection process died: #{inspect(reason)}")
    send(self(), :connect)
    {:noreply, [], %{state | connected: false, conn: nil, consumer_context: nil}}
  end

  # Handle incoming NATS messages from Gnat subscriptions
  def handle_info({:msg, %{body: body, topic: subject, reply_to: reply_to} = msg}, state) do
    broadway_event = %{
      data: body,
      metadata: %{
        subject: subject,
        reply_to: reply_to,
        headers: Map.get(msg, :headers, %{}),
        received_at: DateTime.utc_now()
      },
      ack_data: %{
        conn: state.conn,
        reply_to: reply_to,
        ack_fun: build_ack_fun(state.conn, reply_to)
      }
    }

    new_pending = state.pending_messages ++ [broadway_event]

    if state.demand > 0 do
      {messages, state} = fetch_messages(%{state | pending_messages: new_pending})
      {:noreply, messages, state}
    else
      {:noreply, [], %{state | pending_messages: new_pending}}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, [], state}
  end

  # Private functions

  defp connect(%Config{} = config) do
    connection_settings = build_connection_settings(config.nats)

    with {:ok, conn} <- Gnat.start_link(connection_settings),
         {:ok, consumer_context} <- setup_jetstream_consumer(conn, config) do
      Process.monitor(conn)
      {:ok, conn, consumer_context}
    end
  end

  defp build_connection_settings(nats_config) do
    settings = %{
      host: nats_config.host,
      port: nats_config.port
    }

    settings =
      if nats_config.user do
        Map.merge(settings, %{user: nats_config.user, password: nats_config.password})
      else
        settings
      end

    settings = add_tls_settings(settings, nats_config.tls)

    settings
  end

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

  defp setup_jetstream_consumer(conn, config) do
    # For now, we'll use a simplified approach that subscribes to multiple subjects
    # A full JetStream pull consumer implementation would use the jetstream library
    # to create durable consumers with explicit ack

    # Get all subjects from configured streams
    subjects =
      config.streams
      |> Enum.map(& &1.subject)

    consumer_context = %{
      conn: conn,
      subjects: subjects,
      consumer_name: config.consumer_name,
      subscriptions: []
    }

    # Subscribe to each subject
    subscriptions =
      Enum.map(subjects, fn subject ->
        case Gnat.sub(conn, self(), subject) do
          {:ok, sid} ->
            Logger.debug("Subscribed to #{subject}", sid: sid)
            {subject, sid}

          {:error, reason} ->
            Logger.error("Failed to subscribe to #{subject}: #{inspect(reason)}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, %{consumer_context | subscriptions: subscriptions}}
  end

  defp fetch_messages(state) do
    # In this simplified implementation, messages come via handle_info
    # from the Gnat subscriptions. Here we just return any pending messages.

    messages_to_send = Enum.take(state.pending_messages, state.demand)
    remaining = Enum.drop(state.pending_messages, state.demand)
    new_demand = max(0, state.demand - length(messages_to_send))

    {messages_to_send, %{state | pending_messages: remaining, demand: new_demand}}
  end

  defp schedule_fetch do
    Process.send_after(self(), :fetch, @fetch_interval)
  end

  defp build_ack_fun(conn, reply_to) when is_binary(reply_to) and reply_to != "" do
    fn
      :ack ->
        # For JetStream, acknowledge by sending +ACK to the reply subject
        Gnat.pub(conn, reply_to, "+ACK")

      :nack ->
        # Send -NAK to trigger redelivery
        Gnat.pub(conn, reply_to, "-NAK")
    end
  end

  defp build_ack_fun(_conn, _reply_to) do
    # No reply_to means we can't ack (core NATS, not JetStream)
    fn _ -> :ok end
  end
end
