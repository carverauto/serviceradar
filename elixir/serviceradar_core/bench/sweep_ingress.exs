Code.require_file("sweep_ingress_fixtures.exs", __DIR__)

defmodule ServiceRadar.Bench.SweepIngress do
  @moduledoc """
  The Elixir half of the ONE bounded BODY-PIPELINE benchmark (task 1.17).

  Four stages, the same small fixture matrix as
  `go/pkg/edge/edgerecord/sweep_ingress_benchmark_test.go`, and nothing else. Rejection
  labels, width guards and malformed hand-built structs are correctness tests, not
  benchmarks.

  ## The fixtures are SHARED, and that is checked

  Both runtimes BUILD the bytes from the same documented algorithm and verify them against
  `proto/edge/v1/testdata/sweep_bench_manifest.txt`. Committing ~450 KB of fixtures would be
  worse; a digest per fixture gives the same guarantee. If the two runtimes ever generate
  different bytes their numbers are not comparable, and this fails loudly rather than
  quietly measuring a different workload.

  ## What is NOT claimed

  Stage 3 is the correlation RELATION, not full authorization: it verifies no signature and
  resolves no trust. The composed stage is decode + body validation + correlation, which is
  what the Elixir side performs today -- extraction and crypto join it when 1.5-f and the
  authenticated boundary land.

      MIX_ENV=test mix run --no-start bench/sweep_ingress.exs
  """

  alias ServiceRadar.Bench.SweepIngressFixtures, as: Fixtures
  alias ServiceRadar.Edge.SweepBodyValidate
  alias ServiceRadar.Edge.SweepCorrelate
  alias Serviceradar.Edge.V1, as: V1
  alias ServiceRadar.Edge.WireDecode

  @manifest "../../../proto/edge/v1/testdata/sweep_bench_manifest.txt"

  # Wall-clock samples per stage. P50 AND P95 are reported: on a shared machine the minimum
  # hides exactly the GC-driven tail this harness keeps hitting, so the floor alone would be
  # flattering rather than honest. Reductions are the noise-free companion.
  @samples 25

  @observed_unix_nano 1_700_000_300_000_000_000

  @icmp_bit 1
  @tcp_syn_bit 2
  @tcp_connect_bit 4
  @mtr_bit 8

  def run do
    fixtures = Fixtures.matrix()

    manifest = load_manifest()
    IO.puts("\n== fixture digests (shared with Go) ==")
    encoded = Enum.map(fixtures, &check_fixture(&1, manifest))

    # HEAP GROWTH is a `total_heap_size` DELTA -- occasional capacity growth of the process
    # heap, frequently zero after reuse. It is a DIAGNOSTIC, not words allocated.
    # REDUCTIONS are BEAM-only; Go's peer reports ns/op, B/op and allocs/op instead.
    IO.puts("\n== stages: p50 / p95 wall time, reductions (BEAM), diagnostic heap growth ==")

    IO.puts(
      String.pad_trailing("fixture", 26) <>
        String.pad_trailing("stage", 16) <>
        String.pad_leading("p50 ms", 10) <>
        String.pad_leading("p95 ms", 10) <>
        String.pad_leading("reductions", 14) <>
        String.pad_leading("heap grow", 14) <> "  outcome"
    )

    results =
      for {name, bytes, batch} <- encoded, into: %{} do
        # PREBUILT, like Go's. Constructing the authority record inside the timed function
        # would charge stages 3 and 4 for fixture assembly the Go side does not pay, and the
        # two runtimes' numbers are meant to be comparable.
        record = Fixtures.record_for(batch)

        # APPLICABLE STAGES ONLY. Correlation has a VALID-BODY precondition, so timing it
        # for a body-invalid fixture measures an early refusal -- cheaper, and therefore
        # readable as a speedup, with nothing to catch it: the verifier cannot pin an
        # outcome here without blessing behaviour outside that precondition.
        valid? = SweepBodyValidate.validate(batch) == :ok

        stages =
          [
            {"decode", fn -> WireDecode.decode_sweep_batch(bytes) end},
            {"body_validate", fn -> SweepBodyValidate.validate(batch) end}
          ] ++
            if valid? do
              [{"correlate", fn -> SweepCorrelate.validate(record, batch) end}]
            else
              []
            end ++
            [
              {"composed",
               fn ->
                 case SweepBodyValidate.validate_bytes(bytes) do
                   {:ok, b} -> SweepCorrelate.validate(record, b)
                   other -> other
                 end
               end}
            ]

        measured =
          for {stage, fun} <- stages, into: %{} do
            # A stage that REJECTS is not doing the work the number implies. Recording the
            # outcome stops "fast" from being read as "efficient" when it means "refused
            # on the first host".
            m = Map.put(measure(fun), :outcome, outcome_of(fun.()))
            report(name, stage, m)
            {stage, m}
          end

        {name, measured}
      end

    scaling(results)
    :ok
  end

  # --- fixtures come from the SHARED generator; see sweep_ingress_fixtures.exs ---

  # `outcome_of/1` is REPORTING, not fixture generation: it lives with the benchmark that
  # prints it, not in the generator the verifier shares.
  defp outcome_of(:ok), do: "ok"
  defp outcome_of({:ok, _}), do: "ok"
  defp outcome_of({:error, reason}), do: "REJECTED #{inspect(reason)}"
  defp outcome_of(other), do: inspect(other)

  # --- manifest -------------------------------------------------------------------------

  defp load_manifest do
    path = Path.expand(@manifest, __DIR__)

    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [name, hosts, digest, len] = String.split(line)
      {name, {String.to_integer(hosts), digest, String.to_integer(len)}}
    end)
  end

  defp check_fixture({name, hosts, mixed?, invalid_last?}, manifest) do
    b = Fixtures.batch(hosts, mixed?, invalid_last?)
    bytes = V1.SweepObservationBatchV1.encode(b)
    digest = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

    case Map.fetch(manifest, name) do
      {:ok, {^hosts, ^digest, len}} when len == byte_size(bytes) ->
        IO.puts("  #{String.pad_trailing(name, 26)} OK  #{byte_size(bytes)} bytes")

      {:ok, {_h, want, want_len}} ->
        IO.puts("""
          #{String.pad_trailing(name, 26)} MISMATCH
            got  #{digest} (#{byte_size(bytes)} bytes)
            want #{want} (#{want_len} bytes)
            The two runtimes are generating DIFFERENT bytes; the numbers below are not
            comparable with Go's until this is fixed.
        """)

      :error ->
        IO.puts("  #{String.pad_trailing(name, 26)} MISSING from the manifest")
    end

    {name, bytes, b}
  end

  # --- measurement ----------------------------------------------------------------------

  defp measure(fun) do
    fun.()

    samples =
      for _ <- 1..@samples do
        # REDUCTIONS are the noise-free signal: they count actual work and do not move with
        # machine load, which is why a regression gate should key on them rather than on
        # shared-runner wall time. Heap words are the allocation companion.
        {:reductions, r0} = :erlang.process_info(self(), :reductions)
        {:total_heap_size, m0} = :erlang.process_info(self(), :total_heap_size)
        {us, _} = :timer.tc(fun)
        {:reductions, r1} = :erlang.process_info(self(), :reductions)
        {:total_heap_size, m1} = :erlang.process_info(self(), :total_heap_size)
        {us, r1 - r0, max(m1 - m0, 0)}
      end

    times = samples |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    %{
      p50: percentile(times, 50),
      p95: percentile(times, 95),
      reductions: samples |> Enum.map(&elem(&1, 1)) |> Enum.min(),
      heap_growth: samples |> Enum.map(&elem(&1, 2)) |> Enum.max()
    }
  end

  # Nearest-rank. p50 and p95 rather than a bare minimum, because the minimum hides exactly
  # the GC-driven tail this harness keeps running into.
  defp percentile(sorted, p) do
    idx = max(round(length(sorted) * p / 100) - 1, 0)
    Enum.at(sorted, idx)
  end

  defp report(name, stage, m) do
    IO.puts(
      String.pad_trailing(name, 26) <>
        String.pad_trailing(stage, 16) <>
        String.pad_leading(Float.to_string(Float.round(m.p50 / 1000, 3)), 10) <>
        String.pad_leading(Float.to_string(Float.round(m.p95 / 1000, 3)), 10) <>
        String.pad_leading(Integer.to_string(m.reductions), 14) <>
        String.pad_leading(Integer.to_string(m.heap_growth), 14) <>
        "  " <> m.outcome
    )
  end

  # 1000 -> 2000 hosts is REPORTED against ~2.4x, and gates nothing -- the nightly policy
  # that could act on it belongs to the downstream runtime change. Superlinear REDUCTIONS
  # would mean a nested walk appeared, which is the failure mode worth watching for.
  defp scaling(results) do
    IO.puts(
      "\n== scaling 1000 -> 2000 hosts -- REPORT ONLY (no nightly policy in this change) =="
    )

    a = results["hosts_1000"]
    b = results["hosts_2000"]

    for stage <- ["decode", "body_validate", "correlate", "composed"] do
      t = b[stage].p50 / max(a[stage].p50, 1)
      r = b[stage].reductions / max(a[stage].reductions, 1)

      # REDUCTIONS are the signal worth reading: wall time on a shared machine moves with
      # GC and load -- this harness shows ~3x time against ~2.0x reductions for the same
      # doubling, which is allocation behaviour, not a nested walk. Superlinear REDUCTIONS
      # is what would mean an extra traversal appeared. NOTHING HERE GATES: the nightly
      # policy that could act on it belongs to the downstream runtime change.
      flag =
        cond do
          r > 2.4 -> "  <-- superlinear WORK, worth investigating"
          t > 2.4 -> "  (time only: GC/allocation, work is linear)"
          true -> ""
        end

      IO.puts(
        "  #{String.pad_trailing(stage, 16)} time #{Float.round(t, 2)}x   " <>
          "reductions #{Float.round(r, 2)}x#{flag}"
      )
    end
  end
end

ServiceRadar.Bench.SweepIngress.run()
