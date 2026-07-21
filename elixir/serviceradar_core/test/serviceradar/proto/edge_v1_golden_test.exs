defmodule Serviceradar.Proto.EdgeV1GoldenTest do
  @moduledoc """
  Decodes the Go-produced edge record-plane fixtures and asserts byte + semantic
  cross-language parity: the Elixir binding decodes the same bytes and
  independently recomputes the semantic-envelope digest, capability signing bytes
  (verifying the Ed25519 signatures against the exported issuer keys), the MTR
  completion proof, the UUID identity time, and the plan/recovery hash grammars.
  Every transport-direction / oneof fixture is decoded directly. Fixtures are
  written by proto/edge/v1/golden_test.go.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias Serviceradar.Edge.CapabilitySigning
  alias Serviceradar.Edge.HashGrammar
  alias Serviceradar.Edge.SemanticDigest
  alias Serviceradar.Edge.V1.EdgeDeliveryFrameV1
  alias Serviceradar.Edge.V1.EdgeLossManifestPageV1
  alias Serviceradar.Edge.V1.EdgeRecordClientMessage
  alias Serviceradar.Edge.V1.EdgeRecordLaneOpenAck
  alias Serviceradar.Edge.V1.EdgeRecordServerMessage
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias Serviceradar.Edge.V1.MtrTraceBatchV1
  alias Serviceradar.Edge.V1.RecoveryResolvedV1
  alias Serviceradar.Edge.V1.ScheduledPlanHeaderV1
  alias Serviceradar.Edge.V1.ScheduledPlanPageV1
  alias Serviceradar.Edge.V1.SpoolLossTombstoneV1
  alias Serviceradar.Edge.V1.SweepExecutionEventV1
  alias Serviceradar.Edge.V1.SweepObservationBatchV1

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)
  @fixed_millis 1_784_000_000_000

  defp load(name), do: File.read!(Path.join(@testdata, name))
  defp uuid_millis(<<ts::big-48, _::binary>>), do: ts

  defp digest32(tag), do: for(i <- 0..31, into: <<>>, do: <<tag + i::8>>)

  defp uuidv7(seed) do
    <<ms6::binary-6, _::binary-2>> = <<@fixed_millis <<< 16::big-64>>
    rest = for i <- 6..15, into: <<>>, do: <<seed + i::8>>
    <<b0::binary-6, b6, b7, b8, b9::binary-7>> = ms6 <> rest
    b0 <> <<(b6 &&& 0x0F) ||| 0x70, b7, (b8 &&& 0x3F) ||| 0x80>> <> b9
  end

  test "EdgeRecordV1 decodes; Elixir recomputes the semantic digest and identity time" do
    record = EdgeRecordV1.decode(load("record.bin"))

    assert record.payload_family == :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1
    assert record.cost_model_version == 2
    assert SemanticDigest.compute(record) == record.semantic_envelope_sha256
    assert :crypto.hash(:sha256, record.payload) == record.payload_sha256
    assert uuid_millis(record.event_id) == @fixed_millis

    # Typed, role-bound production capability bound to the producer context.
    assert {:production, prod} = record.production_capability.claims
    assert prod.contract_id == record.output_contract.contract_id
    assert prod.producer_assignment_id == record.producer_context.producer_assignment_id
    assert prod.cost_model_version == record.cost_model_version
    assert {:source, src} = record.source_authorization.capability.claims
    assert src.kind == :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK
    assert src.producer_assignment_id == record.producer_context.producer_assignment_id
  end

  test "Elixir recomputes capability signing bytes and verifies Ed25519 signatures (rotation)" do
    record = EdgeRecordV1.decode(load("record.bin"))
    key_a = load("issuer_key_a.pub")
    key_b = load("issuer_key_b.pub")

    # Signing-byte grammar parity with the committed Go vector.
    assert CapabilitySigning.signing_bytes(record.production_capability) ==
             load("production_signing_bytes.bin")

    # Raw SOURCE claim-frame signing bytes recomputed independently (delivery below).
    assert CapabilitySigning.signing_bytes(record.source_authorization.capability) ==
             load("source_signing_bytes.bin")

    # Real cross-language Ed25519 verification (purpose-bound, like Go).
    assert CapabilitySigning.verify(record.production_capability, :production, key_a)
    assert CapabilitySigning.verify(record.source_authorization.capability, :source, key_b)
    # Wrong key rejects.
    refute CapabilitySigning.verify(record.production_capability, :production, key_b)
    # Purpose mismatch rejects even with the correct key (structural, like Go).
    refute CapabilitySigning.verify(record.production_capability, :source, key_a)
    # Unknown algorithm rejects BEFORE crypto (would-be-valid raw signature).
    bad_alg = %{record.production_capability | algorithm: "rsa"}
    refute CapabilitySigning.verify(bad_alg, :production, key_a)
    assert CapabilitySigning.validate(bad_alg, :production) == {:error, :algorithm}
    # Tamper: replacing the signature breaks verification.
    tampered = %{record.production_capability | signature: :binary.copy(<<0>>, 64)}
    refute CapabilitySigning.verify(tampered, :production, key_a)
  end

  test "delivery frame carries exact canonical record bytes and a bound delivery capability" do
    frame = EdgeDeliveryFrameV1.decode(load("delivery_frame.bin"))
    record = EdgeRecordV1.decode(frame.record_bytes)
    assert :crypto.hash(:sha256, frame.record_bytes) == frame.record_sha256
    assert {:delivery, del} = frame.delivery_capability.claims
    assert del.event_id == record.event_id
    assert del.sequence == frame.sequence

    assert CapabilitySigning.verify(
             frame.delivery_capability,
             :delivery,
             load("issuer_key_a.pub")
           )

    # Raw delivery claim-frame signing bytes for BOTH transition members -- the
    # rollover carried in the frame here, and a renewal variant -- each recomputed
    # independently (the delivery oneof is where the field-framed grammar can drift).
    assert {:delivery, %{transition: {:rollover, _}}} = frame.delivery_capability.claims

    assert CapabilitySigning.signing_bytes(frame.delivery_capability) ==
             load("delivery_signing_bytes.bin")

    renewal = EdgeSignedCapabilityV1.decode(load("delivery_renewal_cap.bin"))
    assert {:delivery, %{transition: {:renewal, _}}} = renewal.claims
    assert CapabilitySigning.signing_bytes(renewal) == load("delivery_renewal_signing_bytes.bin")
    assert CapabilitySigning.verify(renewal, :delivery, load("issuer_key_a.pub"))
  end

  test "record with source authorization absent recomputes a distinct semantic digest" do
    record = EdgeRecordV1.decode(load("record_no_source.bin"))
    assert record.source_authorization == nil
    assert SemanticDigest.compute(record) == record.semantic_envelope_sha256
    # And it differs from the present-source record's digest (the presence marker flips).
    full = EdgeRecordV1.decode(load("record.bin"))
    refute SemanticDigest.compute(record) == SemanticDigest.compute(full)
  end

  test "every transport-direction / oneof fixture decodes directly" do
    client = EdgeRecordClientMessage.decode(load("client_lane_open.bin"))
    assert {:lane_open, open} = client.payload
    assert open.sequence_base == 1

    server = EdgeRecordServerMessage.decode(load("server_ack.bin"))
    assert {:ack, ack} = server.payload
    assert ack.resolved_through_sequence == 1
    assert [disp] = ack.dispositions
    assert disp.kind == :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE

    # Retryable-tail ack: seq 1 accepted-authoritative, seq 2 rejected-retryable, and
    # resolved_through stays 1 (retryable never advances the prefix). The Elixir
    # ENCODER must author byte-identical wire bytes that Go decodes and validates.
    retry_srv = EdgeRecordServerMessage.decode(load("server_ack_retryable.bin"))
    assert {:ack, retry_ack} = retry_srv.payload
    assert retry_ack.resolved_through_sequence == 1
    assert [d1, d2] = retry_ack.dispositions
    assert d1.kind == :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE
    assert d2.kind == :EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE
    assert d2.rejection_code == "WOULD_BLOCK"

    assert IO.iodata_to_binary(EdgeRecordServerMessage.encode(retry_srv)) ==
             load("server_ack_retryable.bin")

    lane_ack = EdgeRecordServerMessage.decode(load("server_lane_open_ack.bin"))
    assert {:lane_open_ack, %EdgeRecordLaneOpenAck{}} = lane_ack.payload

    resolved = RecoveryResolvedV1.decode(load("recovery_resolved.bin"))
    assert resolved.applied_through_sequence == 20

    batch = SweepObservationBatchV1.decode(load("sweep_batch.bin"))
    assert batch.source == :SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK
    assert [host] = batch.hosts
    assert host.first_seen_delta_nano == nil
  end

  test "lifecycle terminal carries an MTR completion proof Elixir recomputes" do
    ev = SweepExecutionEventV1.decode(load("lifecycle.bin"))
    assert ev.kind == :SWEEP_EXECUTION_EVENT_KIND_COMPLETED
    assert ev.mtr_completion_digest_version == 2

    # Reconstruct the same leaves the Go fixture folded and recompute the root.
    leaves = [
      {1, 1, uuidv7(0x30), digest32(0x93)},
      {2, 2, nil, digest32(0x93)}
    ]

    commitment = HashGrammar.mtr_ordinal_range_commitment(leaves)

    assert HashGrammar.mtr_completion_root(leaves, 2, ev.plan_root_sha256, commitment) ==
             ev.mtr_completion_digest

    # Exact-set coverage + membership parity: the valid set verifies; the invalid
    # vectors Go rejects are rejected here too.
    assert {:ok, _} =
             HashGrammar.mtr_completion_verify(leaves, 2, ev.plan_root_sha256, commitment)

    rng = digest32(0x93)
    root = ev.plan_root_sha256

    # {2,2,2} duplicate/missing collision.
    assert :error =
             HashGrammar.mtr_completion_verify(
               [{2, 2, nil, rng}, {2, 2, nil, rng}, {2, 2, nil, rng}],
               3,
               root,
               commitment
             )

    # r5-07: a leaf binding an ordinal to a range the plan never committed.
    assert :error =
             HashGrammar.mtr_completion_verify(
               [{1, 1, uuidv7(0x30), digest32(0xFE)}, {2, 2, nil, digest32(0xFE)}],
               2,
               root,
               commitment
             )

    # r5-08: leaf-level invalid vectors Go rejects.
    c1 = HashGrammar.mtr_ordinal_range_commitment([{1, 2, nil, rng}])
    assert :error = HashGrammar.mtr_completion_verify([{1, 999, <<1>>, <<2>>}], 1, root, c1)
    assert :error = HashGrammar.mtr_completion_verify([{1, 0, nil, <<>>}], 1, root, c1)
    assert :error = HashGrammar.mtr_completion_verify([{1, 2, uuidv7(0x30), rng}], 1, root, c1)
    assert :error = HashGrammar.mtr_completion_verify([{1, 2, nil, rng}], 1, <<0>>, c1)
  end

  test "the lane-open ack round-trips byte-identically through the Elixir encoder" do
    committed = load("server_lane_open_ack.bin")
    decoded = EdgeRecordServerMessage.decode(committed)
    assert {:lane_open_ack, %EdgeRecordLaneOpenAck{}} = decoded.payload
    # Reviewer repro (r5-20): prove the Elixir ENCODER still produces the exact Go
    # bytes for this oneof message (catches a future Elixir encoder regression).
    assert IO.iodata_to_binary(EdgeRecordServerMessage.encode(decoded)) == committed
  end

  test "Elixir independently recomputes the recovery hash grammar" do
    page = EdgeLossManifestPageV1.decode(load("manifest_page.bin"))
    assert HashGrammar.manifest_page_digest(page) == page.page_sha256

    tomb = SpoolLossTombstoneV1.decode(load("tombstone.bin"))
    assert HashGrammar.manifest_root([page]) == tomb.manifest_root_sha256
    assert [scope] = page.affected
    assert scope.run_shard == 3

    # Recovery-operation SCOPE digests: Elixir recomputes the Go-authored vectors,
    # proving the tombstone/manifest-page/resolved scope grammars are byte-identical.
    assert HashGrammar.manifest_page_scope_digest(page) == load("manifest_page_scope.bin")
    assert HashGrammar.tombstone_scope_digest(tomb) == load("tombstone_scope.bin")
    resolved = RecoveryResolvedV1.decode(load("recovery_resolved.bin"))
    assert HashGrammar.resolved_scope_digest(resolved) == load("resolved_scope.bin")
  end

  test "Elixir independently recomputes the plan hash grammar" do
    header = ScheduledPlanHeaderV1.decode(load("plan_header.bin"))
    page = ScheduledPlanPageV1.decode(load("plan_page.bin"))

    assert [range] = page.ranges
    assert HashGrammar.range_digest(range) == range.range_sha256
    assert HashGrammar.plan_page_digest(page) == page.page_sha256
    assert HashGrammar.plan_root([page]) == header.plan_root_sha256
    assert HashGrammar.plan_header_digest(header) == header.execution_plan_sha256
    assert header.total_target_count == 256
  end

  test "MTR batch shares one authoritative correlation context" do
    batch = MtrTraceBatchV1.decode(load("mtr_batch.bin"))
    assert batch.source == :SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK
    assert {:scheduled_check, ctx} = batch.correlation
    assert byte_size(ctx.check_id) == 16
    assert [trace] = batch.traces
    assert [hop] = trace.hops
    assert hop.jitter_worst_micro == 180
  end
end
