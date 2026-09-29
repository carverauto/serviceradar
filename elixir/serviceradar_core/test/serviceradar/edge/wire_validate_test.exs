defmodule PackedVarintFixture do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:vals, 1, repeated: true, type: :int32, packed: true)
end

defmodule PackedFixed32Fixture do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:vals, 1, repeated: true, type: :fixed32, packed: true)
end

defmodule PackedFixed64Fixture do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:vals, 1, repeated: true, type: :double, packed: true)
end

# SINGULAR scalars. A length-delimited payload on these is a wire-type MISMATCH, which Go's
# proto.Unmarshal ACCEPTS and RETAINS as an unknown field (ServiceRadar's Go validator is what
# rejects it) -- so the walker must NOT treat it as a packed payload and apply the packed rules.
defmodule SingularVarintFixture do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:val, 1, type: :int32)
end

defmodule SingularFixed64Fixture do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:val, 1, type: :fixed64)
end

# Declares the INCLUSIVE maximum field number (2^29-1), so the field-number BOUND can be proven
# independently of the unknown-field rule (an in-range but undeclared field is now rejected as an
# unknown field, which would otherwise mask the bound).
defmodule MaxFieldNumberFixture do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:v, 536_870_911, type: :int32)
end

# Self-referential message, used to pin the recursion boundary against Go's counting.
defmodule RecursiveFixture do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:next, 1, type: RecursiveFixture)
end

# Schema metadata that THROWS / EXITS: `rescue` alone does not catch either.
defmodule ThrowingPropsFixture do
  @moduledoc false
  def __message_props__, do: throw(:boom)
end

defmodule ExitingPropsFixture do
  @moduledoc false
  def __message_props__, do: exit(:boom)
end

