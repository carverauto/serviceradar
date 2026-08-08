defmodule ServiceRadar.Edge.WireCompatCorpusTest do
  @moduledoc """
  The SHARED UNKNOWN-FIELD / UNKNOWN-ENUM compatibility corpus (task 1.5-a): Go's bytes,
  Elixir's verdict.

  Both runtimes already enforced these rules before this corpus existed. What did not exist was
  shared EVIDENCE: every structural case was proven by bytes hand-built inside THIS suite, so the
  two runtimes were asserted to agree on inputs neither had seen from the other. These vectors are
  written by `go/pkg/edge/edgerecord/wire_compat_corpus_test.go`.

  ## What is NORMATIVE here, and what is only DIAGNOSTIC

  The frozen claim is the ACCEPT/REFUSE CLASS on the same bytes. The spec says a conforming
  implementation MAY refuse at either layer, so the reason token -- `poison` from the structural
  preflight versus `unsupported_enum` from the semantic validator, and Go's parser versus its own
  unknown-field walk -- is which mechanism got there TODAY. Freezing that would fail a decoder
  upgrade that legitimately refuses earlier while preserving the contract.

  So the tests come in two kinds, and they are labelled:

    * NORMATIVE -- this runtime's class, and the fact that BOTH manifest columns carry that same
      class. Reading only this file's own column would let someone move Elixir to `accept`, update
      only the Elixir column, and leave both suites green while Go still refuses: two halves each
      grading their own homework.
    * DIAGNOSTIC -- the exact reason token and the mechanism that produced it. A legitimate layer
      move updates these rows and MUST NOT change the class.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.SemanticValidate
  alias Serviceradar.Edge.V1.EdgeRecordTrafficClass
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.Edge.WireValidate

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)
  @manifest Path.join(@testdata, "wire_compat_corpus.txt")
  @external_resource @manifest

  # The REQUIRED CASES. This is coverage, not inventory: the manifest-versus-disk test below is
  # what proves nothing is orphaned. A `length >= 12` gate would accept a required case being
  # replaced by a duplicate of another, leaving the corpus green and the case uncovered.
  @required_files [
    "wire_compat_clean.bin",
    "wire_compat_unknown_field_top.bin",
    "wire_compat_unknown_field_nested.bin",
    "wire_compat_unknown_field_depth2.bin",
    "wire_compat_unknown_group_nested.bin",
    "wire_compat_field_number_max.bin",
    "wire_compat_field_number_over.bin",
    "wire_compat_varint_overflow.bin",
    "wire_compat_wire_type_mismatch.bin",
    "wire_compat_enum_positive.bin",
    "wire_compat_enum_negative.bin",
    "wire_compat_enum_unspecified.bin"
  ]

  # THE FROZEN VERDICT VOCABULARY, mirroring `wireCompatClass` in the Go peer.
  #
  # `systemic` and `not_ready` are deliberately absent. Neither is a refusal -- one pauses and one
  # leaves the delivery unresolved -- so a vector that started resolving to either is not a changed
  # reason, it is a changed CONTRACT, and this map fails rather than normalising it to "refuse".
  @accept_verdicts ~w(accept)
  @refuse_verdicts ~w(unknown_fields decode too_large enum poison unsupported_enum)

  defp class(verdict) do
    cond do
      verdict in @accept_verdicts -> "accept"
      verdict in @refuse_verdicts -> "refuse"
      true -> flunk("#{verdict} is outside the frozen verdict vocabulary")
    end
  end

  defp testdata_dir do
    cond do
      File.dir?(@testdata) ->
        @testdata

      dir = System.get_env("TEST_SRCDIR") ->
        [System.get_env("TEST_WORKSPACE"), "_main"]
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&Path.join([dir, &1, "proto/edge/v1/testdata"]))
        |> Enum.find(&File.dir?/1)
        |> case do
          nil -> flunk("shared fixture directory not found under #{@testdata} or TEST_SRCDIR")
          p -> p
        end

      true ->
        flunk("shared fixture directory not found under #{@testdata}")
    end
  end

  defp fixture(name) do
    path = Path.join(testdata_dir(), name)
    if File.exists?(path), do: path, else: flunk("shared fixture #{name} not found")
  end

  defp load(name), do: name |> fixture() |> File.read!()

  defp vectors do
    "wire_compat_corpus.txt"
    |> fixture()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(fn line ->
      [file, go, ex, retain, form] = String.split(line)
      %{file: file, go: go, ex: ex, retain: retain, form: form}
    end)
  end

  # The Elixir half of the frozen claim, taken at the REAL ingress entry point rather than the
  # generated decoder: the structural preflight and the decode classification are both part of the
  # verdict, and calling `EdgeRecordV1.decode/1` directly would skip the first and turn the second
  # into an uncaught raise.
  defp verdict(bytes) do
    case WireDecode.decode_record(bytes) do
      {:error, reason} ->
        Atom.to_string(reason)

      {:ok, record} ->
        case SemanticValidate.validate_record(record) do
          :ok -> "accept"
          {:error, {kind, _path}} -> Atom.to_string(kind)
        end
    end
  end

  describe "NORMATIVE: the accept/refuse class, on bytes both runtimes read" do
    test "this runtime's class matches the class BOTH manifest columns carry" do
      for v <- vectors() do
        go_class = class(v.go)
        ex_class = class(v.ex)

        assert go_class == ex_class,
               "#{v.file}: the runtimes disagree -- Go #{v.go} is #{go_class}, " <>
                 "Elixir #{v.ex} is #{ex_class}"

        assert class(verdict(load(v.file))) == ex_class,
               "#{v.file}: Elixir #{class(verdict(load(v.file)))}s these bytes, " <>
                 "the corpus says #{ex_class}"
      end
    end

    test "the control is ACCEPTED, so none of the rules over-reject valid traffic" do
      bytes = load("wire_compat_clean.bin")

      assert {:ok, _record} = WireDecode.decode_record(bytes)
      assert verdict(bytes) == "accept"
    end

    test "an unknown enum is RETAINED with the value and form Go recorded" do
      # Pins the DECODED NUMBER, not only the rejection. A decoder that clamped or substituted an
      # unknown enum would still be refused by the closed sets, so no class assertion can see it --
      # which is precisely how a silent numeric drift would survive.
      #
      # The FORM is load-bearing too: `SemanticValidate`'s recursive gate identifies "a retained
      # non-member" as "an enum-typed field holding an INTEGER". If a generator change made an
      # undeclared value surface as an atom, that gate would stop seeing it, and this is the
      # assertion that fails.
      for v <- vectors(), v.retain != "-" do
        {:ok, record} = WireDecode.decode_record(load(v.file))
        retained = String.to_integer(v.retain)
        got = record.traffic_class

        case v.form do
          "integer" ->
            assert is_integer(got), "#{v.file}: expected a retained INTEGER, got #{inspect(got)}"
            assert got == retained

          "atom" ->
            assert is_atom(got), "#{v.file}: expected a declared member ATOM, got #{inspect(got)}"
            assert EdgeRecordTrafficClass.value(got) == retained
        end
      end
    end
  end

  describe "the corpus is complete and nothing in it is orphaned" do
    test "the manifest carries exactly the required cases, each once" do
      files = Enum.map(vectors(), & &1.file)

      assert length(files) == length(Enum.uniq(files)), "the manifest lists a vector twice"
      assert MapSet.new(files) == MapSet.new(@required_files)
    end

    test "the manifest and the fixtures ON DISK agree in both directions" do
      # Against DISK, not against the list above: comparing a hand-written list to a manifest
      # generated from another hand-written list is the same source twice, and an orphaned
      # `wire_compat_*.bin` left by a renamed vector is staged by Bazel, read by nobody, and
      # reported by nothing.
      listed = MapSet.new(vectors(), & &1.file)

      on_disk =
        testdata_dir()
        |> Path.join("wire_compat_*.bin")
        |> Path.wildcard()
        |> MapSet.new(&Path.basename/1)

      refute Enum.empty?(on_disk), "no wire_compat_*.bin staged; this guard would pass vacuously"

      assert listed |> MapSet.difference(on_disk) |> Enum.to_list() == [],
             "the manifest names files that are not on disk"

      assert on_disk |> MapSet.difference(listed) |> Enum.to_list() == [],
             "fixtures are on disk that no manifest row names, so no runtime reads them"
    end
  end

  describe "DIAGNOSTIC: the mechanism each refusal comes from today, which is NOT frozen" do
    # Everything below records HOW this runtime refuses, not WHETHER it does. The spec leaves the
    # layer unfrozen, so a decoder upgrade that refuses earlier should update these rows and the
    # manifest's reason columns -- and must leave every class assertion above untouched. If a
    # change here forces a class to move, that is the contract question, not a mechanism one.

    test "the exact reason token still matches the manifest" do
      for v <- vectors() do
        assert verdict(load(v.file)) == v.ex,
               "#{v.file}: reason #{verdict(load(v.file))}, the corpus records #{v.ex} " <>
                 "(mechanism moved; check the class first)"
      end
    end

    test "the parser-level vectors are refused by the PREFLIGHT here, and by Go's parser there" do
      # Go refuses these before any application code runs (`decode` in the manifest). Elixir's
      # generated decoder ACCEPTS both, so without the preflight they would be admitted here and
      # refused there -- the divergence the preflight exists to close.
      over = load("wire_compat_field_number_over.bin")
      overflow = load("wire_compat_varint_overflow.bin")

      assert {:error, :poison} = WireValidate.validate(over, EdgeRecordV1)
      assert {:error, :poison} = WireValidate.validate(overflow, EdgeRecordV1)

      assert %EdgeRecordV1{} = EdgeRecordV1.decode(over)

      # The MASKING is the point, so assert the masked NUMBER rather than merely that a struct
      # came back: 2^64+1 is written as a 10-byte varint into not_before_unix_nano, and the pinned
      # decoder keeps its low 64 bits -- the value aliases to 1.
      decoded = EdgeRecordV1.decode(overflow)
      assert decoded.production_capability.not_before_unix_nano == 1
    end

    test "the wire-type mismatch is refused by the DECODER, not the preflight" do
      # The one vector where the two halves of the Elixir gate swap roles. A SINGULAR scalar
      # arriving length-delimited is a wire-type mismatch: `WireValidate` deliberately passes it,
      # because the packed rules apply only to REPEATED fields and poisoning it would refuse a
      # shape whose bytes Go's PARSER preserves. The generated decoder then raises
      # `Protobuf.DecodeError`, which `WireDecode.classify/1` maps to `:poison`.
      #
      # That mapping is what this pins. One clause away is `:systemic`, which at a known delivery
      # slot means RETRYABLE FOREVER -- against Go's permanent refusal -- and would leave the
      # class assertions above unable to see it, because `:systemic` is not in the vocabulary at
      # all.
      bytes = load("wire_compat_wire_type_mismatch.bin")

      assert :ok = WireValidate.validate(bytes, EdgeRecordV1)
      assert_raise Protobuf.DecodeError, fn -> EdgeRecordV1.decode(bytes) end
      assert {:error, :poison} = WireDecode.decode_record(bytes)
    end

    test "an unknown field is retained by BOTH decoders and refused by BOTH frozen ABIs" do
      # The ordinary forward-compatibility shape, and the one where neither runtime's PARSER
      # objects: Go retains it in the unknown-field set and protobuf-elixir in
      # `__unknown_fields__`. Both refuse only because the edge ABI is frozen closed.
      bytes = load("wire_compat_unknown_field_top.bin")

      decoded = EdgeRecordV1.decode(bytes)
      assert decoded.__unknown_fields__ != [], "the decoder must RETAIN the unknown field"
      assert {:error, :poison} = WireValidate.validate(bytes, EdgeRecordV1)
    end

    test "the group and the plain unknown field differ ONLY in wire type" do
      # Both carry field number 100 at the same offset, so the pair isolates the WIRE TYPE. The
      # group is the shape protobuf-elixir silently DISCARDS -- nothing downstream of the decoder
      # could ever see it -- while Go parses and retains it.
      group = load("wire_compat_unknown_group_nested.bin")
      plain = load("wire_compat_unknown_field_nested.bin")

      assert {:error, :poison} = WireValidate.validate(group, EdgeRecordV1)
      assert {:error, :poison} = WireValidate.validate(plain, EdgeRecordV1)

      # The group leaves NO trace in the decoded struct, which is why a decoded-struct check can
      # never stand in for the raw walk here.
      assert EdgeRecordV1.decode(group).production_capability.__unknown_fields__ == []
    end
  end
end
