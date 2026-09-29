defmodule ServiceRadar.Edge.ExecutionGrantValidateTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias ServiceRadar.Edge.AssignmentValidate
  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.ExecutionGrantValidate, as: V
  alias Serviceradar.Edge.V1.CompiledSweepAssignmentV1
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias Serviceradar.Edge.V1.SweepAssignmentRecordV1

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)
  defp load(name), do: File.read!(Path.join(@testdata, name))

  defp record, do: SweepAssignmentRecordV1.decode(load("compiled_assignment_record.bin"))
  defp carrier, do: CompiledSweepAssignmentV1.decode(load("compiled_assignment.bin"))
  defp grant, do: EdgeSignedCapabilityV1.decode(load("compiled_assignment_execution_grant.bin"))
  defp claims(g), do: elem(g.claims, 1)

  defp with_claim(g, member, value) do
    %{g | claims: {:assignment_execution, Map.put(claims(g), member, value)}}
  end

  # Pads a grant encoding to EXACTLY `target` bytes by repeating issuer_id (field 2, wire type
  # 2) and restoring its REAL value LAST, so the decoder -- which keeps the last occurrence --
  # yields a byte-identical message. Same-value padding is the point: padding with a different
  # value would rewrite the field and break the very control the test relies on.
  defp encode_grant(g), do: EdgeSignedCapabilityV1.encode(g)

  defp pad_grant_to(raw, target) do
    issuer = EdgeSignedCapabilityV1.decode(raw).issuer_id
    true_field = <<0x12>> <> varint(byte_size(issuer)) <> issuer
    filler_total = target - byte_size(raw) - byte_size(true_field)
    payload = filler_total - 1 - byte_size(varint(filler_total))
    if payload < 0, do: raise("target #{target} is too small to pad to")
    raw <> <<0x12>> <> varint(payload) <> :binary.copy(<<0>>, payload) <> true_field
  end

  defp varint(n) when n < 0x80, do: <<n>>
  defp varint(n), do: <<0x80 ||| (n &&& 0x7F)>> <> varint(n >>> 7)

  defp other_value(<<_::binary-size(16)>>),
    do: <<0xA7, 0, 0, 0, 0, 0, 7::4, 0::12, 2::2, 0x27, 0, 0, 0, 0, 0, 0, 1>>

  defp other_value(v) when is_binary(v), do: :binary.copy(<<0xEE>>, byte_size(v))
  defp other_value(v) when is_integer(v), do: v + 1

  describe "the committed vectors" do
    test "the source-PRESENT grant validates against its record and carrier" do
      assert {:ok, _} =
               V.validate_bytes(
                 record(),
                 load("compiled_assignment.bin"),
                 load("compiled_assignment_execution_grant.bin")
               )
    end

    test "the source-ABSENT INTERACTIVE grant validates against its own pair" do
      # The absent branch, and a carrier whose traffic class is INTERACTIVE rather than
      # numerically 1 like digest_version and result_format -- a wrong-slot comparison
      # cannot pass both vectors.
      c = CompiledSweepAssignmentV1.decode(load("compiled_assignment_interactive.bin"))
      g = EdgeSignedCapabilityV1.decode(load("compiled_assignment_interactive_grant.bin"))
      j = claims(g)

      assert j.source_identity == nil
      assert c.traffic_class == :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE

      # This vector has no committed record, so the claim is checked against a record built
      # from the facts the grant itself commits -- the relation under test is claim-vs-record,
      # and a record disagreeing anywhere is covered by the table below.
      r = %SweepAssignmentRecordV1{
        network_scope_id: j.network_scope_id,
        authenticated_agent_id: j.authenticated_agent_id,
        producer_assignment_id: j.producer_assignment_id,
        execution_id: j.execution_id,
        run_id: j.run_id,
        execution_shard: j.run_shard,
        assignment_epoch: j.authority_epoch,
        production_scope_id: j.production_scope_id,
        scope_sha256: j.scope_sha256,
        contract_bundle_sha256: j.contract_bundle_sha256,
        execution_plan_sha256: j.execution_plan_sha256,
        target_range_sha256: j.target_range_sha256
      }

      assert :ok = V.validate(r, c, g)
    end
  end

  describe "every claim member binds" do
    for member <- [
          :network_scope_id,
          :authenticated_agent_id,
          :producer_assignment_id,
          :execution_id,
          :run_id,
          :run_shard,
          :authority_epoch,
          :production_scope_id,
          :scope_sha256,
          :contract_bundle_sha256,
          :execution_plan_sha256,
          :target_range_sha256,
          :compiled_assignment_id,
          :compiled_assignment_sha256
        ] do
      test "a grant disagreeing on #{member} is refused" do
        member = unquote(member)
        g = grant()
        bad = with_claim(g, member, other_value(Map.get(claims(g), member)))

        assert {:error, :binding} = V.validate(record(), carrier(), bad)
      end
    end

    test "an ABSENT plan or range digest is refused, not read as unconstrained" do
      for member <- [:execution_plan_sha256, :target_range_sha256] do
        assert {:error, :binding} =
                 V.validate(record(), carrier(), with_claim(grant(), member, <<>>))

        # ISOLATED: with the RECORD's member also empty, EQUALITY passes and only the required
        # LENGTH can refuse. Without this the equality check does the rejecting and the
        # "empty is not unconstrained" rule stays unproven -- which is the whole rule.
        r = Map.put(record(), member, <<>>)
        bad = with_claim(grant(), member, <<>>)
        assert Map.get(claims(bad), member) == Map.get(r, member)
        assert {:error, :binding} = V.validate(r, carrier(), bad)
      end
    end

    test "the claim's own PURPOSE field must agree with its variant" do
      # The VARIANT stays :assignment_execution, so the shared validator is satisfied and only
      # the claim-body purpose rule can refuse this. Without it a claim body could declare a
      # role its envelope was never issued for.
      bad = with_claim(grant(), :purpose, :EDGE_CAPABILITY_PURPOSE_COLLECTION)

      assert :ok = CapabilitySigning.validate(bad, :assignment_execution)
      assert {:error, :binding} = V.validate(record(), carrier(), bad)
    end

    test "a traffic class differing from the CARRIER's is refused" do
      bad = with_claim(grant(), :traffic_class, :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE)
      assert {:error, :binding} = V.validate(record(), carrier(), bad)
    end

    test "the source identity must be present EXACTLY when the record's is" do
      r = record()
      g = grant()

      # Claim drops it while the record has one.
      assert {:error, :binding} = V.validate(r, carrier(), with_claim(g, :source_identity, nil))

      # Record drops it while the claim has one.
      assert {:error, :binding} = V.validate(%{r | source_identity: nil}, carrier(), g)

      # And each member of a present identity.
      id = claims(g).source_identity

      for {member, value} <- [
            kind: :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP,
            context_id: other_value(id.context_id),
            source_scope_id: other_value(id.source_scope_id),
            source_scope_sha256: other_value(id.source_scope_sha256)
          ] do
        bad = with_claim(g, :source_identity, Map.put(id, member, value))
        assert {:error, :binding} = V.validate(r, carrier(), bad)
      end
    end
  end

  describe "the collection window" do
    test "must be a REAL window, and CONTAINED in the envelope" do
      g = grant()
      j = claims(g)

      # Unset, inverted, and empty are all refused: 0 is the proto default and must not pose
      # as an open-ended grant.
      for {nb, ex} <- [{0, 0}, {0, j.collection_expires_unix_nano}, {200, 100}, {100, 100}] do
        bad =
          g
          |> with_claim(:collection_not_before_unix_nano, nb)
          |> with_claim(:collection_expires_unix_nano, ex)

        assert {:error, :binding} = V.validate(record(), carrier(), bad)
      end

      # CONTAINMENT: each of these CONTAINS the envelope's instants, so only containment
      # refuses them -- a window check alone would accept both.
      before_env = with_claim(g, :collection_not_before_unix_nano, g.not_before_unix_nano - 1)
      after_env = with_claim(g, :collection_expires_unix_nano, g.expires_at_unix_nano + 1)

      assert {:error, :binding} = V.validate(record(), carrier(), before_env)
      assert {:error, :binding} = V.validate(record(), carrier(), after_env)

      # A window EQUAL to the envelope is contained, so the two above are containment and not
      # an off-by-one.
      equal =
        g
        |> with_claim(:collection_not_before_unix_nano, g.not_before_unix_nano)
        |> with_claim(:collection_expires_unix_nano, g.expires_at_unix_nano)

      assert :ok = V.validate(record(), carrier(), equal)
    end
  end

  describe "freshness is separate from shape" do
    test "fresh_at/2 is half-open on BOTH windows" do
      g = grant()

      assert :ok = V.fresh_at(g, g.not_before_unix_nano)
      assert {:error, :not_fresh} = V.fresh_at(g, g.not_before_unix_nano - 1)
      # AT expiry is already outside -- the window is half-open.
      assert {:error, :not_fresh} = V.fresh_at(g, g.expires_at_unix_nano)

      # The CLAIM's window is checked too, not just the envelope's. The committed fixture's two
      # windows COINCIDE, so any instant outside one is outside the other and a test built on
      # it proves nothing. Widen the ENVELOPE and keep the claim narrow: 500 is inside the
      # envelope and outside the claim, so only a check of the CLAIM's window refuses it.
      # (fresh_at/2 answers a question about an instant, not about containment, so a wider
      # envelope is a legitimate input here -- validate/3 is what rejects that shape.)
      wide =
        %{g | not_before_unix_nano: 1, expires_at_unix_nano: 1000}
        |> with_claim(:collection_not_before_unix_nano, 1)
        |> with_claim(:collection_expires_unix_nano, 2)

      assert :ok = V.fresh_at(wide, 1)
      assert {:error, :not_fresh} = V.fresh_at(wide, 500)

      # And the MIRROR, because the coinciding fixture hides this direction too: an instant
      # inside the CLAIM's window but outside the ENVELOPE. Only a check of the envelope
      # refuses it, so together these two prove BOTH windows are consulted rather than either
      # one standing in for the pair.
      narrow_env =
        %{g | not_before_unix_nano: 100, expires_at_unix_nano: 101}
        |> with_claim(:collection_not_before_unix_nano, 1)
        |> with_claim(:collection_expires_unix_nano, 1000)

      assert :ok = V.fresh_at(narrow_env, 100)
      assert {:error, :not_fresh} = V.fresh_at(narrow_env, 500)
    end

    test "a valid grant is NOT fresh forever, and validate/3 says nothing about freshness" do
      g = grant()

      # Shape is fine at any instant; only fresh_at/2 answers the time question.
      assert :ok = V.validate(record(), carrier(), g)
      assert {:error, :not_fresh} = V.fresh_at(g, 1)
    end
  end

  describe "the record's identity domains reach the grant boundary" do
    # validate_bytes/3 delegates the RECORD to AssignmentValidate, which had adopted none of
    # the members task 1.3 added -- so an all-zero run_id reached the composed boundary with
    # nothing in the way.
    #
    # The composed cases below mutate the record AND the grant TOGETHER, to the same malformed
    # value. Mutating only the record leaves the grant disagreeing, so the claim comparison
    # rejects as :binding and the delegated record validation could be deleted with the suite
    # still green -- which is exactly what an earlier version of this block did while claiming
    # otherwise. With both sides matching, only the record's own domain rule can refuse.
    test "an all-zero run_id is refused, and ONLY the record validator can refuse it" do
      zero = <<0::128>>
      r = %{record() | run_id: zero}
      g = with_claim(grant(), :run_id, zero)

      # CONTROL, on the MUTATED PAIR ITSELF: the grant's run_id equals the record's, so the
      # claim comparison has nothing to object to, and decoded validate/3 -- which does NOT
      # delegate the record -- accepts it. Only the record's own domain rule is left. An
      # earlier version validated the UNTOUCHED fixtures here, which said nothing about the
      # pair under test.
      assert claims(g).run_id == r.run_id
      assert :ok = V.validate(r, carrier(), g)

      assert {:error, :identity} = AssignmentValidate.validate(r)

      assert {:error, :identity} =
               V.validate_bytes(r, load("compiled_assignment.bin"), encode_grant(g))
    end

    test "a malformed SOURCE IDENTITY is refused through the composed boundary" do
      id = record().source_identity

      for bad <- [
            %{id | kind: :EDGE_SOURCE_AUTHORIZATION_KIND_UNSPECIFIED},
            %{id | context_id: <<0::128>>},
            %{id | source_scope_id: <<0::96>>},
            %{id | source_scope_sha256: <<0xEE>>}
          ] do
        r = %{record() | source_identity: bad}
        g = with_claim(grant(), :source_identity, bad)

        assert {:error, :identity} = AssignmentValidate.validate(r)

        assert {:error, :identity} =
                 V.validate_bytes(r, load("compiled_assignment.bin"), encode_grant(g))
      end
    end

    test "RETAINED unknown fields inside the source identity are refused, composed too" do
      r = record()
      tainted = %{r.source_identity | __unknown_fields__: [{99, 2, <<1, 2, 3>>}]}
      bad = %{r | source_identity: tainted}

      # The walk previously reached the record and its expectation but not the identity, so
      # bytes sitting outside every grammar that reads it rode along. The GRANT is untouched:
      # unknown fields are not a claim member, so nothing else can be doing the rejecting.
      assert {:error, :unknown_fields} = AssignmentValidate.validate(bad)

      assert {:error, :unknown_fields} =
               V.validate_bytes(
                 bad,
                 load("compiled_assignment.bin"),
                 load("compiled_assignment_execution_grant.bin")
               )
    end

    test "a fully populated PLAIN MAP mtr_expectation is refused, composed too" do
      # Same generated-type family as the record and the source identity: a plain map skipped
      # the wire layer, so its retained unknown fields are invisible to the walk. The GRANT is
      # untouched -- the expectation is not a claim member, so nothing else can be rejecting.
      r = record()
      plain = %{r | mtr_expectation: Map.from_struct(r.mtr_expectation)}

      assert {:error, :expectation} = AssignmentValidate.validate(plain)

      assert {:error, :expectation} =
               V.validate_bytes(
                 plain,
                 load("compiled_assignment.bin"),
                 load("compiled_assignment_execution_grant.bin")
               )
    end

    test "a fully populated PLAIN MAP record is refused, composed too" do
      # Protobuf decoding always yields the struct, so a map skipped the wire layer. A fully
      # populated one used to validate and carry straight through this boundary.
      plain = Map.from_struct(record())

      assert {:error, :identity} = AssignmentValidate.validate(plain)

      assert {:error, :identity} =
               V.validate_bytes(
                 plain,
                 load("compiled_assignment.bin"),
                 load("compiled_assignment_execution_grant.bin")
               )
    end

    # The carrier reference is proven in isolation only, for a simpler reason than resealing:
    # any carrier malformed enough to MATCH is independently rejected by its own validator, so
    # the record rule could never be the one speaking. Changing the carrier's id would
    # additionally require REISSUING the attestation, since the claim binds it.

    for {member, bad, label} <- [
          {:compiled_assignment_id, <<0::128>>, "a non-UUIDv7 carrier id"},
          {:compiled_assignment_sha256, <<0xEE>>, "a short carrier digest"}
        ] do
      test "#{label} is refused by the record validator" do
        {member, bad} = {unquote(member), unquote(bad)}

        assert {:error, :identity} =
                 AssignmentValidate.validate(Map.put(record(), member, bad))
      end
    end
  end

  describe "role, ceiling and totality" do
    test "a capability of the WRONG ROLE is refused as :purpose" do
      # The scheduler's COLLECTION attestation is not execution permission.
      assert {:error, :purpose} = V.validate(record(), carrier(), carrier().collection_capability)
    end

    test "the 16 KiB ceiling is pinned at the BOUNDARY, not at an arbitrary overshoot" do
      raw = load("compiled_assignment_execution_grant.bin")
      carrier_bytes = load("compiled_assignment.bin")

      at_limit = pad_grant_to(raw, 16_384)
      one_over = pad_grant_to(raw, 16_385)

      assert byte_size(at_limit) == 16_384
      assert byte_size(one_over) == 16_385

      # CONTROLS. Both decode to the SAME grant -- the padding duplicates issuer_id and the
      # LAST occurrence restores its REAL value, so the decoded message is untouched. An
      # earlier version padded with a DIFFERENT value and silently rewrote the host issuer to
      # "sched", contradicting the very claim the control exists to make. Both also collapse
      # far below the ceiling on re-encode, which is why a decoded-struct check cannot
      # enforce this bound.
      clean = EdgeSignedCapabilityV1.decode(raw)

      for padded <- [at_limit, one_over] do
        decoded = EdgeSignedCapabilityV1.decode(padded)
        assert decoded == clean
        assert byte_size(EdgeSignedCapabilityV1.encode(decoded)) <= 16 * 1024
      end

      # Exactly at the ceiling ACCEPTED, one byte over REFUSED. An arbitrary overshoot leaves
      # both `>=` and an over-strict ceiling passing.
      assert {:ok, _} = V.validate_bytes(record(), carrier_bytes, at_limit)
      assert {:error, :too_large} = V.validate_bytes(record(), carrier_bytes, one_over)
    end

    test "an unknown GROUP is refused, though a DIRECT decode VALIDATES cleanly" do
      bytes = load("compiled_assignment_grant_unknown_group.bin")
      carrier_bytes = load("compiled_assignment.bin")

      # The vector is built from the grant that MATCHES this record and carrier. Built from a
      # different grant, a runtime that regressed to direct decoding would still reject -- as a
      # BINDING failure against the wrong pair -- and the decoder claim would go unproven.
      direct = EdgeSignedCapabilityV1.decode(bytes)

      assert direct ==
               EdgeSignedCapabilityV1.decode(load("compiled_assignment_execution_grant.bin"))

      # CONTROL: protobuf-elixir ERASES the group, so the DIRECTLY decoded grant validates
      # cleanly. Only the raw boundary can see the bytes, which is the whole reason
      # validate_bytes/3 routes through the curated WireDecode.
      assert :ok = V.validate(record(), carrier(), direct)

      assert {:error, :poison} = V.validate_bytes(record(), carrier_bytes, bytes)
    end

    test "the ROLE is answered FIRST, before any envelope rule" do
      # A wrong-role capability that ALSO has a bad version must report :purpose. Reporting
      # :version says nothing about what is actually wrong with it, and contradicts the
      # documented parity with Go's ordering.
      wrong_role = %{carrier().collection_capability | capability_version: 99}

      assert {:error, :purpose} = V.validate(record(), carrier(), wrong_role)

      # CONTROL: with the RIGHT role the envelope rules do speak, so the case above is the
      # ORDERING and not a blanket :purpose.
      assert {:error, :version} =
               V.validate(record(), carrier(), %{grant() | capability_version: 99})
    end

    test "non-struct and malformed inputs return typed errors, never raise" do
      assert {:error, :capability} = V.validate(record(), carrier(), :nope)
      assert {:error, :capability} = V.validate(record(), carrier(), %{})
      assert {:error, :capability} = V.fresh_at(:nope, 1)

      # NESTED malformed values, both of which used to raise BadMapError: a well-formed oneof
      # shape whose body is not the generated struct, and a claim whose nested source identity
      # is not one either. The claim-body type check only inspects the claim itself, so the
      # identity needs its own guard where its members are read.
      assert {:error, :capability} =
               V.fresh_at(%{grant() | claims: {:assignment_execution, 7}}, 1)

      assert {:error, :binding} =
               V.validate(record(), carrier(), with_claim(grant(), :source_identity, 7))

      assert {:error, :poison} =
               V.validate_bytes(record(), load("compiled_assignment.bin"), <<0xFF, 0xFF, 0xFF>>)

      assert {:error, :systemic} =
               V.validate_bytes(record(), load("compiled_assignment.bin"), :not_binary)
    end

    test "the shared capability validator still owns the envelope" do
      g = grant()
      assert {:error, :algorithm} = V.validate(record(), carrier(), %{g | algorithm: "rot13"})
      assert {:error, :version} = V.validate(record(), carrier(), %{g | capability_version: 99})
      assert {:error, :signature} = V.validate(record(), carrier(), %{g | signature: <<>>})
      assert :ok = CapabilitySigning.validate(g, :assignment_execution)
    end
  end
end
