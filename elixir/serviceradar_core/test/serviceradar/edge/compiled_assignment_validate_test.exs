defmodule ServiceRadar.Edge.CompiledAssignmentValidateTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.CompiledAssignmentValidate, as: V
  alias ServiceRadar.Edge.HashGrammar
  alias Serviceradar.Edge.V1.CompiledSweepAssignmentV1
  alias Serviceradar.Edge.V1.SweepAssignmentRecordV1

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)
  defp load(name), do: File.read!(Path.join(@testdata, name))

  defp carrier, do: CompiledSweepAssignmentV1.decode(load("compiled_assignment.bin"))

  # A DIFFERENT value of the same shape, so a mutation changes the member without changing
  # its type -- otherwise a type error, not the binding rule, would do the rejecting.
  # Recompute both digests and the claim's committed body digest, so a BODY mutation leaves
  # the carrier self-consistent and only the rule under test can refuse it. The signature is
  # NOT re-made -- validate/1 does not verify one, which is exactly its documented scope.
  defp uuidv7(seed) do
    <<seed, 0, 0, 0, 0, 0, 7::4, 0::12, 2::2, seed::6, 0, 0, 0, 0, 0, 0, seed>>
  end

  defp reseal(c) do
    body = HashGrammar.compiled_assignment_body_digest(c)
    {:collection, claims} = c.collection_capability.claims

    cap = %{
      c.collection_capability
      | claims: {:collection, %{claims | compiled_assignment_body_sha256: body}}
    }

    c = %{c | compiled_assignment_body_sha256: body, collection_capability: cap}
    %{c | compiled_assignment_sha256: HashGrammar.compiled_assignment_artifact_digest(c)}
  end

  # A 16-byte member must stay a CANONICAL UUIDv7: the record validator checks that domain, so
  # arbitrary bytes would be refused there rather than by the relation under test.
  defp other_value(<<_::binary-size(16)>>), do: uuidv7(0xA7)
  defp other_value(v) when is_binary(v), do: :binary.copy(<<0xEE>>, byte_size(v))
  defp other_value(v) when is_integer(v), do: v + 1
  defp other_value(:EDGE_RECORD_TRAFFIC_CLASS_BULK), do: :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE
  defp other_value(:EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE), do: :EDGE_RECORD_TRAFFIC_CLASS_BULK
  defp record, do: SweepAssignmentRecordV1.decode(load("compiled_assignment_record.bin"))

  describe "the committed vectors" do
    test "the valid carrier is accepted from RAW BYTES" do
      assert {:ok, c} = V.validate_bytes(load("compiled_assignment.bin"))
      assert c.compiled_assignment_sha256 == load("compiled_assignment_artifact_digest.bin")
    end

    test "the source-absent INTERACTIVE carrier is accepted" do
      assert {:ok, c} = V.validate_bytes(load("compiled_assignment_interactive.bin"))
      assert c.traffic_class == :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE
    end

    test "the record/carrier RELATION holds for the committed pair" do
      assert :ok = V.validate_against_record(record(), carrier())
    end

    # Every committed reject vector, with its reason PINNED -- "some error" would prove
    # no reason parity with Go, only that both runtimes dislike the bytes.
    for {file, reason} <- [
          {"compiled_reject_body_digest.bin", :digest_mismatch},
          {"compiled_reject_artifact_digest.bin", :digest_mismatch},
          {"compiled_reject_no_capability.bin", :capability},
          # LAYERED, and asserted as such: the swapped-in production claim carries an
          # UNSPECIFIED traffic class, so ENUM ADMISSION speaks before the purpose rule.
          # Go reports ErrCapabilityPurpose because it has no admission layer in front.
          # Both refuse the carrier; the vector asserts what THIS runtime actually says
          # rather than pretending the layers match.
          {"compiled_reject_wrong_purpose.bin",
           {:unsupported_enum, [:collection_capability, :production, :traffic_class]}},
          {"compiled_reject_claim_cross_bound.bin", :capability},
          {"compiled_reject_zero_config_generation.bin", :identity},
          {"compiled_reject_unknown_result_format.bin", {:unsupported_enum, [:result_format]}}
        ] do
      test "#{file} is refused as #{inspect(reason)}" do
        assert {:error, unquote(Macro.escape(reason))} = V.validate_bytes(load(unquote(file)))
      end
    end
  end

  describe "the purpose rule itself" do
    test "a wrong-variant capability is refused as :purpose once admission passes" do
      # The vector above is caught by enum admission first, which would leave the purpose
      # rule unproven. Here the decoded carrier goes straight to validate/1, so only the
      # purpose rule can refuse it.
      c = carrier()

      wrong = %{
        c
        | collection_capability: %{
            c.collection_capability
            | claims: {:delivery, %Serviceradar.Edge.V1.EdgeDeliveryClaimsV1{}}
          }
      }

      assert {:error, :purpose} = V.validate(wrong)
    end

    test "an attestation whose OWN window is invalid is refused by the shared validator" do
      c = carrier()

      # `expires <= not_before` is the shared validator's rule, and it speaks first --
      # a more precise reason than the coverage rule below, so it is asserted as its own.
      short = %{
        c
        | collection_capability: %{
            c.collection_capability
            | expires_at_unix_nano: c.collection_capability.not_before_unix_nano
          }
      }

      assert {:error, :window} = V.validate(short)
    end

    test "an attestation that does not COVER the carrier's window is refused" do
      c = carrier()

      # The capability's own window stays VALID; the CARRIER's simply starts earlier, so
      # the tail before the attestation begins would be unattested. Only the coverage rule
      # can refuse this -- the shared validator sees nothing wrong with the capability.
      wide = reseal(%{c | not_before_unix_nano: c.not_before_unix_nano - 1})

      assert :ok = CapabilitySigning.validate(wide.collection_capability, :collection)
      assert {:error, :capability} = V.validate(wide)
    end
  end

  describe "each digest guard is independently observable" do
    # The committed reject vectors mutate a BODY field without resealing, so BOTH digests
    # mismatch and either guard could be the one that spoke. These two isolate them.
    test "only the BODY guard can refuse a carrier whose stored body digest is wrong" do
      c = carrier()
      bogus = :binary.copy(<<0xEE>>, 32)
      {:collection, claims} = c.collection_capability.claims

      # The CLAIM carries the SAME bogus digest. Without that, deleting the body guard falls
      # through to the claim-binding check and still rejects -- so the mutation would look
      # killed while the body guard itself was proven by nothing.
      cap = %{
        c.collection_capability
        | claims: {:collection, %{claims | compiled_assignment_body_sha256: bogus}}
      }

      bad = %{c | compiled_assignment_body_sha256: bogus, collection_capability: cap}

      bad = %{
        bad
        | compiled_assignment_sha256: HashGrammar.compiled_assignment_artifact_digest(bad)
      }

      # CONTROLS: the artifact digest matches (it RECOMPUTES the body rather than reading the
      # stored field) and the claim binding agrees. Only the body guard is left.
      assert HashGrammar.compiled_assignment_artifact_digest(bad) ==
               bad.compiled_assignment_sha256

      assert Map.get(elem(bad.collection_capability.claims, 1), :compiled_assignment_body_sha256) ==
               bad.compiled_assignment_body_sha256

      assert {:error, :digest_mismatch} = V.validate(bad)
    end

    test "only the ARTIFACT guard can refuse a carrier whose stored artifact digest is wrong" do
      c = carrier()
      bad = %{c | compiled_assignment_sha256: :binary.copy(<<0xEE>>, 32)}

      # CONTROL: the body digest is untouched and still matches, and the capability binding
      # is unaffected -- so the artifact guard is the only one left.
      assert HashGrammar.compiled_assignment_body_digest(bad) ==
               bad.compiled_assignment_body_sha256

      assert {:error, :digest_mismatch} = V.validate(bad)
    end
  end

  describe "the attestation binds EVERY member it commits" do
    # Pinning one member left the other nine free: a claim disagreeing with the carrier on
    # any of them would have been accepted. Each is mutated and RESEALED (the artifact
    # digest recomputed), so the binding check is the only rule that can refuse it.
    for member <- [
          :compiled_assignment_body_sha256,
          :producer_assignment_id,
          :execution_id,
          :network_scope_id,
          :authenticated_agent_id,
          :execution_plan_id,
          :target_range_id,
          :execution_shard,
          :assignment_epoch,
          :traffic_class
        ] do
      test "a claim disagreeing on #{member} is refused" do
        c = carrier()
        {:collection, claims} = c.collection_capability.claims
        member = unquote(member)

        bad_claims = Map.put(claims, member, other_value(Map.get(claims, member)))
        cap = %{c.collection_capability | claims: {:collection, bad_claims}}
        bad = %{c | collection_capability: cap}
        # RESEALED: the artifact digest covers the capability, so without this the artifact
        # guard would refuse it and the binding rule would stay unproven.
        bad = %{
          bad
          | compiled_assignment_sha256: HashGrammar.compiled_assignment_artifact_digest(bad)
        }

        assert {:error, :capability} = V.validate(bad)
      end
    end
  end

  describe "the curated decoder composition" do
    test "an unknown GROUP is refused, though a DIRECT decode cannot see it" do
      bytes = load("compiled_assignment_unknown_group.bin")

      # CONTROL: protobuf-elixir ERASES the group, so a direct decode yields a carrier
      # indistinguishable from the clean one. A validator reading only the decoded struct
      # therefore CANNOT reject these bytes -- which is the entire reason validate_bytes/1
      # routes through the curated WireDecode instead of decoding locally.
      direct = CompiledSweepAssignmentV1.decode(bytes)

      assert direct ==
               CompiledSweepAssignmentV1.decode(load("compiled_assignment_interactive.bin"))

      assert :ok = V.validate(direct)

      # The RAW path sees it. Go retains the group and rejects it as unknown fields; here
      # the recursive wire-hygiene gate classifies it as poison.
      assert {:error, :poison} = V.validate_bytes(bytes)
    end
  end

  describe "the physical ceiling" do
    test "exactly at the ceiling is ACCEPTED, one byte over is REFUSED" do
      # Committed at/over vectors: they decode to the SAME carrier and collapse far below
      # the ceiling on re-encode, which is why a decoded-struct check cannot enforce it.
      at = load("compiled_assignment_at_ceiling.bin")
      over = load("compiled_assignment_over_ceiling.bin")

      assert byte_size(at) == 65_536
      assert byte_size(over) == 65_537

      assert {:ok, decoded_at} = V.validate_bytes(at)
      assert {:error, :too_large} = V.validate_bytes(over)

      # CONTROL: the over-limit bytes decode to the same carrier, so nothing but the
      # received-byte count distinguishes them.
      assert CompiledSweepAssignmentV1.decode(over) == decoded_at
    end
  end

  describe "relation and lease" do
    # The RECORD is mutated, never the carrier: corrupting the carrier fails its own artifact
    # digest inside validate/1, so neither relation check is reached and the table would prove
    # nothing. Each member below keeps both artifacts individually valid, leaving the relation
    # as the only rule that can refuse the pair.
    for member <- [
          :compiled_assignment_id,
          :compiled_assignment_sha256,
          :producer_assignment_id,
          :execution_id,
          :execution_plan_id,
          :execution_plan_sha256,
          :target_range_id,
          :target_range_sha256,
          :network_scope_id,
          :authenticated_agent_id,
          :execution_shard,
          :assignment_epoch,
          :check_set_sha256
        ] do
      test "a record disagreeing on #{member} is refused" do
        r = record()
        c = carrier()
        member = unquote(member)
        bad = Map.put(r, member, other_value(Map.get(r, member)))

        # CONTROL: the mutated RECORD is still individually valid, so the relation is the only
        # rule left. A mutation that broke the record would prove the record validator instead.
        assert :ok = ServiceRadar.Edge.AssignmentValidate.validate(bad)
        assert {:error, :binding} = V.validate_against_record(bad, c)
      end
    end

    test "a carrier outliving the lease is refused" do
      r = record()
      c = carrier()
      short = %{r | lease_expires_at_unix_nano: c.expires_at_unix_nano - 1}
      assert {:error, :lease} = V.validate_against_record(short, c)
    end
  end

  describe "totality" do
    # The contract promises {:error, reason}; a shape it never saw must not raise.
    test "non-map and malformed inputs return typed errors, never raise" do
      assert {:error, :identity} = V.validate(:nope)
      assert {:error, :identity} = V.validate(nil)
      assert {:error, :poison} = V.validate_bytes(<<0xFF, 0xFF, 0xFF, 0xFF>>)
      # SYSTEMIC, not poison: a non-binary is a caller/programming fault, and the curated
      # decoder deliberately refuses to convert that into permanent quarantine.
      assert {:error, :systemic} = V.validate_bytes(:not_binary)
      assert {:error, :identity} = V.validate_against_record(:nope, carrier())
      assert {:error, :identity} = V.validate_against_record(record(), :nope)
    end

    test "a carrier missing every field is refused, not raised on" do
      assert {:error, :identity} = V.validate(%CompiledSweepAssignmentV1{})
    end

    test "a PLAIN MAP is refused even when it carries every valid field" do
      # Protobuf decoding always yields the struct, so a map reached validate/1 by skipping
      # the wire layer -- where retained unknown fields and wire-hygiene violations live.
      # Accepting one let a hand-built value claim a validated carrier's status.
      plain = Map.from_struct(carrier())

      assert {:error, :identity} = V.validate(plain)
    end

    test "a carrier with RETAINED unknown fields is refused" do
      # Retained unknown fields sit OUTSIDE the field-framed digests, so a later reader could
      # reinterpret bytes the content address never covered. Go rejects them before trusting
      # any field.
      tainted = %{carrier() | __unknown_fields__: [{99, 2, <<1, 2, 3>>}]}

      assert {:error, :unknown_fields} = V.validate(tainted)
    end

    test "a PLAIN-MAP capability envelope is refused, even fully resealed" do
      # The envelope used to be accepted as any map and walked field-by-field. That was a
      # BYPASS, not leniency: `unknown_fields_clean?/1` matches on `__unknown_fields__`, so a
      # map without that key fell through to `true`.
      c = carrier()
      plain_cap = Map.from_struct(c.collection_capability)
      bad = reseal(%{c | collection_capability: plain_cap})

      assert {:error, :capability} = V.validate(bad)
    end

    test "unknown fields NESTED in a typed claim are refused, and the plain envelope hid them" do
      c = carrier()
      {:collection, claims} = c.collection_capability.claims
      tainted_claims = %{claims | __unknown_fields__: [{99, 2, <<1, 2, 3>>}]}

      # With the STRUCT envelope the recursive walk reaches the claim and rejects it.
      struct_cap = %{c.collection_capability | claims: {:collection, tainted_claims}}

      assert {:error, :unknown_fields} =
               V.validate(reseal(%{c | collection_capability: struct_cap}))

      # CONTROL for the bypass: the SAME tainted claim under a plain-map envelope is now
      # refused at the envelope. Before the struct requirement it was accepted outright --
      # the walk never descended, so the retained bytes inside a perfectly typed claim rode
      # along on a carrier that validated.
      plain_cap = Map.from_struct(struct_cap)
      assert {:error, :capability} = V.validate(reseal(%{c | collection_capability: plain_cap}))
    end

    test "a non-struct claim BODY is a typed error, not a raise" do
      # `{:collection, 7}` is a well-formed oneof shape, so purpose derivation succeeds and
      # every later Map.get/2 raised BadMapError -- a contract promising {:error, reason} must
      # not raise on a shape it did not anticipate.
      c = carrier()
      bad = %{c | collection_capability: %{c.collection_capability | claims: {:collection, 7}}}

      assert {:error, :claims} = V.validate(bad)
    end
  end
end
