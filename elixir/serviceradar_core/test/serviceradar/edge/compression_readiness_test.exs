defmodule ServiceRadar.Edge.CompressionReadinessTest do
  @moduledoc """
  Fail-closed compression admission (task 1.5, PARTIAL — not compression parity).

  The Go-authored `zstd_parity_manifest.txt` is reused, but its meaning here is
  INVERTED relative to the retired parity attempt. It records what Go decides; this
  suite asserts the readiness contract against it:

    * where Go says `ok`, Elixir MUST answer `{:not_ready, _}` — never `:ok`,
      because without a decoder it cannot know what Go knows;
    * where Go rejects, Elixir MAY reject, and any rejection it makes MUST be one
      Go also makes (rejections are a subset, never a superset).

  That is the honest cross-language statement available without a decoder: Elixir
  never ADMITS what Go admits, it defers; and it never rejects what Go accepts.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.CompressionReadiness, as: Readiness

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

  describe "ZSTD is never admitted without a decoder" do
    test "every fixture Go ACCEPTS is not_ready here, never :ok" do
      for {name, declared, encoded, "ok"} <- manifest_rows() do
        payload = load(name <> ".bin")

        assert {:not_ready, :zstd_decoder_unavailable} =
                 zstd_verdict(payload, declared, encoded),
               "#{name}: Go accepts this; without a decoder Elixir must DEFER, not admit"
      end
    end

    test "no ZSTD input anywhere in the corpus yields :ok" do
      results =
        for {name, declared, encoded, _} <- manifest_rows() do
          zstd_verdict(load(name <> ".bin"), declared, encoded)
        end

      refute Enum.any?(results, &(&1 == :ok)),
             "a structural preflight must never admit ZSTD: #{inspect(results)}"

      # Guard against the suite passing because nothing was exercised.
      assert length(results) >= 7
    end

    test "rejections are a SUBSET of Go's" do
      for {name, declared, encoded, go_verdict} <- manifest_rows() do
        case zstd_verdict(load(name <> ".bin"), declared, encoded) do
          {:error, reason} ->
            refute go_verdict == "ok",
                   "#{name}: Elixir rejected (#{reason}) something Go ACCEPTS"

          {:not_ready, _} ->
            :ok
        end
      end
    end
  end

  describe "early rejection (sound, never admission)" do
    test "the preflight signals no-rejection rather than :ok" do
      assert :no_early_rejection = Readiness.single_frame_exactly(load("zstd_single_frame.bin"))
    end

    test "trailing bytes are rejected" do
      assert {:error, :zstd_trailing} =
               Readiness.single_frame_exactly(load("zstd_trailing_byte.bin"))
    end

    test "a second concatenated frame is rejected" do
      assert {:error, :zstd_trailing} =
               Readiness.single_frame_exactly(load("zstd_two_frames.bin"))
    end

    test "a skippable trailing frame is rejected (a decoder would consume it silently)" do
      assert {:error, :zstd_trailing} =
               Readiness.single_frame_exactly(load("zstd_skippable_suffix.bin"))
    end

    test "truncation is invalid, not trailing" do
      assert {:error, :zstd_invalid} = Readiness.single_frame_exactly(load("zstd_truncated.bin"))
    end

    test "a non-zstd magic is invalid" do
      assert {:error, :zstd_invalid} = Readiness.frame_length(load("zstd_bad_magic.bin"))
      assert {:error, :zstd_invalid} = Readiness.frame_length(<<>>)
    end
  end

  describe "declared-size guard (bomb refused before any decode)" do
    test "zero declared size is rejected" do
      assert {:error, :uncompressed_size} =
               Readiness.reject_zstd_early(load("zstd_single_frame.bin"), 0, 53)
    end

    test "declared size above the absolute ceiling is rejected" do
      over = Readiness.max_uncompressed_bytes() + 1
      assert {:error, :uncompressed_size} = Readiness.reject_zstd_early(<<>>, over, over)
    end

    test "declared size beyond the expansion ratio is rejected" do
      encoded = 53
      just_over = encoded * Readiness.max_compression_ratio() + 1

      assert {:error, :uncompressed_size} =
               Readiness.reject_zstd_early(load("zstd_single_frame.bin"), just_over, encoded)
    end

    test "the ratio boundary itself is not a bomb (Go uses strict >)" do
      encoded = 53
      at_limit = encoded * Readiness.max_compression_ratio()

      refute match?(
               {:error, :uncompressed_size},
               Readiness.reject_zstd_early(load("zstd_single_frame.bin"), at_limit, encoded)
             )
    end

    test "zstd may expand a tiny incompressible payload, so there is no lower bound" do
      assert :no_early_rejection =
               Readiness.reject_zstd_early(load("zstd_tiny_incompressible.bin"), 96, 109)
    end
  end

  describe "encoded_size is bound to the actual payload" do
    test "a declared encoded_size that does not match the bytes is rejected" do
      record = record(:EDGE_RECORD_COMPRESSION_NONE, "abcd", 4, 999)
      assert {:error, :encoded_size} = Readiness.assess(record)
    end

    test "binding is enforced for ZSTD too, before any size or frame logic" do
      record = record(:EDGE_RECORD_COMPRESSION_ZSTD, load("zstd_single_frame.bin"), 1920, 999)
      assert {:error, :encoded_size} = Readiness.assess(record)
    end
  end

  describe "NONE is decided completely" do
    test "exact three-way agreement is admitted" do
      assert :ok = Readiness.assess(record(:EDGE_RECORD_COMPRESSION_NONE, "abcd", 4, 4))
    end

    test "uncompressed_size disagreeing with the payload is rejected" do
      assert {:error, :uncompressed_size} =
               Readiness.assess(record(:EDGE_RECORD_COMPRESSION_NONE, "abcd", 5, 4))
    end
  end

  describe "codec advertisement" do
    test "ZSTD is not advertised while it cannot be decided" do
      codecs = Readiness.advertised_codecs()

      assert :EDGE_RECORD_COMPRESSION_NONE in codecs
      refute :EDGE_RECORD_COMPRESSION_ZSTD in codecs
    end

    test "an unset or unknown codec is rejected" do
      assert {:error, :compression} =
               Readiness.assess(record(:EDGE_RECORD_COMPRESSION_UNSPECIFIED, "abcd", 4, 4))
    end
  end

  # A ZSTD record whose encoded_size matches the payload, so assess/1 reaches the
  # codec arm rather than stopping at the binding check.
  defp zstd_verdict(payload, declared, _encoded_from_manifest) do
    Readiness.assess(record(:EDGE_RECORD_COMPRESSION_ZSTD, payload, declared, byte_size(payload)))
  end

  defp record(compression, payload, uncompressed, encoded) do
    struct(Serviceradar.Edge.V1.EdgeRecordV1, %{
      compression: compression,
      payload: payload,
      uncompressed_size: uncompressed,
      encoded_size: encoded
    })
  end
end