defmodule Serviceradar.Edge.WireValidateTest do
  @moduledoc """
  Task 1.5: the RECURSIVE STRUCTURAL wire-hygiene parity gate. `WireDecode`'s scanner closes groups,
  out-of-range field numbers, and 10-byte uint64-overflow varints at the frame TOP level only; these
  prove the same inputs are closed at EVERY message depth (nested capabilities), that packed
  repeated scalars are not opaque, that codegen/metadata failures are `:systemic`/`:not_ready` and
  NEVER the destructive `:poison`, and that none of it OVER-rejects traffic Go accepts.

  The walker makes NO value-level judgement: protobuf's effective-value semantics (last-one-wins,
  oneof resolution, embedded-message merging) cannot be reproduced in a raw walk, so enum/version/
  range verdicts belong to the semantic validator running on the DECODED struct.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias Serviceradar.Edge.V1.EdgeDeliveryFrameV1
  alias Serviceradar.Edge.V1.EdgeRecordClientMessage
  alias Serviceradar.Edge.V1.EdgeRecordLaneOpen
  alias Serviceradar.Edge.V1.EdgeRecordTrafficClass
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.Edge.WireValidate

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)

  defp load(name), do: File.read!(Path.join(@testdata, name))
  defp varint(n) when n < 0x80, do: <<n>>
  defp varint(n), do: <<(n &&& 0x7F) ||| 0x80>> <> varint(n >>> 7)
  defp len_delim(tag, payload), do: <<tag>> <> varint(byte_size(payload)) <> payload

  # EdgeDeliveryFrameV1: delivery_capability = 4 (embedded), record_bytes = 5 (bytes).
  # EdgeSignedCapabilityV1: not_before_unix_nano = 5 (int64, wire 0).
  # EdgeRecordClientMessage: lane_open = 1, delivery_frame = 2.
  # EdgeRecordLaneOpen: traffic_class = 2 (enum, wire 0).
  defp frame_with_capability(cap_payload) do
    len_delim(0x22, cap_payload) <> <<0x2A, 0x01, 0x00>>
  end

  defp wrap_client_frame(frame), do: len_delim(0x12, frame)
  defp wrap_client_lane_open(lane_open), do: len_delim(0x0A, lane_open)

  describe "recursive wire hygiene at nested message depth (Go parity)" do
    test "the Round-6 caveat: an overflow varint inside delivery_capability is poison" do
      # The exact vector the Round-6 verifier confirmed as a decode_frame-reachable admit-vs-reject
      # divergence: cap.not_before_unix_nano = 2^64 + 1. protobuf-elixir MASKS the 10-byte varint to
      # its low 64 bits (yielding not_before = 1) and returns {:ok, ...}; Go's proto.Unmarshal
      # REJECTS it as varint overflow. The top-level scanner never saw it because the peel treats
      # field 4 as opaque length-delimited bytes.
      frame = Base.decode16!("220B28818080808080808080022A0100")
      assert {:error, :poison} = WireDecode.decode_frame(frame)
      assert {:error, :poison} = WireDecode.decode_client_message(wrap_client_frame(frame))

      # Same shape built from parts, to pin the intent rather than only the literal bytes.
      built = frame_with_capability(<<0x28>> <> varint((1 <<< 64) + 1))
      assert {:error, :poison} = WireDecode.decode_frame(built)
    end

    test "a GROUP nested inside delivery_capability is poison" do
      # protobuf-elixir silently DISCARDS an unknown group; Go retains it as an unknown field and
      # rejects the message. Field 6 start-group (0x33) / end-group (0x34) inside the capability.
      nested_group = frame_with_capability(<<0x33, 0x34, 0x28, 0x01>>)
      assert {:error, :poison} = WireDecode.decode_frame(nested_group)
      assert {:error, :poison} = WireDecode.decode_client_message(wrap_client_frame(nested_group))
    end

    test "an out-of-range field number nested inside delivery_capability is poison" do
      # Field 2^29 exceeds Go's MaxValidNumber (2^29 - 1, inclusive); protobuf-elixir leniently
      # accepts it as a retained unknown field.
      over = varint(1 <<< 29 <<< 3) <> <<0x00>>
      assert {:error, :poison} = WireDecode.decode_frame(frame_with_capability(over))

      # The inclusive boundary itself (2^29 - 1) is IN range: against a schema that DECLARES that
      # field it is accepted, while 2^29 is out of range and rejected. (Against the edge schemas an
      # in-range but undeclared field is now rejected as an UNKNOWN FIELD, so the bound has to be
      # proven on a schema that actually declares it.)
      max_tag = varint(WireValidate.max_field_number() <<< 3) <> <<0x01>>
      assert :ok = WireValidate.validate(max_tag, MaxFieldNumberFixture)

      over_tag = varint(1 <<< 29 <<< 3) <> <<0x01>>
      assert {:error, :poison} = WireValidate.validate(over_tag, MaxFieldNumberFixture)
    end

    test "a truncated nested capability payload is poison" do
      # A capability whose last field claims more bytes than remain.
      assert {:error, :poison} =
               WireDecode.decode_frame(frame_with_capability(<<0x2A, 0x10, 0x00>>))
    end
  end

  describe "the walker makes NO value-level judgement (protobuf effective-value semantics)" do
    test "LAST-ONE-WINS: a negative enum overridden by a valid one must NOT be rejected structurally" do
      # THE decisive reason enum verdicts cannot live in a raw walker: protobuf resolves a repeated
      # occurrence of a singular field last-one-wins, so `traffic_class = -1` FOLLOWED BY
      # `traffic_class = BULK` has the effective value BULK -- which Go decodes and ACCEPTS. A
      # first-occurrence verdict would reject a message Go accepts. Structurally these bytes are
      # clean, so the walker must return :ok.
      bulk = EdgeRecordTrafficClass.value(:EDGE_RECORD_TRAFFIC_CLASS_BULK)
      lane_open = <<0x10>> <> varint((1 <<< 64) - 1) <> <<0x10, bulk>>

      assert :ok = WireValidate.validate(lane_open, EdgeRecordLaneOpen)

      # END TO END the effective value is BULK, exactly as Go decodes it. This previously RAISED:
      # protobuf-elixir's decoder walks fields IN ORDER, reached traffic_class = -1, called the
      # generated `key/1` (guarded `tag >= 0`) and blew up before ever seeing the later BULK -- so
      # Elixir REJECTED a message Go ACCEPTS. The generated edge enums now retain negative integers
      # (scripts/patch_edge_enum_negatives.exs), which is what makes last-one-wins resolve correctly.
      assert {:ok, %EdgeRecordClientMessage{payload: {:lane_open, open}}} =
               WireDecode.decode_client_message(wrap_client_lane_open(lane_open))

      assert open.traffic_class == :EDGE_RECORD_TRAFFIC_CLASS_BULK
    end

    test "an UNKNOWN but NON-NEGATIVE enum decodes, exactly as in Go" do
      # Go retains 99 and rejects it in the SEMANTIC validator; protobuf-elixir's key/1 catchall also
      # returns 99. Both runtimes DECODE; the semantic layer owns the unknown-value verdict.
      assert {:ok, %EdgeRecordClientMessage{}} =
               WireDecode.decode_client_message(wrap_client_lane_open(<<0x10, 99>>))
    end

    test "a lone negative enum is structurally clean here (its verdict is the semantic layer's)" do
      # -1 encodes as the 10-byte varint 0xFF*9 0x01 -- terminal chunk 1, a VALID uint64 varint, NOT
      # an overflow. The walker therefore passes it, and the patched generated enums now DECODE it
      # with the integer retained; the verdict belongs to `SemanticValidate`, which rejects the
      # retained non-member (see Serviceradar.Edge.SemanticValidateTest). A terminal chunk of 2 IS an
      # overflow and stays `:poison` structurally. The two rules are distinct and must not collapse.
      negative_one = <<0x10>> <> varint((1 <<< 64) - 1)
      assert :ok = WireValidate.validate(negative_one, EdgeRecordLaneOpen)

      overflow = <<0x10>> <> varint((1 <<< 64) + 1)

      assert {:error, :poison} =
               WireValidate.validate(overflow, EdgeRecordLaneOpen)

      assert {:error, :poison} =
               WireDecode.decode_client_message(wrap_client_lane_open(overflow))
    end
  end

  # The edge schema has NO packed repeated scalar field today (every repeated field is a message or
  # `repeated bytes`), so the packed rules are future-proofing: the moment one is added, a packed
  # element carrying 2^64+N would MASK in Elixir while Go rejects it. These synthetic schemas pin the
  # rules now rather than leaving the gap to be discovered later.
  describe "packed repeated scalar payloads are not opaque" do
    test "a packed varint element that overflows uint64 is poison" do
      clean = varint(1) <> varint(2) <> varint((1 <<< 64) - 1)
      assert :ok = WireValidate.validate(len_delim(0x0A, clean), PackedVarintFixture)

      overflowing = varint(1) <> varint((1 <<< 64) + 1)

      assert {:error, :poison} =
               WireValidate.validate(len_delim(0x0A, overflowing), PackedVarintFixture)
    end

    test "a truncated packed varint element is poison" do
      # A final element whose continuation bit is set but has no successor byte.
      assert {:error, :poison} =
               WireValidate.validate(len_delim(0x0A, <<0x01, 0x80>>), PackedVarintFixture)
    end

    test "a packed fixed-width payload must exactly fill its elements" do
      assert :ok = WireValidate.validate(len_delim(0x0A, <<0::32, 1::32>>), PackedFixed32Fixture)

      assert {:error, :poison} =
               WireValidate.validate(len_delim(0x0A, <<0::32, 1, 2>>), PackedFixed32Fixture)

      # fixed64 (8-byte elements) is a distinct branch from fixed32.
      assert :ok = WireValidate.validate(len_delim(0x0A, <<0::64, 1::64>>), PackedFixed64Fixture)

      assert {:error, :poison} =
               WireValidate.validate(len_delim(0x0A, <<0::64, 1::32>>), PackedFixed64Fixture)
    end

    test "NEGATIVE CONTROL: a SINGULAR scalar arriving length-delimited is NOT treated as packed" do
      # A wire-type mismatch on a singular field is not a PARSE error -- proto.Unmarshal retains the
      # bytes as an unknown field (ServiceRadar's validator rejects them later). Applying the PACKED
      # rules here would misclassify the failure. Each payload
      # below WOULD fail its packed rule (an overflow varint; a non-multiple-of-8 fixed64 run), so
      # these fail iff the `repeated?: true` gate is missing.
      overflow_payload = varint((1 <<< 64) + 1)
      assert :ok = WireValidate.validate(len_delim(0x0A, overflow_payload), SingularVarintFixture)

      assert :ok = WireValidate.validate(len_delim(0x0A, <<1, 2, 3>>), SingularFixed64Fixture)

      # The singular field's OWN wire types still get the normal scalar rules.
      assert {:error, :poison} =
               WireValidate.validate(<<0x08>> <> varint((1 <<< 64) + 1), SingularVarintFixture)
    end
  end

  describe "retained UNKNOWN FIELDS are rejected recursively (frozen edge ABI)" do
    test "an ordinary unknown field on the record is poison, not silently retained" do
      # protobuf-elixir RETAINS an unknown field in `__unknown_fields__` and the struct decodes
      # cleanly, so without a raw-walk check it would sail through the decode boundary and reach
      # semantic admission. Go rejects the same retained unknown recursively, and the frozen
      # task-1.16 table classifies an inner-record unknown field as WIRE POISON at a trustworthy
      # slot. Unknown field 100, wire 0 (tag 0xA0 0x06), value 1.
      raw = load("record.bin") <> <<0xA0, 0x06, 0x01>>

      # The generated decoder alone WOULD accept it -- proving the gate is doing the work.
      assert %EdgeRecordV1{__unknown_fields__: [{100, 0, 1}]} = EdgeRecordV1.decode(raw)
      assert {:error, :poison} = WireDecode.decode_record(raw)
    end

    test "an unknown field NESTED inside a capability is poison" do
      # Depth matters: the record's own fields are not the only place an unknown can hide.
      assert {:error, :poison} =
               WireDecode.decode_frame(frame_with_capability(<<0x28, 0x01, 0xA0, 0x06, 0x01>>))
    end

    test "CROSS-RUNTIME: the Go-authored unknown-group lane vector is rejected here too" do
      # proto/edge/v1/golden_test.go writes these exact bytes and asserts that Go PARSES and RETAINS
      # the unknown group, and that ValidateLaneOpen rejects it with ErrUnknownFields. Both runtimes
      # must reject the same bytes -- previously Go accepted this lane while Elixir closed it.
      assert {:error, :poison} =
               WireDecode.decode_client_message(load("lane_open_unknown_group.bin"))

      # Control: the unmodified golden lane is still accepted by both.
      assert {:ok, %EdgeRecordClientMessage{}} =
               WireDecode.decode_client_message(load("client_lane_open.bin"))
    end
  end

  describe "no over-rejection: legitimate traffic is untouched" do
    test "every shipped fixture still decodes through the recursive gate" do
      assert {:ok, %EdgeRecordV1{}} = WireDecode.decode_record(load("record.bin"))
      assert {:ok, %EdgeDeliveryFrameV1{}} = WireDecode.decode_frame(load("delivery_frame.bin"))

      assert {:ok, %EdgeRecordClientMessage{}} =
               WireDecode.decode_client_message(load("client_lane_open.bin"))

      # A real frame (with a populated delivery_capability) wrapped as a client message.
      assert {:ok, %EdgeRecordClientMessage{payload: {:delivery_frame, _}}} =
               WireDecode.decode_client_message(wrap_client_frame(load("delivery_frame.bin")))
    end

    test "an opaque bytes field is NOT recursed into: the record is validated at its own stage" do
      # record_bytes is `bytes`, so a group inside it is invisible to the FRAME schema and the frame
      # is clean. The same bytes are then rejected when decoded as a record. This proves the
      # recursion is schema-aware (never guessing that a bytes payload is a message) and that the
      # layering still catches the poison at the correct stage.
      group_record = <<0x33, 0x34>>
      frame = <<0x2A>> <> varint(byte_size(group_record)) <> group_record

      assert {:ok, %EdgeDeliveryFrameV1{}} = WireDecode.decode_frame(frame)
      assert {:error, :poison} = WireDecode.decode_record(group_record)
    end
  end

  describe "recursion boundary matches Go's root counting exactly" do
    test "10,000 messages (root + 9,999 nested) are accepted; the 10,001st is rejected" do
      # Go (protobuf v1.36.11, protowire.DefaultRecursionLimit = 10000) decrements the limit for the
      # ROOT message too -- `if o.RecursionLimit--; o.RecursionLimit < 0` -- so a chain of exactly
      # 10,000 messages is accepted and the 10,001st fails. Wrapping k times yields k+1 messages.
      nest = fn payload -> len_delim(0x0A, payload) end
      at_limit = Enum.reduce(1..9_999, <<>>, fn _, acc -> nest.(acc) end)
      over_limit = nest.(at_limit)

      assert :ok = WireValidate.validate(at_limit, RecursiveFixture)
      assert {:error, :poison} = WireValidate.validate(over_limit, RecursiveFixture)
    end

    test "the generated DECODER is configured to the same bound, so parity holds end to end" do
      # protobuf-elixir's `mod.decode/1` defaults to only 100 EMBEDDED levels, so nesting the
      # preflight (and Go) accept would still raise Protobuf.DecodeError at the decode step and the
      # end-to-end parity claim would be false. WireDecode therefore calls `Protobuf.decode/3` with
      # `max_nesting_depth: max_message_depth() - 1` (protobuf-elixir counts embedded levels; the
      # walker counts messages including the root). This pins the two bounds together.
      nest = fn payload -> len_delim(0x0A, payload) end
      embedded = WireValidate.max_message_depth() - 1

      # A chain the DEFAULT decoder would reject (>100 embedded) but our configured depth accepts.
      deep = Enum.reduce(1..150, <<>>, fn _, acc -> nest.(acc) end)
      assert :ok = WireValidate.validate(deep, RecursiveFixture)
      assert_raise Protobuf.DecodeError, fn -> RecursiveFixture.decode(deep) end

      assert %RecursiveFixture{} =
               Protobuf.decode(deep, RecursiveFixture, max_nesting_depth: embedded)

      # At the shared boundary the two agree: 10,000 messages accepted, 10,001 rejected by BOTH.
      at_limit = Enum.reduce(1..9_999, <<>>, fn _, acc -> nest.(acc) end)
      over_limit = nest.(at_limit)

      assert :ok = WireValidate.validate(at_limit, RecursiveFixture)

      assert %RecursiveFixture{} =
               Protobuf.decode(at_limit, RecursiveFixture, max_nesting_depth: embedded)

      assert {:error, :poison} = WireValidate.validate(over_limit, RecursiveFixture)

      assert_raise Protobuf.DecodeError, fn ->
        Protobuf.decode(over_limit, RecursiveFixture, max_nesting_depth: embedded)
      end
    end
  end

  describe "validate/2 is total and NEVER reports a metadata failure as poison" do
    test "an undeployed schema module is not_ready, not poison" do
      # :poison permanently resolves a delivery as dead. A schema that simply is not deployed yet is
      # TRANSIENT -- reporting it as poison would destroy valid data on a deployment defect.
      assert {:error, :not_ready} = WireValidate.validate(<<0x00>>, ThisModuleDoesNotExist)
    end

    test "a loaded module that is not a walkable message schema is systemic, not poison" do
      # An ENUM module is loaded but carries no field_props: a codegen/wiring defect, so PAUSE.
      assert {:error, :systemic} =
               WireValidate.validate(<<>>, EdgeRecordTrafficClass)

      # A plain Elixir module with no protobuf metadata at all.
      assert {:error, :systemic} = WireValidate.validate(<<>>, Enum)
    end

    test "schema metadata that THROWS or EXITS is systemic, not a crash" do
      # `rescue` catches neither a throw nor an exit; without an explicit `catch` the "total"
      # contract is false and a metadata defect would crash the decode boundary it protects.
      assert {:error, :systemic} = WireValidate.validate(<<0x08, 0x01>>, ThrowingPropsFixture)
      assert {:error, :systemic} = WireValidate.validate(<<0x08, 0x01>>, ExitingPropsFixture)
    end

    test "a non-binary argument is a caller fault (systemic), never poison" do
      assert {:error, :systemic} = WireValidate.validate(:not_binary, EdgeRecordV1)
      assert {:error, :systemic} = WireValidate.validate(<<0x00>>, "not a module")
    end

    test "an empty message is clean" do
      assert :ok = WireValidate.validate(<<>>, EdgeRecordV1)
    end
  end
end
