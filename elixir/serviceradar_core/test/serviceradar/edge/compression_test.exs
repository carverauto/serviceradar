defmodule ServiceRadar.Edge.CompressionTest do
  @moduledoc """
  The Elixir compression-admission peer (task 1.5-f, slice 2).

  Every rejection asserts the EXACT reason, because reason parity with Go is the thing being
  proven and an any-error assertion cannot show it.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias ServiceRadar.Edge.Compression

  @max_uncompressed 33_554_432
  @max_window 33_554_432

  defp real_frame(body), do: body |> :zstd.compress() |> IO.iodata_to_binary()

  # A hand-built frame, so the advertised WINDOW and DICTIONARY ID can be varied
  # independently of the payload. `fhd` is the frame header descriptor.
  defp frame(fhd, extra, body) do
    hdr = 1 ||| byte_size(body) <<< 3

    <<0xFD2FB528::little-32, fhd>> <>
      extra <> <<hdr &&& 0xFF, hdr >>> 8 &&& 0xFF, hdr >>> 16 &&& 0xFF>> <> body
  end

  # The Window_Descriptor byte VERBATIM. Computing it from a log jumps whole exponents:
  # descriptor 120 is 32 MiB and 128 is 64 MiB, so a "log + 1" vector skips every mantissa
  # step in between and is not adjacent to the boundary at all.
  defp windowed(descriptor, body), do: frame(0x00, <<descriptor>>, body)

  test "the frozen ceilings are the spec's values" do
    assert Compression.limits() == %{
             uncompressed: 33_554_432,
             ratio: 100,
             window: 33_554_432
           }
  end

  describe "admit_declared/2 -- the pre-decode size and ratio gate" do
    test "a zero or oversize declaration is refused" do
      assert Compression.admit_declared(0, 1000) == {:error, :output_size}

      assert Compression.admit_declared(@max_uncompressed + 1, @max_uncompressed) ==
               {:error, :output_size}
    end

    test "the output ceiling is INCLUSIVE" do
      # encoded_size large enough that the RATIO is not what admits or refuses it.
      assert Compression.admit_declared(@max_uncompressed, @max_uncompressed) == :ok
    end

    test "the ratio is enforced, and is inclusive at exactly 100:1" do
      assert Compression.admit_declared(100, 1) == :ok
      assert Compression.admit_declared(101, 1) == {:error, :output_size}
    end

    test "it is TOTAL -- non-integers are refused, never raised on" do
      for bad <- [nil, :x, "10", 1.5, -1] do
        assert Compression.admit_declared(bad, 10) == {:error, :output_size}
        assert Compression.admit_declared(10, bad) == {:error, :output_size}
      end
    end
  end

  describe "the ENCODED-input ceiling on the public boundary" do
    # A separate KIND of bound from the three work ceilings: this one bounds RECEIVED BYTES.
    # Record admission refuses oversize payloads earlier, so this is about the exported
    # contract -- a direct caller must not be able to hand the frame walker an arbitrarily
    # large buffer just because it never went through record validation.
    #
    # THE INPUT IS A VALID FRAME PLUS PADDING, so the two sides give DIFFERENT reasons: at
    # the ceiling the frame walk decides, one byte above it the ceiling does. The bound is
    # the LITERAL rather than the module's attribute, so the runtimes cannot drift apart.
    @max_payload 524_288

    defp padded(total) do
      f = real_frame("hello")
      f <> :binary.copy(<<0>>, total - byte_size(f))
    end

    test "exactly at the ceiling the FRAME WALK decides" do
      # Admitted by the ceiling, so the walk runs and reports the padding as trailing bytes.
      assert Compression.validate_payload(padded(@max_payload), 5) == {:error, :trailing}
      assert Compression.decompress(padded(@max_payload), 5) == {:error, :trailing}
    end

    test "one byte above the ceiling the CEILING decides first" do
      assert Compression.validate_payload(padded(@max_payload + 1), 5) == {:error, :invalid}
      assert Compression.decompress(padded(@max_payload + 1), 5) == {:error, :invalid}
    end
  end

  describe "the frame walk" do
    test "a real frame's extent is exactly its byte size" do
      # Observed through the public boundary rather than by calling the walk directly: the
      # frame alone is admitted, and ONE more byte is trailing, which is what "the extent is
      # exactly the payload length" means to a caller.
      f = real_frame(:binary.copy("A", 5000))
      assert Compression.validate_payload(f, 5000) == :ok
      assert Compression.validate_payload(f <> <<0>>, 5000) == {:error, :trailing}
    end

    test "CONCATENATED frames are refused, which the OTP decoder alone would accept" do
      f = real_frame(:binary.copy("A", 5000))

      # The control: :zstd.decompress/1 happily returns BOTH frames' output, which is why
      # the walk cannot be replaced by a decode-side check.
      assert IO.iodata_length(:zstd.decompress(f <> f)) == 10_000

      assert Compression.validate_payload(f <> f, 5000) == {:error, :trailing}
    end

    test "trailing bytes after a valid frame are refused" do
      f = real_frame("hello")
      assert Compression.validate_payload(f <> <<0>>, 5) == {:error, :trailing}
    end

    test "a truncated frame is refused" do
      f = real_frame(:binary.copy("A", 5000))

      assert Compression.validate_payload(binary_part(f, 0, byte_size(f) - 1), 5000) ==
               {:error, :invalid}
    end

    test "a non-zstd magic and a SKIPPABLE-frame magic are both refused" do
      assert Compression.validate_payload(<<0, 1, 2, 3, 4>>, 5) == {:error, :invalid}
      # Skippable magic 0x184D2A50..5F carries no content; it is not a standard frame.
      assert Compression.validate_payload(<<0x184D2A50::little-32, 0::32>>, 5) ==
               {:error, :invalid}
    end

    test "the RESERVED frame-header bit and RESERVED block type are refused" do
      assert Compression.validate_payload(frame(0x08, <<0>>, "hi"), 2) == {:error, :invalid}

      # Block type 3 is reserved.
      hdr = 1 ||| 3 <<< 1 ||| 2 <<< 3
      bad = <<0xFD2FB528::little-32, 0x00, 0>> <> <<hdr &&& 0xFF, 0, 0>> <> "hi"
      assert Compression.validate_payload(bad, 2) == {:error, :invalid}
    end
  end

  describe "the window ceiling" do
    test "exactly 32 MiB is ACCEPTED and the ADJACENT value above it is REFUSED" do
      # The two vectors must be adjacent or they do not pin the boundary. Descriptor 120 is
      # exactly 33_554_432; 121 is 37_748_736, the SMALLEST representable window above it --
      # the next mantissa step, not the next exponent.
      assert {:ok, %{windowSize: 33_554_432}} = :zstd.get_frame_header(windowed(120, "hello"))
      assert {:ok, %{windowSize: 37_748_736}} = :zstd.get_frame_header(windowed(121, "hello"))

      assert Compression.validate_payload(windowed(120, "hello"), 5) == :ok
      assert Compression.validate_payload(windowed(121, "hello"), 5) == {:error, :invalid}
    end

    test "the window is refused on its OWN, with output size and ratio both valid" do
      # 5 bytes out of a 12-byte frame: the output ceiling and the 100:1 ratio are nowhere
      # near their limits, so only the window can be what refuses it.
      f = windowed(121, "hello")
      assert Compression.admit_declared(5, byte_size(f)) == :ok
      assert Compression.validate_payload(f, 5) == {:error, :invalid}
    end

    test "BOTH layers refuse it, and windowLogMax alone is not sufficient" do
      # The preflight and the decoder both enforce the ceiling -- deleting the preflight
      # check leaves every vector here passing, which is recorded rather than hidden. The
      # preflight is kept so the frozen VALUE does not depend on how the context is built,
      # and `windowLogMax` alone genuinely is not enough: a context far below the frame's
      # window still decodes it, because a single-segment frame needs no window buffer.
      f = real_frame(:binary.copy("A", 5000))
      {:ok, small} = :zstd.context(:decompress, %{windowLogMax: 10})

      try do
        assert {:continue, out} = :zstd.stream(small, f)
        assert IO.iodata_length(out) == 5000
      after
        :zstd.close(small)
      end

      assert {:ok, %{windowSize: w}} = :zstd.get_frame_header(f)
      assert w <= @max_window
    end
  end

  test "a nonzero dictionary id is refused" do
    # FIELD ORDER: the Dictionary_ID precedes the Frame_Content_Size. Writing them the other
    # way round gives dictID=5 and FCS=7 against a 5-byte body, which breaks TWO rules and
    # proves neither -- so the parsed header is asserted before the rejection is claimed.
    f = frame(0x20 ||| 0x01, <<7, 5>>, "hello")
    assert {:ok, %{dictID: 7, frameContentSize: 5}} = :zstd.get_frame_header(f)
    assert Compression.validate_payload(f, 5) == {:error, :invalid}

    # The control: the SAME frame shape with no dictionary id is admitted, so the dictionary
    # id is what refused it rather than the hand-built shape.
    ok = frame(0x20, <<5>>, "hello")
    assert {:ok, %{dictID: 0, frameContentSize: 5}} = :zstd.get_frame_header(ok)
    assert Compression.validate_payload(ok, 5) == :ok
  end

  describe "bodies larger than OTP's 128 KiB output buffer" do
    # THE REGRESSION THIS SUITE MISSED. `:zstd.stream/2` returns `{:continue, output}` when
    # it consumed all the input, but `{:continue, remainder, output}` when its 128 KiB output
    # buffer filled first. Matching only the two-tuple raised CaseClauseError on a VALID
    # body -- 131_073 bytes is the smallest that triggers it -- so the validator crashed
    # instead of returning a reason. Every fixture above is under the buffer, which is
    # exactly why nothing caught it.
    @boundary 131_072

    test "validation handles the remainder, at and above the buffer boundary" do
      for n <- [@boundary, @boundary + 1, 300_000] do
        body = :crypto.strong_rand_bytes(n)
        f = real_frame(body)
        assert Compression.validate_payload(f, n) == :ok, "#{n} bytes"
      end
    end

    test "decompression returns the whole body, not just the first buffer" do
      for n <- [@boundary, @boundary + 1, 300_000] do
        body = :crypto.strong_rand_bytes(n)
        assert {:ok, ^body} = Compression.decompress(real_frame(body), n), "#{n} bytes"
      end
    end

    test "a wrong declaration above the boundary is still refused, not raised on" do
      body = :crypto.strong_rand_bytes(@boundary + 1)
      f = real_frame(body)
      assert Compression.validate_payload(f, byte_size(body) - 1) == {:error, :output_size}
      assert Compression.validate_payload(f, byte_size(body) + 1) == {:error, :output_size}
    end

    test "INCOMPRESSIBLE data, where the frame is larger than the body" do
      # Random bytes do not compress, so the frame exceeds the body and the remainder path
      # is driven by expansion rather than by a high ratio.
      body = :crypto.strong_rand_bytes(@boundary + 1)
      f = real_frame(body)
      assert byte_size(f) > byte_size(body)
      assert Compression.validate_payload(f, byte_size(body)) == :ok
    end
  end

  describe "declared versus actual output" do
    test "a declaration the frame does not produce is refused, in BOTH directions" do
      f = real_frame(:binary.copy("A", 5000))
      assert Compression.validate_payload(f, 4999) == {:error, :output_size}
      assert Compression.validate_payload(f, 5001) == {:error, :output_size}
      assert Compression.validate_payload(f, 5000) == :ok
    end
  end

  describe "decompress/2" do
    test "it materializes exactly the validated body" do
      body = :binary.copy("A", 5000)
      assert {:ok, ^body} = Compression.decompress(real_frame(body), 5000)
    end

    test "it refuses whatever validation refuses, with the same reason" do
      f = real_frame("hello")
      assert Compression.decompress(f <> f, 5) == {:error, :trailing}
      assert Compression.decompress(f, 4) == {:error, :output_size}
      assert Compression.decompress(<<0, 1, 2>>, 5) == {:error, :invalid}
    end
  end

  test "the public boundary is TOTAL -- the NIF never raises through it" do
    for bad <- [nil, :x, 42, [1, 2], %{}, <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>] do
      assert {:error, r} = Compression.validate_payload(bad, 10)
      assert r in [:invalid, :output_size, :trailing], "#{inspect(bad)} -> #{inspect(r)}"
    end

    assert Compression.validate_payload(real_frame("hi"), :not_an_int) == {:error, :invalid}
  end
end
