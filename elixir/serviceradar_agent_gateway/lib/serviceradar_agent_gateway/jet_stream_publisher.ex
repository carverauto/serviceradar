defmodule ServiceRadarAgentGateway.JetStreamPublisher do
  @moduledoc """
  Project-owned JetStream publish-with-PubAck for the durable edge result relay
  (unify-sweep-results-proto task 3.3).

  Unlike `ServiceRadar.NATS.Connection.publish/3` (fire-and-forget `Gnat.pub`), a durable relay
  MUST observe the server's `PubAck` before it may report a frame durable. This module sends a
  JetStream publish *request*, waits for the reply, parses the `PubAck`, and classifies any
  refusal.

  Durability is the parsed `PubAck` returned here — never gRPC success, never a fire-and-forget
  publish, and never an ack from a stream other than the resolved route's.

  ## Nothing is taken on trust

  There is no public raw-publish entry point and no arity that accepts a route.
  `publish_record/2` takes ONLY the verified publication and derives everything from it: the
  subject and expected stream come from `StreamRoute`, the partition coordinates come from the
  authenticated slot, publication identity is computed from the frozen grammar, and the
  provenance is stamped with the route's own placement generation. A caller cannot supply a
  subject, a header, a partition, or a version, because each is a way for the parts to disagree
  while every part looks individually valid.

  ## Refusals default to WITHHOLD

  A refusal only becomes terminal (`:poison`) on proof the record can never be accepted, and
  NOTHING THE BROKER SAYS IS SUCH PROOF. A size refusal (`err_code` 10054, or the same thing by
  description) fires when headers plus payload exceed either the server's MaxPayload or the target
  stream's configured MaxMsgSize -- so a stale stream configuration produces it for a record that
  is entirely valid under the frozen ABI bounds. Proof requires a LOCAL preflight against those
  bounds, which task 3.4 supplies.

  So today `:poison` has no producer here, deliberately. Every refusal is classified RETRYABLE,
  which is what obliges a caller to leave the source sequence unresolved -- this module holds no
  such state. Sending an unrecognised or ambiguous refusal to the DLQ would discard a record that
  was never proven bad and resolve a sequence that was never accepted.

  ## No DLQ publication here, deliberately

  A DLQ publication is not "the same bytes on another subject": it needs the canonical bounded DLQ
  wrapper, a stable DLQ identity, the source stream/sequence, the error cohort and fingerprint,
  and the failure metadata. None of that exists yet. An earlier revision of this module shipped a
  `publish_dlq/2` that republished the raw record under ordinary publication identity, which
  would have produced DLQ entries indistinguishable from a normal publish and unusable for
  redrive. It is removed until the carrier and failure context land.
  """

  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublisherPool
  alias ServiceRadar.Edge.PublishWindow
  alias ServiceRadar.Edge.StreamRoute
  alias ServiceRadar.NATS.Connection

  require Logger

  @type pub_ack :: %{stream: String.t(), seq: non_neg_integer(), duplicate: boolean()}
  @type error_class :: :capacity | :timeout | :systemic | :misrouted | :poison

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
    contract = contract_of(publication)

    with {:ok, route} <- wrap(StreamRoute.resolve(contract)),
         {:ok, lane} <- resolve_lane(contract),
         {:ok, bytes} <- record_bytes(publication),
         {:ok, key} <- reservation_key(publication, bytes),
         # EVERY fallible local derivation completes BEFORE a credit is taken. Headers were
         # derived after admission, so a publication with a routable contract, a binary body and a
         # positive sequence could still fail the UUID/digest/proof checks -- performing no I/O
         # and leaving a reservation charged against the lane forever.
         {:ok, headers} <- headers_for(route, publication),
         {:ok, pool} <- pool_for(lane, opts),
         # The connection is resolved to a PID here, and the request below uses that pid rather
         # than re-resolving the lane's NAME. Re-resolving let an attempt straddle a lane restart:
         # admit through the old pool, publish through the newly registered connection while the
         # fresh pool holds no reservation, then settle against the dead pool -- an unaccounted
         # publish, and usually a :noproc exit in the caller. A captured pid is dead after a
         # restart, so the publish simply fails instead.
         {:ok, conn_pid} <- connection_for(lane, opts),
         {:ok, reservation} <- admit(pool, key, bytes, opts) do
      route
      |> request(conn_pid, bytes, headers, opts)
      |> settle(pool, reservation)
    end
  end

  defp connection_for(lane, opts) do
    conn = Keyword.get(opts, :connection, Connection)

    case conn.get(PublisherLane.connection_name(lane)) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, classify_transport(reason)}
    end
  end

  # The COMPLETE authenticated slot, which is what a reservation is keyed on. The lane sequence
  # alone aliases: one pool serves every agent and spool in its class, so two agents at sequence 1
  # looked like one frame retrying -- the second published on the first's credits and its ack
  # released the first's reservation.
  defp reservation_key(publication, bytes) do
    slot = Map.get(publication, :slot, %{})

    key =
      PublishWindow.key(
        Map.get(slot, :network_scope_id),
        Map.get(slot, :authenticated_agent_id),
        Map.get(slot, :spool_id),
        Map.get(slot, :sequence),
        fingerprint_of(publication, bytes)
      )

    {:ok, key}
  end

  # What makes a republish provably the SAME publication, and a second record on that slot a
  # DIFFERENT one. Both halves matter: the digest identifies the record, and the size is what the
  # byte credits were charged on.
  #
  # A different record on the same slot is therefore a SEPARATE reservation, admitted or refused on
  # its own credits -- never rejected. The spec requires it to be published: `Nats-Msg-Id` binds
  # `record_sha256`, so JetStream does not deduplicate it away and the frame must reach EventWriter,
  # which adjudicates the transport-integrity violation. Refusing here would move that decision into
  # the gateway and destroy the evidence.
  defp fingerprint_of(publication, bytes), do: {Map.get(publication, :record_sha256), byte_size(bytes)}

  # The lane's window, resolved BEFORE anything is published. Failing closed when no pool is
  # running is deliberate: a publish with no window is an unbounded publish, which is the state
  # this whole increment exists to end. `:pools` injects unregistered pools for tests so they can
  # stay async without colliding on the registered names.
  defp pool_for(lane, opts) do
    case opts |> Keyword.get(:pools, %{}) |> Map.get(lane, PublisherPool.via(lane)) do
      pid when is_pid(pid) ->
        {:ok, pid}

      name when is_atom(name) ->
        case Process.whereis(name) do
          # TRANSIENT, not a derivation failure. `:derivation` means a bad route, identity or
          # grant -- a bug or a bad grant, not something to retry against the broker. A lane
          # restart leaves a registration gap of exactly this shape, so it belongs on the same
          # retryable path as a dead or timed-out pool. Publishing still fails closed; what
          # changes is that the caller is told to come back.
          nil -> {:error, :systemic}
          pid -> {:ok, pid}
        end
    end
  end

  # `:already_outstanding` is NOT an error here: it means this sequence's credits are already
  # held, which is exactly the state a RETRY is in. PublishWindow keeps a retryable frame
  # outstanding on purpose -- a retry republishes the same bytes on the same slot, so
  # re-admitting would hand the same budget out twice and let the in-flight total exceed the
  # grant. Republishing under the credits already held is the designed path.
  defp admit(pool, key, bytes, opts) do
    # The TIMEOUT, not a deadline: the pool stamps the deadline when it actually admits, so time
    # spent queued for the pool is not deducted from the PubAck interval.
    case pool_call(fn -> PublisherPool.admit(pool, key, byte_size(bytes), timeout_of(opts)) end) do
      # Covers BOTH a new reservation and a republish of the same publication. The window
      # recognises the retry by key, charges nothing further, AND RE-ARMS THE DEADLINE -- a retry
      # that kept the expired one would be reported expired forever. The reservation carries the
      # epoch token, so this attempt can only ever settle its own.
      {:ok, reservation} ->
        {:ok, reservation}

      {:error, exhausted} when exhausted in [:frame_credits_exhausted, :byte_credits_exhausted] ->
        # Refuse rather than publish past the grant. The RETRYABLE class is what obliges a
        # caller to withhold progress; nothing is withheld here.
        {:error, :capacity}

      # A retry offered while the previous attempt is STILL on the wire. Refused rather than run
      # concurrently: two requests under one charge means the first acknowledgement frees a credit
      # while the second is still live, and the next admission takes the window past its grant.
      {:error, :attempt_in_flight} ->
        {:error, :capacity}

      # The lane has no live transport generation: it is between restarts, or its accountant was
      # replaced and is deliberately CLOSED until a transport registers. Nothing was published --
      # the refusal happens before any I/O -- and the condition clears on its own, so this is
      # RETRYABLE like any other capacity refusal rather than a fault in this publication.
      #
      # Classifying it as a derivation error, which is what the fall-through did, would have been
      # wrong twice: derivation is about THIS record's route, which is fine, and the fall-through
      # class is not one a caller should treat as terminal.
      {:error, :no_transport} ->
        {:error, :capacity}

      # The pool died between the lookup and this call -- a lane restart landing mid-attempt. The
      # contract is a tuple, not an exit, and nothing was published.
      {:error, :pool_gone} ->
        {:error, :systemic}

      # The pool did not answer in time. `PublisherPool.admit/4` has already revoked the admission,
      # so no credit is stranded. Nothing was published, and the retryable class leaves the
      # decision about progress to the caller.
      {:error, :pool_timeout} ->
        {:error, :systemic}

      {:error, reason} ->
        {:error, {:derivation, reason}}
    end
  end

  # Credits are released only for an outcome the window treats as SETTLING. A durable PubAck
  # settles; proven poison settles as a permanent rejection; everything else -- timeout, capacity,
  # systemic, misrouted -- leaves the frame outstanding, because it is still owed a republish on
  # the same slot. Releasing there would relax the bound exactly when the broker is struggling.
  #
  # The outcome here is an ACCOUNTING outcome, not a disposition. This publisher writes one record
  # to its resolved route and does not yet compute audit/quarantine/security-quarantine routing;
  # that mapping is task 3.5 and supplies the outcome when it lands.
  defp settle({:ok, _ack} = result, pool, reservation) do
    case pool_call(fn -> PublisherPool.settle(pool, reservation, :primary_publication) end) do
      :ok ->
        result

      # The publish reached the broker, but the accounting that authorised it did not survive to
      # record the fact -- the lane restarted, or this reservation was superseded. Reporting it
      # durable would be reporting a fact nothing can account for, so a RETRYABLE error is
      # returned instead. This function does not resolve or withhold a source sequence -- it has
      # no such state; withholding progress on a retryable error is the future caller's
      # obligation.
      #
      # Stated carefully, because a looser version of this comment claimed more: this function
      # returns an error, it does not itself republish -- there is no production caller yet. And
      # if a caller does retry, broker deduplication is not a general answer: `Nats-Msg-Id` dedup
      # is scoped to one stream and one duplicate window, so a copy landing outside that window,
      # or on a different stream, is not deduplicated there. The proposal names database
      # idempotency as the backstop for exactly that.
      #
      # WHICH failure this can now be has narrowed. A replacement pool no longer starts with a
      # full grant: the accountant is stable across transport restarts, so the case where the
      # ledger vanished under a live publish is gone. What reaches here is a SUPERSEDED
      # reservation, or an accountant that itself died -- and under :rest_for_one that terminates
      # the transport too, so the request could not have been completing on it either.
      #
      # Still not closed, and not by this branch: an owner that dies mid-request, whose
      # reservation stays charged (task 3.5's correlation work). See PublishWindow's "what this
      # still does not bound".
      {:error, reason} ->
        Logger.warning("publish could not be accounted for: #{inspect(reason)}")
        {:error, :systemic}
    end
  end

  defp settle({:error, :poison} = result, pool, reservation) do
    pool_call(fn -> PublisherPool.settle(pool, reservation, :permanent_rejection) end)
    result
  end

  defp settle(result, pool, reservation) do
    # NON-terminal: the record is still owed a republish, so the credits stay charged -- but the
    # ATTEMPT is over. Saying so is what makes the next retry a legal re-admission instead of
    # `:attempt_in_flight` forever.
    pool_call(fn -> PublisherPool.attempt_failed(pool, reservation) end)
    result
  end

  # EVERY pool call is guarded, not just settlement. A lane restart can land between resolving the
  # pool and admitting through it, and an unguarded GenServer.call would then exit the caller --
  # breaking the documented tuple-return contract at the one moment the system is already
  # degraded. The restarted lane has discarded its reservations either way.
  defp pool_call(fun) do
    fun.()
  catch
    :exit, reason ->
      Logger.warning("publisher pool unavailable: #{inspect(reason)}")
      {:error, :pool_gone}
  end

  defp timeout_of(opts), do: Keyword.get(opts, :receive_timeout, @default_timeout)

  # The lane comes from the SAME verified contract as the route, not from a second lookup and not
  # from anything on the frame. That is what makes "an agent cannot select the recovery publisher"
  # true at this call site rather than only in PublisherLane's docs: the route profile here is the
  # one the effective grant produced.
  defp resolve_lane(contract) do
    wrap(PublisherLane.for_lane(contract.route_profile, contract.traffic_class))
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

  defp request(route, conn_pid, payload, headers, opts) do
    conn = Keyword.get(opts, :connection, Connection)
    timeout = timeout_of(opts)
    # The CAPTURED lane connection: not the shared one, and not a fresh name lookup. Sharing
    # `:serviceradar_nats` put every lane's outstanding requests behind one socket and one Gnat
    # mailbox; re-resolving the name here let an attempt straddle a lane restart.
    case conn.request(conn_pid, route.subject, payload,
           headers: headers,
           receive_timeout: timeout
         ) do
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
    Logger.error("jetstream ack from unexpected stream: expected=#{expected} acked=#{other}")

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
        case duplicate_flag(ack) do
          {:ok, duplicate} -> {:ok, %{stream: stream, seq: seq, duplicate: duplicate}}
          :error -> {:error, :systemic}
        end

      _ ->
        # A body we cannot parse is NOT proof the record is poison. It is classified RETRYABLE,
        # which is what tells a caller to withhold progress; this function holds no such state.
        {:error, :systemic}
    end
  end

  def parse_ack(_), do: {:error, :systemic}

  # `Map.get(ack, "duplicate", false) == true` silently read any non-boolean as false, so a
  # broker (or a proxy) answering `"duplicate": "true"` would be recorded as a first write.
  defp duplicate_flag(ack) do
    case Map.fetch(ack, "duplicate") do
      :error -> {:ok, false}
      {:ok, v} when is_boolean(v) -> {:ok, v}
      {:ok, _} -> :error
    end
  end

  @doc """
  Whether an error class OBLIGES A CALLER TO WITHHOLD SOURCE PROGRESS (true) or is terminal and
  DLQ-bound (false). The obligation is the caller's; this module classifies, it does not advance
  or withhold anything.

  "Retryable" names the disposition, not a prediction that a retry succeeds. `:misrouted` is the
  case that makes the distinction matter: an ack from an unexpected stream is NOT authoritative
  acceptance, so a caller must leave the source sequence unresolved while publication or
  readiness is broken.
  Classifying it terminal would send a record that may already be durable elsewhere to the DLQ,
  and resolve a sequence that was never authoritatively accepted. It will not clear on retry --
  it clears when the route map or the broker's stream binding is repaired.
  """
  @spec retryable?(error_class()) :: boolean()
  def retryable?(class), do: class != :poison

  # Classify a JetStream ack error object (`%{"code","description","err_code"}`).
  #
  # THE DEFAULT IS WITHHOLD, NOT DLQ. A refusal only becomes terminal on PROOF that the record can
  # never be accepted; anything else -- unknown code, unrecognised description, a broker we do not
  # understand -- is classified retryable, which obliges a caller to leave the source sequence
  # unresolved. The previous default was `:permanent`,
  # which sent every unrecognised broker answer to the DLQ.
  #
  # `err_code` is preferred over the description because descriptions are prose and change. 10060
  # (JSStreamNotMatchErr) is the REAL expected-stream refusal: NATS answers a mismatched
  # `Nats-Expected-Stream` with this error, not with a successful ack naming another stream. It is
  # a routing/readiness fault, so it is classified retryable rather than DLQ-bound.
  defp classify_ack_error(%{} = err) do
    # `to_string/1` raises Protocol.UndefinedError on a map or list, and the error object is
    # whatever the broker sent. A malformed description must classify, not crash the publish.
    desc = description_text(err["description"])

    case err["err_code"] do
      10_060 -> :misrouted
      # 10054 is NOT proof of poison. NATS emits it when headers plus payload exceed EITHER the
      # server's MaxPayload OR the target stream's configured MaxMsgSize, so a stale stream
      # configuration terminalizes a record that is perfectly valid under the frozen ABI bounds.
      # Only a LOCAL frozen-bound preflight can prove a record can never be accepted, and task 3.4
      # supplies that. Until then the broker cannot tell us poison from misconfiguration.
      10_054 -> :systemic
      10_071 -> :systemic
      _ -> classify_by_description(err["code"], desc)
    end
  end

  defp classify_ack_error(_), do: :systemic

  defp description_text(d) when is_binary(d), do: String.downcase(d)
  defp description_text(d) when is_atom(d) or is_number(d), do: d |> to_string() |> String.downcase()
  defp description_text(_), do: ""

  defp classify_by_description(code, desc) do
    if capacity?(code, desc), do: :capacity, else: classify_refusal(desc)
  end

  # "The stream cannot take it right now" -- backpressure, always retryable.
  defp capacity?(code, desc) do
    code == 503 or
      String.contains?(desc, "no responders") or
      String.contains?(desc, "insufficient resources") or
      String.contains?(desc, "maximum messages") or
      String.contains?(desc, "maximum bytes")
  end

  defp classify_refusal(desc) do
    if String.contains?(desc, "expected") do
      :misrouted
    else
      # Everything else -- including a size refusal by description, which has the same
      # server-vs-stream ambiguity as err_code 10054 -- is classified RETRYABLE, not terminal.
      :systemic
    end
  end

  # An unknown transport failure is treated as a retryable timeout -- never
  # silently dropped and never treated as durable success.
  defp classify_transport(:no_responders), do: :capacity
  defp classify_transport({:nats_not_connected, _}), do: :capacity
  defp classify_transport({:nats_connection_died, _}), do: :capacity
  defp classify_transport(_), do: :timeout
end
