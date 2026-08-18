defmodule ServiceRadarWebNGWeb.NotificationFirehoseChannel do
  @moduledoc """
  The subscriber side of the notification firehose (task 4.2.2).

  `ServiceRadar.Notifications.Transports.Stream` publishes a canonical envelope
  for every `:stream` delivery. This channel is how an authenticated operator
  consumes it.

  ## The topic grants nothing

  Placing an envelope on a topic is not an authorization decision - the transport
  says so explicitly, and this module is the half that makes it true. Every join
  is refused unless the connected scope holds `notifications.stream.subscribe`,
  including joins to a suffixed topic: a suffix narrows *which* envelopes a
  subscriber receives, never what they are entitled to receive.

  ## Envelope filtering

  A joined subscriber does not automatically see everything in an envelope:

    * **Identifiers always pass.** `alert_id`, `delivery_id`, and `channel_id`
      are how a subscriber resolves detail through the authenticated API, which
      applies its own authorization. Handing over an id grants nothing.

    * **The rendered payload requires `notifications.deliveries.view`.** The
      payload is delivery content, and the Delivery Log's read policy is exactly
      that key. Without it the firehose would be a way to read delivery bodies
      that the Delivery Log itself would refuse to show - a second, unaudited
      read path around a policy that already exists.

    * **Action links are stripped again here.** The transport already refuses to
      put a capability token on the wire, and drops them a second time itself,
      for the reason this module repeats a third time: an invariant that depends
      on its caller remembering is not an invariant. A capability token reaching
      a broadcast topic would hand one delivery's single-use acknowledgement
      credential to every listener at once.

  Suppressed dispatches never reach here at all - suppression is decided before a
  transport is called, so there is no "suppressed" envelope to filter. Those are
  visible in the Delivery Log with their reason, which is the surface that is
  supposed to show them.

  ## Durable backpressure

  JetStream delivers one record at a time. After the channel pushes the
  notification and its separate signed cursor, it waits for a
  `notification_ack` carrying that exact cursor before acknowledging the broker
  record. A timeout emits `notification_overflow`, leaves the record pending,
  and closes the channel. JetStream is the sole data path for this channel; live
  PubSub copies are ignored so the ephemeral path cannot outrun the durable
  cursor before pending state exists.
  """

  use Phoenix.Channel

  alias ServiceRadar.Notifications.Transports.Stream, as: StreamTransport
  alias ServiceRadarWebNG.Notifications.FirehoseReplay
  alias ServiceRadarWebNG.RBAC

  require Logger

  @subscribe_permission "notifications.stream.subscribe"
  @payload_permission "notifications.deliveries.view"

  @firehose_topic "notifications:stream"

  # A bounded window prevents repeated durable envelopes from turning duplicate
  # suppression into unbounded per-connection memory.
  @dedupe_limit 512
  # The pull callback waits 30 seconds. Fire first so the channel can emit an
  # explicit overflow signal and tell it to leave the record unacknowledged.
  @client_ack_timeout_ms 25_000

  @doc "The RBAC key a join requires."
  @spec subscribe_permission() :: String.t()
  def subscribe_permission, do: @subscribe_permission

  @doc "The RBAC key required to receive the rendered payload."
  @spec payload_permission() :: String.t()
  def payload_permission, do: @payload_permission

  @impl true
  def join(@firehose_topic, payload, socket), do: authorize_join(@firehose_topic, payload, socket)

  def join(@firehose_topic <> ":" <> suffix, payload, socket) do
    if valid_suffix?(suffix) do
      authorize_join(@firehose_topic <> ":" <> suffix, payload, socket)
    else
      {:error, %{reason: "unknown_topic"}}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "unknown_topic"}}

  @impl true
  def handle_in("notification_ack", payload, socket) when is_map(payload) do
    cursor = Map.get(payload, "cursor") || Map.get(payload, :cursor)

    case socket.assigns[:firehose_pending_ack] do
      nil ->
        {:reply, {:error, %{reason: "no_notification_pending"}}, socket}

      %{cursor: expected_cursor} when cursor != expected_cursor ->
        {:reply, {:error, %{reason: "cursor_mismatch"}}, socket}

      pending ->
        socket = complete_pending_ack(socket, pending, :ack)
        {:reply, {:ok, %{cursor: cursor, delivery_id: pending.delivery_id}}, socket}
    end
  end

  def handle_in("notification_ack", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_notification_ack"}}, socket}
  end

  def handle_in(_event, _payload, socket), do: {:reply, {:error, %{reason: "unsupported_event"}}, socket}

  @impl true
  def handle_info({:notification_envelope, _envelope}, socket), do: {:noreply, socket}

  def handle_info({:firehose_replay, envelope, cursor, consumer_pid, reply_ref}, socket)
      when is_map(envelope) and is_pid(consumer_pid) and is_reference(reply_ref) do
    if socket.assigns[:firehose_pending_ack] do
      send(consumer_pid, {:firehose_replay_result, reply_ref, :leave_unacked})

      pending = socket.assigns.firehose_pending_ack

      push_event(socket, "notification_overflow", %{
        "cursor" => pending.cursor,
        "delivery_id" => pending.delivery_id,
        "reason" => "concurrent_replay"
      })

      {:stop, :concurrent_firehose_replay, socket}
    else
      case deliver_authorized(envelope, socket) do
        {:ok, _outcome, refreshed_socket} ->
          case push_replay_cursor(refreshed_socket, cursor, envelope) do
            {:ok, signed_cursor, delivery_id} ->
              pending = %{
                consumer_pid: consumer_pid,
                cursor: signed_cursor,
                delivery_id: delivery_id,
                reply_ref: reply_ref,
                timer_ref: schedule_ack_timeout(refreshed_socket, reply_ref)
              }

              {:noreply, assign(refreshed_socket, :firehose_pending_ack, pending)}

            {:error, reason} ->
              send(consumer_pid, {:firehose_replay_result, reply_ref, :leave_unacked})
              {:stop, reason, refreshed_socket}
          end

        {:error, :permission_revoked, revoked_socket} ->
          # The pull consumer leaves this record unacknowledged. The next
          # authorized reconnect resumes at this envelope instead of advancing a
          # cursor after authority was revoked.
          send(consumer_pid, {:firehose_replay_result, reply_ref, :leave_unacked})
          {:stop, :permission_revoked, revoked_socket}
      end
    end
  end

  def handle_info({:firehose_ack_timeout, reply_ref}, socket) when is_reference(reply_ref) do
    case socket.assigns[:firehose_pending_ack] do
      %{reply_ref: ^reply_ref, cursor: cursor, delivery_id: delivery_id} = pending ->
        push_event(socket, "notification_overflow", %{
          "cursor" => cursor,
          "delivery_id" => delivery_id,
          "reason" => "ack_timeout"
        })

        socket = complete_pending_ack(socket, pending, :leave_unacked)
        {:stop, :notification_ack_timeout, socket}

      _stale_or_completed ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    case socket.assigns[:firehose_pending_ack] do
      nil -> :ok
      pending -> complete_pending_ack(socket, pending, :leave_unacked)
    end

    replay_module(socket).stop(socket.assigns[:firehose_replay])
  end

  @doc """
  Filters an envelope to what a scope may see.

  Public so the authorization contract is testable directly rather than only
  through a live socket.
  """
  @spec filter_envelope(map(), Phoenix.Socket.t() | map()) :: map()
  def filter_envelope(envelope, %Phoenix.Socket{} = socket) do
    filter_envelope(envelope, %{payload?: socket.assigns[:firehose_payload?] == true})
  end

  def filter_envelope(envelope, %{payload?: true}) do
    StreamTransport.strip_action_links(envelope)
  end

  def filter_envelope(envelope, %{payload?: _denied}) do
    envelope
    |> Map.delete("payload")
    |> StreamTransport.strip_action_links()
  end

  @doc """
  Refreshes subscriber authority and filters one envelope.

  This runs for every event, not only at join, so revoking the subscribe
  permission stops the channel and revoking delivery-view authority removes the
  payload from the very next envelope.
  """
  @spec authorize_envelope(map(), Phoenix.Socket.t()) ::
          {:ok, map(), Phoenix.Socket.t()}
          | {:error, :permission_revoked, Phoenix.Socket.t()}
  def authorize_envelope(envelope, %Phoenix.Socket{} = socket) when is_map(envelope) do
    authorization_module = authorization_module(socket)

    case authorization_module.authorize_current(
           socket.assigns[:current_scope],
           [@subscribe_permission]
         ) do
      {:ok, current_scope} ->
        refreshed_socket =
          socket
          |> assign(:current_scope, current_scope)
          |> assign(:firehose_payload?, RBAC.can?(current_scope, @payload_permission))

        {:ok, filter_envelope(envelope, refreshed_socket), refreshed_socket}

      _revoked ->
        {:error, :permission_revoked, socket}
    end
  end

  @doc false
  def dedupe_limit, do: @dedupe_limit

  # --- joining ---------------------------------------------------------------

  defp authorize_join(topic, payload, socket) do
    authorization_module = authorization_module(socket)

    case authorization_module.authorize_current(
           socket.assigns[:current_scope],
           [@subscribe_permission]
         ) do
      {:ok, current_scope} ->
        socket =
          socket
          |> assign(:current_scope, current_scope)
          |> assign(:firehose_payload?, RBAC.can?(current_scope, @payload_permission))
          |> assign(:firehose_pending_ack, nil)
          |> assign(:firehose_seen, empty_seen())

        case start_replay(topic, payload, current_scope, socket) do
          {:ok, replay} ->
            # JetStream is the only channel data path. Subscribing this process
            # to the live PubSub copy would let a burst outrun the one-record
            # client-ACK boundary before the first pull record establishes
            # pending state.
            socket = assign(socket, :firehose_replay, replay)

            {:ok, %{client_id: replay.client_id, cursor: replay.initial_cursor, durable: true}, socket}

          {:error, reason} ->
            Logger.warning(
              "notification firehose join refused because replay is unavailable " <>
                "topic=#{topic} reason=#{inspect(reason)}"
            )

            {:error, public_replay_error(reason)}
        end

      _denied ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  defp authorization_module(socket), do: socket.assigns[:authorization_module] || RBAC

  defp replay_module(socket), do: socket.assigns[:firehose_replay_module] || FirehoseReplay

  defp start_replay(topic, payload, current_scope, socket) do
    replay_module(socket).start(
      topic,
      payload,
      current_scope,
      self(),
      socket.assigns[:firehose_replay_opts] || []
    )
  end

  defp deliver_authorized(envelope, socket) do
    case authorize_envelope(envelope, socket) do
      {:ok, filtered, refreshed_socket} ->
        if seen?(refreshed_socket, envelope) do
          {:ok, :duplicate, refreshed_socket}
        else
          push_envelope(refreshed_socket, filtered)
          {:ok, :pushed, remember(refreshed_socket, envelope)}
        end

      {:error, :permission_revoked, revoked_socket} ->
        {:error, :permission_revoked, revoked_socket}
    end
  end

  defp push_envelope(socket, envelope) do
    push_event(socket, "notification", envelope)
  end

  defp push_replay_cursor(socket, %{stream_sequence: stream_sequence}, envelope)
       when is_integer(stream_sequence) and stream_sequence > 0 do
    delivery_id = Map.get(envelope, "delivery_id") || Map.get(envelope, :delivery_id)

    with true <- is_binary(delivery_id) and delivery_id != "",
         {:ok, cursor} <-
           replay_module(socket).cursor_token(
             socket.assigns[:firehose_replay],
             stream_sequence + 1
           ) do
      push_event(socket, "notification_cursor", %{
        "cursor" => cursor,
        "delivery_id" => delivery_id
      })

      {:ok, cursor, delivery_id}
    else
      false -> {:error, :invalid_cursor_delivery_id}
      {:error, _reason} = error -> error
    end
  end

  defp push_replay_cursor(_socket, _metadata, _envelope), do: {:error, :invalid_cursor_metadata}

  defp push_event(socket, event, payload) do
    case socket.assigns[:firehose_push] do
      fun when is_function(fun, 3) -> fun.(socket, event, payload)
      nil -> push(socket, event, payload)
    end
  end

  defp schedule_ack_timeout(socket, reply_ref) do
    timeout = socket.assigns[:firehose_ack_timeout_ms] || @client_ack_timeout_ms
    Process.send_after(self(), {:firehose_ack_timeout, reply_ref}, timeout)
  end

  defp complete_pending_ack(socket, pending, outcome) do
    Process.cancel_timer(pending.timer_ref, async: false, info: false)
    send(pending.consumer_pid, {:firehose_replay_result, pending.reply_ref, outcome})
    assign(socket, :firehose_pending_ack, nil)
  end

  defp empty_seen, do: %{ids: MapSet.new(), order: :queue.new()}

  defp seen?(socket, envelope) do
    seen = socket.assigns[:firehose_seen] || empty_seen()
    MapSet.member?(seen.ids, envelope_identity(envelope))
  end

  defp remember(socket, envelope) do
    identity = envelope_identity(envelope)
    seen = socket.assigns[:firehose_seen] || empty_seen()

    seen =
      if MapSet.member?(seen.ids, identity) do
        seen
      else
        trim_seen(%{
          ids: MapSet.put(seen.ids, identity),
          order: :queue.in(identity, seen.order)
        })
      end

    assign(socket, :firehose_seen, seen)
  end

  defp trim_seen(%{ids: ids, order: order} = seen) do
    if MapSet.size(ids) <= @dedupe_limit do
      seen
    else
      case :queue.out(order) do
        {{:value, oldest}, rest} -> %{seen | ids: MapSet.delete(ids, oldest), order: rest}
        {:empty, _order} -> empty_seen()
      end
    end
  end

  defp envelope_identity(envelope) do
    case Map.get(envelope, "delivery_id") || Map.get(envelope, :delivery_id) do
      delivery_id when is_binary(delivery_id) and delivery_id != "" ->
        {:delivery, delivery_id}

      _missing ->
        {:envelope,
         envelope
         |> :erlang.term_to_binary([:deterministic])
         |> then(&:crypto.hash(:sha256, &1))}
    end
  end

  defp public_replay_error({:cursor_gap, earliest_cursor}) when is_binary(earliest_cursor) do
    %{reason: "cursor_gap", earliest_cursor: earliest_cursor}
  end

  defp public_replay_error(:client_id_required), do: %{reason: "client_id_required"}
  defp public_replay_error(:invalid_client_id), do: %{reason: "invalid_client_id"}
  defp public_replay_error(:invalid_cursor), do: %{reason: "invalid_cursor"}
  defp public_replay_error(:unauthenticated), do: %{reason: "unauthorized"}
  defp public_replay_error(_reason), do: %{reason: "replay_unavailable"}

  # Mirrors the transport's suffix charset. A suffix that the transport would
  # have refused to save cannot be joined here either, so a crafted topic cannot
  # reach a namespace an operator was never granted.
  defp valid_suffix?(suffix), do: Regex.match?(~r/\A[a-z0-9][a-z0-9_:-]{0,63}\z/, suffix)
end
