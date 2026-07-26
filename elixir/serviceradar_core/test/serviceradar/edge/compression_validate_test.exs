defmodule ServiceRadar.Edge.CompressionValidateTest do
  @moduledoc """
  Cross-language parity for the compression envelope (task 1.5: streaming
  compression expansion, trailing-frame rejection).

  The verdicts are NOT hand-written here. `zstd_parity_manifest.txt` records what
  Go decides, and Go's own `TestZstdParityManifest` re-derives every row from
  `edgerecord.ValidateZstdPayload` plus the `validateCompression` declared-size
  guard. So this suite asserts against Go's REAL behaviour -- ordering included --
  and a Go behaviour change breaks the GO test first, instead of leaving Elixir
  mirroring a stale expectation.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.CompressionValidate

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)

  defp load(name), do: File.read!(Path.join(@testdata, name))

  defp manifest_rows do
    @testdata
    |> Path.join("zstd_parity_manifest.txt")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(fn line ->
      [name, declared, encoded, verdict] = String.split(line, "\t")
      {name, String.to_integer(declared), String.to_integer(encoded), verdict}
    end)
  end

  defp to_go_verdict(:ok), do: "ok"
  defp to_go_verdict({:error, reason}), do: Atom.to_string(reason)

  test "the Go-authored manifest is present and non-trivial" do
    rows = manifest_rows()

    assert length(rows) >= 7, "expected the full fixture set, got #{length(rows)}"
    # A manifest of all-identical verdicts would pass vacuously.
    assert rows |> Enum.map(&elem(&1, 3)) |> Enum.uniq() |> length() >= 3
  end

  test "every fixture reaches the same verdict as Go" do
    for {name, declared, encoded, go_verdict} <- manifest_rows() do
      payload = load(name <> ".bin")
      got = payload |> CompressionValidate.validate_zstd(declared, encoded) |> to_go_verdict()

      assert got == go_verdict,
             "#{name}: Elixir said #{got}, Go said #{go_verdict}"
    end
  end

  describe "declared-size guard (decompression bomb refused before decoding)" do
    test "a zero declared size is rejected" do
      assert {:error, :uncompressed_size} =
               CompressionValidate.validate_zstd(load("zstd_single_frame.bin"), 0, 53)
    end

    test "a declared size above the absolute ceiling is rejected" do
      over = CompressionValidate.max_uncompressed_bytes() + 1

      assert {:error, :uncompressed_size} =
               CompressionValidate.validate_zstd(load("zstd_single_frame.bin"), over, over)
    end

    test "a declared size beyond the expansion ratio is rejected" do
      encoded = 53
      just_over = encoded * CompressionValidate.max_compression_ratio() + 1

      assert {:error, :uncompressed_size} =
               CompressionValidate.validate_zstd(
                 load("zstd_single_frame.bin"),
                 just_over,
                 encoded
               )
    end

    test "the ratio boundary itself is allowed through to frame validation" do
      # Exactly at the ratio is NOT a bomb; Go uses a strict `>` comparison. The
      # frame check then decides, so this must not fail with :uncompressed_size.
      encoded = 53
      at_limit = encoded * CompressionValidate.max_compression_ratio()

      refute match?(
               {:error, :uncompressed_size},
               CompressionValidate.validate_zstd(load("zstd_single_frame.bin"), at_limit, encoded)
             )
    end

    test "zstd may expand a tiny incompressible payload, so there is no lower bound" do
      # declared (96) < encoded (109): Go deliberately permits this.
      assert :ok =
               CompressionValidate.validate_zstd(load("zstd_tiny_incompressible.bin"), 96, 109)
    end
  end

  describe "single-frame structure" do
    test "a clean single frame ends exactly at the payload end" do
      payload = load("zstd_single_frame.bin")

      assert {:ok, len} = CompressionValidate.frame_length(payload)
      assert len == byte_size(payload)
      assert :ok = CompressionValidate.single_frame_exactly(payload)
    end

    test "a trailing byte is rejected even though the frame itself is valid" do
      payload = load("zstd_trailing_byte.bin")

      assert {:ok, len} = CompressionValidate.frame_length(payload)
      assert len < byte_size(payload)
      assert {:error, :zstd_trailing} = CompressionValidate.single_frame_exactly(payload)
    end

    test "a second concatenated frame is rejected" do
      assert {:error, :zstd_trailing} =
               CompressionValidate.single_frame_exactly(load("zstd_two_frames.bin"))
    end

    test "a skippable trailing frame is rejected (a decoder would silently consume it)" do
      assert {:error, :zstd_trailing} =
               CompressionValidate.single_frame_exactly(load("zstd_skippable_suffix.bin"))
    end

    test "truncation is invalid, not trailing" do
      assert {:error, :zstd_invalid} =
               CompressionValidate.single_frame_exactly(load("zstd_truncated.bin"))
    end

    test "a non-zstd magic is invalid" do
      assert {:error, :zstd_invalid} =
               CompressionValidate.frame_length(load("zstd_bad_magic.bin"))

      assert {:error, :zstd_invalid} = CompressionValidate.frame_length(<<>>)
      assert {:error, :zstd_invalid} = CompressionValidate.frame_length(<<0xFD, 0x2F, 0xB5>>)
    end

    test "a skippable frame on its OWN is not a standard frame" do
      skippable = <<0x50, 0x2A, 0x4D, 0x18, 0x00, 0x00, 0x00, 0x00>>

      assert {:error, :zstd_invalid} = CompressionValidate.frame_length(skippable)
    end

    test "the reserved frame-header bit is rejected" do
      <<magic::binary-size(4), fhd, rest::binary>> = load("zstd_single_frame.bin")
      poisoned = <<magic::binary, Bitwise.bor(fhd, 0x08), rest::binary>>

      assert {:error, :zstd_invalid} = CompressionValidate.frame_length(poisoned)
    end
  end

  describe "declared scope of verification" do
    test "the decoded-size equality rule is explicitly declared unverified" do
      # serviceradar_core has no zstd decoder. The gap must be VISIBLE rather than
      # silently weakening the contract.
      scope = CompressionValidate.verified_scope()

      assert :zstd_decoded_size_equality in scope.unverified
      assert :zstd_trailing_data in scope.verified
      assert :zstd_expansion_ratio in scope.verified
    end
  end
end
