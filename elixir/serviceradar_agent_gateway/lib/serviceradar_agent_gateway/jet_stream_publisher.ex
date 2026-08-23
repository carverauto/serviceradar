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
  alias ServiceRadar.Edge.ResolvedRoute
  alias ServiceRadar.NATS.Connection

  require Logger

  @type pub_ack :: %{stream: String.t(), seq: non_neg_integer(), duplicate: boolean()}
  @type error_class :: :capacity | :timeout | :protocol | :permanent

  @default_timeout 5_000

  @doc """
  Publishes one record to a RESOLVED route, deriving publication identity and fencing the ack.

  This is the only way to publish. There is no variant taking a caller's subject or headers:
  publication identity is what makes a replay idempotent, so a caller computing its own
  `Nats-Msg-Id` can silently give two different slots the same de-dup key, or one slot two
  different ones. Equally, a caller-supplied subject and expected-stream can disagree with each
  other. Taking one `ResolvedRoute` removes both possibilities -- subject, partition, expected
  stream, and map version are computed together by `StreamRoute` or not at all (task 3.3).

  Arguments:

    * `route` — a `ServiceRadar.Edge.ResolvedRoute` from `StreamRoute.resolve/1` (or
      `resolve_dlq/2` for the DLQ path).
    * `publication` — a map:
      * `:slot` — `%{authenticated_agent_id, network_scope_id, spool_id, sequence}`, all
        GATEWAY-VERIFIED from the mTLS session, never read out of the frame.
      * `:record_bytes` — the exact `EdgeDeliveryFrameV1.record_bytes`. Published UNCHANGED; the
        delivery wrapper is never the body (task 3.4).
      * `:record_sha256`, `:semantic_envelope_sha256` — 32-byte digests.
      * `:delivery_mode` — defaults to fresh; a non-fresh mode requires `:delivery_proof`.

  The route's `map_version` is what stamps the provenance, so the generation recorded is always
  the one that produced the subject.

  Returns `{:ok, pub_ack}`; `{:error, error_class}` from the publish; or
  `{:error, {:derivation, reason}}` when identity could not be derived -- distinct on purpose,
  because that is a bug or a bad grant rather than something to retry against the broker.
  """
  @spec publish_record(ResolvedRoute.t(), map(), keyword()) ::
          {:ok, pub_ack()} | {:error, error_class()} | {:error, {:derivation, term()}}
  def publish_record(route, publication, opts \\ [])

  def publish_record(%ResolvedRoute{} = route, publication, opts) when is_map(publication) do
    with {:ok, bytes} <- record_bytes(publication),
         {:ok, headers} <- headers_for(route, publication) do
      request(route, bytes, headers, opts)
    end
  end

  def publish_record(_, _, _), do: {:error, {:derivation, :route}}

  @doc """
  Builds the header set for a resolved route without performing any I/O.

  Separate from `publish_record/3` so the derivation is testable on its own, and so an audit
  caller can see exactly what would be sent.
  """
  @spec headers_for(ResolvedRoute.t(), map()) :: {:ok, list()} | {:error, {:derivation, term()}}
  def headers_for(%ResolvedRoute{} = route, publication) when is_map(publication) do
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
             # The route's own generation, never a separately-supplied one.
             route_map_version: route.map_version
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

  def headers_for(_, _), do: {:error, {:derivation, :route}}

  # `:record_bytes` is REQUIRED. Returning the documented error tuple rather than letting the map
  # access raise: a caller that omits it gets the same shape as every other refusal, instead of a
  # KeyError escaping a function whose contract says it returns {:error, _}.
  defp record_bytes(publication) do
    case Map.get(publication, :record_bytes) do
      bytes when is_binary(bytes) -> {:ok, bytes}
      _ -> {:error, {:derivation, :record_bytes}}
    end
  end

  # The raw request. PRIVATE: a public raw publish is a bypass around every guarantee above, and
  # it existed only because the DLQ path needed a subject -- which `StreamRoute.resolve_dlq/2` now
  # supplies as a ResolvedRoute, so the bypass has no remaining caller.
  defp request(%ResolvedRoute{} = route, payload, headers, opts) do
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
  # assumes every broker on the path honours it; an ack from another stream means the record is
  # durable somewhere the resolved route did not choose, which is indistinguishable from
  # misrouting. `:protocol` is the right class -- not retryable, because retrying reproduces it.
  defp fence(expected, {:ok, %{stream: expected} = ack}), do: {:ok, ack}

  defp fence(expected, {:ok, %{stream: other}}) do
    Logger.error("jetstream ack from unexpected stream",
      expected_stream: expected,
      acked_stream: other
    )

    {:error, :protocol}
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

      {:ok, %{"stream" => stream, "seq" => seq} = ack}
      when is_binary(stream) and is_integer(seq) ->
        {:ok, %{stream: stream, seq: seq, duplicate: Map.get(ack, "duplicate", false) == true}}

      _ ->
        {:error, :protocol}
    end
  end

  def parse_ack(_), do: {:error, :protocol}

  @doc "Whether an error class should be retried (withhold progress) vs DLQ'd."
  @spec retryable?(error_class()) :: boolean()
  def retryable?(class), do: class in [:capacity, :timeout]

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
