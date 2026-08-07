defmodule ServiceRadar.Edge.CanonicalMicrosCorpusTest do
  @moduledoc """
  The SHARED ns->us CANONICALIZATION corpus (task 1.5-c): one hand-written table, both runtimes.

  THE MANIFEST IS NOT GENERATED FROM EITHER IMPLEMENTATION. Every expected value in
  `canonical_micros_corpus.txt` is written out by hand, because a table produced by calling the
  helper cannot detect the helper being wrong -- which is exactly the failure this corpus exists
  to catch, and exactly the failure that was live in Go until this slice.

  ## What this runtime proves, and what it cannot

  Elixir integers are arbitrary precision, so the overflow that broke Go's implementation is not
  reachable here. These vectors therefore prove the SHARED MATHEMATICS -- floor to the
  containing bucket, including for negatives -- and hold both runtimes to one table. They do not
  and cannot prove anything about 64-bit overflow behaviour; Go's suite owns that.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.ProjectionTime
  alias ServiceRadar.Edge.SemanticDigest
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.MtrTraceBatchV1

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)
  @manifest Path.join(@testdata, "canonical_micros_corpus.txt")
  @external_resource @manifest

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

  defp vectors do
    "canonical_micros_corpus.txt"
    |> fixture()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(fn line ->
      [ns, us] = String.split(line)
      {String.to_integer(ns), String.to_integer(us)}
    end)
  end

  @min_int64 -9_223_372_036_854_775_808

  # EXACT MEMBERSHIP, not a count. A `length >= 14` gate would accept a required boundary row
  # being replaced by a duplicate of another -- the count holds, the suite stays green, and the
  # case that was meant to be covered is gone.
  @required_inputs [
    -1500,
    -1001,
    -1000,
    -999,
    -1,
    0,
    999,
    1000,
    1500,
    @min_int64,
    @min_int64 + 807,
    @min_int64 + 808,
    @min_int64 + 999,
    @min_int64 + 1000
  ]

  test "the manifest carries exactly the required inputs, each once" do
    inputs = Enum.map(vectors(), &elem(&1, 0))

    assert length(inputs) == length(Enum.uniq(inputs)), "the manifest lists an input twice"
    assert MapSet.new(inputs) == MapSet.new(@required_inputs)
  end

  test "every shared vector canonicalizes identically in both runtimes" do
    rows = vectors()

    for {ns, want} <- rows do
      assert ProjectionTime.canonical_micros(ns) == want,
             "#{ns} ns: Elixir says #{ProjectionTime.canonical_micros(ns)}, manifest says #{want}"
    end
  end

  test "every result names the bucket CONTAINING its instant" do
    # Checks the INVARIANT rather than the table, so a manifest and an implementation that
    # drifted together are still caught. Elixir integers are arbitrary precision, so u * 1000
    # can be evaluated directly here -- the widening Go needs is free in this runtime.
    for {ns, _want} <- vectors() do
      u = ProjectionTime.canonical_micros(ns)
      lo = u * 1000
      hi = lo + 1000

      assert ns >= lo and ns < hi,
             "#{ns} ns: bucket #{u} spans [#{lo}, #{hi}), which does not contain it"
    end
  end

  test "negatives floor away from zero, which truncation would not do" do
    # The pair that distinguishes floor from truncation. div/2 truncates toward zero and would
    # answer -1 for -1500, naming a bucket that does not contain the instant.
    assert ProjectionTime.canonical_micros(-1500) == -2
    assert div(-1500, 1000) == -1
    refute ProjectionTime.canonical_micros(-1500) == div(-1500, 1000)
  end

  describe "canonicalized time never reaches either contract hash" do
    # THE SAME COMMITTED RECORDS GO USES, read byte-for-byte. An earlier version of this test
    # hashed short synthetic blobs whose bytes had nothing to do with 128 or 999 ns -- the
    # digests differed, but for a reason unrelated to the rule, so the control proved nothing.
    #
    # 128 ns and 999 ns rather than 1 ns and 999 ns because both are TWO-BYTE varints. A 1/999
    # pair also moves encoded_size and uncompressed_size, which the transcript frames directly,
    # so the digests would differ even with the transcript's payload_sha256 dependency deleted.
    #
    # The records are UNCOMPRESSED, so the payload IS the MTR body and the width argument
    # applies to the bytes actually hashed.

    test "two MTR payloads in one bucket differ in payload hash and semantic digest" do
      a = record("canonical_hash_observed_128.bin")
      b = record("canonical_hash_observed_999.bin")

      # The decoded value is what makes the pair mean anything -- without it these are two
      # blobs that happen to differ.
      assert observed_nanos(a) == 128
      assert observed_nanos(b) == 999

      assert ProjectionTime.canonical_micros(128) == ProjectionTime.canonical_micros(999),
             "the two instants must share one bucket for this control to mean anything"

      assert byte_size(a.payload) == byte_size(b.payload),
             "equal varint widths are what isolate payload_sha256"

      assert a.encoded_size == b.encoded_size
      assert a.uncompressed_size == b.uncompressed_size

      refute a.payload == b.payload
      refute a.payload_sha256 == b.payload_sha256
      refute SemanticDigest.compute(a) == SemanticDigest.compute(b)

      # ISOLATION PROVEN MECHANICALLY. Normalizing the one permitted difference and everything
      # derived from it must leave the records EQUAL -- so a second difference introduced by a
      # future regeneration fails here instead of quietly weakening every assertion above.
      assert normalize_observed(a) == normalize_observed(b),
             "the pair differs in more than observed_at_unix_nano; the control is not isolated"
    end

    test "a framed capability nanosecond moves the digest on its own" do
      # DIGEST-ONLY, NOT AN ADMISSION CASE. Retaining a signature over a moved timestamp makes
      # the record cryptographically invalid; neither member is expected to be admitted. The
      # field is named because "a capability timestamp" could otherwise be implemented against
      # DELIVERY authority, which the semantic envelope excludes -- and would show no movement.
      a = record("canonical_hash_capability_128.bin")
      b = record("canonical_hash_capability_999.bin")

      assert a.production_capability.not_before_unix_nano == 128
      assert b.production_capability.not_before_unix_nano == 999

      assert a.payload == b.payload
      assert a.payload_sha256 == b.payload_sha256
      assert a.production_capability.signature == b.production_capability.signature

      assert a.production_capability.expires_at_unix_nano ==
               b.production_capability.expires_at_unix_nano

      refute SemanticDigest.compute(a) == SemanticDigest.compute(b)

      assert normalize_capability(a) == normalize_capability(b),
             "the pair differs in more than not_before_unix_nano; the control is not isolated"
    end

    test "every committed fixture carries a digest matching its own contents" do
      # The generator computes semantic_envelope_sha256 before mutating the capability
      # timestamp unless it reseals, which left both fixtures carrying one STALE digest that
      # matched neither. Every other assertion recomputes, so nothing noticed.
      for name <- [
            "canonical_hash_observed_128.bin",
            "canonical_hash_observed_999.bin",
            "canonical_hash_capability_128.bin",
            "canonical_hash_capability_999.bin"
          ] do
        r = record(name)

        assert r.semantic_envelope_sha256 == SemanticDigest.compute(r),
               "#{name} carries a semantic_envelope_sha256 that does not match its contents"
      end
    end
  end

  defp normalize_observed(%EdgeRecordV1{} = r) do
    batch = MtrTraceBatchV1.decode(r.payload)
    [trace] = batch.traces

    payload =
      %{batch | traces: [%{trace | observed_at_unix_nano: 0}]}
      |> MtrTraceBatchV1.encode()
      |> IO.iodata_to_binary()

    %{
      r
      | payload: payload,
        encoded_size: byte_size(payload),
        uncompressed_size: byte_size(payload),
        payload_sha256: nil,
        semantic_envelope_sha256: nil
    }
  end

  defp normalize_capability(%EdgeRecordV1{} = r) do
    %{
      r
      | production_capability: %{r.production_capability | not_before_unix_nano: 0},
        semantic_envelope_sha256: nil
    }
  end

  # The MTR body decodes from the payload, which is uncompressed in these controls.
  defp observed_nanos(%EdgeRecordV1{payload: payload}) do
    batch = MtrTraceBatchV1.decode(payload)
    [trace] = batch.traces
    trace.observed_at_unix_nano
  end

  defp record(name), do: name |> fixture() |> File.read!() |> EdgeRecordV1.decode()
end
