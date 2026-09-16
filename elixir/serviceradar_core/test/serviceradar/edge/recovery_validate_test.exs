defmodule ServiceRadar.Edge.RecoveryValidateTest do
  @moduledoc """
  The Elixir relational validator, exercised against the GO-AUTHORED fixture corpus.

  Before 1.6a the Elixir side had `HashGrammar` only: it could recompute a digest but
  could not say whether a manifest was well-formed. "Both runtimes agree" was
  therefore true of the digest and vacuous of every relational rule. These tests are
  the other half of that claim.

  Most ACCEPT cases start from the committed Go fixture and most REJECT cases are a
  single-field mutation of it, so a rule Go enforces and Elixir does not shows up here
  rather than in production.

  Some cases are necessarily SYNTHETIC and are marked as such where they appear:
  the UUID negative vectors construct byte patterns no valid producer emits, the
  raw-byte cases build padded or malformed pages the fixture cannot express, the
  two-page chains are constructed because the corpus has a single page, and the
  decode-outcome test drives a pure error-only helper because fixed bytes only ever
  yield one outcome. Where a case is synthetic, its accept-side counterpart is still anchored to
  the fixture wherever one exists.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.RecoveryValidate
  alias Serviceradar.Edge.V1.EdgeAttributedActiveV1
  alias Serviceradar.Edge.V1.EdgeAttributedPassiveV1
  alias Serviceradar.Edge.V1.EdgeAttributedSpanIdentityV1
  alias Serviceradar.Edge.V1.EdgeClassificationSpanV1
  alias Serviceradar.Edge.V1.EdgeLossManifestPageV1
  alias Serviceradar.Edge.V1.EdgeSourceSpanIdentityV1
  alias Serviceradar.Edge.V1.EdgeUnattributableV1
  alias Serviceradar.Edge.V1.SpoolLossTombstoneV1
  alias ServiceRadar.Edge.WireDecode

  @fixtures Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)

  defp load(name), do: File.read!(Path.join(@fixtures, name))

  defp go_page, do: EdgeLossManifestPageV1.decode(load("manifest_page.bin"))
  defp go_tombstone, do: SpoolLossTombstoneV1.decode(load("tombstone.bin"))

  # Recompute page_sha256 after a mutation, so a rejection is attributable to the
  # RULE under test rather than to a stale digest.
  defp reseal(page), do: %{page | page_sha256: HashGrammar.manifest_page_digest(page)}

  defp with_spans(page, spans), do: reseal(%{page | classification_spans: spans})

  # A REAL two-page chain: page_index/page_count/terminal/prev_page_sha256 all set and
  # each page resealed. Needed because every acceptance case being single-page would
  # leave cross-page behaviour unproven -- a mutation rejecting every second page
  # would survive.
  defp chain(page, spans_a, spans_b) do
    a =
      reseal(%{
        page
        | page_index: 0,
          page_count: 2,
          terminal: false,
          prev_page_sha256: "",
          classification_spans: spans_a
      })

    b =
      reseal(%{
        page
        | page_index: 1,
          page_count: 2,
          terminal: true,
          prev_page_sha256: a.page_sha256,
          classification_spans: spans_b
      })

    [a, b]
  end

  # CANONICAL UUIDs, not 16 arbitrary bytes. An earlier version of this helper used
  # `:binary.copy(<<b>>, 16)`, which has version nibble `b >>> 4` and variant nibble
  # `b >>> 4` -- non-canonical for almost every b. That MASKED a real parity defect:
  # Elixir checked only byte_size and accepted identities Go rejects.
  defp uuid(b), do: canonical(b, 0x40)

  defp canonical(b, version_nibble) do
    <<b, b, b, b, b, b, version_nibble ||| 0x0A, b, 0x80 ||| rem(b, 0x40), b, b, b, b, b, b, b>>
  end

  defp d32(b), do: :binary.copy(<<b>>, 32)

  defp parse_csv(""), do: []
  defp parse_csv(s), do: String.split(s, ",", trim: true)

  defp identity(overrides \\ []) do
    base = %EdgeAttributedSpanIdentityV1{
      producer_assignment_id: uuid(0x11),
      run_id: uuid(0x12),
      run_shard: 2,
      authority_epoch: 5,
      production_scope_id: uuid(0x13),
      scope_sha256: d32(0x21),
      contract_bundle_sha256: d32(0x22),
      source: nil
    }

    struct!(base, overrides)
  end

  defp active(from, through, id \\ nil) do
    %EdgeClassificationSpanV1{
      from_sequence: from,
      through_sequence: through,
      classification:
        {:attributed_active,
         %EdgeAttributedActiveV1{identity: id || identity(), range_sha256: d32(0x23)}}
    }
  end

  defp passive(from, through, id \\ nil) do
    %EdgeClassificationSpanV1{
      from_sequence: from,
      through_sequence: through,
      classification: {:attributed_passive, %EdgeAttributedPassiveV1{identity: id || identity()}}
    }
  end

  defp unattributable(from, through, reason) do
    %EdgeClassificationSpanV1{
      from_sequence: from,
      through_sequence: through,
      classification: {:unattributable, %EdgeUnattributableV1{reason: reason}}
    }
  end

  describe "the Go-authored corpus" do
    test "validates unchanged, and its tombstone reconciles" do
      page = go_page()
      assert :ok = RecoveryValidate.manifest_chain([page], HashGrammar.manifest_root([page]))
      assert :ok = RecoveryValidate.tombstone(go_tombstone(), [page])
    end

    test "carries all three classification bodies and both source framings" do
      assert [a, p, u] = go_page().classification_spans

      assert {:attributed_active, %{identity: %{source: %EdgeSourceSpanIdentityV1{}}}} =
               a.classification

      assert {:attributed_passive, %{identity: %{source: nil}}} = p.classification
      assert {:unattributable, _} = u.classification
    end
  end

  describe "span ordering" do
    test "gaps and adjacency are accepted WITHIN a page" do
      page = go_page()

      for {name, spans} <- [
            {"gap within a page", [active(1, 1), active(100, 100)]},
            {"adjacent, differing bodies", [active(1, 1), passive(2, 2)]},
            {"bounded at max uint64", [active(1, 0xFFFF_FFFF_FFFF_FFFF)]}
          ] do
        p = with_spans(page, spans)

        assert :ok = RecoveryValidate.manifest_chain([p], HashGrammar.manifest_root([p])),
               "#{name} must be accepted"
      end
    end

    test "gaps and adjacency are accepted ACROSS a page boundary" do
      # Adjacency is not special at a page boundary, and a gap there still means NOT
      # LOST. Every other acceptance case is single-page, so without these a mutation
      # rejecting every second page would go unnoticed.
      page = go_page()

      for {name, a, b} <- [
            {"gap across the boundary", [active(1, 1)], [active(100, 100)]},
            {"adjacent across the boundary", [active(1, 1)], [passive(2, 2)]},
            {"multi-span pages", [active(1, 1), active(3, 3)], [passive(10, 12), active(20, 20)]}
          ] do
        pages = chain(page, a, b)

        assert :ok = RecoveryValidate.manifest_chain(pages, HashGrammar.manifest_root(pages)),
               "#{name} must be accepted"
      end
    end

    test "rejects zero, inverted, overlapping, and out-of-order spans" do
      page = go_page()

      for {name, spans} <- [
            {"sequence 0", [active(0, 5)]},
            {"inverted interval", [active(9, 5)]},
            {"overlap", [active(1, 10), active(5, 20)]},
            {"out of order", [active(10, 20), active(1, 5)]},
            {"duplicate", [active(1, 5), active(1, 5)]},
            # Touching at a single point: the next span STARTS on the previous span's
            # last sequence. The rule is `from <= prev_through`, so this is the exact
            # boundary that separates it from `from < prev_through` -- without this
            # vector, weakening the comparison by one goes unnoticed.
            {"touching at a point", [active(1, 5), active(5, 10)]},
            {"touching at a point, reversed", [active(5, 10), active(1, 5)]}
          ] do
        assert {:error, :manifest_span} =
                 RecoveryValidate.manifest_chain([with_spans(page, spans)], nil),
               "#{name} must be rejected"
      end
    end

    test "rejects spans touching at a point ACROSS a page boundary" do
      # Ordering is total across the WHOLE chain, not merely within a page: two
      # individually valid pages must not share a sequence.
      page = go_page()

      a = %{
        page
        | page_index: 0,
          page_count: 2,
          terminal: false,
          classification_spans: [active(1, 5)]
      }

      a = %{a | page_sha256: HashGrammar.manifest_page_digest(a)}

      b = %{
        page
        | page_index: 1,
          page_count: 2,
          terminal: true,
          prev_page_sha256: a.page_sha256,
          classification_spans: [active(5, 10)]
      }

      b = %{b | page_sha256: HashGrammar.manifest_page_digest(b)}

      assert {:error, :manifest_span} = RecoveryValidate.manifest_chain([a, b], nil)
    end

    test "rejects an empty page: no spans means no derivable extent" do
      assert {:error, :manifest_bounds} =
               RecoveryValidate.manifest_chain([with_spans(go_page(), [])], nil)
    end
  end

  describe "span bodies" do
    test "rejects the states proto3 still permits" do
      page = go_page()
      no_oneof = %EdgeClassificationSpanV1{from_sequence: 1, through_sequence: 1}

      nil_identity = %EdgeClassificationSpanV1{
        from_sequence: 1,
        through_sequence: 1,
        classification:
          {:attributed_active, %EdgeAttributedActiveV1{identity: nil, range_sha256: d32(1)}}
      }

      no_range = %EdgeClassificationSpanV1{
        from_sequence: 1,
        through_sequence: 1,
        classification:
          {:attributed_active, %EdgeAttributedActiveV1{identity: identity(), range_sha256: ""}}
      }

      for {name, span} <- [
            {"unset oneof", no_oneof},
            {"nil identity", nil_identity},
            {"ACTIVE without range_sha256", no_range},
            {"non-UUID production scope", passive(1, 1, identity(production_scope_id: "nope"))},
            {"short scope digest", passive(1, 1, identity(scope_sha256: <<1, 2, 3>>))}
          ] do
        assert {:error, :manifest_span_body} =
                 RecoveryValidate.manifest_chain([with_spans(page, [span])], nil),
               "#{name} must be rejected"
      end
    end

    test "source members are all-or-nothing, and absence is legal" do
      page = go_page()

      full =
        identity(
          source: %EdgeSourceSpanIdentityV1{
            kind: :EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC,
            context_id: uuid(0x31),
            source_scope_id: uuid(0x32),
            source_scope_sha256: d32(0x33)
          }
        )

      ok_page = with_spans(page, [passive(1, 1, full)])

      assert :ok =
               RecoveryValidate.manifest_chain([ok_page], HashGrammar.manifest_root([ok_page]))

      # Absent source: legal, and NOT the same as PASSIVE. The two axes are
      # independent, so an ACTIVE span with no source must also be accepted.
      no_src = with_spans(page, [active(1, 1, identity())])
      assert :ok = RecoveryValidate.manifest_chain([no_src], HashGrammar.manifest_root([no_src]))

      partial =
        identity(
          source: %EdgeSourceSpanIdentityV1{
            kind: :EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC,
            context_id: uuid(0x31)
          }
        )

      assert {:error, :manifest_span_body} =
               RecoveryValidate.manifest_chain([with_spans(page, [passive(1, 1, partial)])], nil)
    end
  end

  describe "closed enum sets" do
    test "every accepted reason validates and every other value is rejected" do
      page = go_page()

      for r <- RecoveryValidate.accepted_reasons() do
        p = with_spans(page, [unattributable(1, 1, r)])

        assert :ok = RecoveryValidate.manifest_chain([p], HashGrammar.manifest_root([p])),
               "#{r} is in the accepted set and must validate"
      end

      # 0 and the RESERVED numbers 1 and 5, a negative, the next unknown, and a far
      # value. The negative-tag transform is what lets these decode to integers at all
      # rather than raising -- which is precisely why the validator must reject them.
      for v <- [:EDGE_UNATTRIBUTABLE_REASON_UNSPECIFIED, -1, 1, 5, 8, 999] do
        assert {:error, :manifest_span_body} =
                 RecoveryValidate.manifest_chain(
                   [with_spans(page, [unattributable(1, 1, v)])],
                   nil
                 ),
               "reason #{inspect(v)} must be rejected"
      end
    end

    test "every accepted source kind validates and every other value is rejected" do
      page = go_page()

      for k <- RecoveryValidate.accepted_source_kinds() do
        id =
          identity(
            source: %EdgeSourceSpanIdentityV1{
              kind: k,
              context_id: uuid(0x31),
              source_scope_id: uuid(0x32),
              source_scope_sha256: d32(0x33)
            }
          )

        p = with_spans(page, [passive(1, 1, id)])

        assert :ok = RecoveryValidate.manifest_chain([p], HashGrammar.manifest_root([p])),
               "#{k} is in the accepted set and must validate"
      end

      for v <- [:EDGE_SOURCE_AUTHORIZATION_KIND_UNSPECIFIED, -1, 8, 999] do
        id =
          identity(
            source: %EdgeSourceSpanIdentityV1{
              kind: v,
              context_id: uuid(0x31),
              source_scope_id: uuid(0x32),
              source_scope_sha256: d32(0x33)
            }
          )

        assert {:error, :manifest_span_body} =
                 RecoveryValidate.manifest_chain([with_spans(page, [passive(1, 1, id)])], nil),
               "kind #{inspect(v)} must be rejected"
      end
    end

    test "an unaccepted value is rejected BEFORE the page is hashed" do
      # Only observable when the digest does NOT match: with a matching digest both
      # orderings reach the body check and report the same error. So mutate the span
      # WITHOUT resealing, and assert the BODY error -- hash-first would report
      # :manifest_page_digest.
      page = %{go_page() | classification_spans: [unattributable(1, 1, 8)]}
      refute HashGrammar.manifest_page_digest(page) == page.page_sha256

      assert {:error, :manifest_span_body} = RecoveryValidate.manifest_chain([page], nil)
    end
  end

  describe "raw-byte bounds" do
    test "an in-budget chain validates through the raw entry point" do
      page = go_page()
      raw = [page |> EdgeLossManifestPageV1.encode() |> IO.iodata_to_binary()]

      assert :ok =
               RecoveryValidate.manifest_chain_from_raw(raw, HashGrammar.manifest_root([page]))
    end

    test "the AGGREGATE received size is bounded, not just each page" do
      page = go_page()
      one = IO.iodata_to_binary(EdgeLossManifestPageV1.encode(page))
      limit = RecoveryValidate.limits().max_manifest_bytes

      # Pad with DECODABLE filler -- repeated copies of the singular digest_version
      # field (tag 8, varint), which protobuf resolves last-one-wins to the value it
      # already had. Trailing zero bytes do NOT work: tag 0 is rejected, so the page
      # would fail to decode and never reach the budget check.
      # An ODD byte count needs a 3-byte NON-MINIMAL varint (0x81 0x00 encodes 1 in two
      # bytes); a bare <<0x40>> is a tag with no value -- an incomplete field, which
      # decodes as :poison and would never reach the budget check.
      pad = fn b, target ->
        need = target - byte_size(b)

        {prefix, need} =
          if rem(need, 2) == 1, do: {<<0x40, 0x81, 0x00>>, need - 3}, else: {<<>>, need}

        b <> prefix <> :binary.copy(<<0x40, 0x01>>, div(need, 2))
      end

      half = div(limit, 2)
      fat = [pad.(one, half), pad.(one, half + 1)]

      # Each page individually under the cap, together EXACTLY one byte over it.
      assert Enum.all?(fat, &(byte_size(&1) <= limit))
      assert Enum.sum(Enum.map(fat, &byte_size/1)) == limit + 1

      # Each padded page must still DECODE, and to the same page it started as, so the
      # only thing rejecting the chain can be the aggregate received size.
      for b <- fat do
        assert {:ok, decoded} = WireDecode.decode_manifest_page(b)
        assert decoded == page

        assert byte_size(IO.iodata_to_binary(EdgeLossManifestPageV1.encode(decoded))) <
                 div(limit, 2)
      end

      assert {:error, :manifest_bounds} = RecoveryValidate.manifest_chain_from_raw(fat, nil)
    end

    test "the aggregate bound is checked BEFORE any decode" do
      # A malformed page that would fail to decode, followed by a page that pushes the
      # AGGREGATE over the cap. If the implementation interleaved bounding and
      # decoding, page 1 would fail to decode first and report a decode outcome --
      # masking the budget violation entirely. Bounding first makes :manifest_bounds
      # the only possible verdict.
      limit = RecoveryValidate.limits().max_manifest_bytes
      malformed = <<0xFF, 0xFF, 0xFF>>
      big = :binary.copy(<<0x40, 0x01>>, div(limit + 1 - byte_size(malformed), 2))

      assert byte_size(malformed) + byte_size(big) > limit

      assert {:error, :manifest_bounds} =
               RecoveryValidate.manifest_chain_from_raw([malformed, big], nil)
    end

    test "the typed WireDecode outcome is PROPAGATED, not collapsed" do
      # An in-budget but malformed page must surface its own decode outcome. Collapsing
      # every decode failure into one generic chain error makes a deployment/decoder
      # fault (:not_ready / :systemic -- pause and replay) indistinguishable from bad
      # customer bytes (:poison / :too_large -- permanently resolvable), and the caller
      # cannot make the required decision.
      malformed = <<0xFF, 0xFF, 0xFF>>
      assert byte_size(malformed) < RecoveryValidate.limits().max_manifest_bytes

      # Whatever WireDecode says for these bytes is what the chain API must return.
      expected = WireDecode.decode_manifest_page(malformed)
      assert {:error, reason} = expected
      assert reason in [:poison, :systemic, :not_ready, :too_large]

      assert {:error, ^reason} = RecoveryValidate.manifest_chain_from_raw([malformed], nil)

      refute match?(
               {:error, :manifest_chain},
               RecoveryValidate.manifest_chain_from_raw([malformed], nil)
             )
    end

    test "EVERY decode outcome propagates, including the transient ones" do
      # Proven through the PURE, ERROR-ONLY helper, not an injected decoder.
      #
      # An injectable decoder would prove the same property while handing callers a
      # bypass: malformed raw bytes plus `fn _ -> {:ok, valid_page} end` would be
      # admitted, skipping WireDecode and WireValidate entirely.
      # `propagate_decode_error/1` cannot do that -- it takes an error and returns an
      # error, with no success clause to hand a page back through.
      #
      # Fixed malformed bytes only ever yield :poison, so without this the transient
      # outcomes are unreachable in a test, and :not_ready/:systemic are exactly the
      # ones whose loss is destructive: they mean PAUSE AND REPLAY, not quarantine.
      for outcome <- [:not_ready, :systemic, :poison, :too_large] do
        assert {:error, ^outcome} = RecoveryValidate.propagate_decode_error({:error, outcome}),
               "#{outcome} must propagate verbatim, not collapse"
      end

      # The helper must have NO success clause. Reintroducing one would let a caller
      # hand it a page and get one back -- the capability this module must not expose,
      # and the reason the earlier injectable-decoder seam was a bypass. Asserted here
      # so adding that clause fails the suite rather than passing review unnoticed.
      # apply/3 so the call is resolved at RUNTIME. A direct call is STATICALLY
      # invalid -- there is no matching clause, which is the property under test -- and
      # the type checker rightly rejects it, turning the proof into a compile error
      # under --warnings-as-errors.
      assert_raise FunctionClauseError, fn ->
        apply(RecoveryValidate, :propagate_decode_error, [{:ok, go_page()}])
      end
    end

    test "a real decode failure surfaces its own outcome end to end" do
      # End-to-end complement: the hard-wired WireDecode path surfaces its own outcome
      # rather than a generic chain error.
      #
      # SCOPE, stated because the obvious reading overstates it: this does NOT pin that
      # the API calls `propagate_decode_error/1`. Bypassing the helper with a
      # behaviour-identical passthrough is unobservable and cannot be mutation-killed.
      # What the two tests together pin is that the MAPPING is total and
      # non-collapsing, and that a real decode failure is not flattened into a
      # relational error -- which is what a caller actually depends on.
      malformed = <<0xFF, 0xFF, 0xFF>>
      assert byte_size(malformed) < RecoveryValidate.limits().max_manifest_bytes

      assert {:error, reason} = WireDecode.decode_manifest_page(malformed)
      assert {:error, ^reason} = RecoveryValidate.manifest_chain_from_raw([malformed], nil)
      refute reason == :manifest_chain
    end

    test "a single oversize page is rejected before decode" do
      limit = RecoveryValidate.limits().max_manifest_bytes

      assert {:error, :manifest_bounds} =
               RecoveryValidate.manifest_chain_from_raw([:binary.copy(<<0>>, limit + 1)], nil)
    end
  end

  describe "UUID parity with Go" do
    test "rejects the non-canonical IDs Go rejects" do
      page = go_page()

      # Go's ValidateCanonicalUUID: 16 bytes, version 1..8, RFC variant 10xx, not
      # all-zero. A byte_size-only check accepts every one of these.
      for {name, bad} <- [
            # The nil UUID is rejected by the VERSION range (its version nibble is 0),
            # not by the explicit all-zero guard, which is redundant. Listed because
            # it is the value most likely to be passed by accident, not because it
            # isolates that guard.
            {"nil UUID", <<0::128>>},
            {"version 0", <<1, 1, 1, 1, 1, 1, 0x0A, 1, 0x8A, 1, 1, 1, 1, 1, 1, 1>>},
            {"version 9", <<1, 1, 1, 1, 1, 1, 0x9A, 1, 0x8A, 1, 1, 1, 1, 1, 1, 1>>},
            {"non-RFC variant", <<1, 1, 1, 1, 1, 1, 0x4A, 1, 0x0A, 1, 1, 1, 1, 1, 1, 1>>},
            {"15 bytes", :binary.copy(<<1>>, 15)}
          ] do
        span = passive(1, 1, identity(production_scope_id: bad))

        assert {:error, :manifest_span_body} =
                 RecoveryValidate.manifest_chain([with_spans(page, [span])], nil),
               "#{name} must be rejected as a span identity"
      end
    end

    test "EVERY UUID-bearing field is validated, not just one per message" do
      # Dropping validation at any single call site must fail. Without a table, a
      # mutation removing the check on run_id, a source ID, or new_spool_id survives
      # because no vector touches that field.
      page = go_page()
      bad = <<0::128>>

      span_fields = [:producer_assignment_id, :run_id, :production_scope_id]

      for field <- span_fields do
        span = passive(1, 1, identity([{field, bad}]))

        assert {:error, :manifest_span_body} =
                 RecoveryValidate.manifest_chain([with_spans(page, [span])], nil),
               "identity.#{field} must be validated"
      end

      for field <- [:context_id, :source_scope_id] do
        src =
          struct!(
            %EdgeSourceSpanIdentityV1{
              kind: :EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC,
              context_id: uuid(0x31),
              source_scope_id: uuid(0x32),
              source_scope_sha256: d32(0x33)
            },
            [{field, bad}]
          )

        span = passive(1, 1, identity(source: src))

        assert {:error, :manifest_span_body} =
                 RecoveryValidate.manifest_chain([with_spans(page, [span])], nil),
               "source.#{field} must be validated"
      end

      t = go_tombstone()

      # prior/new spool IDs isolate their call sites: nothing else inspects them.
      for field <- [:prior_spool_id, :new_spool_id] do
        assert {:error, :tombstone_mismatch} =
                 RecoveryValidate.tombstone(struct!(t, [{field, bad}]), [page]),
               "tombstone.#{field} must be validated"
      end

      # recovery_id does NOT isolate its call site: a bad value is also caught by
      # manifest validation and by the final tombstone/manifest ID equality, so this
      # asserts the OUTCOME rather than proving the tombstone's own check runs.
      assert {:error, _} = RecoveryValidate.tombstone(%{t | recovery_id: bad}, [page])
    end

    test "the UUIDv7 VARIANT check is load-bearing, not just the version nibble" do
      # Version 7 with a NON-RFC variant. A check testing only the version nibble
      # accepts this; Go requires both.
      v7_bad_variant = <<1, 1, 1, 1, 1, 1, 0x7A, 1, 0x0A, 1, 1, 1, 1, 1, 1, 1>>
      page = go_page()

      assert {:error, :manifest_recovery_id} =
               RecoveryValidate.manifest_chain(
                 [reseal(%{page | recovery_id: v7_bad_variant})],
                 nil
               )
    end

    test "recovery and spool IDs must be UUIDv7 specifically, not merely canonical" do
      page = go_page()
      # A canonical v4 is fine for a SPAN identity but not for a recovery id, whose
      # embedded timestamp is load-bearing.
      v4 = uuid(0x22)

      assert {:error, :manifest_recovery_id} =
               RecoveryValidate.manifest_chain([reseal(%{page | recovery_id: v4})], nil)

      t = go_tombstone()

      assert {:error, :tombstone_mismatch} =
               RecoveryValidate.tombstone(%{t | prior_spool_id: v4}, [page])
    end
  end

  describe "retained unknown fields" do
    test "are rejected on a decoded page and on a tombstone" do
      # The field-framed digest walks DECLARED fields only, so retained unknown bytes
      # are invisible to it: the page keeps the SAME digest and would otherwise
      # validate. The raw path rejects unknown tags at the WireDecode gate; this closes
      # the same hole for callers handing in already-decoded structs.
      page = go_page()
      dirty = %{page | __unknown_fields__: [{99, 2, "junk"}]}
      assert HashGrammar.manifest_page_digest(dirty) == page.page_sha256

      assert {:error, :unknown_fields} = RecoveryValidate.manifest_chain([dirty], nil)

      t = go_tombstone()

      assert {:error, :unknown_fields} =
               RecoveryValidate.tombstone(%{t | __unknown_fields__: [{99, 2, "junk"}]}, [page])
    end

    test "are rejected when NESTED inside a span body" do
      # A top-level-only check would miss this.
      page = go_page()
      id = identity()
      dirty_id = %{id | __unknown_fields__: [{77, 0, <<1>>}]}

      assert {:error, :unknown_fields} =
               RecoveryValidate.manifest_chain([with_spans(page, [passive(1, 1, dirty_id)])], nil)
    end
  end

  describe "applied-prefix parity with Go" do
    test "computes the SAME value from the SAME complete inputs" do
      # Read the GO-AUTHORED vectors. The rule needs all four inputs -- prior
      # watermark, allocated high-water, per-sequence durable state, and the validated
      # union -- because the same union yields different answers depending on what was
      # allocated and applied. A bare span pair pins nothing.
      @fixtures
      |> Path.join("applied_prefix_vectors.txt")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.each(fn line ->
        [name, prior, high, applied, lost, expected] = String.split(line, "\t")

        applied_set =
          applied |> parse_csv() |> MapSet.new(&String.to_integer/1)

        lost_spans =
          lost
          |> parse_csv()
          |> Enum.map(fn r ->
            [f, t] = String.split(r, "-")
            {String.to_integer(f), String.to_integer(t)}
          end)

        got =
          RecoveryValidate.applied_through_sequence(
            String.to_integer(prior),
            String.to_integer(high),
            applied_set,
            lost_spans
          )

        assert got == String.to_integer(expected), "#{name}: got #{got}, want #{expected}"
      end)
    end

    test "the gapped case rejects both wrong candidate meanings" do
      # Lost [1,1] + [100,100], allocated 1..100, only sequence 1 applied.
      lost = [{1, 1}, {100, 100}]
      applied = MapSet.new([1])
      got = RecoveryValidate.applied_through_sequence(0, 100, applied, lost)

      assert got == 99
      refute got == 100, "100 is the max span end AND the high-water -- both wrong here"
    end
  end

  describe "shared cross-language vectors" do
    test "every unattributable reason validates from the Go-authored page" do
      # manifest_page.bin carries only ONE reason, so the other four were pinned by
      # runtime-local tests -- each runtime self-consistent, neither cross-checked.
      # One page per reason, so a divergence names the reason.
      for {file, reason} <- [
            {"manifest_page_reason_2.bin", :EDGE_UNATTRIBUTABLE_REASON_BINDING_MISSING},
            {"manifest_page_reason_3.bin", :EDGE_UNATTRIBUTABLE_REASON_BINDING_CORRUPT},
            {"manifest_page_reason_4.bin", :EDGE_UNATTRIBUTABLE_REASON_TORN_TAIL},
            {"manifest_page_reason_6.bin",
             :EDGE_UNATTRIBUTABLE_REASON_BINDING_VERSION_UNSUPPORTED},
            {"manifest_page_reason_7.bin",
             :EDGE_UNATTRIBUTABLE_REASON_DISCRIMINATOR_UNREPRESENTABLE}
          ] do
        page = EdgeLossManifestPageV1.decode(load(file))

        assert [%{classification: {:unattributable, %{reason: ^reason}}}] =
                 page.classification_spans,
               "#{file} must carry #{reason}"

        # The digest agrees AND the relational validator accepts -- both halves, since
        # a digest match alone would not prove the reason is policed.
        assert HashGrammar.manifest_page_digest(page) == page.page_sha256
        assert :ok = RecoveryValidate.manifest_chain([page], HashGrammar.manifest_root([page]))
      end
    end

    test "the shared OVER-BUDGET pair is rejected on the aggregate bound" do
      # The same bytes the Go suite reads, and a GENUINE two-page chain: page 0/2
      # nonterminal and page 1/2 terminal, correctly chained. An earlier version padded
      # two copies of the same page 0/1 terminal, so the pair was a BROKEN chain and a
      # re-encode-summing implementation would still have rejected it -- just later,
      # for an unrelated reason. The bypass was never isolated.
      a = load("manifest_page_overbudget_a.bin")
      b = load("manifest_page_overbudget_b.bin")
      limit = RecoveryValidate.limits().max_manifest_bytes

      # (1) the DECODED pair is a valid chain -- decoded through the REAL ingress
      # stage, not the generated decoder.
      #
      # EdgeLossManifestPageV1.decode/1 bypasses WireDecode/WireValidate entirely. That
      # matters here because the aggregate bound is checked BEFORE any decode: a
      # regression making either padded page :poison at the preflight would still
      # produce {:error, :manifest_bounds} for the pair, and the per-page controls
      # below only REFUTE the bounds error, which :poison satisfies. Asserting {:ok, _}
      # from the stage is what pins that these bytes are genuinely admissible and the
      # rejection is the aggregate alone.
      pages =
        Enum.map([a, b], fn raw ->
          assert {:ok, page} = WireDecode.decode_manifest_page(raw),
                 "each padded page must pass the ingress preflight, or the bounds " <>
                   "rejection is not attributable to the aggregate"

          page
        end)

      assert :ok = RecoveryValidate.manifest_chain(pages, HashGrammar.manifest_root(pages)),
             "the decoded pair must be a VALID chain, or the bounds rejection is not " <>
               "attributable to byte accounting"

      # (2) its RE-ENCODED aggregate is below the cap, so a re-encode-summing
      # implementation would ADMIT it -- the bypass under test
      reencoded =
        pages
        |> Enum.map(&byte_size(IO.iodata_to_binary(EdgeLossManifestPageV1.encode(&1))))
        |> Enum.sum()

      assert reencoded < limit,
             "re-encoded aggregate #{reencoded} must be BELOW #{limit}"

      # (3) the RAW pair is exactly one byte over, each page individually under
      assert byte_size(a) <= limit and byte_size(b) <= limit
      assert byte_size(a) + byte_size(b) == limit + 1

      # (4) the raw boundary rejects, and neither page alone does
      assert {:error, :manifest_bounds} = RecoveryValidate.manifest_chain_from_raw([a, b], nil)

      for one <- [a, b] do
        refute match?(
                 {:error, :manifest_bounds},
                 RecoveryValidate.manifest_chain_from_raw([one], nil)
               )
      end
    end

    test "the shared non-canonical bloat vector decodes identically but is larger" do
      # Previously each runtime built its OWN padded bytes, so neither proved the two
      # agree on what "the received bytes" are. Same Go-authored bytes now.
      bloated = load("manifest_page_bloated.bin")
      canonical = load("manifest_page.bin")

      assert byte_size(bloated) > byte_size(canonical),
             "the bloat vector must be larger on the wire"

      assert {:ok, decoded} = WireDecode.decode_manifest_page(bloated)

      # It decodes to the SAME message: the extra bytes are a duplicate singular field,
      # resolved last-one-wins. That is what makes it non-canonical BLOAT rather than a
      # different page -- and why a re-encoded byte count would miss it.
      assert decoded == EdgeLossManifestPageV1.decode(canonical)

      assert byte_size(IO.iodata_to_binary(EdgeLossManifestPageV1.encode(decoded))) <
               byte_size(bloated)
    end
  end

  describe "retired tags" do
    test "each retired tag is refused INDEPENDENTLY, on the Go-authored bytes" do
      # SIX separate vectors, deliberately not bundled: a decoder that refuses the
      # retired REPEATED fields while silently accepting a stale BOOLEAN would pass a
      # combined fixture and still admit a page whose digest cannot be reproduced.
      #
      # Tag reservation prevents SOURCE reuse; it does not prove old bytes are refused
      # at RUNTIME, and the grammar deliberately keeps version 1 -- so a same-version
      # atomic rewrite could otherwise admit stale candidate bytes.
      pages = [
        {"retired_page_tag7_coarsened.bin", 7, "coarsened"},
        {"retired_page_tag9_lost_ranges.bin", 9, "lost_ranges"},
        {"retired_page_tag10_affected.bin", 10, "affected"}
      ]

      for {file, tag, field} <- pages do
        raw = load(file)

        # Pin the OUTCOME, not merely "some error": a page carrying a retired tag is
        # bad bytes, so it must be :poison. Accepting any error would pass if the page
        # were rejected for an unrelated relational reason instead.
        assert {:error, :poison} = RecoveryValidate.manifest_chain_from_raw([raw], nil),
               "page carrying retired tag #{tag} (#{field}) must be :poison"
      end

      tombstones = [
        {"retired_tombstone_tag3_lost_from.bin", 3, "lost_from_sequence"},
        {"retired_tombstone_tag4_lost_through.bin", 4, "lost_through_sequence"},
        {"retired_tombstone_tag8_coarsened.bin", 8, "coarsened"}
      ]

      page = go_page()

      for {file, tag, field} <- tombstones do
        t = SpoolLossTombstoneV1.decode(load(file))

        assert {:error, :unknown_fields} = RecoveryValidate.tombstone(t, [page]),
               "tombstone carrying retired tag #{tag} (#{field}) was ACCEPTED"
      end
    end

    test "every retired vector carries ITS OWN advertised tag" do
      # Guard the guard, for ALL SIX and by TAG NUMBER. Checking two files for "some
      # unknown field" would pass if a vector carried the WRONG retired tag, or none --
      # in which case the rejections above prove nothing about the tag they name.
      # TAG AND WIRE TYPE. Proving the number alone would accept a tag-9 VARINT even
      # though lost_ranges was length-delimited -- bytes that retired field could never
      # have produced, advertised as if it had. Wire 0 = varint (bool/uint64),
      # 2 = length-delimited (the two repeated message fields).
      vectors = [
        {"retired_page_tag7_coarsened.bin", EdgeLossManifestPageV1, 7, 0},
        {"retired_page_tag9_lost_ranges.bin", EdgeLossManifestPageV1, 9, 2},
        {"retired_page_tag10_affected.bin", EdgeLossManifestPageV1, 10, 2},
        {"retired_tombstone_tag3_lost_from.bin", SpoolLossTombstoneV1, 3, 0},
        {"retired_tombstone_tag4_lost_through.bin", SpoolLossTombstoneV1, 4, 0},
        {"retired_tombstone_tag8_coarsened.bin", SpoolLossTombstoneV1, 8, 0}
      ]

      for {file, mod, tag, wire} <- vectors do
        decoded = mod.decode(load(file))
        unknown = decoded.__unknown_fields__

        refute unknown in [nil, []], "#{file} retained no unknown field; the vector is inert"

        retained = Enum.map(unknown, fn {t, w, _bytes} -> {t, w} end)

        assert {tag, wire} in retained,
               "#{file} advertises tag #{tag} wire #{wire} but retained #{inspect(retained)}"
      end
    end
  end

  describe "tombstone" do
    test "carries no loss interval, so a GAPPED manifest reconciles" do
      # [1,1] + [100,100] says 2..99 were NOT lost. The retired tombstone interval
      # would have declared [1,100] lost -- and because the tombstone scope is signed,
      # that would have been an authenticated second source of truth.
      page = with_spans(go_page(), [active(1, 1), active(100, 100)])
      t = %{go_tombstone() | manifest_root_sha256: HashGrammar.manifest_root([page])}

      assert :ok = RecoveryValidate.tombstone(t, [page])
      refute Map.has_key?(t, :lost_from_sequence)
      refute Map.has_key?(t, :coarsened)
    end

    test "rejects a wrong root, a wrong page count, and identical spool ids" do
      page = go_page()
      t = go_tombstone()

      assert {:error, :manifest_root} =
               RecoveryValidate.tombstone(%{t | manifest_root_sha256: d32(0x77)}, [page])

      assert {:error, :manifest_chain} =
               RecoveryValidate.tombstone(%{t | manifest_page_count: 9}, [page])

      assert {:error, :tombstone_mismatch} =
               RecoveryValidate.tombstone(%{t | new_spool_id: t.prior_spool_id}, [page])
    end
  end
end
