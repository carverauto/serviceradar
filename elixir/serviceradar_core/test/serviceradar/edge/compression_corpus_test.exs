defmodule ServiceRadar.Edge.CompressionCorpusTest do
  @moduledoc """
  The SHARED FRAME AND OUTPUT-SIZE corpus (task 1.5-f, slice 2): Go's bytes, Elixir's verdict.

  This is the only thing that shows the two implementations reach one answer, because they do
  NOT share a shape. Go delegates the window and dictionary rules to its decoder, while this
  runtime enforces them in a project-owned preflight over the parsed frame header. Two
  different routes agreeing on hand-built bytes is the proof; each runtime's own unit tests
  cannot be.

  The expectation travels WITH the bytes in `compression_corpus.txt`, so this side DERIVES it
  rather than restating it. Two hand-written expectation tables would let the runtimes drift
  while both stayed green.

  ## Scope

  These vectors exercise the FRAME AND OUTPUT-SIZE stage -- frame structure, window,
  dictionary, and declared-versus-actual output. They do NOT exercise RECORD-LEVEL admission,
  which additionally binds `encoded_size` to the payload length and applies the 100:1 ratio
  BEFORE any of this runs. Several vectors here are deliberately unreachable as whole
  records: `zstd_valid_5k.bin` declares 5000 bytes from a 15-byte frame. That is the stage
  they belong to, not a defect -- but this corpus must not be read as proving compression
  admission. Slice 3 owes the record-level vectors.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.Compression

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)
  @manifest Path.join(@testdata, "compression_corpus.txt")
  @external_resource @manifest

  # Runfiles-aware, matching the other shared-fixture suites: a bare relative path is the
  # failure mode where a required Bazel shard silently reads nothing.
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
    "compression_corpus.txt"
    |> fixture()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [file, declared, outcome] = String.split(line)
      {file, String.to_integer(declared), outcome}
    end)
  end

  defp verdict(payload, declared) do
    case Compression.validate_payload(payload, declared) do
      :ok -> "accept"
      {:error, reason} -> Atom.to_string(reason)
    end
  end

  test "every shared vector reaches the SAME verdict in both runtimes" do
    for {file, declared, want} <- manifest() do
      payload = file |> fixture() |> File.read!()

      assert verdict(payload, declared) == want,
             "#{file}: Elixir says #{verdict(payload, declared)}, Go's manifest says #{want}"
    end
  end

  test "the manifest and the vector files on disk agree" do
    named = MapSet.new(manifest(), fn {f, _, _} -> f end)

    on_disk =
      @testdata
      |> Path.join("zstd_*.bin")
      |> Path.wildcard()
      |> MapSet.new(&Path.basename/1)

    # A vector file added without a manifest line would never be loaded, so the corpus would
    # silently shrink to whatever the manifest happened to list.
    assert named == on_disk,
           "manifest/disk disagree: #{inspect(MapSet.symmetric_difference(named, on_disk))}"
  end

  test "the corpus covers every outcome the contract can produce" do
    outcomes = MapSet.new(manifest(), fn {_, _, o} -> o end)
    assert outcomes == MapSet.new(["accept", "invalid", "output_size", "trailing"])
  end

  test "an ACCEPTING vector also decompresses to exactly its declared size" do
    # Validation proves the size without retaining the body; this proves the second pass
    # produces it. A runtime could pass every verdict above and still return short output.
    for {file, declared, "accept"} <- Enum.filter(manifest(), &(elem(&1, 2) == "accept")) do
      payload = file |> fixture() |> File.read!()
      assert {:ok, body} = Compression.decompress(payload, declared), file
      assert byte_size(body) == declared, file
    end
  end
end
