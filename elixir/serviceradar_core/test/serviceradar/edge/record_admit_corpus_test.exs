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

  test "the corpus covers the record-stage outcomes it was BUILT to cover" do
    # Not "every outcome the contract can produce" -- it deliberately omits some.
    # `payload_too_large` would need a >512 KiB fixture to say what slice 2's constructed
    # ceiling vectors already say at the frame API, and `:record` is an Elixir-only shape
    # guard with no Go counterpart, so no shared vector can produce it.
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

  test "a body ABOVE the physical ceiling is transport-reachable, and is a REAL body" do
    # The two bounds are different KINDS: 512 KiB bounds RECEIVED BYTES, 32 MiB bounds
    # EXTRACTED WORK. This ABI accepts NONCANONICAL encodings -- the payload's identity is
    # its digest over the exact received bytes, not a re-encoding -- so the padding rides in
    # a duplicate of a singular field and last-one-wins yields the ordinary bounded batch.
    r = record("record_admit_oversize_body.bin")

    assert r.uncompressed_size > @max_payload
    assert byte_size(r.payload) <= @max_payload
    assert Compression.admit_record(r) == :ok

    assert {:ok, body} = Compression.decompress(r.payload, r.uncompressed_size)
    assert byte_size(body) > @max_payload
    assert {:ok, batch} = SweepBodyValidate.validate_bytes(body)
    assert batch.availability_policy_id == "policy-1"
  end

  test "the COMPOSED vector carries a real contract body, not filler" do
    # Admission looks at neither the envelope nor the decoded body, so a vector that stops
    # at admission can be satisfied by an incomplete record carrying arbitrary bytes. This
    # asserts the payload really is a valid contract message: extract ONCE, then validate.
    #
    # NOT SYMMETRIC WITH GO, deliberately. Go additionally runs ValidateRecord over these
    # same bytes; this runtime has no whole-record validator to run, so it asserts the half
    # it owns rather than implying a check it does not perform.
    r = record("record_admit_composed_sweep.bin")

    assert Compression.admit_record(r) == :ok
    assert {:ok, body} = Compression.decompress(r.payload, r.uncompressed_size)
    assert {:ok, _batch} = SweepBodyValidate.validate_bytes(body)
  end

  describe "the 32 MiB output ceiling, at RECORD scope" do
    # COMMITTED, not constructed. Compressing a shared recipe independently in each runtime
    # produces two different frames, so "the ceiling is inclusive" would have been asserted
    # about two different inputs. Both halves below come from the SAME committed bytes.
    setup do
      %{record: record("record_admit_output_ceiling.bin")}
    end

    test "exactly 32 MiB is ADMITTED, with the ratio slack so the CEILING is what decides",
         %{record: r} do
      assert r.uncompressed_size == @max_uncompressed
      assert byte_size(r.payload) <= @max_payload
      assert @max_uncompressed <= r.encoded_size * @max_ratio
      assert Compression.admit_record(r) == :ok

      # And the ceiling vector is a REAL contract body, not filler.
      assert {:ok, body} = Compression.decompress(r.payload, r.uncompressed_size)
      assert byte_size(body) == @max_uncompressed
      assert {:ok, _batch} = SweepBodyValidate.validate_bytes(body)
    end

    test "one byte more is REFUSED, and the ratio still passes", %{record: r} do
      over = %{r | uncompressed_size: @max_uncompressed + 1}

      assert over.uncompressed_size <= over.encoded_size * @max_ratio
      assert Compression.admit_record(over) == {:error, :uncompressed_size}
    end
  end

  describe "admit_record/1 is TOTAL and fail-closed" do
    test "a bare struct map is refused, not raised on" do
      # `%EdgeRecordV1{} = r` matches this, and `r.payload` would then raise KeyError.
      assert Compression.admit_record(%{__struct__: EdgeRecordV1}) == {:error, :record}
    end

    test "a TAGGED MAP carrying only the matched keys is refused" do
      # A struct pattern checks `__struct__` and the keys it NAMES. This map satisfies every
      # one of them and every guard, and is still not a record: the generated struct has
      # twenty fields, this has six.
      forged = %{
        __struct__: EdgeRecordV1,
        payload: <<>>,
        payload_sha256: :crypto.hash(:sha256, <<>>),
        encoded_size: 0,
        uncompressed_size: 0,
        compression: :EDGE_RECORD_COMPRESSION_NONE
      }

      assert map_size(forged) < map_size(EdgeRecordV1.__struct__())
      assert Compression.admit_record(forged) == {:error, :record}
    end

    test "a SAME-ARITY map with a renamed field is refused" do
      # Both forgeries above differ in SIZE from the generated struct, so a size-only check
      # would pass them and prove nothing about the key NAMES. This one has exactly the right
      # number of keys and the wrong set.
      base = EdgeRecordV1.__struct__() |> Map.from_struct() |> Map.put(:__struct__, EdgeRecordV1)

      forged =
        base
        |> Map.delete(:event_id)
        |> Map.put(:not_a_record_field, nil)

      assert map_size(forged) == map_size(EdgeRecordV1.__struct__())
      assert Compression.admit_record(forged) == {:error, :record}
    end

    test "a map with EXTRA keys beside the full inventory is refused" do
      # The inventory is compared both ways, so a superset is refused too.
      forged =
        EdgeRecordV1.__struct__()
        |> Map.from_struct()
        |> Map.put(:__struct__, EdgeRecordV1)
        |> Map.put(:not_a_record_field, 1)

      assert Compression.admit_record(forged) == {:error, :record}
    end

    test "a missing payload is REFUSED, not normalized to empty bytes" do
      r = %EdgeRecordV1{
        compression: :EDGE_RECORD_COMPRESSION_NONE,
        payload: nil,
        payload_sha256: :crypto.hash(:sha256, <<>>),
        encoded_size: 0,
        uncompressed_size: 0
      }

      assert Compression.admit_record(r) == {:error, :record}
    end

    test "FLOAT sizes are refused, which loose equality would have admitted" do
      payload = "an uncompressed contract payload"

      r = %EdgeRecordV1{
        compression: :EDGE_RECORD_COMPRESSION_NONE,
        payload: payload,
        payload_sha256: :crypto.hash(:sha256, payload),
        encoded_size: byte_size(payload),
        uncompressed_size: byte_size(payload) * 1.0
      }

      # 32.0 == 32 is TRUE in Elixir, so the NONE arm would have accepted this.
      assert r.uncompressed_size == r.encoded_size
      assert Compression.admit_record(r) == {:error, :record}
    end

    test "non-records of every shape are refused" do
      for bad <- [nil, :x, 42, "bytes", [1, 2], %{}, {:tuple}] do
        assert Compression.admit_record(bad) == {:error, :record}, inspect(bad)
      end
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
