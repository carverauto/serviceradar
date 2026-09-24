defmodule ServiceRadar.Edge.ProvenanceCorpusTest do
  @moduledoc """
  Task 1.5-h: the SHARED TRANSPORT-PROVENANCE GUARD CORPUS, this runtime's half.

  ONE BOUND, ONE TESTABLE SITE. `MaxTransportProvenanceHeaderBytes` bounds one encoded
  `Sr-Edge-Transport-Provenance` header on RECEIVED bytes, before decode. The receive path is
  the only site that can fail for its own reason; the EMIT-side check is defence in depth over
  output the same function just built, so it gets no row.

  ## A guard, not an attainable maximum

  No conforming producer emits a header at the ceiling: the largest either runtime can build is
  468 bytes -- an edge slot with a 128-byte principal (itself the maximum), a 32-byte delivery
  proof, and valid fixed-width numeric fields. So this corpus never claims "512 accepted".
  It claims the largest CONFORMING header decodes, and that one over the ceiling is refused
  BEFORE the parser runs.

  ## The stage is the obligation, not the refusal

  An oversize header and a malformed one are both refused, so a verdict PAIR proves nothing
  about which check ran first -- and the bound exists to prevent PARSING, not to produce a
  refusal. The witness is therefore a pair of inputs malformed IDENTICALLY and differing only
  in length: at the ceiling the decoder must be reached and must object as the decoder
  (`:bad_base64`), and one byte over it must not be reached at all (`:too_large`).

  This runtime already returns those two tags, so the stage reads directly off the verdict; Go
  reads the same pair from the `base64.CorruptInputError` it wraps. Neither freezes diagnostic
  TEXT and neither mints an error class for the test.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.PublicationIdentity

  @corpus "provenance_corpus.txt"

  test "the corpus and this runtime agree, and the bound is still a GUARD" do
    c = corpus()

    assert c["witness_parser_ran"] == c["bound"],
           "the live witness must sit AT the ceiling"

    assert c["witness_parser_skipped"] == c["bound"] + 1,
           "the skipped witness must sit ONE over"

    # If the largest conforming header ever reached the ceiling, this would stop being a guard
    # and would owe an attainable-maximum pair instead.
    assert c["largest_conforming"] < c["bound"],
           "largest conforming header is not below the ceiling -- this is no longer a guard"
  end

  test "the largest conforming header decodes" do
    c = corpus()
    header = largest_conforming()

    # THE FROZEN LENGTH IS ASSERTED, not merely "under the ceiling": a change that shrank the
    # envelope would otherwise leave the guard claim resting on a header that no longer
    # represents the maximum.
    assert byte_size(header) == c["largest_conforming"]
    assert {:ok, _} = PublicationIdentity.decode_transport_provenance(header)
  end

  test "the guard runs BEFORE the parser" do
    c = corpus()

    # A trailing byte outside the base64url alphabet. Everything before it is valid, so the
    # decoder must reach the end to object -- which is what makes "the parser ran" observable.
    at = String.duplicate("A", c["witness_parser_ran"] - 1) <> "!"
    over = at <> "!"

    assert byte_size(at) == c["witness_parser_ran"]
    assert byte_size(over) == c["witness_parser_skipped"]

    # THE LIVE-WITNESS CONTROL. Without it, ":too_large below" is also what a broken
    # observation reports -- a decoder that stopped being reached for some other reason.
    assert {:error, :bad_base64} = PublicationIdentity.decode_transport_provenance(at)

    assert {:error, :too_large} = PublicationIdentity.decode_transport_provenance(over),
           "one byte over the ceiling the parser was ENTERED -- the guard did not run first"
  end

  # ---------------------------------------------------------------------------
  # adapters
  # ---------------------------------------------------------------------------

  # The largest header this runtime can EMIT, built the same way Go builds its own.
  defp largest_conforming do
    slot = %{
      network_scope_id: uuidv7(0x51),
      authenticated_agent_id: :binary.copy("x", 128),
      spool_id: uuidv7(0x52),
      sequence: Bitwise.bsl(1, 62)
    }

    {:ok, header} =
      PublicationIdentity.transport_provenance(%{
        edge: slot,
        record_sha256: :binary.copy(<<0x01>>, 32),
        delivery_mode: PublicationIdentity.mode_renewal(),
        delivery_proof: :binary.copy(<<1>>, 32),
        route_map_version: Bitwise.bsl(1, 62)
      })

    header
  end

  defp uuidv7(seed) do
    <<a::48, _::4, b::12, _::2, c::62>> = :binary.copy(<<seed>>, 16)
    <<a::48, 7::4, b::12, 2::2, c::62>>
  end

  defp corpus do
    rows =
      corpus_path()
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
      |> Enum.map(fn line ->
        [field, value | _] = String.split(String.trim(line), ~r/\s+/)
        {field, String.to_integer(value)}
      end)

    assert length(rows) == length(Enum.uniq_by(rows, &elem(&1, 0))),
           "the corpus repeats a field"

    map = Map.new(rows)

    # EXACTLY the four expected keys, both directions. Required-key checks alone would admit a
    # fifth field arriving with nothing here to notice it, and a size check alone would admit a
    # substitution that keeps the count.
    for k <- ["bound", "largest_conforming", "witness_parser_ran", "witness_parser_skipped"] do
      assert Map.has_key?(map, k), "the corpus is missing field #{k}"
    end

    assert map_size(map) == 4,
           "the corpus carries #{map_size(map)} fields, want exactly 4: #{inspect(Map.keys(map))}"

    map
  end

  defp corpus_path, do: Path.expand("../../../../../proto/edge/v1/testdata/#{@corpus}", __DIR__)
end
