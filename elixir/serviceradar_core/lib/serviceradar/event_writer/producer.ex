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
  alias ServiceRadar.NATS.JetstreamConsumer

  @behaviour Broadway.Producer

  @fetch_interval 100
  @reconnect_delay 5_000
  @ack_wait_ns 30_000_000_000
  @max_ack_pending 5_000
  @max_deliver 10

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

  # Handle incoming NATS messages from JetStream durable consumer delivery subjects.
  def handle_info({:msg, %{body: body, topic: subject, reply_to: reply_to} = msg}, state) do
    headers = Map.get(msg, :headers, %{})
    original_subject = extract_original_subject(subject, headers)

    broadway_event = %{
      data: body,
      metadata: %{
        subject: original_subject,
        reply_to: reply_to,
        headers: headers,
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

    case connection_settings do
      {:error, reason} ->
        {:error, reason}

      settings ->
        with {:ok, conn} <- Gnat.start_link(settings),
             {:ok, consumer_context} <- setup_jetstream_consumers(conn, config) do
          Process.monitor(conn)
          Process.unlink(conn)
          {:ok, conn, consumer_context}
        end
    end
  end

  defp build_connection_settings(nats_config) do
    settings = %{
      host: nats_config.host,
      port: nats_config.port
    }

    settings =
      case apply_auth_settings(settings, nats_config) do
        {:ok, updated} -> updated
        {:error, reason} -> {:error, reason}
      end

    case settings do
      {:error, reason} ->
        {:error, reason}

      updated ->
        add_tls_settings(updated, nats_config.tls)
    end
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

  defp apply_auth_settings(settings, nats_config) do
    jwt = normalize(nats_config.jwt)
    nkey_seed = normalize(nats_config.nkey_seed)
    user = normalize(nats_config.user)

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
        {:ok, Map.merge(settings, %{user: user, password: nats_config.password})}

      true ->
        {:ok, settings}
    end
  end

  defp normalize(nil), do: nil

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(value), do: value

  defp setup_jetstream_consumers(conn, config) do
    consumers =
      Enum.map(config.streams, fn stream ->
        durable_name = durable_name(config.consumer_name, stream.name)
        deliver_subject = deliver_subject(config.consumer_name, stream.name)

        with {:ok, ensured} <-
               JetstreamConsumer.ensure_durable(conn,
                 stream_name: Map.get(stream, :stream_name) || stream.name,
                 consumer_name: durable_name,
                 filter_subject: stream.subject,
                 deliver_subject: deliver_subject,
                 description: "EventWriter consumer for #{stream.name}",
                 ack_policy: :explicit,
                 ack_wait: @ack_wait_ns,
                 deliver_policy: :all,
                 max_ack_pending: @max_ack_pending,
                 max_deliver: @max_deliver
               ),
             {:ok, sid} <- Gnat.sub(conn, self(), deliver_subject) do
          Logger.info("EventWriter JetStream consumer ready",
            stream: ensured.stream_name,
            durable: durable_name,
            filter_subject: stream.subject,
            deliver_subject: deliver_subject,
            sid: sid
          )

          %{stream: ensured.stream_name, durable: durable_name, sid: sid, subject: stream.subject}
        else
          {:error, reason} ->
            Logger.error("Failed to initialize EventWriter durable consumer",
              stream: stream.name,
              filter_subject: stream.subject,
              reason: inspect(reason)
            )

            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if consumers == [] do
      {:error, :no_consumers_initialized}
    else
      {:ok, %{conn: conn, consumer_name: config.consumer_name, consumers: consumers}}
    end
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
        safe_ack_publish(conn, reply_to, "+ACK")

      :nack ->
        # Send -NAK to trigger redelivery
        safe_ack_publish(conn, reply_to, "-NAK")
    end
  end

  defp build_ack_fun(_conn, _reply_to) do
    # No reply_to means we can't ack (core NATS, not JetStream)
    fn _ -> :ok end
  end

  defp safe_ack_publish(conn, reply_to, payload) when is_binary(reply_to) and reply_to != "" do
    conn_ref = resolve_conn_ref(conn)

    cond do
      is_nil(conn_ref) ->
        {:error, :nats_connection_not_available}

      is_pid(conn_ref) and not Process.alive?(conn_ref) ->
        {:error, :nats_connection_not_alive}

      true ->
        try do
          Gnat.pub(conn_ref, reply_to, payload)
        rescue
          error ->
            {:error, error}
        catch
          :exit, reason ->
            {:error, {:exit, reason}}

          kind, reason ->
            {:error, {kind, reason}}
        end
    end
  end

  defp safe_ack_publish(_conn, _reply_to, _payload), do: {:error, :invalid_ack_payload}

  defp resolve_conn_ref(conn) when is_pid(conn), do: conn

  defp resolve_conn_ref(conn) when is_atom(conn) do
    Process.whereis(conn)
  end

  defp resolve_conn_ref(conn), do: conn

  defp durable_name(base, stream_name) do
    suffix =
      stream_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    "#{base}-#{suffix}"
  end

  defp deliver_subject(base, stream_name) do
    suffix =
      stream_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    "_INBOX.serviceradar.event_writer.#{base}.#{suffix}"
  end

  defp extract_original_subject(topic, headers) do
    find_header_value(headers, "nats-subject") ||
      find_header_value(headers, "nats-subject-token") ||
      topic
  end

  defp find_header_value(headers, key) when is_map(headers) do
    headers
    |> Enum.find_value(fn {k, v} ->
      if normalize_header_key(k) == key do
        normalize_header_value(v)
      else
        nil
      end
    end)
  end

  defp find_header_value(headers, key) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {k, v} ->
        if normalize_header_key(k) == key do
          normalize_header_value(v)
        else
          nil
        end

      _ ->
        nil
    end)
  end

  defp find_header_value(_headers, _key), do: nil

  defp normalize_header_key(key) when is_binary(key), do: String.downcase(key)

  defp normalize_header_key(key) when is_atom(key),
    do: key |> Atom.to_string() |> String.downcase()

  defp normalize_header_key(key) when is_list(key), do: key |> to_string() |> String.downcase()
  defp normalize_header_key(_), do: ""

  defp normalize_header_value(value) when is_binary(value), do: value

  defp normalize_header_value(value) when is_list(value) do
    case value do
      [first | _] when is_binary(first) -> first
      [first | _] when is_list(first) -> to_string(first)
      _ -> to_string(value)
    end
  rescue
    _ -> nil
  end

  defp normalize_header_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_header_value(value), do: to_string(value)
end
