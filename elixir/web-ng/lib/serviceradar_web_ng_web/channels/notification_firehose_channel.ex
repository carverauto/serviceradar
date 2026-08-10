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
  """

  use Phoenix.Channel

  alias ServiceRadar.Notifications.Transports.Stream, as: StreamTransport
  alias ServiceRadarWebNG.RBAC

  require Logger

  @subscribe_permission "notifications.stream.subscribe"
  @payload_permission "notifications.deliveries.view"

  @firehose_topic "notifications:stream"

  @doc "The RBAC key a join requires."
  @spec subscribe_permission() :: String.t()
  def subscribe_permission, do: @subscribe_permission

  @doc "The RBAC key required to receive the rendered payload."
  @spec payload_permission() :: String.t()
  def payload_permission, do: @payload_permission

  @impl true
  def join(@firehose_topic, _payload, socket), do: authorize_join(@firehose_topic, socket)

  def join(@firehose_topic <> ":" <> suffix, _payload, socket) do
    if valid_suffix?(suffix) do
      authorize_join(@firehose_topic <> ":" <> suffix, socket)
    else
      {:error, %{reason: "unknown_topic"}}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "unknown_topic"}}

  @impl true
  def handle_info({:notification_envelope, envelope}, socket) when is_map(envelope) do
    push(socket, "notification", filter_envelope(envelope, socket))
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

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

  # --- joining ---------------------------------------------------------------

  defp authorize_join(topic, socket) do
    scope = socket.assigns[:current_scope]

    if RBAC.can?(scope, @subscribe_permission) do
      {:ok,
       socket
       |> assign(:firehose_payload?, RBAC.can?(scope, @payload_permission))
       |> subscribe(topic)}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  defp subscribe(socket, topic) do
    Phoenix.PubSub.subscribe(ServiceRadar.PubSub, topic)
    socket
  end

  # Mirrors the transport's suffix charset. A suffix that the transport would
  # have refused to save cannot be joined here either, so a crafted topic cannot
  # reach a namespace an operator was never granted.
  defp valid_suffix?(suffix), do: Regex.match?(~r/\A[a-z0-9][a-z0-9_:-]{0,63}\z/, suffix)
end
