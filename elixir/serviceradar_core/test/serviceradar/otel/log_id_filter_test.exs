defmodule ServiceRadar.Otel.LogIdFilterTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Otel.LogIdFilter

  @hex_trace_id "0af7651916cd43dd8448eb211c80319c"
  @hex_span_id "b7ad6b7169203331"
  @raw_trace_id Base.decode16!("0af7651916cd43dd8448eb211c80319c", case: :lower)
  @raw_span_id Base.decode16!("b7ad6b7169203331", case: :lower)

  describe "transform_metadata/1" do
    test "decodes 32-char hex otel_trace_id to 16 raw bytes" do
      meta = %{otel_trace_id: @hex_trace_id}

      assert %{otel_trace_id: @raw_trace_id} = LogIdFilter.transform_metadata(meta)
      assert byte_size(LogIdFilter.transform_metadata(meta).otel_trace_id) == 16
    end

    test "decodes 16-char hex otel_span_id to 8 raw bytes" do
      meta = %{otel_span_id: @hex_span_id}

      assert %{otel_span_id: @raw_span_id} = LogIdFilter.transform_metadata(meta)
      assert byte_size(LogIdFilter.transform_metadata(meta).otel_span_id) == 8
    end

    test "decodes both ids and preserves all other metadata" do
      meta = %{
        otel_trace_id: @hex_trace_id,
        otel_span_id: @hex_span_id,
        otel_trace_flags: "01",
        domain: [:elixir],
        mfa: {Foo, :bar, 1}
      }

      assert LogIdFilter.transform_metadata(meta) == %{
               otel_trace_id: @raw_trace_id,
               otel_span_id: @raw_span_id,
               otel_trace_flags: "01",
               domain: [:elixir],
               mfa: {Foo, :bar, 1}
             }
    end

    test "accepts uppercase and mixed-case hex" do
      meta = %{otel_trace_id: String.upcase(@hex_trace_id)}
      assert %{otel_trace_id: @raw_trace_id} = LogIdFilter.transform_metadata(meta)
    end

    test "accepts charlist hex values" do
      meta = %{
        otel_trace_id: String.to_charlist(@hex_trace_id),
        otel_span_id: String.to_charlist(@hex_span_id)
      }

      assert %{otel_trace_id: @raw_trace_id, otel_span_id: @raw_span_id} =
               LogIdFilter.transform_metadata(meta)
    end

    test "leaves already-raw byte ids untouched" do
      meta = %{otel_trace_id: @raw_trace_id, otel_span_id: @raw_span_id}
      assert LogIdFilter.transform_metadata(meta) == meta
    end

    test "leaves metadata without otel id keys untouched" do
      meta = %{foo: 1, domain: [:elixir]}
      assert LogIdFilter.transform_metadata(meta) == meta
    end

    test "leaves garbage values untouched" do
      meta = %{
        # right length, not hex
        otel_trace_id: String.duplicate("zx", 16),
        # wrong length
        otel_span_id: "abcd"
      }

      assert LogIdFilter.transform_metadata(meta) == meta
    end

    test "leaves non-binary, non-list values untouched" do
      meta = %{otel_trace_id: 12_345, otel_span_id: nil}
      assert LogIdFilter.transform_metadata(meta) == meta
    end

    test "leaves invalid iodata lists untouched" do
      meta = %{otel_trace_id: [99_999, :nope]}
      assert LogIdFilter.transform_metadata(meta) == meta
    end
  end

  describe "filter/2" do
    test "rewrites meta in the log event and keeps other fields" do
      event = %{
        level: :info,
        msg: {:string, "hello"},
        meta: %{otel_trace_id: @hex_trace_id, otel_span_id: @hex_span_id, time: 123}
      }

      assert LogIdFilter.filter(event, :no_arg) == %{
               level: :info,
               msg: {:string, "hello"},
               meta: %{otel_trace_id: @raw_trace_id, otel_span_id: @raw_span_id, time: 123}
             }
    end

    test "never stops or ignores events" do
      event = %{level: :info, msg: {:string, "hi"}, meta: %{}}
      assert LogIdFilter.filter(event, :no_arg) == event
    end

    test "passes through events without a meta map" do
      assert LogIdFilter.filter(%{level: :info}, :no_arg) == %{level: :info}
    end
  end
end
