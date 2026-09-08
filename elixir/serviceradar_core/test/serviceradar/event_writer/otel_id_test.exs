defmodule ServiceRadar.EventWriter.OtelIdTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.OtelId

  @raw_trace <<102, 88, 99, 99, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 255>>
  @hex_trace "665863630102030405060708090a0bff"
  @raw_span <<1, 2, 3, 4, 5, 6, 7, 255>>
  @hex_span "01020304050607ff"

  describe "normalize_trace_id/1" do
    test "nil and empty input map to nil" do
      assert OtelId.normalize_trace_id(nil) == nil
      assert OtelId.normalize_trace_id("") == nil
    end

    test "raw 16 bytes are hex encoded once" do
      assert OtelId.normalize_trace_id(@raw_trace) == @hex_trace
    end

    test "raw 16 bytes that are printable text still encode as raw bytes" do
      assert OtelId.normalize_trace_id("abcdefghijklmnop") ==
               Base.encode16("abcdefghijklmnop", case: :lower)
    end

    test "already-hex 32-char string is NOT hexed again" do
      assert OtelId.normalize_trace_id(@hex_trace) == @hex_trace
    end

    test "ascii hex arriving inside a bytes field is detected (32 hex bytes)" do
      # The Erlang OTLP logs exporter puts the hex TEXT into the protobuf
      # bytes field; consumers must not hex it a second time.
      ascii_hex_bytes = :binary.list_to_bin(String.to_charlist(@hex_trace))
      assert byte_size(ascii_hex_bytes) == 32
      assert OtelId.normalize_trace_id(ascii_hex_bytes) == @hex_trace
    end

    test "uppercase hex is downcased" do
      assert OtelId.normalize_trace_id(String.upcase(@hex_trace)) == @hex_trace
    end

    test "legacy double-hex 64-char string folds to canonical 32-char hex" do
      double_hex = Base.encode16(@hex_trace, case: :lower)
      assert byte_size(double_hex) == 64
      assert OtelId.normalize_trace_id(double_hex) == @hex_trace
    end

    test "uppercase double-hex folds and downcases" do
      double_hex = Base.encode16(String.upcase(@hex_trace), case: :upper)
      assert OtelId.normalize_trace_id(double_hex) == @hex_trace
    end

    test "64-char hex whose decode is not ascii hex is rejected" do
      not_double_hex = Base.encode16(:binary.copy(<<255>>, 32), case: :lower)
      assert byte_size(not_double_hex) == 64
      assert OtelId.normalize_trace_id(not_double_hex) == nil
    end

    test "standard base64 of 16 raw bytes decodes to hex" do
      assert OtelId.normalize_trace_id(Base.encode64(@raw_trace)) == @hex_trace
    end

    test "base64 with wrong decoded length is rejected" do
      assert OtelId.normalize_trace_id(Base.encode64(<<1, 2, 3>>)) == nil
    end

    test "all-zero ids normalize to nil in every encoding" do
      assert OtelId.normalize_trace_id(:binary.copy(<<0>>, 16)) == nil
      assert OtelId.normalize_trace_id(String.duplicate("0", 32)) == nil
      assert OtelId.normalize_trace_id(String.duplicate("0", 64)) == nil
      assert OtelId.normalize_trace_id(Base.encode64(:binary.copy(<<0>>, 16))) == nil
    end

    test "garbage is rejected" do
      assert OtelId.normalize_trace_id("trace-123") == nil
      assert OtelId.normalize_trace_id("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz") == nil
      assert OtelId.normalize_trace_id(String.duplicate("g", 64)) == nil
      assert OtelId.normalize_trace_id(123) == nil
      assert OtelId.normalize_trace_id(%{}) == nil
      assert OtelId.normalize_trace_id(:binary.copy(<<1>>, 5)) == nil
    end

    test "is idempotent" do
      canonical = OtelId.normalize_trace_id(@raw_trace)
      assert OtelId.normalize_trace_id(canonical) == canonical
    end
  end

  describe "normalize_span_id/1" do
    test "nil and empty input map to nil" do
      assert OtelId.normalize_span_id(nil) == nil
      assert OtelId.normalize_span_id("") == nil
    end

    test "raw 8 bytes are hex encoded once" do
      assert OtelId.normalize_span_id(@raw_span) == @hex_span
    end

    test "already-hex 16-char string is NOT hexed again" do
      assert OtelId.normalize_span_id(@hex_span) == @hex_span
    end

    test "uppercase hex is downcased" do
      assert OtelId.normalize_span_id(String.upcase(@hex_span)) == @hex_span
    end

    test "legacy double-hex 32-char string folds to canonical 16-char hex" do
      double_hex = Base.encode16(@hex_span, case: :lower)
      assert byte_size(double_hex) == 32
      assert OtelId.normalize_span_id(double_hex) == @hex_span
    end

    test "standard base64 of 8 raw bytes decodes to hex" do
      assert OtelId.normalize_span_id(Base.encode64(@raw_span)) == @hex_span
    end

    test "all-zero ids normalize to nil in every encoding" do
      assert OtelId.normalize_span_id(:binary.copy(<<0>>, 8)) == nil
      assert OtelId.normalize_span_id(String.duplicate("0", 16)) == nil
      assert OtelId.normalize_span_id(String.duplicate("0", 32)) == nil
    end

    test "garbage is rejected" do
      assert OtelId.normalize_span_id("span-4567-bad") == nil
      assert OtelId.normalize_span_id("zzzzzzzzzzzzzzzz") == nil
      assert OtelId.normalize_span_id(42) == nil
    end

    test "an 8-byte non-hex binary is treated as raw bytes per the contract" do
      # Any exactly-N-byte value is the raw OTLP encoding by definition;
      # there is no N-byte textual form in the contract.
      assert OtelId.normalize_span_id("span-456") ==
               Base.encode16("span-456", case: :lower)
    end
  end

  describe "normalize_parent_span_id/1" do
    test "empty and zero parents map to nil (root spans store NULL)" do
      assert OtelId.normalize_parent_span_id(nil) == nil
      assert OtelId.normalize_parent_span_id("") == nil
      assert OtelId.normalize_parent_span_id("0000000000000000") == nil
      assert OtelId.normalize_parent_span_id(:binary.copy(<<0>>, 8)) == nil
    end

    test "valid parent ids normalize like span ids" do
      assert OtelId.normalize_parent_span_id(@raw_span) == @hex_span
      assert OtelId.normalize_parent_span_id(String.upcase(@hex_span)) == @hex_span
    end
  end
end
