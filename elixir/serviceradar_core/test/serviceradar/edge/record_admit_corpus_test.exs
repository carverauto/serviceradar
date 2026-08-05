defmodule ServiceRadar.Edge.RecordAdmitCorpusTest do
  @moduledoc """
  The RECORD-STAGE compression-admission corpus (task 1.5-f, slice 3): Go's bytes, Elixir's
  verdict.

  Slice 2's corpus stops at the frame validator, which sees a payload and a declared size.
  The two rules that make the ratio meaningful are not reachable from there -- the BINDING of
  `encoded_size` to the actual payload length, and the ratio and 32 MiB ceiling applied to
  the DECLARED sizes before any decode -- because they live in record validation. These
  vectors are whole encoded `EdgeRecordV1` messages.

  The expectation travels WITH the bytes in `record_admit_corpus.txt`, so this side DERIVES
  it. Two hand-written expectation tables would let the runtimes drift while both stayed
  green.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.Compression
  alias ServiceRadar.Edge.SweepBodyValidate
  alias Serviceradar.Edge.V1.EdgeRecordV1

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)
  @manifest Path.join(@testdata, "record_admit_corpus.txt")
  @external_resource @manifest

  @max_uncompressed 33_554_432
  @max_ratio 100
  @max_payload 524_288

  defp fixture(name) do
    direct = Path.join(@testdata, name)

    cond do
      File.exists?(direct) ->
        direct

      dir = System.get_env("TEST_SRCDIR") ->
        [System.get_env("TEST_WORKSPACE"), "_main"]
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&Path.join([dir, &1, "proto/edge/v1/testdata", name]))
        |> Enum.find(&File.exists?/1)
        |> case do
          nil -> flunk("shared fixture #{name} not found under #{@testdata} or TEST_SRCDIR")
          p -> p
        end

      true ->
        flunk("shared fixture #{name} not found under #{@testdata}")
    end
  end

  defp manifest do
    "record_admit_corpus.txt"
    |> fixture()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [file, outcome] = String.split(line)
      {file, outcome}
    end)
  end

  defp record(file), do: file |> fixture() |> File.read!() |> EdgeRecordV1.decode()

  defp verdict(record) do
    case Compression.admit_record(record) do
      :ok -> "accept"
      {:error, reason} -> Atom.to_string(reason)
    end
  end

  # The same deterministic filler Go's corpus uses: sha256 over a counter. Shared RECIPE,
  # not shared bytes, for the vectors too large to commit.
  defp chain_bytes(n) do
    0
    |> Stream.iterate(&(&1 + 1))
    |> Stream.map(&:crypto.hash(:sha256, <<&1::big-64>>))
    |> Enum.reduce_while(<<>>, fn block, acc ->
      acc = acc <> block
      if byte_size(acc) >= n, do: {:halt, acc}, else: {:cont, acc}
    end)
    |> binary_part(0, n)
  end

  defp tuned_body(total, incompressible) do
    chain_bytes(incompressible) <> :binary.copy(<<0>>, total - incompressible)
  end

  defp zstd_record(body) do
    payload = body |> :zstd.compress() |> IO.iodata_to_binary()

    %EdgeRecordV1{
      compression: :EDGE_RECORD_COMPRESSION_ZSTD,
      payload: payload,
      payload_sha256: :crypto.hash(:sha256, payload),
      encoded_size: byte_size(payload),
      uncompressed_size: byte_size(body)
    }
  end

  test "every shared vector reaches the SAME verdict in both runtimes" do
    for {file, want} <- manifest() do
      got = file |> record() |> verdict()
      assert got == want, "#{file}: Elixir says #{got}, Go's manifest says #{want}"
    end
  end

  test "the manifest and the vector files on disk agree" do
    named = MapSet.new(manifest(), fn {f, _} -> f end)

    on_disk =
      @testdata
      |> Path.join("record_admit_*.bin")
      |> Path.wildcard()
      |> MapSet.new(&Path.basename/1)

    assert named == on_disk,
           "manifest/disk disagree: #{inspect(MapSet.symmetric_difference(named, on_disk))}"
  end

  test "the corpus covers every record-stage outcome the contract can produce" do
    outcomes = MapSet.new(manifest(), fn {_, o} -> o end)

    assert outcomes ==
             MapSet.new([
               "accept",
               "encoded_size",
               "payload_digest",
               "compression",
               "uncompressed_size"
             ])
  end

  test "a body ABOVE the physical ceiling is transport-reachable" do
    # The two bounds are different KINDS: 512 KiB bounds RECEIVED BYTES, 32 MiB bounds
    # EXTRACTED WORK. This vector's body exceeds the first and is still admitted, because
    # what crossed the wire is the frame.
    r = record("record_admit_reachable_body.bin")

    assert r.uncompressed_size > @max_payload
    assert byte_size(r.payload) <= @max_payload
    assert Compression.admit_record(r) == :ok
  end

  describe "the 32 MiB output ceiling, at RECORD scope" do
    # CONSTRUCTED, NOT COMMITTED. The accepted side needs a frame that really produces
    # 33_554_432 bytes while staying above 1/100th of it -- about 340 KiB of fixture, larger
    # than every committed vector here combined. The window it must land in is ASSERTED
    # below, so a compressor change fails loudly instead of quietly weakening the vector.
    setup do
      %{record: zstd_record(tuned_body(@max_uncompressed, 400_000))}
    end

    test "exactly 32 MiB is ADMITTED, with the ratio slack so the CEILING is what decides",
         %{record: r} do
      assert r.encoded_size <= @max_payload
      assert @max_uncompressed <= r.encoded_size * @max_ratio
      assert Compression.admit_record(r) == :ok
    end

    test "one byte more is REFUSED, and the ratio still passes", %{record: r} do
      over = %{r | uncompressed_size: @max_uncompressed + 1}

      assert over.uncompressed_size <= over.encoded_size * @max_ratio
      assert Compression.admit_record(over) == {:error, :uncompressed_size}
    end
  end

  test "RECURSIVE compression: one layer is extracted, and the result is not a contract body" do
    # The frozen rule is ONE compression layer. The record carries a valid frame whose
    # extracted bytes are ANOTHER valid frame wrapping a valid contract message.
    r = record("record_admit_recursive_outer.bin")

    # Admission accepts: the outer frame is well formed, and recursion is not an
    # admission-stage property.
    assert Compression.admit_record(r) == :ok

    # Exactly one decompression.
    assert {:ok, extracted} = Compression.decompress(r.payload, r.uncompressed_size)
    assert <<0x28, 0xB5, 0x2F, 0xFD, _::binary>> = extracted

    # And those bytes are refused AS THE CONTRACT PAYLOAD, with the EXACT reason: `:poison`
    # is the curated decoder's "malformed", which is what a zstd frame is to a protobuf
    # parser. Asserting any-error would also pass if the stage started refusing everything.
    assert SweepBodyValidate.validate_bytes(extracted) == {:error, :poison}

    # THE CONTROL: unwrapping a second time yields a body that VALIDATES. Without this, the
    # assertion above could be satisfied by inner content that was junk to begin with, and
    # would say nothing about recursion -- the vector has to be one a recursive runtime
    # would WRONGLY ACCEPT.
    inner = extracted |> :zstd.decompress() |> IO.iodata_to_binary()
    assert {:ok, ^inner} = Compression.decompress(extracted, byte_size(inner))
    assert {:ok, _batch} = SweepBodyValidate.validate_bytes(inner)
  end
end
