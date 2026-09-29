defmodule ServiceRadar.Edge.SweepBatchDecodeTest do
  @moduledoc """
  The raw sweep-body ingress stage (task 1.2-c, step 1).

  The bound under test is the EXTRACTED-BODY work ceiling, not the record's 512 KiB
  physical bound. A compressed payload under 512 KiB may legitimately expand past it
  — Go decompresses to `MaxUncompressedBytes` and decodes with no second physical
  cap — so applying 512 KiB here would permanently reject valid records.

  SCOPE: every vector below is an input to THIS STAGE, which runs on already-extracted,
  uncompressed bytes. None of them asserts that a composed record carrying that body is
  transport-reachable — the compression ratio rule can refuse a body this stage accepts.
  ZSTD extraction, the ratio check, the trailing-frame rule and the composed-record
  reachability proof are task 1.5-f's.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias Serviceradar.Edge.V1, as: V1
  alias ServiceRadar.Edge.WireDecode

  @ceiling 32 * 1024 * 1024

  defp u(seed), do: <<seed::8, 0::40, 7::4, 0::12, 0b10::2, 0::62>>
  defp d32(seed), do: :binary.copy(<<seed>>, 32)

  # A batch that would SURVIVE body validation, not a stub. An AD_HOC batch missing
  # source_run_id, ids, digests, timestamp and checks is refused long before any
  # ceiling matters, so a stub proves nothing about a real body reaching this size.
  defp valid_batch do
    %V1.SweepObservationBatchV1{
      source: :SWEEP_EXECUTION_SOURCE_AD_HOC,
      source_run_id: u(0x23),
      execution_id: u(0x20),
      execution_plan_id: u(0x21),
      target_range_id: u(0x22),
      execution_plan_sha256: d32(0xBB),
      target_range_sha256: d32(0xAA),
      availability_policy_id: "policy-1",
      batch_sequence: 1,
      observed_at_unix_nano: 1_700_000_300_000_000_000,
      configured_mode_bits: 1,
      tested_checks: [
        %V1.SweepTestV1{mode: :SWEEP_MODE_ICMP, protocol: :TRANSPORT_PROTOCOL_ICMP}
      ],
      hosts: []
    }
  end

  defp encoded_valid, do: V1.SweepObservationBatchV1.encode(valid_batch())

  defp varint(v) when v < 128, do: <<v>>
  defp varint(v), do: <<(v &&& 0x7F) ||| 0x80>> <> varint(v >>> 7)

  # Pad to an EXACT size with MANY SMALL DUPLICATES of a known singular field (field 13,
  # `availability_policy_id`, wire type 2 -> tag byte 0x6A). Duplicates are legal protobuf
  # and COLLAPSE on decode: last one wins.
  #
  # THE FINAL DUPLICATE CARRIES THE REAL VALUE and any remainder is absorbed by an EARLIER
  # one. Last-one-wins therefore restores `valid_batch/0` exactly, so the assertions can
  # compare against it rather than against whatever decoded -- an assertion that substitutes
  # the decoded policy back in would also pass with an EMPTY policy, which Go rejects.
  #
  # It is also what makes N and N+1 decode to the SAME message: if the remainder went into
  # the tail, the surviving value would be 8 bytes at N and 9 at N+1, so the two inputs
  # would differ semantically and the pair would prove nothing about SIZE.
  #
  # Small duplicates matter too. A single giant one also collapses, but the SURVIVING value
  # is then huge and re-encoding stays at ~32 MiB, demonstrating nothing.
  @policy "policy-1"
  @dup_payload byte_size(@policy)
  # tag(1) + len(1) + payload
  @dup_size 1 + 1 + @dup_payload

  defp dup(payload), do: <<0x6A>> <> varint(byte_size(payload)) <> payload

  defp pad_to(base, target) do
    gap = target - byte_size(base)
    tail = dup(@policy)
    body_gap = gap - byte_size(tail)

    full = div(body_gap, @dup_size)
    rest = rem(body_gap, @dup_size)

    # The remainder goes into ONE EARLIER duplicate, never the tail.
    absorber = if rest == 0, do: <<>>, else: dup(:binary.copy(<<0x41>>, @dup_payload + rest))
    full = if rest == 0, do: full, else: full - 1

    out =
      base <> :binary.copy(dup(:binary.copy(<<0x41>>, @dup_payload)), full) <> absorber <> tail

    ^target = byte_size(out)
    out
  end

  test "a valid extracted body decodes to the target struct" do
    assert {:ok, %V1.SweepObservationBatchV1{} = b} =
             WireDecode.decode_sweep_batch(encoded_valid())

    assert b == valid_batch()
  end

  test "a valid body LARGER than the record's 512 KiB physical bound is ACCEPTED" do
    # Scope: this asserts the DECODER STAGE only -- a bound of 512 KiB here would reject a
    # body this size, which is the mistake being guarded against.
    #
    # It does NOT claim this particular body is transport-reachable. These padded inputs are
    # highly repetitive and compress far beyond the permitted 100:1 ratio, so a composed
    # record carrying one is refused at compression admission, before extraction. Whether
    # some body over 512 KiB survives that gate is task 1.5-f's to prove; it owns the ratio
    # rule and the composed-record vectors.
    big = pad_to(encoded_valid(), 700 * 1024)
    assert byte_size(big) > 512 * 1024
    assert {:ok, %V1.SweepObservationBatchV1{}} = WireDecode.decode_sweep_batch(big)
  end

  describe "the extracted-body work ceiling is EXACTLY 32 MiB" do
    # A 700 KiB acceptance plus a 32 MiB+1 rejection would permit any ceiling between
    # them. These pin the boundary itself.
    test "exactly 32 MiB is accepted and decodes to a valid batch" do
      at = pad_to(encoded_valid(), @ceiling)
      assert byte_size(at) == @ceiling
      assert {:ok, %V1.SweepObservationBatchV1{} = b} = WireDecode.decode_sweep_batch(at)

      # EXACT equality with the fixture. Last-one-wins restores the real policy value, so
      # nothing here is read back out of the subject: substituting the decoded policy into
      # the expectation would also accept an EMPTY policy, which Go refuses.
      assert b == valid_batch()
    end

    test "the duplicate padding COLLAPSES, which is why a post-decode bound cannot see it" do
      at = pad_to(encoded_valid(), @ceiling)
      {:ok, b} = WireDecode.decode_sweep_batch(at)
      re_encoded = V1.SweepObservationBatchV1.encode(b)

      assert byte_size(re_encoded) < @ceiling,
             "re-encoding did not collapse; the padding assumption is wrong"

      # Concretely: a bound applied after decode would see THESE bytes, not 32 MiB — and
      # they are byte-identical to the unpadded fixture.
      assert re_encoded == encoded_valid()
    end

    test "32 MiB + 1 is rejected, and differs from the accepted input ONLY in size" do
      at = pad_to(encoded_valid(), @ceiling)
      over = pad_to(encoded_valid(), @ceiling + 1)
      assert byte_size(at) == @ceiling
      assert byte_size(over) == @ceiling + 1

      # The rejecting input is decoded DIRECTLY here -- the curated decoder never sees it,
      # so without this the pair could differ semantically and the rejection would be
      # attributable to something other than size.
      decoded_at = V1.SweepObservationBatchV1.decode(at)
      decoded_over = V1.SweepObservationBatchV1.decode(over)
      assert decoded_at == decoded_over

      # And that shared decoding is the VALID batch itself, compared exactly.
      assert decoded_at == valid_batch()
      assert decoded_over == valid_batch()

      assert WireDecode.decode_sweep_batch(over) == {:error, :too_large}
    end

    test "oversize takes precedence over malformedness" do
      # Bytes that are BOTH oversize and garbage report :too_large, proving the bound is
      # applied BEFORE the decoder runs rather than being a decode failure relabelled.
      junk = :binary.copy(<<0xFF>>, @ceiling + 1)
      assert WireDecode.decode_sweep_batch(junk) == {:error, :too_large}
    end
  end

  test "malformed bytes are POISON, not a crash and not a pause" do
    assert WireDecode.decode_sweep_batch(<<0xFF, 0xFF, 0xFF>>) == {:error, :poison}
  end

  test "a non-binary argument is SYSTEMIC — a caller fault, never poison" do
    # The spec is term() precisely because this path is reachable and contractual.
    for bad <- [:not_binary, nil, 42, %{}, [1, 2]] do
      assert WireDecode.decode_sweep_batch(bad) == {:error, :systemic},
             "#{inspect(bad)} was misclassified"
    end
  end

  describe "unknown fields" do
    # Field 9999, wire type 2, zero length. Tag varint = 9999*8+2 = 79994 -> FA F0 04.
    # The wire type MUST be a valid one (0,1,2,5): an invalid wire type is rejected by a
    # different rule, so such bytes would not test unknown-field handling at all.
    @unknown_field <<0xFA, 0xF0, 0x04, 0x00>>

    test "the generated decoder RETAINS it — this is the bypass being closed" do
      # The control. Without it the rejection below could come from anything, and a
      # change that stopped calling WireValidate would go unnoticed.
      direct = V1.SweepObservationBatchV1.decode(encoded_valid() <> @unknown_field)
      assert %V1.SweepObservationBatchV1{} = direct
      refute direct.__unknown_fields__ == []
    end

    test "the curated decoder REJECTS it" do
      assert WireDecode.decode_sweep_batch(encoded_valid() <> @unknown_field) ==
               {:error, :poison}
    end
  end

  test "an unknown GROUP is rejected — protobuf-elixir ERASES these" do
    # Wire types 3/4 are erased by the generated decoder, so this is only observable on
    # the raw path. Go retains and rejects them; parity requires the same verdict.
    assert WireDecode.decode_sweep_batch(encoded_valid() <> <<0x0B, 0x0C>>) == {:error, :poison}
  end

  test "truncation is rejected" do
    e = encoded_valid()
    assert WireDecode.decode_sweep_batch(binary_part(e, 0, byte_size(e) - 1)) == {:error, :poison}
  end
end
