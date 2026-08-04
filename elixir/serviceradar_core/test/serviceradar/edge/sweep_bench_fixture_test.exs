defmodule ServiceRadar.Edge.SweepBenchFixtureTest do
  @moduledoc """
  The TIMING-FREE verifier for the body-pipeline benchmark fixtures (task 1.17-c).

  The benchmark script itself is not a gate and must not be: shared-runner milliseconds are
  too noisy. But its EVIDENCE fails open without this. The script prints a digest mismatch
  and carries on, and a fixture that degrades into an early rejection gets CHEAPER, so it
  reads as a speedup rather than as a broken measurement. That had already happened twice --
  the mixed fixture named one TCP bit while referencing two TCP checks, and its MTR trace
  ids overflowed the signed window.

  So this test, which the required workflow runs, pins three things with no timing at all:

    1. the Elixir generator produces EXACTLY the manifest's fixture set,
    2. byte-for-byte the digests Go recorded, and
    3. every fixture reaches the OUTCOME its measurement assumes.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Bench.SweepIngressFixtures
  alias ServiceRadar.Edge.SweepBodyValidate
  alias ServiceRadar.Edge.SweepCorrelate
  alias Serviceradar.Edge.V1, as: V1
  alias ServiceRadar.Edge.WireDecode

  @manifest Path.expand(
              "../../../../../proto/edge/v1/testdata/sweep_bench_manifest.txt",
              __DIR__
            )

  @external_resource @manifest
  @fixture_generator Path.expand("../../../bench/sweep_ingress_fixtures.exs", __DIR__)
  @external_resource @fixture_generator

  Code.require_file(@fixture_generator)

  # ONLY the expected outcomes are stated here. The fixture SET comes from the shared
  # generator's `matrix/0` -- restating it would be a second hand-written list, and two
  # hand-written lists agreeing proves only that one author wrote both.
  @expected %{
    "hosts_1" => :ok,
    "hosts_100" => :ok,
    "hosts_1000" => :ok,
    "hosts_2000" => :ok,
    "hosts_2000_mixed" => :ok,
    "hosts_2000_invalid_last" => {:error, {:address, :length}},
    "hosts_2001_over_ceiling" => {:error, {:bounds, :hosts}}
  }

  # {name, hosts, mixed?, invalid_last?, expected outcome}, derived not restated.
  defp fixtures do
    for {name, hosts, mixed?, invalid?} <- SweepIngressFixtures.matrix() do
      {name, hosts, mixed?, invalid?, Map.fetch!(@expected, name)}
    end
  end

  defp manifest do
    @manifest
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [name, hosts, digest, len] = String.split(line)
      {name, {String.to_integer(hosts), digest, String.to_integer(len)}}
    end)
  end

  # The SHARED generator. `mix test` does not load `bench/`, so it is required explicitly --
  # and requiring the same file the benchmark uses is the point: a verifier with its own copy
  # could pass while the benchmark measured something else.
  defp build(hosts, mixed?, invalid_last?),
    do: SweepIngressFixtures.batch(hosts, mixed?, invalid_last?)

  test "the generator produces EXACTLY the manifest's fixture set" do
    names = MapSet.new(Enum.map(SweepIngressFixtures.matrix(), &elem(&1, 0)))

    assert MapSet.new(Map.keys(manifest())) == names,
           "the two runtimes are not measuring the same fixtures"

    # ...and every fixture has a declared outcome, so a new one cannot be added to the
    # generator without deciding what it is supposed to do.
    assert MapSet.new(Map.keys(@expected)) == names
  end

  test "every fixture matches Go's digest byte-for-byte" do
    m = manifest()

    for {name, hosts, mixed?, invalid_last?, _outcome} <- fixtures() do
      bytes = V1.SweepObservationBatchV1.encode(build(hosts, mixed?, invalid_last?))
      digest = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

      assert {hosts, digest, byte_size(bytes)} == Map.fetch!(m, name),
             "#{name}: the Elixir generator diverged from Go, so the two sides' numbers " <>
               "are not comparable"
    end
  end

  test "every fixture reaches the OUTCOME its measurement assumes" do
    for {name, hosts, mixed?, invalid_last?, want} <- fixtures() do
      batch = build(hosts, mixed?, invalid_last?)
      got = SweepBodyValidate.validate(batch)

      assert got == want,
             "#{name}: body validation = #{inspect(got)}, want #{inspect(want)} -- the " <>
               "benchmark would be measuring different work than it claims"

      # A VALID fixture must also CORRELATE, or stage 3 measures an early refusal, which is
      # cheaper and therefore reads as a speedup.
      if want == :ok do
        assert SweepCorrelate.validate(SweepIngressFixtures.record_for(batch), batch) == :ok,
               "#{name}: correlation refused; stage 3 would not be measuring a full comparison"
      end
    end
  end

  test "EVERY fixture round-trips the decoder and composed path the benchmark times" do
    # Including the body-INVALID ones. The benchmark times `decode` and `composed` for those
    # too, so checking only the valid fixtures left exactly the hole this verifier exists to
    # close: a decode failure, or a changed post-decode outcome, is cheaper and would pass
    # unnoticed. Correlation stays valid-only -- see the outcome test above.
    for {name, hosts, mixed?, invalid_last?, want} <- fixtures() do
      bytes = V1.SweepObservationBatchV1.encode(build(hosts, mixed?, invalid_last?))

      assert {:ok, _} = WireDecode.decode_sweep_batch(bytes),
             "#{name}: decode failed, so the decode stage is timing an error path"

      case want do
        :ok ->
          assert {:ok, _batch} = SweepBodyValidate.validate_bytes(bytes),
                 "#{name}: the composed stage would be measuring a rejection"

        {:error, _} = expected ->
          assert SweepBodyValidate.validate_bytes(bytes) == expected,
                 "#{name}: the composed stage reports a different outcome than the " <>
                   "benchmark's fixture declares"
      end
    end
  end
end
