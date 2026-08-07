defmodule ServiceRadar.Edge.AsnCorpusTest do
  @moduledoc """
  The SHARED ASN OBSERVATION corpus (task 1.5-e): Go's bytes, this runtime's decode.

  The requirement "An MTR hop's ASN is diagnostic enrichment, not an allocation claim" freezes
  SEMANTICS rather than a rejection path -- implementations SHALL NOT apply allocation-status
  filtering, zero means unavailable, and every other `uint32` is carried through unchanged.
  There is no value a conforming decoder can produce that the rule refuses, so there is nothing
  for a validator to reject and nothing a rejection test could pin.

  TWO REGRESSIONS ARE PROHIBITED, and they need different assertions.

  NUMERIC DRIFT -- a decode that substitutes, clamps or truncates -- is caught by comparing the
  decoded value. `SemanticValidate.validate_message/1` cannot catch it: like Go's
  `ValidateMtrTraceBatch` it never reads `asn`, so a truncated number passes it unnoticed.

  ALLOCATION-STATUS FILTERING AT THIS STAGE -- `SemanticValidate` beginning to refuse
  transitional, private-use or reserved values -- is caught by the POSITIVE assertion that
  every vector still validates. Each vector is admitted, so a new filter THERE turns one of
  them red.

  That is the limit of the claim. A filter introduced at full record ingress would not be
  visible here, because this runtime has no such entrypoint to exercise; that surface belongs
  to `unify-sweep-results-proto` tasks 5.1/5.4.

  ## What this runtime can and cannot claim

  There is no raw MTR admission entrypoint here and no full MTR body validator. These vectors
  prove GENERATED DECODE, NUMERIC PRESERVATION, and the RECURSIVE SEMANTIC TRAVERSAL -- and
  nothing beyond that. Full record-ingress admission belongs to `unify-sweep-results-proto`
  tasks 5.1/5.4.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.SemanticValidate
  alias Serviceradar.Edge.V1.MtrTraceBatchV1

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)
  @manifest Path.join(@testdata, "asn_corpus.txt")
  @external_resource @manifest

  # Field 6 (`asn`) of MtrTraceHopV1 at wire type 0 (varint): (6 <<< 3) ||| 0.
  @asn_tag 0x30

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
    "asn_corpus.txt"
    |> fixture()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [file, asn, org] = String.split(line)
      {file, String.to_integer(asn), if(org == "-", do: "", else: org)}
    end)
  end

  defp hop(file) do
    batch = file |> fixture() |> File.read!() |> MtrTraceBatchV1.decode()
    [trace] = batch.traces
    [hop] = trace.hops
    {batch, hop}
  end

  test "every shared vector decodes to the same values AND passes the semantic traversal" do
    # ONE test, not two. ExUnit guarantees no order between tests, so a comment claiming the
    # numeric comparison "runs first" would be describing luck. Both assertions belong to the
    # same claim anyway: the value survives decode, and the value is admitted.
    #
    # Neither check subsumes the other. `validate_message/1` polices retained non-member enums
    # across the decoded graph and never reads `asn`, so it cannot catch a substituted or
    # truncated number -- but it IS what catches the other prohibited regression, an
    # implementation that started filtering on allocation status and refused one of these.
    for {file, want_asn, want_org} <- manifest() do
      {batch, hop} = hop(file)

      assert hop.asn == want_asn,
             "#{file}: Elixir decoded asn #{hop.asn}, Go's manifest says #{want_asn}"

      assert hop.asn_org == want_org,
             "#{file}: Elixir decoded asn_org #{inspect(hop.asn_org)}, manifest says #{inspect(want_org)}"

      assert SemanticValidate.validate_message(batch) == :ok, file
    end
  end

  test "the manifest and the vector files on disk agree" do
    named = MapSet.new(manifest(), fn {f, _, _} -> f end)

    on_disk =
      @testdata
      |> Path.join("asn_*.bin")
      |> Path.wildcard()
      |> MapSet.new(&Path.basename/1)

    assert named == on_disk,
           "manifest/disk disagree: #{inspect(MapSet.symmetric_difference(named, on_disk))}"
  end

  describe "the two zero encodings" do
    test "differ on the WIRE and agree after decode" do
      absent = "asn_absent.bin" |> fixture() |> File.read!()
      explicit = "asn_explicit_zero.bin" |> fixture() |> File.read!()

      # Asserting only the decoded value would pass trivially -- both are 0, which is the
      # point -- and would say nothing about what is on the wire.
      #
      # SCOPE OF THIS CLAIM: a whole-batch byte scan shows the tag+varint PAIR IS PRESENT in
      # one payload and ABSENT from the other. It does NOT prove field 6 occurs exactly once
      # inside the nested hop -- 0x30 0x00 could in principle arise from other framing. The
      # EXACTLY-ONCE property is proven structurally on the Go side, which walks the hop's own
      # encoding field by field.
      refute absent == explicit
      assert :binary.match(explicit, <<@asn_tag, 0x00>>) != :nomatch
      assert :binary.match(absent, <<@asn_tag, 0x00>>) == :nomatch

      {absent_batch, absent_hop} = hop("asn_absent.bin")
      {explicit_batch, explicit_hop} = hop("asn_explicit_zero.bin")

      assert absent_hop.asn == 0
      assert explicit_hop.asn == 0

      # SEPARATELY IDENTIFIED RECORDS. Under one (network_scope_id, event_id) these would be
      # conflicting encodings of a single record rather than a pair, which is what the
      # requirement says they must not be.
      [absent_trace] = absent_batch.traces
      [explicit_trace] = explicit_batch.traces

      refute absent_trace.event_id == explicit_trace.event_id
      refute absent_trace.trace_id == explicit_trace.trace_id
    end
  end

  test "values above the signed 32-bit boundary survive decode intact" do
    # The pair that exists to catch a signed-32-bit projection column. A runtime that decoded
    # through an int32 would wrap 2147483648 to a negative number or clamp it.
    for {file, want} <- [
          {"asn_2147483647.bin", 2_147_483_647},
          {"asn_2147483648.bin", 2_147_483_648},
          {"asn_4294967295.bin", 4_294_967_295}
        ] do
      {_batch, hop} = hop(file)
      assert hop.asn == want, file
      assert hop.asn > 0, "#{file}: decoded as #{hop.asn}, which means it wrapped"
    end
  end

  test "asn_org is admitted independently of the number" do
    for {file, want_asn} <- [{"asn_zero_with_org.bin", 0}, {"asn_nonzero_with_org.bin", 64_512}] do
      {batch, hop} = hop(file)

      assert hop.asn == want_asn, file
      assert hop.asn_org == "AS-Example-Org", file
      assert SemanticValidate.validate_message(batch) == :ok, file
    end
  end
end
