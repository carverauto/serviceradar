defmodule ServiceRadarAgentGateway.JetStreamPublisher do
  @moduledoc """
  Project-owned JetStream publish-with-PubAck for the durable edge result relay
  (unify-sweep-results-proto task 3.3).

  Unlike `ServiceRadar.NATS.Connection.publish/3` (fire-and-forget `Gnat.pub`), a durable relay
  MUST observe the server's `PubAck` before it may report a frame durable. This module sends a
  JetStream publish *request*, waits for the reply, parses the `PubAck`, and classifies any error
  so the caller can withhold the resolved prefix (retryable) or route to the DLQ (permanent).

  Durability is the parsed `PubAck` returned here — never gRPC success, never a fire-and-forget
  publish, and never an ack from a stream other than the resolved route's.

  ## Nothing is taken on trust

  There is no public raw-publish entry point. `publish_record/3` takes a
  `ServiceRadar.Edge.ResolvedRoute` plus the verified slot and derives everything else: the
  subject and expected stream come from the route, publication identity is computed from the
  frozen grammar, and the provenance is stamped with the route's own map generation. A caller
  cannot supply a subject, a header, or a route-map version, because each of those is a way for
  the parts to disagree with one another while each looks individually valid.

  The returned ack is fenced against the resolved route's expected stream, so an ack from
  anywhere else is a `:protocol` error rather than a durability claim.
  """

  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadar.Edge.StreamRoute
  alias ServiceRadar.NATS.Connection

  require Logger

  @type pub_ack :: %{stream: String.t(), seq: non_neg_integer(), duplicate: boolean()}
  @type error_class :: :capacity | :timeout | :protocol | :permanent | :misrouted

  @default_timeout 5_000

  @doc """
  Publishes one record. The route is DERIVED here, from the same publication being sent.

  There is no variant that accepts a route, a subject, or a header. Accepting a route alongside a
  publication let the two describe different records -- a route resolved for one network scope
  could carry a slot from another, and every part still looked valid. Deriving from the
  authenticated publication makes that state unrepresentable rather than merely discouraged
  (task 3.3).

  `publication` is the GATEWAY-VERIFIED description of the record:

    * `:slot` — `%{authenticated_agent_id, network_scope_id, spool_id, sequence}`, all from the
      mTLS session, never read out of the frame. It is also the source of the partition
      coordinates, so the route cannot describe a different scope than the identity does.
    * `:route_profile`, `:traffic_class` — from the effective control-plane grant.
    * `:partition_rule` — the rule the output-contract bundle pins. Required; no default.
    * `:record_bytes` — the exact `EdgeDeliveryFrameV1.record_bytes`, published UNCHANGED.
    * `:record_sha256`, `:semantic_envelope_sha256` — 32-byte digests.
    * `:delivery_mode` — defaults to fresh; a non-fresh mode requires `:delivery_proof`.

  Returns `{:ok, pub_ack}`; `{:error, error_class}`; or `{:error, {:derivation, reason}}` when the
  route or identity could not be derived, which is a bug or a bad grant rather than something to
  retry against the broker.
  """
  @spec publish_record(map(), keyword()) ::
          {:ok, pub_ack()} | {:error, error_class()} | {:error, {:derivation, term()}}
  def publish_record(publication, opts \\ []) when is_map(publication) do
    with {:ok, route} <- resolve_route(publication) do
      send_to(route, publication, opts)
    end
  end

  @doc """
  Publishes a failed record to its class-preserving DLQ route.

  The DLQ route is derived from the SOURCE route and the same publication, so a failure cannot be
  reclassified into another traffic class or moved to another partition on its way to the queue.
  """
  @spec publish_dlq(map(), keyword()) ::
          {:ok, pub_ack()} | {:error, error_class()} | {:error, {:derivation, term()}}
  def publish_dlq(publication, opts \\ []) when is_map(publication) do
    with {:ok, source} <- resolve_route(publication),
         {:ok, dlq} <- wrap(StreamRoute.resolve_dlq(source, contract_of(publication))) do
      send_to(dlq, publication, opts)
    end
  end

  @doc """
  The route and headers this publication would use, without performing any I/O.

  For audit and for tests. It takes only the publication, for the same reason `publish_record/2`
  does.
  """
  @spec plan(map()) :: {:ok, map()} | {:error, {:derivation, term()}}
  def plan(publication) when is_map(publication) do
    with {:ok, route} <- resolve_route(publication),
         {:ok, headers} <- headers_for(route, publication) do
      {:ok, %{route: route, headers: headers}}
    end
  end

  # The contract handed to StreamRoute. The partition coordinates come from the AUTHENTICATED
  # slot rather than from a parallel field, which is what binds the route to the identity: there
  # is no second place for a scope to come from, so the two cannot disagree.
  defp contract_of(publication) do
    slot = Map.get(publication, :slot)

    coords =
      case slot do
        %{} = s ->
          %{
            network_scope_id: Map.get(s, :network_scope_id),
            authenticated_agent_id: Map.get(s, :authenticated_agent_id),
            spool_id: Map.get(s, :spool_id)
          }

        _ ->
          %{}
      end

    %{
      route_profile: Map.get(publication, :route_profile),
      traffic_class: Map.get(publication, :traffic_class),
      partition_rule: Map.get(publication, :partition_rule),
      partition_coordinates: coords
    }
  end

  defp resolve_route(publication), do: wrap(StreamRoute.resolve(contract_of(publication)))

  defp wrap({:ok, value}), do: {:ok, value}
  defp wrap({:error, reason}), do: {:error, {:derivation, reason}}

  defp send_to(route, publication, opts) do
    with {:ok, bytes} <- record_bytes(publication),
         {:ok, headers} <- headers_for(route, publication) do
      request(route, bytes, headers, opts)
    end
  end

  # PRIVATE: it takes a route, so exposing it would reopen exactly the route/publication split
  # that `publish_record/2` exists to close.
  defp headers_for(route, publication) do
    slot = Map.get(publication, :slot)
    record_sha = Map.get(publication, :record_sha256)
    semantic_sha = Map.get(publication, :semantic_envelope_sha256)
    mode = Map.get(publication, :delivery_mode, PublicationIdentity.mode_fresh())
    proof = Map.get(publication, :delivery_proof)

    with {:ok, msg_id} <- PublicationIdentity.nats_msg_id(slot, semantic_sha, record_sha),
         {:ok, delivery_id} <- PublicationIdentity.delivery_id(slot),
         {:ok, provenance} <-
           PublicationIdentity.transport_provenance(%{
             edge: slot,
             delivery_mode: mode,
             delivery_proof: proof,
             record_sha256: record_sha,
             # The PLACEMENT generation, from the route itself. Readiness compares this, and a
             # separately-supplied value would describe a placement that never happened.
             route_map_version: route.placement_version
           }) do
      {:ok,
       [
         {"Nats-Msg-Id", msg_id},
         {"Nats-Expected-Stream", route.expected_stream},
         {"Sr-Edge-Delivery-Id", delivery_id},
         {"Sr-Edge-Transport-Provenance", provenance}
       ]}
    else
      {:error, reason} -> {:error, {:derivation, reason}}
    end
  end

  # `:record_bytes` is REQUIRED. Returning the documented error tuple rather than letting the map
  # access raise: a caller that omits it gets the same shape as every other refusal, instead of a
  # KeyError escaping a function whose contract says it returns {:error, _}.
  defp record_bytes(publication) do
    case Map.get(publication, :record_bytes) do
      bytes when is_binary(bytes) -> {:ok, bytes}
      _ -> {:error, {:derivation, :record_bytes}}
    end
  end

  defp request(route, payload, headers, opts) do
    conn = Keyword.get(opts, :connection, Connection)
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)

    case conn.request(route.subject, payload, headers: headers, receive_timeout: timeout) do
      {:ok, %{body: body}} ->
        fence(route.expected_stream, parse_ack(body))

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, classify_transport(reason)}
    end
  end

  # `Nats-Expected-Stream` asks the SERVER to fence the publish, but a PubAck naming a different
  # stream must still be refused here rather than reported durable. Trusting the header alone
  # assumes every broker on the path honours it.
  defp fence(expected, {:ok, %{stream: expected} = ack}), do: {:ok, ack}

  defp fence(expected, {:ok, %{stream: other}}) do
    Logger.error("jetstream ack from unexpected stream",
      expected_stream: expected,
      acked_stream: other
    )

    {:error, :misrouted}
  end

  defp fence(_expected, other), do: other

  @doc """
  Parses a JetStream PubAck reply body. A success body is
  `{"stream","seq","duplicate"?}`; an error body carries an `"error"` object.
  """
  @spec parse_ack(binary()) :: {:ok, pub_ack()} | {:error, error_class()}
  def parse_ack(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} ->
        {:error, classify_ack_error(error)}

      # seq must be a POSITIVE u64. `is_integer/1` alone accepted -1 and 0, which are not
      # sequences any stream issues -- a malformed ack would have been reported as durable.
      {:ok, %{"stream" => stream, "seq" => seq} = ack}
      when is_binary(stream) and is_integer(seq) and seq >= 1 and seq <= 0xFFFFFFFFFFFFFFFF ->
        {:ok, %{stream: stream, seq: seq, duplicate: Map.get(ack, "duplicate", false) == true}}

      _ ->
        {:error, :protocol}
    end
  end

  def parse_ack(_), do: {:error, :protocol}

  @doc """
  Whether an error class WITHHOLDS SOURCE PROGRESS (true) or is terminal and DLQ-bound (false).

  "Retryable" names the disposition, not a prediction that a retry succeeds. `:misrouted` is the
  case that makes the distinction matter: an ack from an unexpected stream is NOT authoritative
  acceptance, so the source sequence must stay unresolved while publication/readiness is broken.
  Classifying it terminal would send a record that may already be durable elsewhere to the DLQ,
  and resolve a sequence that was never authoritatively accepted. It will not clear on retry --
  it clears when the route map or the broker's stream binding is repaired.
  """
  @spec retryable?(error_class()) :: boolean()
  def retryable?(class), do: class in [:capacity, :timeout, :misrouted]

  # Classify a JetStream ack error object
  # (`%{"code","description","err_code"}`). Capacity/back-pressure is retryable;
  # an expected-stream/sequence fence failure is a protocol error; anything else
  # is a permanent rejection routed to the DLQ.
  defp classify_ack_error(%{} = err) do
    code = err["code"]
    desc = err["description"] |> to_string() |> String.downcase()

    cond do
      code == 503 -> :capacity
      String.contains?(desc, "no responders") -> :capacity
      String.contains?(desc, "insufficient resources") -> :capacity
      String.contains?(desc, "maximum") and String.contains?(desc, "exceeded") -> :capacity
      String.contains?(desc, "expected") -> :protocol
      String.contains?(desc, "wrong last sequence") -> :protocol
      true -> :permanent
    end
  end

  defp classify_ack_error(_), do: :permanent

  # An unknown transport failure is treated as a retryable timeout -- never
  # silently dropped and never treated as durable success.
  defp classify_transport(:no_responders), do: :capacity
  defp classify_transport({:nats_not_connected, _}), do: :capacity
  defp classify_transport({:nats_connection_died, _}), do: :capacity
  defp classify_transport(_), do: :timeout
end
