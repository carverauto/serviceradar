defmodule ServiceRadarAgentGateway.JetStreamPublisherTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublisherPool
  alias ServiceRadar.Edge.StreamRoute
  alias Serviceradar.Edge.V1.EdgeDeliveryFrameV1
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias ServiceRadarAgentGateway.JetStreamPublisher

  # A fake connection module driven by the test process mailbox: it records the
  # request and returns a canned reply.
  defmodule FakeConn do
    @moduledoc false
    # The publisher resolves the lane connection to a PID before admitting, so the double has to
    # answer get/1 too. Returning self() is enough: the test only cares WHICH connection was
    # resolved, which the :resolved message records.
    def get(name) do
      send(self(), {:resolved, name})
      {:ok, self()}
    end

    def request(conn_name, subject, payload, opts) do
      send(self(), {:requested, conn_name, subject, payload, opts})

      # Simulates a lane restart landing between admit and settle: the pool the caller admitted
      # through dies while its request is in flight.
      case Process.get(:kill_pool_during_request) do
        nil -> :ok
        pid -> Process.exit(pid, :kill)
      end

      Process.get(:fake_reply)
    end
  end

  defp with_reply(reply), do: Process.put(:fake_reply, reply)

  # Publishing now requires the lane's window: a publish with no pool is an unbounded publish, so
  # the publisher fails closed. These are UNREGISTERED pools, so the file stays async instead of
  # colliding with any other test on PublisherPool.via/1.
  defp with_pools(opts) do
    pools =
      Map.new(PublisherLane.lanes(), fn lane ->
        {:ok, pid} =
          PublisherPool.start_link(
            class: lane,
            frame_credits: 64,
            byte_credits: 64 * 1024 * 1024,
            name: nil
          )

        # A lane accountant is CLOSED until a transport registers. These tests are about the
        # PUBLISHER, not the transport, so a bare process stands in: what the accountant binds to
        # is a lifetime, and a real Gnat connection is not needed to provide one.
        transport = spawn(fn -> Process.sleep(:infinity) end)
        on_exit(fn -> Process.exit(transport, :kill) end)
        {:ok, _generation} = PublisherPool.register_transport(pid, transport)

        {lane, pid}
      end)

    Keyword.put(opts, :pools, pools)
  end

  describe "parse_ack/1" do
    test "parses a success PubAck" do
      body = ~s({"stream":"TELEMETRY_EDGE_RECORD_V1_BULK","seq":42})

      assert {:ok, %{stream: "TELEMETRY_EDGE_RECORD_V1_BULK", seq: 42, duplicate: false}} =
               JetStreamPublisher.parse_ack(body)
    end

    test "parses a duplicate PubAck" do
      body = ~s({"stream":"S","seq":7,"duplicate":true})
      assert {:ok, %{seq: 7, duplicate: true}} = JetStreamPublisher.parse_ack(body)
    end

    test "classifies a capacity (503) error as retryable capacity" do
      body = ~s({"error":{"code":503,"description":"no responders available"}})
      assert {:error, :capacity} = JetStreamPublisher.parse_ack(body)
    end

    test "classifies maximum-messages-exceeded as capacity" do
      body = ~s({"error":{"code":400,"description":"maximum messages exceeded"}})
      assert {:error, :capacity} = JetStreamPublisher.parse_ack(body)
    end

    test "the REAL expected-stream refusal (err_code 10060) is RETRYABLE, never terminal" do
      # NATS answers a mismatched Nats-Expected-Stream with error 10060 (JSStreamNotMatchErr),
      # NOT with a successful ack naming another stream. This is the path that actually fires,
      # and it was terminal.
      body = ~s({"error":{"code":400,"err_code":10060,"description":"expected stream does not match"}})
      assert {:error, :misrouted} = JetStreamPublisher.parse_ack(body)
      assert JetStreamPublisher.retryable?(:misrouted)
    end

    test "a wrong-last-sequence fence is retryable, not poison" do
      body = ~s({"error":{"code":400,"err_code":10071,"description":"wrong last sequence: 5"}})
      assert {:error, :systemic} = JetStreamPublisher.parse_ack(body)
      assert JetStreamPublisher.retryable?(:systemic)
    end

    test "a SIZE refusal is NOT proof of poison, because the broker cannot tell us why" do
      # NATS emits 10054 when headers plus payload exceed EITHER the server MaxPayload OR the
      # target stream's configured MaxMsgSize. A stale stream configuration therefore produces it
      # for a record entirely valid under the frozen ABI bounds, so treating it as terminal DLQs
      # a good record. Only a local frozen-bound preflight (task 3.4) can prove poison.
      assert {:error, :systemic} =
               JetStreamPublisher.parse_ack(
                 ~s({"error":{"code":400,"err_code":10054,"description":"message size exceeds maximum"}})
               )

      # ...and by description alone, which carries the same ambiguity.
      assert {:error, :systemic} =
               JetStreamPublisher.parse_ack(~s({"error":{"code":400,"description":"message size exceeds maximum"}}))
    end

    test "the WHOLE broker-code domain produces no :poison" do
      # Swept, not enumerated. The previous version listed six bodies, which proved only that
      # those six were safe. JetStream's API error space is 10000-10999; the sweep also covers
      # zero, negatives, and values past the range, because a broker is free to send anything.
      #
      # BOUND STATED HONESTLY: this is the realistic domain plus its edges, not literally every
      # integer. What it establishes is that no code-driven branch reaches :poison.
      codes = Enum.concat([[0, -1, -10_060, 1, 999], 10_000..10_999, [11_000, 999_999_999]])

      for code <- codes do
        body = ~s({"error":{"code":400,"err_code":#{code},"description":"x"}})
        assert {:error, class} = JetStreamPublisher.parse_ack(body)

        refute class == :poison, "err_code #{code} classified as :poison"

        assert JetStreamPublisher.retryable?(class),
               "err_code #{code} classified as #{class}, which is terminal"
      end
    end

    test "no DESCRIPTION reaches :poison either, including the size wording" do
      # The description path is the other way a refusal could become terminal. Size wording is
      # included deliberately: it is exactly the phrase that used to prove poison, and it must
      # not any more, because the broker cannot distinguish its own MaxPayload from a stale
      # stream MaxMsgSize.
      descriptions = [
        "message size exceeds maximum",
        "maximum messages exceeded",
        "maximum bytes exceeded",
        "no responders",
        "insufficient resources",
        "expected stream does not match",
        "wrong last sequence: 5",
        "",
        "something nobody has written yet"
      ]

      for desc <- descriptions do
        body = ~s({"error":{"code":400,"description":"#{desc}"}})
        assert {:error, class} = JetStreamPublisher.parse_ack(body)

        refute class == :poison, "description #{inspect(desc)} classified as :poison"
      end
    end

    test ":poison remains terminal, and its ONLY future source is local validation" do
      # The class still exists and is still the terminal one -- what changed is that nothing the
      # broker says produces it. Message-size validation against the frozen ABI bounds is the
      # sole intended source, and it is LOCAL (task 3.4). If a broker code is ever mapped back
      # to :poison, the sweep above fails and the decision has to be argued there.
      refute JetStreamPublisher.retryable?(:poison)

      for withheld <- [:capacity, :timeout, :misrouted, :systemic] do
        assert JetStreamPublisher.retryable?(withheld)
      end
    end

    test "a non-string error description classifies instead of raising" do
      # `to_string/1` raises Protocol.UndefinedError on a map or list, and the error object is
      # whatever the broker sent.
      for desc <- [~s({}), ~s([1,2]), "null", "17", "true"] do
        assert {:error, class} =
                 JetStreamPublisher.parse_ack(~s({"error":{"description":#{desc}}})),
               "description #{desc} did not classify"

        assert JetStreamPublisher.retryable?(class)
      end
    end

    test "an UNKNOWN broker refusal is classified RETRYABLE rather than DLQ-bound" do
      # The old default was :permanent, so any refusal this module did not recognise sent the
      # record to the DLQ without proof it was bad.
      for body <- [
            ~s({"error":{"code":400,"description":"some future error nobody has seen"}}),
            ~s({"error":{"code":499,"err_code":19999,"description":""}}),
            ~s({"error":{}})
          ] do
        assert {:error, :systemic} = JetStreamPublisher.parse_ack(body), "#{body} was terminal"
      end
    end

    test "an unparseable body is unresolved, not terminal" do
      assert {:error, :systemic} = JetStreamPublisher.parse_ack("not json")
      assert {:error, :systemic} = JetStreamPublisher.parse_ack(~s({"unexpected":true}))
      assert {:error, :systemic} = JetStreamPublisher.parse_ack(nil)
    end

    test "a non-boolean duplicate flag is refused, not silently read as false" do
      # `Map.get(ack, "duplicate", false) == true` read "true" (a string) as false, recording a
      # duplicate as a first write.
      for dup <- [~s("true"), "1", "null"] do
        assert {:error, :systemic} =
                 JetStreamPublisher.parse_ack(~s({"stream":"S","seq":1,"duplicate":#{dup}})),
               "duplicate=#{dup} was accepted"
      end

      assert {:ok, %{duplicate: true}} =
               JetStreamPublisher.parse_ack(~s({"stream":"S","seq":1,"duplicate":true}))

      assert {:ok, %{duplicate: false}} = JetStreamPublisher.parse_ack(~s({"stream":"S","seq":1}))
    end
  end

  describe "PubAck sequence bounds" do
    test "a non-positive or out-of-range sequence is a protocol error, never durable" do
      # `is_integer/1` alone accepted these. A malformed ack reported as durable resolves a
      # source sequence that was never accepted.
      for bad <- [-1, 0, -9_999, 0x1_0000_0000_0000_0000] do
        assert {:error, :systemic} =
                 JetStreamPublisher.parse_ack(~s({"stream":"S","seq":#{bad}})),
               "seq #{bad} was accepted"
      end
    end

    test "the boundaries themselves: 1 and u64 max are valid" do
      assert {:ok, %{seq: 1}} = JetStreamPublisher.parse_ack(~s({"stream":"S","seq":1}))

      assert {:ok, %{seq: 18_446_744_073_709_551_615}} =
               JetStreamPublisher.parse_ack(~s({"stream":"S","seq":18446744073709551615}))
    end
  end

  describe "publish_record/2 derives its own route" do
    defp uuidv7(seed) do
      bytes = Enum.map(0..15, &rem(seed + &1, 256))

      bytes
      |> List.replace_at(6, bor(band(Enum.at(bytes, 6), 0x0F), 0x70))
      |> List.replace_at(8, bor(band(Enum.at(bytes, 8), 0x3F), 0x80))
      |> :erlang.list_to_binary()
    end

    defp publication(overrides \\ %{}) do
      bytes = Map.get(overrides, :record_bytes, "the-canonical-record-bytes")

      Map.merge(
        %{
          slot: %{
            network_scope_id: uuidv7(0x40),
            authenticated_agent_id: "agent-0",
            spool_id: uuidv7(0x01),
            sequence: 7
          },
          route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
          traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
          partition_rule: :network_scope_v1,
          record_bytes: bytes,
          record_sha256: :crypto.hash(:sha256, bytes),
          semantic_envelope_sha256: :binary.copy(<<0xAA>>, 32)
        },
        overrides
      )
    end

    defp header(headers, name), do: Enum.find_value(headers, fn {k, v} -> if k == name, do: v end)

    test "there is NO api that accepts a route, so route and publication cannot disagree" do
      # Exercises the real entry point as well as the shape: the structural assertions below are
      # only meaningful if the two-arg form is the one that actually works.
      assert {:ok, %{route: _, headers: _}} = JetStreamPublisher.plan(publication())

      # The previous shape took (route, publication) and a test proved the two could describe
      # different records -- a route resolved for one scope publishing a slot from another.
      # ensure_loaded! first: function_exported?/3 answers false for a module that simply has
      # not been loaded, which would make every assertion here pass for the wrong reason.
      {:module, _} = Code.ensure_loaded(JetStreamPublisher)

      refute function_exported?(JetStreamPublisher, :publish_record, 3)
      refute function_exported?(JetStreamPublisher, :headers_for, 2)
      assert function_exported?(JetStreamPublisher, :publish_record, 2)
    end

    test "the subject follows the slot's scope: changing the scope moves the record" do
      {:ok, a} = JetStreamPublisher.plan(publication())

      other_slot = %{publication().slot | network_scope_id: uuidv7(0x70)}
      {:ok, b} = JetStreamPublisher.plan(publication(%{slot: other_slot}))

      refute a.route.subject == b.route.subject,
             "the route ignored the authenticated scope, so it is not bound to the publication"
    end

    test "publishes the record bytes UNCHANGED to the derived subject" do
      {:ok, planned} = JetStreamPublisher.plan(publication())
      with_reply({:ok, %{body: ~s({"stream":"#{planned.route.expected_stream}","seq":3})}})

      assert {:ok, %{seq: 3}} =
               JetStreamPublisher.publish_record(publication(), with_pools(connection: FakeConn))

      assert_received {:requested, _conn, subject, payload, _opts}
      assert payload == publication().record_bytes
      assert subject == planned.route.subject
      assert subject =~ ~r"^telemetry\.edge-record\.v1\.bulk\.p\d{2}$"
    end

    test "each active lane publishes on ITS OWN connection, never the shared one" do
      # The point of the separate connections is only real if the PUBLISHER uses them. Asserting
      # the connection inventory elsewhere cannot see this: the names can be perfectly correct
      # while every publish still goes out on :serviceradar_nats.
      conns =
        for {profile, class} <- StreamRoute.active_lanes() do
          {:ok, lane} = PublisherLane.for_lane(profile, class)
          pub = publication(%{route_profile: profile, traffic_class: class})
          {:ok, planned} = JetStreamPublisher.plan(pub)
          with_reply({:ok, %{body: ~s({"stream":"#{planned.route.expected_stream}","seq":1})}})

          assert {:ok, _} = JetStreamPublisher.publish_record(pub, with_pools(connection: FakeConn))
          # The connection is resolved by NAME once, before admission, and the request then uses
          # the resolved PID -- so the lane is asserted on the resolution, not on the request.
          assert_received {:resolved, name}
          assert_received {:requested, conn, _subject, _payload, _opts}
          assert name === PublisherLane.connection_name(lane)
          assert is_pid(conn)
          name
        end

      # NOT VACUOUS: the four active pairs resolve to THREE distinct connections -- both recovery
      # pairs share one -- so a single hard-coded connection cannot satisfy this, and neither can
      # a per-call unique value.
      assert length(conns) === 4
      assert length(Enum.uniq(conns)) === 3

      # And none of them is the shared platform connection.
      refute ServiceRadar.NATS.Supervisor.connection_name() in conns
    end

    # A pool per lane with room for exactly ONE frame, so saturation is reachable.
    defp one_frame_pools do
      Map.new(PublisherLane.lanes(), fn lane ->
        {:ok, pid} =
          PublisherPool.start_link(class: lane, frame_credits: 1, byte_credits: 10_000, name: nil)

        transport = spawn(fn -> Process.sleep(:infinity) end)
        on_exit(fn -> Process.exit(transport, :kill) end)
        {:ok, _generation} = PublisherPool.register_transport(pid, transport)

        {lane, pid}
      end)
    end

    defp pub_seq(seq) do
      base = publication()
      %{base | slot: Map.put(base.slot, :sequence, seq)}
    end

    # A publication on a DIFFERENT authenticated slot at the same lane sequence. The normative
    # identity is (network_scope_id, authenticated_agent_id, spool_id, sequence), and one lane
    # pool is shared by every agent and spool in that class, so the sequence alone does not
    # identify a reservation.
    defp pub_other_slot(seq, bytes) do
      base = publication(%{record_bytes: bytes})

      slot = %{
        network_scope_id: uuidv7(0x41),
        authenticated_agent_id: "agent-OTHER",
        spool_id: uuidv7(0x02),
        sequence: seq
      }

      %{base | slot: slot}
    end

    test "COUNTEREXAMPLE: a different slot at the same sequence must not ride A's reservation" do
      pools = one_frame_pools()

      # A takes the lane's only frame and times out, so its reservation stays outstanding.
      with_reply({:error, :timeout})
      assert {:error, :timeout} = JetStreamPublisher.publish_record(pub_seq(1), connection: FakeConn, pools: pools)
      assert_received {:requested, _, _, _, _}

      # B is a DIFFERENT agent and spool with DIFFERENT bytes, at the same sequence number. It is
      # not a retry of A. With one frame already held, it must be refused -- not published on A's
      # credits, and certainly not able to settle A's reservation.
      {:ok, planned} = JetStreamPublisher.plan(pub_seq(1))
      with_reply({:ok, %{body: ~s({"stream":"#{planned.route.expected_stream}","seq":9})}})

      assert {:error, :capacity} =
               JetStreamPublisher.publish_record(pub_other_slot(1, "different-bytes"),
                 connection: FakeConn,
                 pools: pools
               )

      refute_received {:requested, _, _, _, _}

      # And A's reservation is still held: B must not have released it.
      assert %{outstanding_frames: 1, available_frames: 0} = PublisherPool.capacity(pools[:bulk])
    end

    test "a DIFFERENT record on the SAME slot is published, on its OWN credits" do
      # NORMATIVE: "a frame reuses the same slot with a different record_sha256 ... JetStream SHALL
      # NOT deduplicate it away and the frame SHALL reach EventWriter", which rejects it as a
      # transport-integrity violation. Refusing it in the gateway -- as an earlier :slot_conflict
      # did -- moves EventWriter's adjudication upstream and destroys the evidence.
      #
      # A holds its reservation THROUGHOUT: an earlier version settled A first, which passed just
      # as well with record identity dropped from the key, so it bound nothing. Two credits, two
      # charges, both outstanding at once is what proves the keys are distinct.
      pools =
        Map.new(PublisherLane.lanes(), fn lane ->
          {:ok, pid} =
            PublisherPool.start_link(class: lane, frame_credits: 2, byte_credits: 10_000, name: nil)

          transport = spawn(fn -> Process.sleep(:infinity) end)
          on_exit(fn -> Process.exit(transport, :kill) end)
          {:ok, _generation} = PublisherPool.register_transport(pid, transport)

          {lane, pid}
        end)

      first = publication()
      second = publication(%{record_bytes: "a-different-record"})

      # A times out, so its attempt ends but its reservation stays charged.
      with_reply({:error, :timeout})
      assert {:error, :timeout} = JetStreamPublisher.publish_record(first, connection: FakeConn, pools: pools)
      assert_received {:requested, _c1, _s1, _p1, opts1}
      assert %{outstanding_frames: 1} = PublisherPool.capacity(pools[:bulk])

      {:ok, planned} = JetStreamPublisher.plan(second)
      with_reply({:ok, %{body: ~s({"stream":"#{planned.route.expected_stream}","seq":2})}})

      assert {:ok, _} =
               JetStreamPublisher.publish_record(second, connection: FakeConn, pools: pools),
             "the second record on that slot was refused; the spec requires it to be published"

      assert_received {:requested, _c2, _s2, payload2, opts2}
      assert payload2 === "a-different-record"

      # TWO independent charges. With the record dropped from the key, B would have been taken for
      # A's retry -- refused as :attempt_in_flight, or riding A's single charge.
      assert %{outstanding_frames: 1} = PublisherPool.capacity(pools[:bulk]),
             "B settled, so only A's charge should remain -- two distinct reservations existed"

      # Distinct Nats-Msg-Id is what stops JetStream deduplicating the second away.
      msg_id = fn opts -> opts |> Keyword.fetch!(:headers) |> header("Nats-Msg-Id") end
      refute msg_id.(opts1) === msg_id.(opts2)
    end

    test "admission against a DEAD pool returns a tuple, never an exit" do
      # The pool pid is captured before admission, so a lane restart can land between the lookup
      # and the call. An unguarded GenServer.call would exit the caller and break the documented
      # tuple contract at exactly the moment the system is already degraded.
      pools = with_pools([])[:pools]
      Process.flag(:trap_exit, true)
      dead = pools[:bulk]
      Process.exit(dead, :kill)
      assert_receive {:EXIT, ^dead, _}

      with_reply({:ok, %{body: ~s({"stream":"S","seq":1})}})

      assert {:error, :systemic} =
               JetStreamPublisher.publish_record(publication(), connection: FakeConn, pools: pools)

      refute_received {:requested, _, _, _, _}
    end

    test "a pool that dies mid-attempt does not exit the caller" do
      # :one_for_all restarts a lane as a unit, so the pool a caller admitted through can be gone
      # by the time it settles. The publish has already happened; the caller must get its result,
      # not a :noproc exit from settlement.
      # The pools are LINKED to this process, so trap exits: the point is that the PUBLISHER
      # survives the pool dying, not that the pool can be killed without consequence here.
      Process.flag(:trap_exit, true)

      pools = with_pools([])[:pools]
      {:ok, planned} = JetStreamPublisher.plan(publication())
      with_reply({:ok, %{body: ~s({"stream":"#{planned.route.expected_stream}","seq":4})}})
      Process.put(:kill_pool_during_request, pools[:bulk])

      # NOT reported durable. The publish reached the broker, but the accounting that authorised
      # it is gone, so a RETRYABLE class is returned instead: reporting {:ok, ack} would report a
      # fact nothing can account for.
      #
      # What happens next is NOT established here. Nothing at this layer republishes -- there is
      # no production caller -- and if a caller does retry, `Nats-Msg-Id` deduplication is scoped
      # to one stream and one duplicate window, so it is not a general answer either.
      assert {:error, :systemic} =
               JetStreamPublisher.publish_record(publication(),
                 connection: FakeConn,
                 pools: pools
               ),
             "a publish whose accounting was destroyed was reported durable"

      assert JetStreamPublisher.retryable?(:systemic)

      Process.delete(:kill_pool_during_request)
      refute Process.alive?(pools[:bulk])
    end

    test "COUNTEREXAMPLE: a derivation failure after admission must not consume a credit" do
      pools = one_frame_pools()

      # Routable contract, binary body, positive sequence -- but the identity derivation fails on
      # a short digest, so no I/O happens. A reservation taken before that check leaks.
      assert {:error, {:derivation, _}} =
               JetStreamPublisher.publish_record(publication(%{record_sha256: <<1, 2, 3>>}),
                 connection: FakeConn,
                 pools: pools
               )

      refute_received {:requested, _, _, _, _}

      assert %{outstanding_frames: 0, available_frames: 1} = PublisherPool.capacity(pools[:bulk]),
             "a failed derivation consumed a credit despite performing no I/O"
    end

    test "COUNTEREXAMPLE: a verified retry re-arms its deadline" do
      pools = one_frame_pools()

      with_reply({:error, :timeout})

      assert {:error, :timeout} =
               JetStreamPublisher.publish_record(pub_seq(1),
                 connection: FakeConn,
                 pools: pools,
                 receive_timeout: 0
               )

      # The retry carries a long timeout. PublishWindow documents re-arm as the retry path, so
      # after it the frame must NOT already be expired.
      assert {:error, :timeout} =
               JetStreamPublisher.publish_record(pub_seq(1),
                 connection: FakeConn,
                 pools: pools,
                 receive_timeout: 60_000
               )

      # The pool owns the clock, so there is no `now` to pass -- and no malformed `now` that could
      # crash it and take the lane with it.
      assert PublisherPool.expired(pools[:bulk]) === [],
             "the retry kept the expired deadline instead of re-arming it"
    end

    test "a saturated lane REFUSES and publishes nothing" do
      pools = one_frame_pools()

      # A timeout leaves the frame OUTSTANDING -- it is still owed a republish on the same slot --
      # so its credit stays held. That is what makes the lane saturated with one frame.
      with_reply({:error, :timeout})
      assert {:error, :timeout} = JetStreamPublisher.publish_record(pub_seq(1), connection: FakeConn, pools: pools)
      assert_received {:requested, _, _, _, _}

      # The second frame has no credit. It must be refused BEFORE any I/O.
      assert {:error, :capacity} =
               JetStreamPublisher.publish_record(pub_seq(2), connection: FakeConn, pools: pools)

      refute_received {:requested, _, _, _, _}
    end

    test "a durable PubAck settles, releasing the credit for the next frame" do
      pools = one_frame_pools()

      {:ok, planned} = JetStreamPublisher.plan(pub_seq(1))
      with_reply({:ok, %{body: ~s({"stream":"#{planned.route.expected_stream}","seq":1})}})
      assert {:ok, _} = JetStreamPublisher.publish_record(pub_seq(1), connection: FakeConn, pools: pools)
      assert_received {:requested, _, _, _, _}

      # NOT VACUOUS: the previous test proves a one-frame lane refuses a second frame when the
      # first is unsettled. Here the first SETTLED, so the second must get through.
      with_reply({:ok, %{body: ~s({"stream":"#{planned.route.expected_stream}","seq":2})}})
      assert {:ok, _} = JetStreamPublisher.publish_record(pub_seq(2), connection: FakeConn, pools: pools)
      assert_received {:requested, _, _, _, _}
    end

    test "republishing an OUTSTANDING sequence is admitted without a second credit" do
      pools = one_frame_pools()

      with_reply({:error, :timeout})
      assert {:error, :timeout} = JetStreamPublisher.publish_record(pub_seq(1), connection: FakeConn, pools: pools)
      assert_received {:requested, _, _, _, _}

      # The retry is the SAME sequence: its credits are already held, so re-admitting would hand
      # the same budget out twice. It must publish, not be refused as saturated.
      {:ok, planned} = JetStreamPublisher.plan(pub_seq(1))
      with_reply({:ok, %{body: ~s({"stream":"#{planned.route.expected_stream}","seq":9})}})
      assert {:ok, _} = JetStreamPublisher.publish_record(pub_seq(1), connection: FakeConn, pools: pools)
      assert_received {:requested, _, _, _, _}
    end

    test "with NO pool running, the publish fails closed and sends nothing" do
      # A publish with no window is an unbounded publish. Refusing is the whole point; falling
      # back to the shared connection would restore exactly the state this replaced.
      #
      # The absent pool is INJECTED by name rather than relied on being absent globally: the
      # gateway application starts the real PublisherSupervisor, so :edge_publisher_pool_bulk is
      # registered in this VM and a test that assumed otherwise passed for the wrong reason.
      with_reply({:ok, %{body: ~s({"stream":"S","seq":1})}})

      # RETRYABLE, not a derivation failure: a lane restart leaves a registration gap of exactly
      # this shape, and `:derivation` means a bad route, identity or grant.
      assert {:error, :systemic} =
               JetStreamPublisher.publish_record(publication(),
                 connection: FakeConn,
                 pools: %{bulk: :no_such_publisher_pool_is_registered}
               )

      assert JetStreamPublisher.retryable?(:systemic)

      refute_received {:requested, _, _, _, _}
    end

    test "an unknown partition rule refuses before any publish" do
      with_reply({:ok, %{body: ~s({"stream":"S","seq":1})}})

      assert {:error, {:derivation, :unknown_partition_rule}} =
               JetStreamPublisher.publish_record(
                 publication(%{partition_rule: :execution_v1}),
                 with_pools(connection: FakeConn)
               )

      refute_received {:requested, _, _, _, _}
    end

    # NAMED for what it actually varies. `publication/1` derives record_sha256 from the bytes, but
    # the publisher consumes only the DIGEST -- nothing yet binds the bytes to the hash, so this
    # proves the digest moves the msg id, not the bytes. Task 3.4 adds that binding; rename this
    # back when it does.
    test "a different record digest produces a different msg id" do
      {:ok, a} = JetStreamPublisher.plan(publication(%{record_bytes: "record-one"}))
      {:ok, b} = JetStreamPublisher.plan(publication(%{record_bytes: "record-two"}))

      refute header(a.headers, "Nats-Msg-Id") == header(b.headers, "Nats-Msg-Id")
      assert header(a.headers, "Sr-Edge-Delivery-Id") == header(b.headers, "Sr-Edge-Delivery-Id")
    end
  end

  describe "the header wiring is bound to the ABI vectors" do
    # Task 3.3 requires the exact vector assertion to cover the PUBLISHER's header wiring, not
    # merely the identity functions underneath. Asserting only that headers are non-empty and
    # change relationally leaves `Nats-Msg-Id` and the provenance swappable while staying green.
    @testdata Path.expand("../../../../proto/edge/v1/testdata", __DIR__)

    defp fixture_path(name) do
      direct = Path.join(@testdata, name)

      cond do
        File.exists?(direct) ->
          {:ok, direct}

        dir = System.get_env("TEST_SRCDIR") ->
          [System.get_env("TEST_WORKSPACE"), "_main"]
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&Path.join([dir, &1, "proto/edge/v1/testdata", name]))
          |> Enum.find(&File.exists?/1)
          |> case do
            nil -> :error
            p -> {:ok, p}
          end

        true ->
          :error
      end
    end

    defp load(name) do
      case fixture_path(name) do
        {:ok, path} -> File.read!(path)
        :error -> raise "shared fixture #{name} not found under #{@testdata} or TEST_SRCDIR"
      end
    end

    # The EXACT construction the shared vectors were cut with -- it embeds a fixed millisecond
    # prefix rather than sequential bytes. Reproducing it is the whole point: a nearby-but-
    # different spool id yields a different msg id, which is how this test first failed.
    @fixed_millis 1_784_000_000_000

    defp vector_uuidv7(seed) do
      <<ms6::binary-6, _::binary-2>> = <<@fixed_millis <<< 16::big-64>>
      rest = for i <- 6..15, into: <<>>, do: <<seed + i::8>>
      <<b0::binary-6, b6, b7, b8, b9::binary-7>> = ms6 <> rest
      b0 <> <<(b6 &&& 0x0F) ||| 0x70, b7, (b8 &&& 0x3F) ||| 0x80>> <> b9
    end

    defp vector_publication do
      record_bin = load("record.bin")
      record = EdgeRecordV1.decode(record_bin)

      %{
        # The same slot the shared golden vectors were cut against.
        slot: %{
          network_scope_id: record.network_scope_id,
          authenticated_agent_id: record.producer_context.origin_principal_id,
          spool_id: vector_uuidv7(0x01),
          sequence: 1
        },
        route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
        traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
        partition_rule: :network_scope_v1,
        record_bytes: record_bin,
        record_sha256: :crypto.hash(:sha256, record_bin),
        semantic_envelope_sha256: record.semantic_envelope_sha256
      }
    end

    test "each header carries the exact ABI vector value for its own name" do
      publication = vector_publication()

      assert {:ok, planned} = JetStreamPublisher.plan(publication)

      expected_msg_id = load("nats_msg_id.txt")
      expected_delivery_id = load("delivery_id.txt")

      # NOT VACUOUS, and this is the point: the value is pinned to the header NAME. Swapping
      # Nats-Msg-Id with the provenance, or with the delivery id, fails here.
      assert header(planned.headers, "Nats-Msg-Id") == expected_msg_id
      assert header(planned.headers, "Sr-Edge-Delivery-Id") == expected_delivery_id

      # The two are distinct values, so the assertions above cannot both pass by coincidence.
      refute expected_msg_id == expected_delivery_id

      # Provenance is a real, distinct value on its own header.
      provenance = header(planned.headers, "Sr-Edge-Transport-Provenance")
      assert is_binary(provenance) and provenance != ""
      refute provenance in [expected_msg_id, expected_delivery_id]

      assert header(planned.headers, "Nats-Expected-Stream") == planned.route.expected_stream
    end

    # DERIVED from the module's exported mode_*/0 functions rather than a hand-written list, so a
    # new delivery mode is covered automatically -- or fails loudly here for having no capability
    # mapping, which is the outcome we want rather than silent non-coverage.
    defp all_delivery_modes do
      :functions
      |> PublicationIdentity.__info__()
      |> Enum.filter(fn {name, arity} ->
        arity == 0 and String.starts_with?(Atom.to_string(name), "mode_")
      end)
      |> Enum.map(fn {name, _} -> {name, apply(PublicationIdentity, name, [])} end)
      |> Enum.sort_by(&elem(&1, 1))
    end

    defp renewal_capability, do: EdgeSignedCapabilityV1.decode(load("delivery_renewal_cap.bin"))

    # The rollover capability is the one embedded in the shared delivery frame.
    defp rollover_capability do
      EdgeDeliveryFrameV1.decode(load("delivery_frame.bin")).delivery_capability
    end

    # mode -> the capability whose transition that mode accepts. fresh takes no proof;
    # late_fenced accepts a renewal OR a rollover grant.
    defp capability_for(:mode_fresh), do: nil
    defp capability_for(:mode_renewal), do: renewal_capability()
    defp capability_for(:mode_rollover), do: rollover_capability()
    defp capability_for(:mode_late_fenced), do: renewal_capability()

    defp publication_in_mode(name, mode) do
      case capability_for(name) do
        nil ->
          vector_publication()

        cap ->
          {:ok, proof} = PublicationIdentity.delivery_proof_digest(cap, mode)

          vector_publication()
          |> Map.put(:delivery_mode, mode)
          |> Map.put(:delivery_proof, proof)
      end
    end

    # The normative set, stated once. Compared BIDIRECTIONALLY against reflection below.
    @normative_modes [
      {:mode_fresh, 1},
      {:mode_renewal, 2},
      {:mode_rollover, 3},
      {:mode_late_fenced, 4}
    ]

    test "every supported delivery mode is exercised, and the set is derived" do
      modes = all_delivery_modes()

      # BIDIRECTIONAL, on names AND values. Reflection alone catches an ADDITION, but a deletion
      # or a rename would silently shrink the universe these tests iterate -- the suite would
      # still pass while covering less. Comparing both directions makes any of the three fail.
      assert MapSet.new(modes) == MapSet.new(@normative_modes),
             "discovered #{inspect(Enum.sort(modes))}, normative #{inspect(@normative_modes)}"

      # And the reflection is not vacuously empty.
      assert length(modes) == 4

      for {name, mode} <- modes do
        assert {:ok, planned} = JetStreamPublisher.plan(publication_in_mode(name, mode)),
               "#{name} did not plan"

        value = header(planned.headers, "Sr-Edge-Transport-Provenance")

        {:ok, decoded} = PublicationIdentity.decode_transport_provenance(value)

        assert decoded.delivery_mode == mode,
               "#{name} produced provenance for mode #{decoded.delivery_mode}"
      end
    end

    test "each mode produces a DISTINCT provenance, so proof propagation cannot be dropped" do
      values =
        for {name, mode} <- all_delivery_modes() do
          {:ok, planned} = JetStreamPublisher.plan(publication_in_mode(name, mode))
          header(planned.headers, "Sr-Edge-Transport-Provenance")
        end

      # NOT VACUOUS: deleting proof propagation collapses the non-fresh modes onto the fresh
      # value, which this catches without needing to know what any of them should be.
      assert length(Enum.uniq(values)) == length(values),
             "two delivery modes produced identical provenance"
    end

    test "the header key multiset is EXACTLY four keys once each, in EVERY delivery mode" do
      # EVERY mode, from the same derived set. Checking fresh alone let a renewal-only extra
      # header survive the whole publisher file; checking fresh and renewal alone would still
      # have missed a rollover- or late-fenced-only one. Distinct provenance (above) is
      # additional evidence, NOT a substitute for asserting the exact key set here.
      for {label, pub} <-
            Enum.map(all_delivery_modes(), fn {name, mode} ->
              {name, publication_in_mode(name, mode)}
            end) do
        {:ok, planned} = JetStreamPublisher.plan(pub)
        keys = Enum.map(planned.headers, &elem(&1, 0))

        assert Enum.sort(keys) == [
                 "Nats-Expected-Stream",
                 "Nats-Msg-Id",
                 "Sr-Edge-Delivery-Id",
                 "Sr-Edge-Transport-Provenance"
               ],
               "#{label} mode emitted #{inspect(Enum.sort(keys))}"

        assert length(keys) == length(Enum.uniq(keys)), "#{label} mode repeated a header key"
      end
    end

    test "the provenance value is EXACT for a fresh delivery, not merely nonempty" do
      pub = vector_publication()
      {:ok, planned} = JetStreamPublisher.plan(pub)

      # Bound to the inputs the publisher must supply, spelled out here. The grammar itself is
      # bound to the shared vectors by the core golden test; this layer proves the WIRING --
      # mode, proof, digest, slot and the route's own placement generation. `transport_provenance`
      # vectors were cut at route_map_version 7, which no route carries, so the value cannot be
      # asserted against the file directly.
      {:ok, expected} =
        PublicationIdentity.transport_provenance(%{
          edge: pub.slot,
          delivery_mode: PublicationIdentity.mode_fresh(),
          delivery_proof: nil,
          record_sha256: pub.record_sha256,
          route_map_version: planned.route.placement_version
        })

      assert header(planned.headers, "Sr-Edge-Transport-Provenance") == expected

      # And it DECODES to the fields the publisher claimed, via the independent decoder.
      {:ok, decoded} =
        PublicationIdentity.decode_transport_provenance(expected)

      assert decoded.delivery_mode == PublicationIdentity.mode_fresh()
      assert decoded.route_map_version == planned.route.placement_version
    end

    test "a NON-FRESH delivery propagates its proof into the provenance" do
      cap =
        EdgeSignedCapabilityV1.decode(load("delivery_renewal_cap.bin"))

      renewal = PublicationIdentity.mode_renewal()
      {:ok, proof} = PublicationIdentity.delivery_proof_digest(cap, renewal)

      pub =
        vector_publication()
        |> Map.put(:delivery_mode, renewal)
        |> Map.put(:delivery_proof, proof)

      {:ok, planned} = JetStreamPublisher.plan(pub)
      value = header(planned.headers, "Sr-Edge-Transport-Provenance")

      {:ok, expected} =
        PublicationIdentity.transport_provenance(%{
          edge: pub.slot,
          delivery_mode: renewal,
          delivery_proof: proof,
          record_sha256: pub.record_sha256,
          route_map_version: planned.route.placement_version
        })

      assert value == expected

      # NOT VACUOUS: deleting the proof propagation would produce the FRESH value, and every
      # fixture in this file was fresh before, so nothing would have noticed.
      {:ok, fresh_planned} = JetStreamPublisher.plan(vector_publication())
      refute value == header(fresh_planned.headers, "Sr-Edge-Transport-Provenance")

      {:ok, decoded} = PublicationIdentity.decode_transport_provenance(value)
      assert decoded.delivery_mode == renewal
    end

    test "a non-fresh mode WITHOUT its proof is refused" do
      pub = Map.put(vector_publication(), :delivery_mode, PublicationIdentity.mode_renewal())
      assert {:error, {:derivation, _}} = JetStreamPublisher.plan(pub)
    end
  end

  describe "a wrong-stream ack is classified RETRYABLE rather than DLQ-bound" do
    defp planned_pub do
      pub = %{
        slot: %{
          network_scope_id: uuidv7(0x40),
          authenticated_agent_id: "agent-0",
          spool_id: uuidv7(0x01),
          sequence: 7
        },
        route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
        traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
        partition_rule: :network_scope_v1,
        record_bytes: "rec",
        record_sha256: :crypto.hash(:sha256, "rec"),
        semantic_envelope_sha256: :binary.copy(<<0xAA>>, 32)
      }

      {:ok, planned} = JetStreamPublisher.plan(pub)
      {pub, planned}
    end

    test "an ack naming the expected stream is durable" do
      {pub, planned} = planned_pub()
      with_reply({:ok, %{body: ~s({"stream":"#{planned.route.expected_stream}","seq":5})}})

      assert {:ok, %{seq: 5}} = JetStreamPublisher.publish_record(pub, with_pools(connection: FakeConn))
    end

    test "an ack from ANOTHER stream is :misrouted, and :misrouted is RETRYABLE" do
      {pub, _planned} = planned_pub()
      with_reply({:ok, %{body: ~s({"stream":"TELEMETRY_EDGE_RECORD_V1_INTERACTIVE","seq":5})}})

      assert {:error, :misrouted} = JetStreamPublisher.publish_record(pub, with_pools(connection: FakeConn))

      # THE POINT: a wrong-stream ack is not authoritative acceptance. Classifying it terminal
      # would DLQ a record that may already be durable elsewhere and resolve a sequence that was
      # never accepted. Progress must stay unresolved instead.
      assert JetStreamPublisher.retryable?(:misrouted),
             "a misrouted ack must be RETRYABLE so a caller can withhold progress, not terminal"
    end

    test "ONLY proven poison is terminal; everything else is RETRYABLE" do
      refute JetStreamPublisher.retryable?(:poison)

      for retryable <- [:capacity, :timeout, :misrouted, :systemic] do
        assert JetStreamPublisher.retryable?(retryable), "#{retryable} must be classified retryable"
      end
    end
  end

  describe "refusals never reach the broker" do
    defp base_pub do
      %{
        slot: %{
          network_scope_id: uuidv7(0x40),
          authenticated_agent_id: "agent-0",
          spool_id: uuidv7(0x01),
          sequence: 7
        },
        route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
        traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
        partition_rule: :network_scope_v1,
        record_bytes: "rec",
        record_sha256: :crypto.hash(:sha256, "rec"),
        semantic_envelope_sha256: :binary.copy(<<0xAA>>, 32)
      }
    end

    test "MISSING record_bytes returns the documented error tuple rather than raising" do
      with_reply({:ok, %{body: ~s({"stream":"S","seq":1})}})

      assert {:error, {:derivation, :record_bytes}} =
               JetStreamPublisher.publish_record(
                 Map.delete(base_pub(), :record_bytes),
                 with_pools(connection: FakeConn)
               )

      refute_received {:requested, _, _, _, _}
    end

    test "non-binary record_bytes is refused the same way" do
      assert {:error, {:derivation, :record_bytes}} =
               JetStreamPublisher.publish_record(
                 Map.put(base_pub(), :record_bytes, :not_binary),
                 with_pools(connection: FakeConn)
               )
    end

    test "a malformed slot is a derivation error, never a published record" do
      with_reply({:ok, %{body: ~s({"stream":"S","seq":1})}})

      for bad <- [
            %{slot: %{base_pub().slot | sequence: 0}},
            %{slot: %{base_pub().slot | authenticated_agent_id: "not a principal!"}},
            %{slot: %{base_pub().slot | spool_id: <<0::128>>}},
            %{record_sha256: <<1, 2, 3>>},
            %{semantic_envelope_sha256: <<>>}
          ] do
        assert {:error, {:derivation, _}} =
                 JetStreamPublisher.publish_record(
                   Map.merge(base_pub(), bad),
                   with_pools(connection: FakeConn)
                 ),
               "expected #{inspect(Map.keys(bad))} to fail derivation"
      end

      refute_received {:requested, _, _, _, _}
    end

    test "there is no public raw-publish bypass" do
      {:module, _} = Code.ensure_loaded(JetStreamPublisher)

      # The supported path works...
      assert {:ok, %{headers: _}} = JetStreamPublisher.plan(base_pub())

      # ...and there is no raw one beside it.
      refute function_exported?(JetStreamPublisher, :publish, 3)
      refute function_exported?(JetStreamPublisher, :publish, 4)
    end

    test "transport failures stay retryable and are never durable success" do
      with_reply({:error, :timeout})

      assert {:error, :timeout} =
               JetStreamPublisher.publish_record(base_pub(), with_pools(connection: FakeConn))

      with_reply({:error, {:nats_not_connected, :down}})

      assert {:error, :capacity} =
               JetStreamPublisher.publish_record(base_pub(), with_pools(connection: FakeConn))
    end
  end
end
