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

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadar.Edge.SemanticDigest
  alias ServiceRadar.Edge.SemanticValidate
  alias Serviceradar.Edge.V1.EdgeDeliveryFrameV1
  alias Serviceradar.Edge.V1.EdgeLossManifestPageV1
  alias Serviceradar.Edge.V1.EdgeRecordClientMessage
  alias Serviceradar.Edge.V1.EdgeRecordLaneOpenAck
  alias Serviceradar.Edge.V1.EdgeRecordServerMessage
  alias Serviceradar.Edge.V1.EdgeRecordTrafficClass
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias Serviceradar.Edge.V1.MtrTraceBatchV1
  alias Serviceradar.Edge.V1.RecoveryResolvedV1
  alias Serviceradar.Edge.V1.ScheduledPlanHeaderV1
  alias Serviceradar.Edge.V1.ScheduledPlanPageV1
  alias Serviceradar.Edge.V1.SpoolLossTombstoneV1
  alias Serviceradar.Edge.V1.SweepExecutionEventV1
  alias Serviceradar.Edge.V1.SweepObservationBatchV1
  alias ServiceRadar.Edge.WireDecode

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)
  @fixed_millis 1_784_000_000_000

  defp load(name), do: File.read!(Path.join(@testdata, name))
  defp encode_varint(n) when n < 0x80, do: <<n>>
  defp encode_varint(n), do: <<(n &&& 0x7F) ||| 0x80>> <> encode_varint(n >>> 7)
  defp uuid_millis(<<ts::big-48, _::binary>>), do: ts

  defp digest32(tag), do: for(i <- 0..31, into: <<>>, do: <<tag + i::8>>)

  defp uuidv7(seed) do
    <<ms6::binary-6, _::binary-2>> = <<@fixed_millis <<< 16::big-64>>
    rest = for i <- 6..15, into: <<>>, do: <<seed + i::8>>
    <<b0::binary-6, b6, b7, b8, b9::binary-7>> = ms6 <> rest
    b0 <> <<(b6 &&& 0x0F) ||| 0x70, b7, (b8 &&& 0x3F) ||| 0x80>> <> b9
  end

  # A 16-byte UUID with version nibble 4 (not 7): valid canonical UUID, invalid UUIDv7.
  defp non_v7_uuid do
    <<a::binary-6, b6, rest::binary>> = uuidv7(0x01)
    a <> <<(b6 &&& 0x0F) ||| 0x40>> <> rest
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

  # NOTE: this is signature-vector parity + purpose binding, NOT key rotation. It
  # injects two raw public keys directly and never resolves (issuer_id,
  # issuer_key_id) through a tuple-keyed resolver, overlaps two keys for one issuer,
  # retires one, or rejects a cross-issuer substitution. Real rotation coverage is
  # deferred to the post-ABI-freeze fixture regeneration (the capability signing-byte
  # grammar changes there), where same-issuer/different-key-ID vectors are added.
  test "Elixir recomputes capability signing bytes and verifies Ed25519 signatures (signature-vector parity)" do
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
    # An UNSIGNED unknown field on the capability is rejected by the SHARED signing validator
    # (recursively), so it can never verify -- not only in publication-proof generation.
    unknown = %{record.production_capability | __unknown_fields__: [{99, 2, "x"}]}
    assert CapabilitySigning.validate(unknown, :production) == {:error, :unknown_fields}
    refute CapabilitySigning.verify(unknown, :production, key_a)

    # FIXED-WIDTH ALIAS: capability times 2^100 / 2^100+1 would truncate to the same preimage as
    # 0 / 1 under <<v::big-signed-64>>; they are rejected BEFORE any preimage.
    aliased = %{
      record.production_capability
      | not_before_unix_nano: 0x1_0000_0000_0000_0000,
        expires_at_unix_nano: 0x1_0000_0000_0000_0001
    }

    assert CapabilitySigning.validate(aliased, :production) == {:error, :window}
    refute CapabilitySigning.verify(aliased, :production, key_a)

    # P2: capability validate/verify are TOTAL -- malformed maps, nonbinary IDs, and nonbinary
    # public keys return {:error}/false, never raise.
    assert CapabilitySigning.validate(%{foo: 1}, :production) == {:error, :version}
    assert CapabilitySigning.validate(:nope, :production) == {:error, :capability}

    assert {:error, :issuer} =
             CapabilitySigning.validate(
               %{record.production_capability | issuer_id: 123},
               :production
             )

    refute CapabilitySigning.verify(record.production_capability, :production, 123)
    refute CapabilitySigning.verify(%{foo: 1}, :production, key_a)

    # A plain map carrying `__unknown_fields__` reaches the unknown-field walk; it must NOT raise
    # (Map.from_struct/1 on a plain map) -- validate stays total.
    assert {:error, _} = CapabilitySigning.validate(%{__unknown_fields__: []}, :production)

    # A production claim with a NEGATIVE unsigned field (authority_epoch = -1) validates the
    # envelope but would raise in the checked framing during signing_bytes; verify MUST stay total.
    {:production, prod} = record.production_capability.claims

    neg_epoch = %{
      record.production_capability
      | claims: {:production, %{prod | authority_epoch: -1}}
    }

    refute CapabilitySigning.verify(neg_epoch, :production, key_a)
  end

  test "WireDecode outcomes after the task-1.5 structural preflight: poison / ok" do
    # 1. Negative enum on the REAL gRPC ingress type: EdgeRecordClientMessage.lane_open.traffic_class
    #    = -1 now DECODES with the integer RETAINED, exactly as Go's proto.Unmarshal retains it (the
    #    generated edge enums are patched by scripts/patch_edge_enum_negatives.exs). It is the
    #    SEMANTIC validator -- not the decoder -- that rejects it, as `REJECTED_PERMANENT` at a known
    #    delivery slot. Decoding it is what makes protobuf's last-one-wins resolution work; see
    #    Serviceradar.Edge.SemanticValidateTest for the full two-layer proof.
    assert {:ok, %EdgeRecordClientMessage{payload: {:lane_open, open}}} =
             WireDecode.decode_client_message(load("poison_client_message_negative_enum.bin"))

    assert open.traffic_class == -1

    # The fixture also leaves route_profile UNSPECIFIED, which Go's ValidateLaneOpen rejects first
    # (`!knownRouteProfile(o) || !knownTrafficClass(o)`), so the named field is route_profile here.
    # Per-field coverage lives in Serviceradar.Edge.SemanticValidateTest.
    assert {:error, {:unsupported_enum, _field}} = SemanticValidate.validate_lane_open(open)

    # 2. A deterministic malformed-wire vector (field 23 wire 5, then field 1 wire 3 = a start-GROUP).
    #    It used to raise an AMBIGUOUS MatchError -> `:systemic`, which at a KNOWN delivery slot stays
    #    retryable FOREVER and pins the cumulative-prefix watermark. The typed malformed-wire preflight
    #    now recognizes the group as genuine bad bytes -> `:poison`, so no decodable slot is retryable
    #    forever. (Genuine codegen/metadata MatchErrors still classify `:systemic` -- see the
    #    stack-independence test below, which exercises `classify/1` directly.)
    assert {:error, :poison} = WireDecode.decode_record(Base.decode16!("BD38B3632E0B28E84B69"))

    # 3. Other malformed bytes -> poison (here the preflight rejects the reserved wire type 7).
    assert {:error, :poison} = WireDecode.decode_record(<<0xFF, 0xFF, 0xFF>>)

    # A well-formed record still decodes cleanly through the same boundary.
    assert {:ok, %EdgeRecordV1{}} = WireDecode.decode_record(load("record.bin"))
  end

  test "WireDecode classification is STACK-INDEPENDENT: keyed on the exception value, not the trace" do
    # The decoder's deliberate malformed-wire error -> poison (by exception type; no stacktrace).
    assert WireDecode.classify(%Protobuf.DecodeError{message: "x"}) == :poison

    # A MatchError is ambiguous (malformed wire OR a codegen/metadata bug) -> systemic, never poison.
    assert WireDecode.classify(%MatchError{term: ""}) == :systemic
    assert WireDecode.classify(%MatchError{term: :bad_generated_metadata}) == :systemic

    # An edge-ENUM FunctionClauseError is now SYSTEMIC, not poison. The generated edge enums carry
    # injected negative identity clauses and the DSL's catchall covers every non-negative integer,
    # so key/1 and value/1 are TOTAL over integers: no wire bytes can legitimately raise this. If it
    # is raised, the transform is missing/corrupt or codegen drifted -- a deployment defect, which
    # must PAUSE rather than permanently resolve a delivery as quarantined.
    assert WireDecode.classify(%FunctionClauseError{
             module: EdgeRecordTrafficClass,
             function: :key,
             arity: 1
           }) == :systemic

    # A FunctionClauseError from a MESSAGE (non-enum) module is a decoder BUG -> systemic, never poison.
    assert WireDecode.classify(%FunctionClauseError{
             module: EdgeRecordV1,
             function: :decode,
             arity: 1
           }) == :systemic

    # Any other exception shape is a genuine decoder bug -> systemic (the default), never silent poison.
    assert WireDecode.classify(%ArgumentError{message: "boom"}) == :systemic
    assert WireDecode.classify(%RuntimeError{message: "boom"}) == :systemic
    assert WireDecode.classify(%KeyError{key: :x}) == :systemic
  end

  # The reviewer's repro (real negative-enum fixture flipping :poison -> :systemic after
  # `:erlang.system_flag(:backtrace_depth, 1)`) cannot recur: `classify/1` above NEVER reads
  # `__STACKTRACE__`, it keys only on the exception's own value, so the end-to-end verdict is immune to
  # VM stack depth by construction. (We do not mutate the global `backtrace_depth` flag inside this
  # async suite, which would race concurrent tests.)

  test "WireDecode refuses oversize input BEFORE decode (:too_large), non-binary input (:systemic)" do
    # Oversize raw bytes are a PERMANENT rejection checked before protobuf is invoked, per frozen stage
    # bound (record 512 KiB; frame = record + 16 KiB envelope; client = frame + 8). NOT poison.
    assert {:error, :too_large} = WireDecode.decode_record(:binary.copy(<<0>>, 512 * 1024 + 1))

    assert {:error, :too_large} =
             WireDecode.decode_frame(:binary.copy(<<0>>, (512 + 16) * 1024 + 1))

    assert {:error, :too_large} =
             WireDecode.decode_client_message(:binary.copy(<<0>>, (512 + 16) * 1024 + 9))

    # A just-under-bound but malformed record is still decoded (and poisoned), proving the guard is a
    # size check, not a blanket reject.
    assert {:error, :poison} = WireDecode.decode_record(:binary.copy(<<0xFF>>, 512 * 1024))

    # A non-binary caller argument is a caller/programming fault -> systemic, never poison.
    assert {:error, :systemic} = WireDecode.decode_record(:not_bytes)
  end

  test "decode_frame enforces the RELATIONAL envelope budget on RAW bytes (duplicate-field bypass)" do
    # 1-byte record_bytes (field 5, wire type 2) + 20 KiB of duplicate `sequence` (field 2, varint = 1)
    # fields. Protobuf decode collapses the duplicates (last-wins) so a canonical-size check would MISS
    # it; the RAW check (byte_size(raw) - byte_size(record_bytes) > 16 KiB) rejects it as :too_large.
    bloat = <<0x2A, 0x01, 0x00>> <> :binary.copy(<<0x10, 0x01>>, 10 * 1024)
    assert {:error, :too_large} = WireDecode.decode_frame(bloat)

    # A minimal frame (1 KiB record_bytes + one sequence field) has a tiny overhead -> accepted.
    small = <<0x2A, 0x80, 0x08>> <> :binary.copy(<<0>>, 1024) <> <<0x10, 0x01>>
    assert {:ok, %EdgeDeliveryFrameV1{}} = WireDecode.decode_frame(small)
  end

  test "decode_client_message peels the NESTED frame and enforces its raw envelope (P1-2)" do
    # The reviewer's attack: wrap the 20 KiB bloated frame in EdgeRecordClientMessage.delivery_frame
    # (field 2, wire type 2 -> tag 0x12). The generated client-message decode would collapse the frame's
    # duplicate fields and MISS the bloat; the raw OUTER-wire peel catches it before decode.
    bloat_frame = <<0x2A, 0x01, 0x00>> <> :binary.copy(<<0x10, 0x01>>, 10 * 1024)
    bloat_client = <<0x12>> <> encode_varint(byte_size(bloat_frame)) <> bloat_frame
    assert {:error, :too_large} = WireDecode.decode_client_message(bloat_client)

    # A well-formed nested frame (1 KiB record + one sequence) wrapped in a client message is accepted.
    ok_frame = <<0x2A, 0x80, 0x08>> <> :binary.copy(<<0>>, 1024) <> <<0x10, 0x01>>
    ok_client = <<0x12>> <> encode_varint(byte_size(ok_frame)) <> ok_frame

    assert {:ok, %EdgeRecordClientMessage{payload: {:delivery_frame, _}}} =
             WireDecode.decode_client_message(ok_client)
  end

  test "decode_client_message fails closed on the three scanner-bypass vectors (P0)" do
    bloat_frame = <<0x2A, 0x01, 0x00>> <> :binary.copy(<<0x10, 0x01>>, 10 * 1024)
    tiny_frame = <<0x2A, 0x01, 0x00>>
    frame2 = fn f -> <<0x12>> <> encode_varint(byte_size(f)) <> f end

    # (1) DUPLICATE outer oneof: a bloated field-2 frame followed by a tiny decoy field-2 frame. Generated
    # decode keeps the LAST (tiny) frame and would miss the bloat; two payloads -> reject (:poison).
    dup = frame2.(bloat_frame) <> frame2.(tiny_frame)
    assert byte_size(dup) < 528 * 1024
    assert {:error, :poison} = WireDecode.decode_client_message(dup)

    # (2) A protobuf GROUP (field 3, start-group wire type 3 = tag 0x1B; end-group 0x1C) before the
    # bloated frame. The scanner rejects the group rather than skipping to accept the frame.
    group_then_bloat = <<0x1B, 0x1C>> <> frame2.(bloat_frame)
    assert {:error, :poison} = WireDecode.decode_client_message(group_then_bloat)

    # (3) The exact OVERFLOW/masking alias: protobuf-elixir's 10-byte varint clause masks the value to 64
    # bits, so (1 <<< 64) ||| 0x12 decodes to field 2 / wire type 2 -- a delivery_frame -- in the generated
    # decoder. The scanner's take_varint does NOT mask (it accumulates bits 0..63+), so it reads a field
    # number well above @max_field_number (2^29-1) and rejects. Any bit the decoder masks off (>= bit 64)
    # forces the scanner's field >= 2^61, so this asymmetry is always fail-closed.
    overflow_tag = encode_varint(1 <<< 64 ||| 0x12)
    overflow_then_bloat = overflow_tag <> encode_varint(byte_size(bloat_frame)) <> bloat_frame
    assert {:error, :poison} = WireDecode.decode_client_message(overflow_then_bloat)
  end

  test "malformed frame envelope (unknown group) fails closed instead of silent acceptance (P1)" do
    # A frame carrying an unknown protobuf GROUP (field 6: start-group tag 0x33 / end-group tag 0x34)
    # around a small record. protobuf-elixir SILENTLY DROPS the group and returns {:ok, ...}, whereas Go
    # retains it as an unknown field and REJECTS the frame. The raw envelope check must distinguish a
    # :malformed peel from an absent record and poison it -- both when decoding a frame directly and when
    # the frame is wrapped in a client message -- restoring accept/reject parity with Go.
    group_frame = <<0x33, 0x34, 0x2A, 0x01, 0x00, 0x10, 0x01>>
    assert {:error, :poison} = WireDecode.decode_frame(group_frame)

    wrapped = <<0x12>> <> encode_varint(byte_size(group_frame)) <> group_frame
    assert byte_size(wrapped) < 528 * 1024
    assert {:error, :poison} = WireDecode.decode_client_message(wrapped)
  end

  test "group-bearing frame with a >16 KiB record is poison, not misclassified as oversize (P1)" do
    # An OPAQUE 20 KiB record_bytes payload plus a top-level group. record_bytes is `bytes`, never decoded
    # by the frame envelope, so its content is arbitrary here -- the point is the SIZE. The total frame is
    # ~20 KiB but the actual non-record overhead is only a few bytes. Because a malformed peel has NO known
    # record_len, the relational envelope budget must NOT run over it -- with record_len forced to 0 it would
    # count the whole 20 KiB payload as overhead and wrongly return :too_large (REJECTED_PERMANENT),
    # contradicting the frozen wire-poison -> ACCEPTED_QUARANTINE path. The frame stays under the hard
    # @max_frame_bytes total bound, so oversize does not legitimately fire. (The one-byte-record test above
    # never crosses the 16 KiB relational budget, so it misses this ordering bug.)
    opaque_payload = :binary.copy(<<0x00>>, 20 * 1024)
    record_field = <<0x2A>> <> encode_varint(byte_size(opaque_payload)) <> opaque_payload
    group = <<0x33, 0x34>>

    # group AFTER the record: peel_last_field accumulates {:ok, record}, then hits the group and returns
    # :malformed (the accumulated value discarded), exercising the size crossover directly.
    trailing_group = record_field <> group
    assert byte_size(trailing_group) > 16 * 1024
    assert byte_size(trailing_group) < 528 * 1024
    assert {:error, :poison} = WireDecode.decode_frame(trailing_group)

    wrapped = <<0x12>> <> encode_varint(byte_size(trailing_group)) <> trailing_group
    assert byte_size(wrapped) < 528 * 1024
    assert {:error, :poison} = WireDecode.decode_client_message(wrapped)

    # group BEFORE the record: malformed at the first token, same poison verdict.
    leading_group = group <> record_field
    assert {:error, :poison} = WireDecode.decode_frame(leading_group)
  end

  test "frame record field with an overflow/masking tag is poison, not silently absent (P1 parity)" do
    # A record field (field 5, wire type 2) whose tag uses the overflow/masking encoding (1 <<< 64) ||| 0x2A.
    # protobuf-elixir MASKS the tag to 64 bits and decodes it as a real field-5 record, while an UNBOUNDED
    # raw peel would read a ~2^61 field number, treat it as "not the record", and return :absent (record_len
    # 0) -> a silent {:ok}. Go rejects an out-of-range field number. peel_last_field must bound the field
    # number (like scan_client_message) so the frame is :poison at BOTH decode_frame and decode_client_message
    # (the client scanner only bounds the OUTER field 2, so the inner overflow tag reaches raw_frame_envelope_check).
    overflow_record_tag = encode_varint(1 <<< 64 ||| 0x2A)
    overflow_frame = overflow_record_tag <> encode_varint(1) <> <<0x00>>
    assert {:error, :poison} = WireDecode.decode_frame(overflow_frame)

    wrapped = <<0x12>> <> encode_varint(byte_size(overflow_frame)) <> overflow_frame
    assert {:error, :poison} = WireDecode.decode_client_message(wrapped)
  end

  test "sequence field with a 2^64+1 overflow varint is poison, not masked to 1 (P1)" do
    # sequence = field 2, wire type 0 (tag 0x10), encoded as 2^64 + 1: a 10-byte varint whose 10th byte
    # (shift 63) is chunk 0x02 (bit 64 set). take_varint must REJECT it -- only bit 63 is valid at the 10th
    # byte -- matching Go/protowire. Without the fix the generated decoder MASKS 2^64+1 to sequence: 1 and
    # accepts the frame while WireDecode consumed the field silently: an admit-vs-reject divergence.
    record = <<0x2A, 0x01, 0x00>>
    overflow_seq = <<0x10>> <> encode_varint((1 <<< 64) + 1)
    seq_overflow_frame = overflow_seq <> record
    assert {:error, :poison} = WireDecode.decode_frame(seq_overflow_frame)

    seq_wrapped = <<0x12>> <> encode_varint(byte_size(seq_overflow_frame)) <> seq_overflow_frame
    assert {:error, :poison} = WireDecode.decode_client_message(seq_wrapped)

    # POSITIVE boundary: the MAXIMUM valid uint64 (2^64 - 1) sequence has a 10th-byte chunk of 0x01 (only
    # bit 63) and is ACCEPTED, so a well-formed frame carrying it decodes rather than being spuriously
    # poisoned -- through BOTH entry points.
    max_uint64 = (1 <<< 64) - 1
    max_seq = <<0x10>> <> encode_varint(max_uint64)
    max_frame = max_seq <> record
    assert {:ok, %EdgeDeliveryFrameV1{sequence: ^max_uint64}} = WireDecode.decode_frame(max_frame)

    max_wrapped = <<0x12>> <> encode_varint(byte_size(max_frame)) <> max_frame

    assert {:ok, %EdgeRecordClientMessage{payload: {:delivery_frame, nested}}} =
             WireDecode.decode_client_message(max_wrapped)

    assert nested.sequence == max_uint64
  end

  test "tenth-byte varint boundary table: chunks 0/1 accepted, >1 and continuation rejected (P2)" do
    # Compact committed boundary table for the take_varint/3 shift-63 clause, which is a DISTINCT fallback
    # branch from the shift < 63 clauses. Only bit 63 fits in the 10th byte, so a terminal chunk of 0 or 1
    # is valid and anything larger sets bits >= 64 (uint64 overflow, rejected by Go/protowire). A 10th byte
    # carrying a CONTINUATION bit (an 11-byte varint) is rejected by both runtimes.
    record = <<0x2A, 0x01, 0x00>>
    nine_continuation_bytes = :binary.copy(<<0x80>>, 9)

    # {tenth byte, expected disposition, decoded sequence when accepted}
    table = [
      {<<0x00>>, :ok, 0},
      {<<0x01>>, :ok, 1 <<< 63},
      {<<0x02>>, :poison, nil},
      {<<0x7F>>, :poison, nil}
    ]

    for {tenth, expected, decoded} <- table do
      frame = <<0x10>> <> nine_continuation_bytes <> tenth <> record

      case expected do
        :ok ->
          assert {:ok, %EdgeDeliveryFrameV1{sequence: ^decoded}} = WireDecode.decode_frame(frame)

        :poison ->
          assert {:error, :poison} = WireDecode.decode_frame(frame)
      end

      wrapped = <<0x12>> <> encode_varint(byte_size(frame)) <> frame

      case expected do
        :ok ->
          assert {:ok, %EdgeRecordClientMessage{}} = WireDecode.decode_client_message(wrapped)

        :poison ->
          assert {:error, :poison} = WireDecode.decode_client_message(wrapped)
      end
    end

    # A CONTINUATION bit in the 10th byte (an 11-byte varint) is malformed, not merely over-large.
    eleven_byte = <<0x10>> <> nine_continuation_bytes <> <<0x81, 0x00>> <> record
    assert {:error, :poison} = WireDecode.decode_frame(eleven_byte)

    eleven_wrapped = <<0x12>> <> encode_varint(byte_size(eleven_byte)) <> eleven_byte
    assert {:error, :poison} = WireDecode.decode_client_message(eleven_wrapped)
  end

  test "field numbers past @max_field_number are rejected (bound + unknown-field rule)" do
    # The peel's field bound equals Go's MaxValidNumber (2^29 - 1) EXACTLY and is INCLUSIVE: a top-level
    # field number == 2^29-1 is in range (a frame carrying it plus a record is NOT poisoned), while one past
    # it (2^29) is out of range and poisons -- matching protowire (accepts 2^29-1, rejects 2^29). This
    # exercises the peel_last_field field bound with VALID uint64 tags (the (1<<64) overflow tags are now
    # rejected earlier by take_varint, so they no longer reach the field-range comparison).
    record = <<0x2A, 0x01, 0x00>>
    max_field = (1 <<< 29) - 1

    # An in-range but UNDECLARED field is now rejected as a retained UNKNOWN FIELD (the frozen edge
    # ABI rejects those recursively), so against an edge schema BOTH cases poison and this test can
    # no longer isolate the bound here. The inclusive-boundary proof lives in
    # Serviceradar.Edge.WireValidateTest against a schema that DECLARES field 2^29-1.
    in_range_frame = encode_varint(max_field <<< 3) <> <<0x00>> <> record
    assert {:error, :poison} = WireDecode.decode_frame(in_range_frame)

    # out-of-range field (2^29, wire type 0) -> :poison.
    over_frame = encode_varint((max_field + 1) <<< 3) <> <<0x00>> <> record
    assert {:error, :poison} = WireDecode.decode_frame(over_frame)
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

  test "publication-identity headers (grammars 6-8) match the Go vectors byte-for-byte" do
    record = EdgeRecordV1.decode(load("record.bin"))
    record_sha = :crypto.hash(:sha256, load("record.bin"))
    sed = record.semantic_envelope_sha256

    # The authenticated principal is the record's OWN producer_context.origin_principal_id
    # (decision 5): an ASCII component-id ([A-Za-z0-9_-], 1..128) and the only origin input.
    # There is NO lane_id (spool_id is the persistent per-lane UUIDv7).
    agent = record.producer_context.origin_principal_id
    assert agent == "agent-0"
    assert PublicationIdentity.valid_authenticated_principal?(agent)

    slot = %{
      network_scope_id: record.network_scope_id,
      authenticated_agent_id: agent,
      spool_id: uuidv7(0x01),
      sequence: 1
    }

    assert {:ok, msg_id} = PublicationIdentity.nats_msg_id(slot, sed, record_sha)
    assert msg_id == load("nats_msg_id.txt")
    assert {:ok, del_id} = PublicationIdentity.delivery_id(slot)
    assert del_id == load("delivery_id.txt")
    # Raw grammar preimages (framed transcript, pre-SHA-256): prove the framed bytes, not
    # merely the resulting digest.
    assert {:ok, msg_pre} = PublicationIdentity.nats_msg_id_preimage(slot, sed, record_sha)
    assert msg_pre == load("nats_msg_id_preimage.bin")
    assert {:ok, del_pre} = PublicationIdentity.delivery_id_preimage(slot)
    assert del_pre == load("delivery_id_preimage.bin")

    # RENEWAL proof: the Elixir gateway STRUCTURALLY validates the delivery capability + its
    # transition (never hashes an arbitrary binary) before hashing its signing bytes.
    renewal_cap = EdgeSignedCapabilityV1.decode(load("delivery_renewal_cap.bin"))
    assert {:delivery, %{transition: {:renewal, _}}} = renewal_cap.claims
    assert {:ok, renewal_proof} = PublicationIdentity.delivery_proof_digest(renewal_cap, 2)
    # A ROLLOVER capability under RENEWAL mode is rejected (transition mismatch).
    rollover_cap = EdgeDeliveryFrameV1.decode(load("delivery_frame.bin")).delivery_capability
    assert {:delivery, %{transition: {:rollover, _}}} = rollover_cap.claims
    assert {:error, :transition} = PublicationIdentity.delivery_proof_digest(rollover_cap, 2)

    renewal_in = %{
      edge: slot,
      record_sha256: record_sha,
      delivery_mode: 2,
      delivery_proof: renewal_proof,
      route_map_version: 7
    }

    assert {:ok, prov} = PublicationIdentity.transport_provenance(renewal_in)
    assert prov == load("transport_provenance.txt")
    assert {:ok, prov_pre} = PublicationIdentity.transport_provenance_preimage(renewal_in)
    assert prov_pre == load("transport_provenance_preimage.bin")

    # FRESH: no delivery proof.
    assert {:ok, fresh} =
             PublicationIdentity.transport_provenance(%{
               edge: slot,
               record_sha256: record_sha,
               delivery_mode: 1,
               delivery_proof: nil,
               route_map_version: 7
             })

    assert fresh == load("transport_provenance_fresh.txt")

    # ROLLOVER + LATE_FENCED_DELIVERY over the rollover grant; late-fenced ALSO accepts a renewal.
    assert {:ok, rollover_proof} = PublicationIdentity.delivery_proof_digest(rollover_cap, 3)
    assert {:ok, late_proof} = PublicationIdentity.delivery_proof_digest(rollover_cap, 4)
    assert {:ok, _} = PublicationIdentity.delivery_proof_digest(renewal_cap, 4)

    assert {:ok, prov_ro} =
             PublicationIdentity.transport_provenance(%{
               edge: slot,
               record_sha256: record_sha,
               delivery_mode: 3,
               delivery_proof: rollover_proof,
               route_map_version: 7
             })

    assert prov_ro == load("transport_provenance_rollover.txt")

    assert {:ok, prov_late} =
             PublicationIdentity.transport_provenance(%{
               edge: slot,
               record_sha256: record_sha,
               delivery_mode: 4,
               delivery_proof: late_proof,
               route_map_version: 7
             })

    assert prov_late == load("transport_provenance_late.txt")

    # Values above 2^32 round-trip losslessly (u64, never truncated to 32 bits).
    big_slot = %{slot | sequence: 0x1_0000_0000_0007}

    assert {:ok, prov_big} =
             PublicationIdentity.transport_provenance(%{
               edge: big_slot,
               record_sha256: record_sha,
               delivery_mode: 1,
               route_map_version: 0x1_0000_0000_0003
             })

    assert prov_big == load("transport_provenance_bigvals.txt")

    # Service-ingress variants generated from an ACTUAL CLUSTER_SERVICE record (its own
    # origin_kind, principal, semantic digest and hash), NOT the agent record.
    svc_record = EdgeRecordV1.decode(load("service_record.bin"))
    svc_record_sha = :crypto.hash(:sha256, load("service_record.bin"))
    svc_sed = svc_record.semantic_envelope_sha256
    svc_id = svc_record.producer_context.origin_principal_id
    assert svc_id == "svc-0"
    assert svc_record.producer_context.origin_kind == :EDGE_ORIGIN_KIND_CLUSTER_SERVICE

    svc = %{
      network_scope_id: svc_record.network_scope_id,
      authenticated_service_id: svc_id,
      publication_lane_id: uuidv7(0xB1),
      publication_sequence: 5
    }

    assert {:ok, svc_msg} = PublicationIdentity.service_nats_msg_id(svc, svc_sed, svc_record_sha)
    assert svc_msg == load("service_nats_msg_id.txt")
    assert {:ok, svc_del} = PublicationIdentity.service_delivery_id(svc)
    assert svc_del == load("service_delivery_id.txt")

    assert {:ok, svc_msg_pre} =
             PublicationIdentity.service_nats_msg_id_preimage(svc, svc_sed, svc_record_sha)

    assert svc_msg_pre == load("service_nats_msg_id_preimage.bin")
    assert {:ok, svc_del_pre} = PublicationIdentity.service_delivery_id_preimage(svc)
    assert svc_del_pre == load("service_delivery_id_preimage.bin")

    svc_in = %{
      service: svc,
      record_sha256: svc_record_sha,
      delivery_mode: 1,
      delivery_proof: nil,
      route_map_version: 7
    }

    assert {:ok, prov_svc} = PublicationIdentity.transport_provenance(svc_in)
    assert prov_svc == load("service_transport_provenance.txt")
    assert {:ok, prov_svc_pre} = PublicationIdentity.transport_provenance_preimage(svc_in)
    assert prov_svc_pre == load("service_transport_provenance_preimage.bin")

    # Fail-closed structural guards mirroring the Go matrix.
    assert {:error, :slot_arity} =
             PublicationIdentity.transport_provenance(%{
               edge: slot,
               service: svc,
               record_sha256: record_sha,
               delivery_mode: 1,
               route_map_version: 7
             })

    assert {:error, :delivery_mode} =
             PublicationIdentity.transport_provenance(%{
               edge: slot,
               record_sha256: record_sha,
               delivery_mode: 0,
               route_map_version: 7
             })

    assert {:error, :route_map} =
             PublicationIdentity.transport_provenance(%{
               edge: slot,
               record_sha256: record_sha,
               delivery_mode: 1,
               route_map_version: 0
             })

    assert {:error, :proof} =
             PublicationIdentity.transport_provenance(%{
               edge: slot,
               record_sha256: record_sha,
               delivery_mode: 1,
               delivery_proof: renewal_proof,
               route_map_version: 7
             })

    assert {:error, :proof} =
             PublicationIdentity.transport_provenance(%{
               edge: slot,
               record_sha256: record_sha,
               delivery_mode: 2,
               route_map_version: 7
             })

    assert {:error, :service_not_fresh} =
             PublicationIdentity.transport_provenance(%{
               service: svc,
               record_sha256: record_sha,
               delivery_mode: 2,
               delivery_proof: renewal_proof,
               route_map_version: 7
             })

    # Encoder INPUT validation: zero sequence, invalid principal, non-16-byte UUID, bad digest.
    assert {:error, :sequence} =
             PublicationIdentity.nats_msg_id(%{slot | sequence: 0}, sed, record_sha)

    assert {:error, :principal} =
             PublicationIdentity.delivery_id(%{slot | authenticated_agent_id: "bad id!"})

    assert {:error, :spool_id} = PublicationIdentity.delivery_id(%{slot | spool_id: "short"})
    # UUID SEMANTICS, not just shape: a 16-byte but non-v7 spool and a non-16-byte scope fail.
    assert {:error, :spool_id} =
             PublicationIdentity.delivery_id(%{slot | spool_id: non_v7_uuid()})

    assert {:error, :network_scope} =
             PublicationIdentity.delivery_id(%{
               slot
               | network_scope_id: :binary.copy(<<0x5A>>, 20)
             })

    assert {:error, :digest_len} =
             PublicationIdentity.nats_msg_id(slot, binary_part(sed, 0, 16), record_sha)

    refute PublicationIdentity.valid_authenticated_principal?("has space")
  end

  test "delivery-proof validation rejects unknown fields, nil transition members, and malformed claims" do
    cap = EdgeSignedCapabilityV1.decode(load("delivery_renewal_cap.bin"))
    assert {:ok, _} = PublicationIdentity.delivery_proof_digest(cap, 2)
    {:delivery, claims} = cap.claims

    # Unsigned unknown field on the capability (outside the field-framed signature) is rejected.
    assert {:error, :unknown_fields} =
             PublicationIdentity.delivery_proof_digest(
               %{cap | __unknown_fields__: [{99, 2, "x"}]},
               2
             )

    # Unknown field on a NESTED message (the delivery claims) is rejected RECURSIVELY.
    nested = %{cap | claims: {:delivery, %{claims | __unknown_fields__: [{88, 0, <<1>>}]}}}
    assert {:error, :unknown_fields} = PublicationIdentity.delivery_proof_digest(nested, 2)

    # A NIL transition member is rejected WITHOUT crashing the field-framing.
    nil_member = %{cap | claims: {:delivery, %{claims | transition: {:renewal, nil}}}}
    assert {:error, :transition} = PublicationIdentity.delivery_proof_digest(nil_member, 2)

    # A malformed nested claim (non-UUIDv7 event_id) is rejected before hashing.
    bad_claims = %{cap | claims: {:delivery, %{claims | event_id: <<0, 1, 2>>}}}
    assert {:error, :claims} = PublicationIdentity.delivery_proof_digest(bad_claims, 2)

    # Malformed transition MEMBER (mirrors Go): a mis-ordered renewal window (not_before=9,
    # expires=2), and a rollover with a non-UUID prior_spool_id + prior_sequence=0. Reuses the
    # COMPLETE delivery-claim validator, not merely a base-field check.
    {:renewal, renewal_member} = claims.transition

    bad_window = %{
      cap
      | claims:
          {:delivery,
           %{
             claims
             | transition:
                 {:renewal,
                  %{
                    renewal_member
                    | renewed_not_before_unix_nano: 9,
                      renewed_expires_unix_nano: 2
                  }}
           }}
    }

    assert {:error, :claims} = PublicationIdentity.delivery_proof_digest(bad_window, 2)

    rollover_cap = EdgeDeliveryFrameV1.decode(load("delivery_frame.bin")).delivery_capability
    {:delivery, ro_claims} = rollover_cap.claims
    {:rollover, ro_member} = ro_claims.transition

    bad_rollover = %{
      rollover_cap
      | claims:
          {:delivery,
           %{
             ro_claims
             | transition:
                 {:rollover, %{ro_member | prior_spool_id: "not-a-uuid", prior_sequence: 0}}
           }}
    }

    assert {:error, :claims} = PublicationIdentity.delivery_proof_digest(bad_rollover, 3)

    # A SAME-SPOOL rollover (prior_spool_id == spool_id) is invalid -- a rollover moves to a NEW spool.
    same_spool = %{
      rollover_cap
      | claims:
          {:delivery,
           %{
             ro_claims
             | transition: {:rollover, %{ro_member | prior_spool_id: ro_claims.spool_id}}
           }}
    }

    assert {:error, :claims} = PublicationIdentity.delivery_proof_digest(same_spool, 3)

    # P2: poison input returns {:error}, never raises.
    assert {:error, :capability} = PublicationIdentity.delivery_proof_digest(%{foo: 1}, 2)
    assert {:error, :capability} = PublicationIdentity.delivery_proof_digest(:not_a_cap, 2)
  end

  test "external publication-identity APIs return {:error} on poison input instead of raising" do
    # extract_header_set: wrong top-level type + a list with a non-tuple entry.
    assert {:error, :headers} = PublicationIdentity.extract_header_set("nope")
    assert {:error, :headers} = PublicationIdentity.extract_header_set([:bad_entry])
    assert {:error, :missing_header} = PublicationIdentity.extract_header_set(%{})
    # A non-binary header NAME (would raise on downcase) and a non-binary VALUE are rejected.
    assert {:error, :headers} = PublicationIdentity.extract_header_set(%{{:tuple, :key} => "v"})
    assert {:error, :headers} = PublicationIdentity.extract_header_set(%{"Nats-Msg-Id" => 123})

    # validate_header_set: non-map inputs + a header_set/ctx missing required keys.
    assert {:error, :input} = PublicationIdentity.validate_header_set(:nope, %{})
    assert {:error, :input} = PublicationIdentity.validate_header_set(%{}, :nope)
    assert match?({:error, _}, PublicationIdentity.validate_header_set(%{}, %{}))
  end

  test "u64 range guard rejects out-of-range sequence / route-map (no silent mod-2^64 alias)" do
    record = EdgeRecordV1.decode(load("record.bin"))
    record_sha = :crypto.hash(:sha256, load("record.bin"))

    base = %{
      network_scope_id: record.network_scope_id,
      authenticated_agent_id: record.producer_context.origin_principal_id,
      spool_id: uuidv7(0x01),
      sequence: 1
    }

    # 2^64 and -1 would alias to 0 / 2^64-1 under a raw <<v::big-64>>; both must fail closed.
    assert {:error, :sequence} =
             PublicationIdentity.delivery_id(%{base | sequence: 0x1_0000_0000_0000_0000})

    assert {:error, :sequence} = PublicationIdentity.delivery_id(%{base | sequence: -1})

    assert {:error, :route_map} =
             PublicationIdentity.transport_provenance(%{
               edge: base,
               record_sha256: record_sha,
               delivery_mode: 1,
               route_map_version: 0x1_0000_0000_0000_0000
             })

    # u64 max is in range and encodes.
    assert {:ok, _} = PublicationIdentity.delivery_id(%{base | sequence: 0xFFFF_FFFF_FFFF_FFFF})
  end

  test "strict transport-provenance decoder round-trips and cross-checks the trust context" do
    record = EdgeRecordV1.decode(load("record.bin"))
    record_sha = :crypto.hash(:sha256, load("record.bin"))
    sed = record.semantic_envelope_sha256
    agent = record.producer_context.origin_principal_id

    slot = %{
      network_scope_id: record.network_scope_id,
      authenticated_agent_id: agent,
      spool_id: uuidv7(0x01),
      sequence: 1
    }

    renewal_cap = EdgeSignedCapabilityV1.decode(load("delivery_renewal_cap.bin"))
    assert {:ok, renewal_proof} = PublicationIdentity.delivery_proof_digest(renewal_cap, 2)
    header = load("transport_provenance.txt")

    assert {:ok, dp} = PublicationIdentity.decode_transport_provenance(header)
    assert dp.kind == :edge
    assert dp.slot.authenticated_agent_id == agent
    assert dp.slot.sequence == 1
    assert dp.delivery_mode == 2
    assert dp.delivery_proof == renewal_proof
    assert dp.record_sha256 == record_sha
    assert dp.route_map_version == 7

    # Bidirectional round-trip: decode -> re-encode == original bytes.
    assert {:ok, ^header} =
             PublicationIdentity.transport_provenance(%{
               edge: dp.slot,
               record_sha256: dp.record_sha256,
               delivery_mode: dp.delivery_mode,
               delivery_proof: dp.delivery_proof,
               route_map_version: dp.route_map_version
             })

    # Big values decode without 32-bit truncation.
    assert {:ok, big} =
             PublicationIdentity.decode_transport_provenance(
               load("transport_provenance_bigvals.txt")
             )

    assert big.slot.sequence == 0x1_0000_0000_0007
    assert big.route_map_version == 0x1_0000_0000_0003

    # Header-set trust binding: recompute + cross-check the whole set against the record- and
    # credential-derived context (scope, origin kind, publisher class, principal).
    assert {:ok, msg} = PublicationIdentity.nats_msg_id(slot, sed, record_sha)
    assert {:ok, del} = PublicationIdentity.delivery_id(slot)
    hs = %{nats_msg_id: msg, delivery_id: del, provenance: header}

    # EDGE trust: the gateway credential identity DIFFERS from the originating agent BY DESIGN, so
    # trusted_publisher_principal is a gateway id (NOT agent) and edge validation MUST still pass.
    ctx = %{
      record_network_scope_id: record.network_scope_id,
      record_origin_kind: :EDGE_ORIGIN_KIND_AGENT,
      record_principal: agent,
      expected_publisher_class: :edge,
      trusted_publisher_principal: "gateway-edge-1",
      semantic_envelope_sha256: sed,
      record_sha256: record_sha
    }

    assert :ok == PublicationIdentity.validate_header_set(hs, ctx)

    assert {:error, :nats_msg_id} =
             PublicationIdentity.validate_header_set(%{hs | nats_msg_id: "tampered"}, ctx)

    assert {:error, :record_hash} =
             PublicationIdentity.validate_header_set(hs, %{ctx | record_sha256: digest32(0xEE)})

    assert {:error, :network_scope} =
             PublicationIdentity.validate_header_set(hs, %{
               ctx
               | record_network_scope_id: uuidv7(0x99)
             })

    assert {:error, :publisher_class} =
             PublicationIdentity.validate_header_set(hs, %{
               ctx
               | expected_publisher_class: :service
             })

    assert {:error, :slot_kind} =
             PublicationIdentity.validate_header_set(hs, %{
               ctx
               | record_origin_kind: :EDGE_ORIGIN_KIND_CLUSTER_SERVICE,
                 expected_publisher_class: :service
             })

    assert {:error, :principal} =
             PublicationIdentity.validate_header_set(hs, %{ctx | record_principal: "other-agent"})

    # NOTE: no edge :publisher_principal case -- edge deliberately ignores trusted_publisher_principal
    # (the gateway credential is not the agent). The credential binding is asserted service-only below.

    assert {:error, :origin_kind} =
             PublicationIdentity.validate_header_set(hs, %{
               ctx
               | record_origin_kind: :EDGE_ORIGIN_KIND_UNSPECIFIED,
                 expected_publisher_class: nil
             })

    # Service header set validated against the ACTUAL service record + its credential identity.
    svc_record = EdgeRecordV1.decode(load("service_record.bin"))
    svc_record_sha = :crypto.hash(:sha256, load("service_record.bin"))
    svc_sed = svc_record.semantic_envelope_sha256
    svc_id = svc_record.producer_context.origin_principal_id

    svc = %{
      network_scope_id: svc_record.network_scope_id,
      authenticated_service_id: svc_id,
      publication_lane_id: uuidv7(0xB1),
      publication_sequence: 5
    }

    assert {:ok, svc_prov} =
             PublicationIdentity.transport_provenance(%{
               service: svc,
               record_sha256: svc_record_sha,
               delivery_mode: 1,
               route_map_version: 7
             })

    assert {:ok, svc_msg} = PublicationIdentity.service_nats_msg_id(svc, svc_sed, svc_record_sha)
    assert {:ok, svc_del} = PublicationIdentity.service_delivery_id(svc)
    svc_hs = %{nats_msg_id: svc_msg, delivery_id: svc_del, provenance: svc_prov}

    svc_ctx = %{
      record_network_scope_id: svc_record.network_scope_id,
      record_origin_kind: :EDGE_ORIGIN_KIND_CLUSTER_SERVICE,
      record_principal: svc_id,
      expected_publisher_class: :service,
      trusted_publisher_principal: svc_id,
      semantic_envelope_sha256: svc_sed,
      record_sha256: svc_record_sha
    }

    assert :ok == PublicationIdentity.validate_header_set(svc_hs, svc_ctx)

    # SERVICE-ONLY credential binding: a credential-derived service identity that disagrees with
    # the record/provenance principal MUST fail (the governed service IS the publisher).
    assert {:error, :publisher_principal} =
             PublicationIdentity.validate_header_set(svc_hs, %{
               svc_ctx
               | trusted_publisher_principal: "other-svc"
             })

    # Service headers under the edge (agent) context must fail (class/kind + scope/principal).
    assert {:error, _} = PublicationIdentity.validate_header_set(svc_hs, ctx)

    # Raw multimap boundary: duplicate / case-variant / missing rejected; case-insensitive OK.
    assert {:ok, extracted} =
             PublicationIdentity.extract_header_set(%{
               "Nats-Msg-Id" => msg,
               "Sr-Edge-Delivery-Id" => del,
               "Sr-Edge-Transport-Provenance" => header
             })

    assert extracted.provenance == header

    assert {:error, :duplicate_header} =
             PublicationIdentity.extract_header_set(%{
               "Nats-Msg-Id" => [msg, msg],
               "Sr-Edge-Delivery-Id" => del,
               "Sr-Edge-Transport-Provenance" => header
             })

    assert {:error, :duplicate_header} =
             PublicationIdentity.extract_header_set([
               {"Nats-Msg-Id", msg},
               {"nats-msg-id", msg},
               {"Sr-Edge-Delivery-Id", del},
               {"Sr-Edge-Transport-Provenance", header}
             ])

    assert {:error, :missing_header} =
             PublicationIdentity.extract_header_set(%{
               "Nats-Msg-Id" => msg,
               "Sr-Edge-Delivery-Id" => del
             })

    assert {:ok, _} =
             PublicationIdentity.extract_header_set(%{
               "nats-msg-id" => msg,
               "sr-edge-delivery-id" => del,
               "sr-edge-transport-provenance" => header
             })
  end

  test "strict transport-provenance decoder rejects the shared Go malformed vectors" do
    expected_labels =
      ~w(cr-lf trailing-byte truncated empty bad-base64-char non-canonical-base64-alias
         unknown-version unknown-slot-kind unknown-mode invalid-presence zero-route-map
         bad-digest-length length-prefix-overflow service-non-fresh oversized)

    parsed =
      "pubid_reject_vectors.txt"
      |> load()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        [label, b64] = String.split(line, "\t", parts: 2)
        {label, Base.decode64!(b64)}
      end)

    # The fixture must carry the WHOLE frozen battery in order -- neither peer may silently drop
    # coverage (the label list is the shared contract, base64-wrapped so CR/LF + empty survive).
    assert Enum.map(parsed, &elem(&1, 0)) == expected_labels

    for {label, header} <- parsed do
      assert match?({:error, _}, PublicationIdentity.decode_transport_provenance(header)),
             "malformed vector #{label} must be rejected by the Elixir decoder"
    end
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

    # The three classification bodies, and BOTH source framings. Source presence is
    # part of the span identity, so a source-present and a source-absent span must not
    # collide -- and the 1-byte presence MARKER is only pinnable cross-language, since
    # within one runtime the members alone already differ. This vector is that pin: if
    # Go emits the marker and Elixir does not (or vice versa), the digest assertion
    # above fails.
    assert [active, passive, unattributable] = page.classification_spans

    # NOTE: this vector pairs ACTIVE with source-present and PASSIVE with
    # source-absent purely so ONE page exercises BOTH source framings. That pairing is
    # a property of THIS FIXTURE, not of the contract: attribution classification and
    # source presence are INDEPENDENT axes, and all four combinations are legal.
    assert {:attributed_active, a} = active.classification
    assert a.identity.run_shard == 3
    assert a.identity.source != nil, "this fixture's ACTIVE span carries a source identity"
    assert a.identity.source.kind == :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP
    # range_sha256 IS required on ACTIVE -- that one is contractual.
    assert byte_size(a.range_sha256) == 32

    assert {:attributed_passive, pv} = passive.classification
    assert pv.identity.source == nil, "this fixture's PASSIVE span carries no source identity"

    assert {:unattributable, u} = unattributable.classification
    assert u.reason == :EDGE_UNATTRIBUTABLE_REASON_BINDING_CORRUPT

    # Gaps are LEGAL and mean NOT LOST: 21 sits between the active and passive spans,
    # and 23-29 before the unattributable one.
    assert active.through_sequence == 20 and passive.from_sequence == 22
    assert passive.through_sequence == 22 and unattributable.from_sequence == 30

    # The tombstone carries NO loss interval after 1.6a; the manifest root is the loss
    # commitment. A regenerated binding that still had the field would fail here.
    refute Map.has_key?(tomb, :lost_from_sequence)
    refute Map.has_key?(tomb, :coarsened)

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
