defmodule ServiceRadar.Edge.SemanticEnvelopeCorpusTest do
  @moduledoc """
  Task 1.5-i: the SEMANTIC-ENVELOPE TRANSCRIPT INVENTORY, this runtime's half.

  SEVEN KEYED SETS, EACH GUARDED ON ITS OWN, AND NO GRAND TOTAL -- they count different proof
  units, so adding them would invent a number that means nothing.

  ## What makes this cross-runtime evidence

  The vectors are FROZEN and the baselines are COMMITTED `.bin` artifacts. Both runtimes frame
  THE SAME INPUT and are held to THE SAME EXPECTED BYTES. A peer that built its own baseline
  would compare a different message and agree only by luck; a peer that recomputed the expected
  value would compare the grammar against itself and drift in step with it.

  That is the whole point of this file: it is the only place the two implementations of the
  grammar are forced to produce identical bytes rather than merely to be internally consistent.

  ## What this runtime can and cannot reach

  `ClaimsFraming.output_contract/1` and `claims_framed/1` are PUBLIC here, so the two seams are
  compared as exact framed bytes. `capability`, `source_auth` and `producer_context` are private
  inside `SemanticDigest`, so their rows go through `compute/1` -- the same split the manifest
  records, from the opposite side: those framers are same-package private in Go too.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.ClaimsFraming
  alias ServiceRadar.Edge.SemanticDigest
  alias Serviceradar.Edge.V1.EdgeAssignmentExecutionClaimsV1
  alias Serviceradar.Edge.V1.EdgeCollectionClaimsV1
  alias Serviceradar.Edge.V1.EdgeDeliveryClaimsV1
  alias Serviceradar.Edge.V1.EdgeDeliveryFrameV1
  alias Serviceradar.Edge.V1.EdgeDeliveryRenewalV1
  alias Serviceradar.Edge.V1.EdgeDeliveryRolloverV1
  alias Serviceradar.Edge.V1.EdgeOutputContractRef
  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeProductionClaimsV1
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias Serviceradar.Edge.V1.EdgeSourceAuthorizationV1
  alias Serviceradar.Edge.V1.EdgeSourceClaimsV1

  @seam_framers ~w(output_contract collection_claims production_claims source_claims
                   delivery_claims execution_grant_claims)

  # EVERY COMMITTED VECTOR MUST BE READ BY SOME TEST HERE.
  #
  # A NAMED INVENTORY IS NOT AN OBSERVED ONE. The previous guard listed the keys this runtime
  # "consumes" and compared that list to the file, which passes whether or not anything reads
  # them: restricting the shape loop to two of three variants left thirteen `.v2` keys unread and
  # every test green. Reads are recorded at the accessor instead.
  #
  # THE CHECK RUNS IN after_suite, NOT IN setup_all's on_exit. A failure raised from on_exit is
  # attributed to EVERY test in the module -- one unread key reported twenty-six failures and
  # buried whichever assertion actually broke -- and reading the vector file from setup_all moved
  # the duplicate-key rejection into setup, where ExUnit reported it outside the failure count.
  #
  # NO READS AT ALL means this module was filtered out of the run, not that its vectors go
  # unasserted, so the check stands down.
  ExUnit.after_suite(fn _results -> __MODULE__.assert_every_vector_was_read!() end)

  @doc false
  # Public because the after_suite closure is built in MODULE SCOPE, where private functions are
  # not in scope; the call itself is resolved at run time.
  def assert_every_vector_was_read! do
    if :persistent_term.get({__MODULE__, :any_read}, false) do
      unread =
        committed_vector_keys()
        |> Enum.reject(&:persistent_term.get({__MODULE__, :read, &1}, false))
        |> Enum.sort()

      if unread != [] do
        raise "#{length(unread)} committed vectors are asserted by NO test in this runtime, so " <>
                "they are frozen values that cannot fail and cannot catch a divergence: " <>
                inspect(unread)
      end
    end
  end

  @doc false
  def committed_vector_keys do
    "semantic_envelope_vectors.txt"
    |> fixture()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
    |> Enum.map(&(&1 |> String.trim() |> String.split(~r/\s+/, parts: 2) |> hd()))
  end

  # The states ONE capability carrier can be in: absent, or present carrying one claims
  # discriminant -- refined by the delivery transition oneof and the execution grant's
  # source-identity presence, which are themselves declared axes.
  @carrier_states ~w(absent production source collection unset
                     delivery delivery.renewal delivery.rollover
                     assignment assignment.no_identity)

  # THE FULL CROSS PRODUCT OF THE DECLARED STRUCTURAL AXES, enumerated mechanically.
  #
  # A hand-picked matrix did not converge: five rounds each found a reordering conditioned on some
  # state no fixture held, and each round added the missing case. So the matrix is ENUMERATED from
  # the declared axes rather than chosen, and it is exhaustive OVER THOSE AXES -- not over every
  # program either runtime can express. The static guards in both runtimes are defense-in-depth
  # regression checks on the shape this enumeration assumes, with known limits recorded alongside
  # them:
  #
  #   output_contract presence   2
  #   producer_context presence  2, and its optional authority_epoch when present -> 3
  #   production capability     10 states
  #   source_authorization      11: absent, or present with its capability in 10 states
  #
  # 2 x 3 x 10 x 11 = 660, plus the base record whose claims come from the generator.
  @shapes ["base"] ++
            for(
              oc <- ~w(1 0),
              pc <- ~w(1 0),
              ep <- if(pc == "1", do: ~w(1 0), else: ~w(-)),
              p <- @carrier_states,
              n <- ["sa_absent" | @carrier_states],
              do: "oc#{oc}|pc#{pc}|ep#{ep}|p-#{p}|n-#{n}"
            )

  @record_variants 3

  describe "the manifest is intact" do
    test "each keyed set holds its exact count and no key repeats" do
      want = %{
        "op" => 125,
        "slot" => 17,
        "state" => 8,
        "edge" => 13,
        "sep" => 5,
        "excl" => 2,
        "rel" => 1
      }

      rows = corpus()
      got = Enum.frequencies_by(rows, & &1.kind)

      assert got == want, "keyed-set cardinality drifted: #{inspect(got)}"

      keys = Enum.map(rows, & &1.key)
      assert length(keys) == length(Enum.uniq(keys)), "a key appears twice"
    end

    test "the slot classes are DERIVED FROM THIS RUNTIME'S DESCRIPTORS, not copied" do
      # Counting rows cannot see a RELABELLING. `direct` vs `composite` is exactly "does this
      # field carry a message", so both runtimes derive it from their own view of the schema --
      # which is also what makes the two views comparable at all.
      class =
        Map.new(EdgeRecordV1.__message_props__().field_props, fn {num, f} ->
          kind = if composite?(f.type), do: "composite", else: "direct"
          {"#{String.pad_leading(to_string(num), 2, "0")}.#{f.name}", kind}
        end)

      for row <- rows_of("slot"), row.key != "version" do
        assert Map.has_key?(class, row.key),
               "slot #{row.key} names no {number, name} pair in this runtime's descriptor"

        assert {row.detail, row.probe} == {Map.fetch!(class, row.key), "attach"},
               "slot #{row.key}: manifest says {#{row.detail} #{row.probe}}, this runtime's " <>
                 "descriptor says {#{Map.fetch!(class, row.key)} attach}"
      end

      assert "slot"
             |> rows_of()
             |> Enum.find(&(&1.key == "version"))
             |> then(&{&1.detail, &1.probe}) ==
               {"version_corpus.semantic_envelope", "reuse"}
    end

    test "the claims discriminants agree with THIS runtime's descriptors" do
      # Those numbers ARE the framed discriminant values, so a renumbering relabels every claim
      # while the member set and the count stay identical. Both runtimes pin them independently;
      # a peer that trusted Go's view could not catch a divergence between the two.
      got =
        EdgeSignedCapabilityV1.__message_props__().field_props
        |> Enum.filter(fn {_, f} -> f.oneof end)
        |> Map.new(fn {num, f} -> {num, f.type} end)

      assert got == %{
               7 => EdgeProductionClaimsV1,
               8 => EdgeSourceClaimsV1,
               9 => EdgeDeliveryClaimsV1,
               11 => EdgeCollectionClaimsV1,
               12 => EdgeAssignmentExecutionClaimsV1
             }
    end

    test "every non-slot set is bound to EXACT {key, detail, probe} tuples" do
      # Cardinality survives a wholesale rename, and a `detail` column nothing compares is a
      # column that can say anything. Go owns the NESTED-LEAF closure (it walks all nine grammar
      # roots); this runtime owns the same shared file's tuples, so neither consumer can drift
      # from it alone.
      assert_tuples("excl", %{
        "17.semantic_envelope_sha256" => {"self", "exclude"},
        "18.payload" => {"raw", "exclude"}
      })

      assert_tuples("rel", %{"18.payload->06.payload_sha256" => {"transitive", "relation"}})

      assert_tuples("sep", %{
        "producer_receipt.submission_sha256" => {"schema-absent", "closure"},
        "physical_artifact.record_sha256.legal_reencoding" => {"reencode", "invariant"},
        "delivery_frame.spool_id" => {"outer-frame", "invariant"},
        "delivery_frame.sequence" => {"outer-frame", "invariant"},
        "delivery_frame.delivery_capability" => {"outer-frame", "invariant"}
      })

      assert_tuples("state", %{
        "presence.output_contract" => {"absent+present", "preimage"},
        "presence.producer_context" => {"absent+present", "committed"},
        "presence.capability@production+source_auth" => {"absent+present", "committed"},
        "presence.source_authorization" => {"absent+present", "committed"},
        "presence.execution_source_identity" => {"absent+present", "preimage"},
        "discriminant.claims" => {"0,7,8,9,11,12", "preimage"},
        "discriminant.delivery_transition" => {"0,5,6", "preimage"},
        "optional.producer_context.authority_epoch" => {"absent,0,1", "digest"}
      })

      assert_tuples(
        "edge",
        Map.new(
          ~w(root->output_contract root->producer_context root->production_capability
             root->source_authorization source_authorization->capability
             capability->claims_framed claims_framed->production_claims
             claims_framed->source_claims claims_framed->delivery_claims
             claims_framed->collection_claims claims_framed->execution_grant_claims
             delivery_claims->transition execution_grant_claims->source_identity),
          &{&1, {"occurrence", "attach"}}
        )
      )
    end

    test "what this runtime does NOT own is stated, not implied" do
      # THE LEDGER SAID BOTH CONSUMERS CLOSED THE SHARED MANIFEST; THEY DO NOT. `op` is 125 keys
      # naming leaf paths across nine grammar roots, and its closure is DESCRIPTOR-DRIVEN in Go:
      # the walk discovers the paths and the manifest classifies them. Restating 125 keys here
      # would be duplication, not independent evidence -- so this runtime owns the slot and
      # discriminant derivations from its OWN descriptors, the exact tuples of every other set,
      # and frozen-vector parity. Go owns `op` and the nested-leaf closure. This test exists so
      # the division is asserted rather than described.
      assert length(rows_of("op")) == 125

      bound = ~w(slot state edge sep excl rel)

      for kind <- bound do
        assert rows_of(kind) != [],
               "#{kind} is claimed as bound here but the manifest has no rows"
      end

      refute "op" in bound
    end
  end

  defp composite?({:enum, _}), do: false
  defp composite?(type) when is_atom(type), do: Code.ensure_loaded?(type)
  defp composite?(_), do: false

  defp rows_of(kind), do: Enum.filter(corpus(), &(&1.kind == kind))

  defp assert_tuples(kind, want) do
    rows = rows_of(kind)

    assert length(rows) == map_size(want),
           "#{kind}: manifest has #{length(rows)} rows, this runtime binds #{map_size(want)}"

    for row <- rows do
      assert Map.has_key?(want, row.key),
             "#{kind}: manifest key #{row.key} is bound to nothing here"

      assert {row.detail, row.probe} == Map.fetch!(want, row.key),
             "#{kind} #{row.key}: manifest tuple {#{row.detail} #{row.probe}} disagrees with the bound"
    end
  end

  describe "cross-runtime vector parity" do
    test "every seam framer produces the COMMITTED bytes, populated and default" do
      vectors = vectors()

      for framer <- @seam_framers, state <- ["populated", "default"] do
        key = "framer.#{framer}.#{state}"
        want = vector!(vectors, key)

        msg =
          case state do
            "populated" -> baseline(framer)
            "default" -> empty_for(framer)
          end

        assert hex(frame(framer, msg)) == want,
               "#{key}: this runtime frames different bytes from the committed vector"
      end
    end

    test "BOTH states matter: default vectors are where conditional omission would hide" do
      # A populated baseline pins order and width. A framer that skipped zero-valued fields
      # would frame the populated case identically to a conforming one and diverge only here,
      # which is exactly the cross-runtime disagreement this pair exists to catch.
      vectors = vectors()

      for framer <- @seam_framers do
        assert vector!(vectors, "framer.#{framer}.populated") !=
                 vector!(vectors, "framer.#{framer}.default"),
               "#{framer}: populated and default frame identically, so the default vector adds nothing"
      end
    end
  end

  describe "state cases against committed vectors" do
    test "presence at the two public seams" do
      vectors = vectors()

      # output_contract carries presence EXPLICITLY: `nil` is the absent case, not a typed nil
      # that reads as present.
      assert hex(ClaimsFraming.output_contract(nil)) ==
               vector!(vectors, "state.output_contract.absent")

      assert hex(ClaimsFraming.output_contract(baseline("output_contract"))) ==
               vector!(vectors, "state.output_contract.present")
    end

    test "the execution grant's source identity, both states" do
      vectors = vectors()
      with_id = baseline("execution_grant_claims")
      without = %{with_id | source_identity: nil}

      assert hex(frame("execution_grant_claims", with_id)) ==
               vector!(vectors, "state.execution_source_identity.present")

      assert hex(frame("execution_grant_claims", without)) ==
               vector!(vectors, "state.execution_source_identity.absent")
    end

    test "the claims discriminants are the EXACT frozen values" do
      # Changing a variant also changes the branch BODY, so inequality between variants would
      # hold even if the discriminant were dropped entirely. Only the frozen value pins it.
      vectors = vectors()

      pairs = [
        {"production", {:production, %EdgeProductionClaimsV1{}}},
        {"source", {:source, %EdgeSourceClaimsV1{}}},
        {"delivery", {:delivery, %EdgeDeliveryClaimsV1{}}},
        {"collection", {:collection, %EdgeCollectionClaimsV1{}}},
        {"assignment_execution", {:assignment_execution, %EdgeAssignmentExecutionClaimsV1{}}},
        {"unset", nil}
      ]

      for {name, claims} <- pairs do
        assert hex(ClaimsFraming.claims_framed(claims)) ==
                 vector!(vectors, "state.claims_discriminant.#{name}"),
               "claims discriminant #{name} disagrees with the committed vector"
      end
    end

    test "the delivery transition discriminants are the EXACT frozen values" do
      vectors = vectors()

      for {name, transition} <- [
            {"renewal", {:renewal, %EdgeDeliveryRenewalV1{}}},
            {"rollover", {:rollover, %EdgeDeliveryRolloverV1{}}},
            {"unset", nil}
          ] do
        claims = %EdgeDeliveryClaimsV1{transition: transition}

        assert hex(frame("delivery_claims", claims)) ==
                 vector!(vectors, "state.delivery_transition.#{name}"),
               "delivery transition #{name} disagrees with the committed vector"
      end
    end

    test "the delivery transition's POPULATED bodies, both variants" do
      # The `unset` vector above shares its bytes with a framer that dropped the branch entirely;
      # a defaulted body shares them with one that wrote the marker and nothing else. Only a
      # populated body pins the ORDER and WIDTH of the fields inside each branch, and the two
      # variants have to be pinned separately because they are different messages.
      vectors = vectors()

      renewal = %EdgeDeliveryClaimsV1{
        transition:
          {:renewal,
           %EdgeDeliveryRenewalV1{
             renewed_not_before_unix_nano: 1_700_000_000_000_000_000,
             renewed_expires_unix_nano: 1_900_000_000_000_000_000
           }}
      }

      rollover = %EdgeDeliveryClaimsV1{
        transition:
          {:rollover,
           %EdgeDeliveryRolloverV1{
             recovery_id: :binary.copy(<<0x61>>, 16),
             prior_spool_id: :binary.copy(<<0x62>>, 16),
             prior_sequence: 7
           }}
      }

      assert hex(frame("delivery_claims", renewal)) ==
               vector!(vectors, "state.delivery_transition.renewal.populated")

      assert hex(frame("delivery_claims", rollover)) ==
               vector!(vectors, "state.delivery_transition.rollover.populated")
    end

    test "the fully populated whole-envelope digest is the ROOT-ORDER witness" do
      # Per-slot inequality cannot see order: swapping two composite blocks leaves every slot row
      # green in both runtimes. The base shape NAMES that measurement -- it shares its value with
      # the state.<slot>.present rows, which are the same whole-envelope measurement under other
      # names -- and it moves HERE, at every committed variant, so a reordering that reached one
      # runtime and not the other cannot hide. WHICH rows those are is not restated here; the
      # test below derives the set from the committed vectors.
      vectors = vectors()

      digests =
        for v <- 0..(record_variants() - 1) do
          d = hex(SemanticDigest.compute(record(v)))
          assert d == vector!(vectors, "root.shape.base.v#{v}")
          d
        end

      assert length(Enum.uniq(digests)) == length(digests),
             "the record variants frame identically, so the extra fixtures add no signature"
    end

    test "the base-shape alias set is EXACT" do
      # DERIVED, NOT COUNTED IN PROSE. The keys sharing the base-shape digest are the same
      # whole-envelope measurement under other names, and which rows they are decides what the
      # witness above is evidence FOR. The size was written out in three places; when the fifth
      # row appeared one of them still read "four" and survived a review round, because nothing
      # executed it. This fails instead, and names the drift.
      vectors = vectors()
      base = vector!(vectors, "root.shape.base.v0")

      # vectors/0 directly, NOT vector!/2: recording a read for every key would mark the whole
      # corpus observed and make the after_suite unread-vector guard vacuous. The members are
      # asserted by their own tests, which is what records them.
      got =
        vectors
        |> Enum.filter(fn {_k, v} -> v == base end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      assert got == [
               "root.shape.base.v0",
               "state.capability.present",
               "state.capability@source_auth.present",
               "state.output_contract@root.present",
               "state.producer_context.present",
               "state.source_authorization.present"
             ],
             "the base-shape alias set moved"
    end

    test "the capability framer's SECOND carrier, both states" do
      # The framer is called from the production slot AND from source_auth. Covering one leaves
      # the other's presence argument free to be hardcoded.
      vectors = vectors()
      rec = record()

      assert hex(SemanticDigest.compute(rec)) ==
               vector!(vectors, "state.capability@source_auth.present")

      without = %{rec | source_authorization: %{rec.source_authorization | capability: nil}}

      assert hex(SemanticDigest.compute(without)) ==
               vector!(vectors, "state.capability@source_auth.absent")
    end

    test "the only optU64 site: absent, present-zero, present-one" do
      # Absent vs present-zero proves the MARKER; present-zero vs present-one proves the VALUE.
      # Without the first pair, weakening `!= nil` to `!= 0` is invisible.
      vectors = vectors()
      rec = record()

      for {name, value} <- [{"absent", nil}, {"zero", 0}, {"one", 1}] do
        ctx = %{rec.producer_context | authority_epoch: value}

        assert hex(SemanticDigest.compute(%{rec | producer_context: ctx})) ==
                 vector!(vectors, "state.authority_epoch.#{name}"),
               "authority_epoch #{name} disagrees with the committed vector"
      end
    end

    test "present-but-DEFAULT states, where conditional omission hides" do
      # A populated baseline cannot see a framer that skips zero-valued fields: it would frame
      # the populated case identically and diverge only here.
      vectors = vectors()
      rec = record()

      cases = [
        {"capability", %{rec | production_capability: %EdgeSignedCapabilityV1{}}},
        {"source_auth", %{rec | source_authorization: %EdgeSourceAuthorizationV1{}}},
        {"producer_context", %{rec | producer_context: %EdgeProducerContext{}}},
        {"transition",
         put_nested_claims(
           rec,
           {:delivery,
            %EdgeDeliveryClaimsV1{
              transition: {:renewal, %EdgeDeliveryRenewalV1{}}
            }}
         )},
        {"source_identity",
         put_nested_claims(
           rec,
           {:assignment_execution,
            %EdgeAssignmentExecutionClaimsV1{
              source_identity: %Serviceradar.Edge.V1.EdgeSourceSpanIdentityV1{}
            }}
         )},
        {"scalars",
         %{
           rec
           | event_id: <<>>,
             network_scope_id: <<>>,
             payload_sha256: <<>>,
             encoded_size: 0,
             uncompressed_size: 0,
             projected_row_count: 0,
             projected_write_bytes: 0,
             cost_model_version: 0,
             payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_UNSPECIFIED,
             compression: :EDGE_RECORD_COMPRESSION_UNSPECIFIED,
             route_profile: :EDGE_RECORD_ROUTE_PROFILE_UNSPECIFIED,
             traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_UNSPECIFIED
         }}
      ]

      for {name, variant} <- cases do
        assert hex(SemanticDigest.compute(variant)) ==
                 vector!(vectors, "root.#{name}.defaulted"),
               "root.#{name}.defaulted disagrees with the committed vector"
      end
    end

    test "EVERY whole-record SHAPE at EVERY committed variant" do
      # A FROZEN DIGEST PER SHAPE IS NOT ORDER EVIDENCE, and one variant per shape is not either.
      # With `collection` claims, `payload_family` and `compression` are both zero in the first
      # variant, so a swap CONDITIONED on that shape moved no byte anywhere. Each shape is now a
      # first-class fixture at every variant, and this runtime holds the same frozen values.
      vectors = vectors()

      for shape <- shapes(), v <- 0..(record_variants() - 1) do
        key = "root.shape.#{shape}.v#{v}"

        assert hex(SemanticDigest.compute(shape_record(shape, v))) == vector!(vectors, key),
               "#{key}: this runtime frames a different record from the committed vector"
      end
    end

    test "the ROOT's own presence inference for the output contract" do
      # The seam rows freeze what the framer does when TOLD a carrier is absent; this freezes
      # what the ROOT infers. Replacing that inference with a literal `true` left the whole Go
      # package green, because no committed record omitted the contract.
      vectors = vectors()
      rec = record()

      assert hex(SemanticDigest.compute(rec)) ==
               vector!(vectors, "state.output_contract@root.present")

      assert hex(SemanticDigest.compute(%{rec | output_contract: nil})) ==
               vector!(vectors, "state.output_contract@root.absent")
    end

    test "the three record-level presence markers, as whole-envelope digests" do
      vectors = vectors()
      rec = record()

      for {slot, field} <- [
            {"producer_context", :producer_context},
            {"capability", :production_capability},
            {"source_authorization", :source_authorization}
          ] do
        assert hex(SemanticDigest.compute(rec)) ==
                 vector!(vectors, "state.#{slot}.present"),
               "#{slot}: the present-state digest disagrees with the committed vector"

        assert hex(SemanticDigest.compute(Map.put(rec, field, nil))) ==
                 vector!(vectors, "state.#{slot}.absent"),
               "#{slot}: the absent-state digest disagrees with the committed vector"
      end
    end
  end

  describe "exclusions and the payload relation" do
    test "field 17 does not feed its own recomputation" do
      rec = record()
      base = SemanticDigest.compute(rec)
      prior = rec.semantic_envelope_sha256
      mutated = %{rec | semantic_envelope_sha256: :binary.copy(<<0xAB>>, 32)}

      refute mutated.semantic_envelope_sha256 == prior,
             "the substitution did not change the stored value"

      assert SemanticDigest.compute(mutated) == base
    end

    test "field 18 is excluded directly, and length changes do not leak either" do
      rec = record()
      base = SemanticDigest.compute(rec)

      # EQUAL LENGTH: catches an ordinary payload write.
      same_len = %{rec | payload: :binary.copy(<<0x5A>>, byte_size(rec.payload))}
      assert SemanticDigest.compute(same_len) == base

      # DIFFERENT LENGTH, with the hash and declared sizes HELD FIXED: catches an accidental
      # `len(payload)` write, which an equal-length swap cannot see.
      longer = %{rec | payload: rec.payload <> :binary.copy(<<0x5B>>, 64)}
      refute byte_size(longer.payload) == byte_size(rec.payload)
      assert SemanticDigest.compute(longer) == base
    end

    test "the payload is committed TRANSITIVELY through payload_sha256" do
      rec = record()

      # THE BASELINE MUST BE HONEST, or this proves field-6 sensitivity and nothing about the
      # payload being carried through it.
      assert rec.payload_sha256 == :crypto.hash(:sha256, rec.payload)

      base = SemanticDigest.compute(rec)
      swapped = :binary.copy(<<0x5A>>, byte_size(rec.payload))

      held = %{rec | payload: swapped}
      assert SemanticDigest.compute(held) == base

      recomputed = %{held | payload_sha256: :crypto.hash(:sha256, swapped)}
      refute SemanticDigest.compute(recomputed) == base
    end
  end

  describe "root slots and separation" do
    test "every committed record slot is attached" do
      rec = record()
      base = SemanticDigest.compute(rec)

      mutations = [
        event_id: :binary.copy(<<0x21>>, 16),
        encoded_size: rec.encoded_size + 1,
        uncompressed_size: rec.uncompressed_size + 1,
        payload_sha256: :binary.copy(<<0x22>>, 32),
        network_scope_id: :binary.copy(<<0x23>>, 16),
        projected_row_count: rec.projected_row_count + 1,
        projected_write_bytes: rec.projected_write_bytes + 1,
        cost_model_version: rec.cost_model_version + 1
      ]

      for {field, value} <- mutations do
        refute SemanticDigest.compute(Map.put(rec, field, value)) == base,
               "record slot #{field} is not attached to the transcript"
      end
    end

    test "the outer delivery frame cannot move the inner digest" do
      # SEPARATION, VARIED rather than merely asserted absent. Decoding the same bytes twice
      # proves nothing: it would pass even if the frame quantities DID feed the transcript,
      # because they never changed. Each row below builds a real frame variant around IDENTICAL
      # record bytes and recomputes the inner digest from the decoded record.
      #
      # This runtime does NOT claim signed-frame admission -- Go owns that boundary. What it
      # claims is narrower and true: the record it decodes is unchanged, and its semantic digest
      # is unchanged, while the frame around it varies.
      raw = fixture("sem_record_deterministic.bin")
      inner = SemanticDigest.compute(EdgeRecordV1.decode(raw))
      record_sha = :crypto.hash(:sha256, raw)

      frames = [
        {"spool_id",
         %EdgeDeliveryFrameV1{
           spool_id: :binary.copy(<<0x71>>, 16),
           sequence: 1,
           record_sha256: record_sha,
           record_bytes: raw
         }},
        {"spool_id.varied",
         %EdgeDeliveryFrameV1{
           spool_id: :binary.copy(<<0x72>>, 16),
           sequence: 1,
           record_sha256: record_sha,
           record_bytes: raw
         }},
        {"sequence.varied",
         %EdgeDeliveryFrameV1{
           spool_id: :binary.copy(<<0x71>>, 16),
           sequence: 99,
           record_sha256: record_sha,
           record_bytes: raw
         }},
        {"delivery_capability.present",
         %EdgeDeliveryFrameV1{
           spool_id: :binary.copy(<<0x71>>, 16),
           sequence: 1,
           record_sha256: record_sha,
           record_bytes: raw,
           delivery_capability: %EdgeSignedCapabilityV1{
             capability_version: 1,
             algorithm: "ed25519",
             claims:
               {:delivery,
                %EdgeDeliveryClaimsV1{
                  spool_id: :binary.copy(<<0x71>>, 16),
                  sequence: 1
                }}
           }
         }}
      ]

      for {name, frame} <- frames do
        # THE FRAME MUST REALLY CARRY THE RECORD, or "unchanged" is unchanged for the
        # uninteresting reason that nothing was ever enclosed.
        assert frame.record_bytes == raw, "#{name}: record bytes were not held fixed"
        assert frame.record_sha256 == record_sha, "#{name}: record digest was not held fixed"

        decoded = EdgeRecordV1.decode(frame.record_bytes)

        assert SemanticDigest.compute(decoded) == inner,
               "#{name}: an outer-frame quantity moved the INNER semantic digest"
      end

      # The frame variants must actually DIFFER from one another, or the loop above compared
      # four copies of the same frame.
      encoded = Enum.map(frames, fn {_, f} -> EdgeDeliveryFrameV1.encode(f) end)

      assert length(Enum.uniq(encoded)) == length(encoded),
             "every frame variant must be distinct, or the loop compared copies of one frame"
    end

    test "a legal re-encoding moves record_sha256 but not the semantic digest" do
      # PHYSICAL identity is separate from SEMANTIC identity. The alternate encoding is
      # CONSTRUCTED, not hoped for: re-emitting one scalar with its own value is legal
      # (proto3 scalars are last-wins) and decodes to the same message.
      raw = fixture("sem_record_deterministic.bin")
      rec = EdgeRecordV1.decode(raw)

      # field 3 (compression), varint wire type: tag = 3 <<< 3 ||| 0 = 0x18
      alt =
        raw <> <<0x18>> <> <<Serviceradar.Edge.V1.EdgeRecordCompression.value(rec.compression)>>

      refute alt == raw, "the alternate encoding must differ in bytes"
      assert EdgeRecordV1.decode(alt) == rec, "both encodings must decode to the same record"

      refute :crypto.hash(:sha256, alt) == :crypto.hash(:sha256, raw),
             "two differing legal encodings must yield differing record digests"

      assert SemanticDigest.compute(EdgeRecordV1.decode(alt)) == SemanticDigest.compute(rec),
             "the semantic digest must be invariant across legal re-encodings"
    end

    test "producer-receipt identity is absent from the record schema" do
      names =
        Enum.map(EdgeRecordV1.__message_props__().field_props, fn {_, f} ->
          to_string(f.name_atom)
        end)

      refute Enum.any?(names, &String.contains?(&1, "submission")),
             "producer-receipt submission identity must not appear in the record schema"
    end
  end

  # ---------------------------------------------------------------------------
  # adapters
  # ---------------------------------------------------------------------------

  defp frame("output_contract", m), do: ClaimsFraming.output_contract(m)

  defp frame("collection_claims", m),
    do: {:collection, m} |> ClaimsFraming.claims_framed() |> drop_discriminant()

  defp frame("production_claims", m),
    do: {:production, m} |> ClaimsFraming.claims_framed() |> drop_discriminant()

  defp frame("source_claims", m),
    do: {:source, m} |> ClaimsFraming.claims_framed() |> drop_discriminant()

  defp frame("delivery_claims", m),
    do: {:delivery, m} |> ClaimsFraming.claims_framed() |> drop_discriminant()

  defp frame("execution_grant_claims", m),
    do: {:assignment_execution, m} |> ClaimsFraming.claims_framed() |> drop_discriminant()

  # `claims_framed/1` prefixes the discriminant; the framer vectors are the BODY alone, so the
  # leading u64 is removed rather than a second entry point being invented for the test.
  defp drop_discriminant(iodata) do
    <<_::binary-size(8), body::binary>> = IO.iodata_to_binary(iodata)
    body
  end

  defp empty_for("output_contract"), do: %EdgeOutputContractRef{}
  defp empty_for("collection_claims"), do: %EdgeCollectionClaimsV1{}
  defp empty_for("production_claims"), do: %EdgeProductionClaimsV1{}
  defp empty_for("source_claims"), do: %EdgeSourceClaimsV1{}
  defp empty_for("delivery_claims"), do: %EdgeDeliveryClaimsV1{}
  defp empty_for("execution_grant_claims"), do: %EdgeAssignmentExecutionClaimsV1{}

  # TWO BASELINE SETS, PER VARIANT. The cross product puts a claim body in BOTH carriers at once,
  # so splicing the same artifact into both made every corresponding field pair hold one value,
  # and disjoint VALUES cannot fix it -- `production_claims` alone needs three distinct values
  # from fields of range 3, 4 and 3, exhausting the range-3 space for one carrier. The separation
  # is by SIGNATURE across variants, so each set is committed once per variant.
  defp baseline(root, carrier \\ "production", variant \\ 0) do
    suffix = if carrier == "production", do: "", else: "_nested"
    vsuffix = if variant == 0, do: "", else: "_v#{variant}"

    "sem_#{root}_populated#{suffix}#{vsuffix}.bin"
    |> fixture()
    |> decode_baseline(root)
  end

  defp decode_baseline(raw, "output_contract"), do: EdgeOutputContractRef.decode(raw)
  defp decode_baseline(raw, "collection_claims"), do: EdgeCollectionClaimsV1.decode(raw)
  defp decode_baseline(raw, "production_claims"), do: EdgeProductionClaimsV1.decode(raw)
  defp decode_baseline(raw, "source_claims"), do: EdgeSourceClaimsV1.decode(raw)
  defp decode_baseline(raw, "delivery_claims"), do: EdgeDeliveryClaimsV1.decode(raw)

  defp decode_baseline(raw, "execution_grant_claims"),
    do: EdgeAssignmentExecutionClaimsV1.decode(raw)

  # PER CARRIER, because both can hold a renewal or a rollover at once in the cross product and
  # equal values across the two would be exchangeable.
  defp renewal("production"),
    do:
      {:renewal,
       %EdgeDeliveryRenewalV1{
         renewed_not_before_unix_nano: 1_700_000_000_000_000_000,
         renewed_expires_unix_nano: 1_900_000_000_000_000_000
       }}

  defp renewal(_),
    do:
      {:renewal,
       %EdgeDeliveryRenewalV1{
         renewed_not_before_unix_nano: 2_100_000_000_000_000_000,
         renewed_expires_unix_nano: 2_300_000_000_000_000_000
       }}

  defp rollover("production"),
    do:
      {:rollover,
       %EdgeDeliveryRolloverV1{
         recovery_id: :binary.copy(<<0x61>>, 16),
         prior_spool_id: :binary.copy(<<0x62>>, 16),
         prior_sequence: 700_000_000_000_007
       }}

  defp rollover(_),
    do:
      {:rollover,
       %EdgeDeliveryRolloverV1{
         recovery_id: :binary.copy(<<0x63>>, 16),
         prior_spool_id: :binary.copy(<<0x64>>, 16),
         prior_sequence: 800_000_000_000_009
       }}

  defp shapes, do: @shapes
  defp record_variants, do: @record_variants

  # Every shape is a STRUCTURAL edit of a committed record plus, where a claim is spliced, a
  # COMMITTED baseline -- so this runtime reproduces each shape from artifacts it already decodes
  # rather than needing one committed record per shape.
  defp shape_record("base", variant) do
    rec = record(variant)
    %{rec | semantic_envelope_sha256: SemanticDigest.compute(rec)}
  end

  defp shape_record(shape, variant) do
    [oc, pc, ep, p, n] = String.split(shape, "|")
    "p-" <> production = p
    "n-" <> nested = n

    built =
      variant
      |> record()
      |> then(&if oc == "oc0", do: %{&1 | output_contract: nil}, else: &1)
      |> apply_producer_context(pc, ep)
      |> apply_carrier_state("production", production, variant)
      |> apply_nested(nested, variant)

    # FIELD 17 IS RESEALED for every shape: it is excluded from the transcript, so a stale value
    # leaves the digest stable while the record BYTES vary.
    %{built | semantic_envelope_sha256: SemanticDigest.compute(built)}
  end

  defp apply_producer_context(rec, "pc0", _ep), do: %{rec | producer_context: nil}

  defp apply_producer_context(rec, _pc, "ep0"),
    do: %{rec | producer_context: %{rec.producer_context | authority_epoch: nil}}

  defp apply_producer_context(rec, _pc, _ep), do: rec

  defp apply_nested(rec, "sa_absent", _variant), do: %{rec | source_authorization: nil}
  defp apply_nested(rec, state, variant), do: apply_carrier_state(rec, "nested", state, variant)

  # apply_carrier_state puts ONE capability carrier into one state. Both carriers go through it,
  # which is what makes the cross product mechanical rather than a second hand-written matrix.
  defp apply_carrier_state(rec, "production", "absent", _variant),
    do: %{rec | production_capability: nil}

  defp apply_carrier_state(rec, "nested", "absent", _variant),
    do: %{rec | source_authorization: %{rec.source_authorization | capability: nil}}

  defp apply_carrier_state(rec, carrier, state, variant) do
    cap = carrier_capability(rec, carrier)
    put_carrier(rec, carrier, %{cap | claims: claims_for_state(state, carrier, variant)})
  end

  defp carrier_capability(rec, "production"), do: rec.production_capability
  defp carrier_capability(rec, _), do: rec.source_authorization.capability

  defp put_carrier(rec, "production", cap), do: %{rec | production_capability: cap}

  defp put_carrier(rec, _, cap),
    do: %{rec | source_authorization: %{rec.source_authorization | capability: cap}}

  defp claims_for_state("unset", _carrier, _variant), do: nil

  defp claims_for_state("delivery.renewal", carrier, variant),
    do:
      {:delivery, %{baseline("delivery_claims", carrier, variant) | transition: renewal(carrier)}}

  defp claims_for_state("delivery.rollover", carrier, variant),
    do:
      {:delivery,
       %{baseline("delivery_claims", carrier, variant) | transition: rollover(carrier)}}

  defp claims_for_state("assignment", carrier, variant),
    do: {:assignment_execution, baseline("execution_grant_claims", carrier, variant)}

  defp claims_for_state("assignment.no_identity", carrier, variant),
    do:
      {:assignment_execution,
       %{baseline("execution_grant_claims", carrier, variant) | source_identity: nil}}

  defp claims_for_state(state, carrier, variant),
    do: {String.to_existing_atom(state), baseline("#{state}_claims", carrier, variant)}

  defp record, do: record(0)

  # THE PEER DECODES EVERY COMMITTED VARIANT. One record cannot separate the root transcript --
  # it is a flat, untagged concatenation with seven enum writes competing for three values -- so
  # the fixtures separate positions by SIGNATURE across variants, and a variant this runtime
  # never decoded would be Go-only evidence.
  defp record(variant) do
    name =
      if variant == 0,
        do: "sem_record_deterministic.bin",
        else: "sem_record_deterministic_v#{variant}.bin"

    name |> fixture() |> EdgeRecordV1.decode()
  end

  defp put_nested_claims(rec, claims) do
    cap = %{rec.source_authorization.capability | claims: claims}
    %{rec | source_authorization: %{rec.source_authorization | capability: cap}}
  end

  defp hex(iodata), do: iodata |> IO.iodata_to_binary() |> Base.encode16(case: :lower)

  # vector! reads one committed value and RECORDS the read, which is what makes the guard above
  # observational rather than a restatement of the file.
  defp vector!(vectors, key) do
    :persistent_term.put({__MODULE__, :any_read}, true)
    :persistent_term.put({__MODULE__, :read, key}, true)
    Map.fetch!(vectors, key)
  end

  defp vectors do
    "semantic_envelope_vectors.txt"
    |> fixture()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
    |> Enum.reduce(%{}, fn line, acc ->
      [k, v] = String.split(String.trim(line), ~r/\s+/, parts: 2)

      # A DUPLICATE KEY IS A DEFECT, NOT A LAST-WINS. `Map.new/1` collapses one silently, and a
      # collapsed key still satisfies the exact key-set guard while one of the two committed
      # values is never asserted by anything.
      if Map.has_key?(acc, k) do
        raise "duplicate vector key #{k}: one of the two committed values would go unasserted"
      end

      Map.put(acc, k, v)
    end)
  end

  defp corpus do
    "semantic_envelope_corpus.txt"
    |> fixture()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
    |> Enum.map(fn line ->
      [kind, key, detail, probe] = String.split(String.trim(line), ~r/\s+/)
      %{kind: kind, key: key, detail: detail, probe: probe}
    end)
  end

  defp fixture(name),
    do: "../../../../../proto/edge/v1/testdata/#{name}" |> Path.expand(__DIR__) |> File.read!()
end
