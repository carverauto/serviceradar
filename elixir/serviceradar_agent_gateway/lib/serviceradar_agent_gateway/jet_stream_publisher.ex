defmodule ServiceRadarAgentGateway.JetStreamPublisher do
  @moduledoc """
  Project-owned JetStream publish-with-PubAck for the durable edge result relay
  (unify-sweep-results-proto task 3.3).

  Unlike `ServiceRadar.NATS.Connection.publish/3` (fire-and-forget `Gnat.pub`),
  a durable relay MUST observe the server's `PubAck` before it may report a
  frame durable. This module sends a JetStream publish *request* (subject +
  `Nats-Msg-Id` for de-duplication + `Nats-Expected-Stream` to fence the target
  stream), waits for the reply, parses the `PubAck`, and classifies any error so
  the caller can withhold the resolved prefix (retryable) or route to the DLQ
  (permanent).

  Durability is the parsed `PubAck` returned here — never gRPC success, never a
  fire-and-forget publish. The classification mirrors the Go reference core
  `go/pkg/edge/gwpublish` (`:capacity`/`:timeout` retryable; `:protocol`/
  `:permanent` not).
  """

  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadar.Edge.StreamRoute
  alias ServiceRadar.NATS.Connection

  require Logger

  @type pub_ack :: %{stream: String.t(), seq: non_neg_integer(), duplicate: boolean()}
  @type error_class :: :capacity | :timeout | :protocol | :permanent

  @default_timeout 5_000

  @doc """
  Publishes one delivery frame, DERIVING its subject, expected stream, and every header.

  This is the entry point the relay should use. `publish/4` below takes a caller's subject and
  headers, which cannot be the durable path: publication identity is what makes a replay
  idempotent, so a caller that computes its own `Nats-Msg-Id` can silently give two different
  slots the same de-dup key, or the same slot two different ones. Nothing here is taken on
  trust (task 3.3).

  `publication` is a map:

    * `:slot` — `%{authenticated_agent_id, network_scope_id, spool_id, sequence}`, all
      GATEWAY-VERIFIED from the mTLS session, never read out of the frame.
    * `:record_bytes` — the exact `EdgeDeliveryFrameV1.record_bytes`. Published UNCHANGED; the
      delivery wrapper is never the body (task 3.4).
    * `:record_sha256`, `:semantic_envelope_sha256` — 32-byte digests.
    * `:route_profile`, `:traffic_class` — from the effective control-plane grant.
    * `:delivery_mode` — defaults to fresh; a non-fresh mode requires `:delivery_proof`.
    * `:partition_key` — defaults to the slot's `network_scope_id`.
    * `:route_map_version` — defaults to `StreamRoute.subject_version/0`.

  The four headers are the canonical transport set (`nats-msg-id`, `sr-edge-delivery-id`,
  `sr-edge-transport-provenance`) plus the `Nats-Expected-Stream` publish fence. The semantic
  envelope is NOT re-exported as headers; it is committed inside the msg id.

  Returns `{:ok, pub_ack}`, `{:error, error_class}` from the publish itself, or
  `{:error, {:derivation, reason}}` when identity or routing could not be derived — which is
  distinct on purpose, because a derivation failure is a bug or a bad grant, not something to
  retry against the broker.
  """
  @spec publish_record(map(), keyword()) ::
          {:ok, pub_ack()} | {:error, error_class()} | {:error, {:derivation, term()}}
  def publish_record(publication, opts \\ []) when is_map(publication) do
    with {:ok, derived} <- derive(publication) do
      publish(derived.subject, publication.record_bytes, derived.headers, opts)
    end
  end

  @doc """
  Derives the subject and headers for a publication without performing any I/O.

  Separate from `publish_record/2` so the derivation is testable on its own, and so a caller that
  needs the subject (audit, DLQ routing) does not have to publish to learn it.
  """
  @spec derive(map()) :: {:ok, map()} | {:error, {:derivation, term()}}
  def derive(publication) when is_map(publication) do
    slot = Map.get(publication, :slot)
    profile = Map.get(publication, :route_profile)
    class = Map.get(publication, :traffic_class)
    record_sha = Map.get(publication, :record_sha256)
    semantic_sha = Map.get(publication, :semantic_envelope_sha256)
    mode = Map.get(publication, :delivery_mode, PublicationIdentity.mode_fresh())
    proof = Map.get(publication, :delivery_proof)

    # The routing key defaults to the signed network scope, matching the partition contract.
    partition_key = Map.get(publication, :partition_key) || slot_scope(slot)

    # route_map_version has no frozen constant of its own; it must simply be nonzero. Defaulting
    # it to the subject scheme's version keeps the two in lockstep, so a subject-space bump is
    # recorded in the provenance of every record published under the new scheme. Override it if
    # the deployment ever versions its route map independently of the subject scheme.
    rmv = Map.get(publication, :route_map_version, StreamRoute.subject_version())

    with {:ok, partition} <- partition_of(partition_key),
         {:ok, subject} <- StreamRoute.data_subject(profile, class, partition),
         {:ok, stream} <- StreamRoute.physical_stream(profile, class),
         {:ok, msg_id} <- PublicationIdentity.nats_msg_id(slot, semantic_sha, record_sha),
         {:ok, delivery_id} <- PublicationIdentity.delivery_id(slot),
         {:ok, provenance} <-
           PublicationIdentity.transport_provenance(%{
             edge: slot,
             delivery_mode: mode,
             delivery_proof: proof,
             record_sha256: record_sha,
             route_map_version: rmv
           }) do
      {:ok,
       %{
         subject: subject,
         partition: partition,
         expected_stream: stream,
         headers: [
           {"Nats-Msg-Id", msg_id},
           {"Nats-Expected-Stream", stream},
           {"Sr-Edge-Delivery-Id", delivery_id},
           {"Sr-Edge-Transport-Provenance", provenance}
         ]
       }}
    else
      {:error, reason} -> {:error, {:derivation, reason}}
    end
  end

  defp slot_scope(slot) when is_map(slot), do: Map.get(slot, :network_scope_id)
  defp slot_scope(_), do: nil

  # A missing routing key is a derivation failure rather than partition 0. StreamRoute treats an
  # EMPTY key as partition 0 so a frame is always routable, but a key that is absent entirely
  # means the slot was never populated, and silently publishing that to partition 0 would pile
  # unrelated scopes onto one partition.
  defp partition_of(key) when is_binary(key), do: {:ok, StreamRoute.partition(key)}
  defp partition_of(_), do: {:error, :partition_key}

  @doc """
  Publishes `payload` to `subject` with `headers` and returns the parsed PubAck.

  LOW-LEVEL. Prefer `publish_record/2`, which derives the subject and headers; this one trusts
  both. It remains public because the DLQ path publishes an already-derived subject, and because
  the ack parsing and classification below are worth exercising directly.

  Options:

    * `:connection` — the connection module (default `ServiceRadar.NATS.Connection`);
      injectable for tests.
    * `:receive_timeout` — PubAck wait in ms (default #{@default_timeout}).
  """
  @spec publish(String.t(), binary(), list(), keyword()) ::
          {:ok, pub_ack()} | {:error, error_class()}
  def publish(subject, payload, headers, opts \\ []) do
    conn = Keyword.get(opts, :connection, Connection)
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)

    case conn.request(subject, payload, headers: headers, receive_timeout: timeout) do
      {:ok, %{body: body}} ->
        parse_ack(body)

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, classify_transport(reason)}
    end
  end

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
