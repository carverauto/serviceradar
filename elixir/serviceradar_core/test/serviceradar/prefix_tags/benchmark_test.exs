defmodule ServiceRadar.PrefixTags.BenchmarkTest do
  @moduledoc """
  Lightweight synthetic gate for the pure-Elixir LPM engine.

  Not a full EventWriter P99 bench (that needs a running pipeline). This
  records raw lookup throughput + persistent_term swap cost so we can spot
  regressions and decide if the Rustler NIF path is warranted.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadar.PrefixTags.Trie

  @moduletag :benchmark

  setup do
    on_exit(fn -> Store.clear() end)
    Store.clear()
    :ok
  end

  test "500k-prefix trie supports high lookup throughput and cheap snapshot swap" do
    # Keep the default suite fast: full 500k / multi-source only when requested.
    # PREFIX_TAG_BENCH_SIZE=400000 exercises provider-scale loads.
    prefix_count =
      case System.get_env("PREFIX_TAG_BENCH_SIZE") do
        nil -> 5_000
        raw -> String.to_integer(raw)
      end

    multi? = System.get_env("PREFIX_TAG_BENCH_MULTI_SOURCE") in ["1", "true", "yes"]

    rows = build_rows(prefix_count, "bench")
    build_us = timed_us(fn -> Trie.build(rows) end)
    trie = Trie.build(rows)

    # Synthetic rows can collide after network normalization (e.g. 10.0.1.0/16
    # and 10.0.0.0/16); multi-VRF-aware counting only tallies unique leaves.
    total = Trie.stats(trie).total_prefixes
    assert total > 0
    assert total <= prefix_count

    if multi? do
      # Second source approximates NetBox + provider co-resident tries.
      provider_rows = build_rows(min(prefix_count, 50_000), "provider")
      _ = Store.put_rows("provider", provider_rows)
    end

    ips = for i <- 1..1_000, do: "10.#{rem(i, 250)}.#{rem(div(i, 250), 250)}.#{rem(i, 250)}"

    lookup_us =
      timed_us(fn ->
        Enum.each(ips, fn ip -> _ = Trie.lookup(trie, ip) end)
      end)

    # Merged multi-source Store lookups (when multi bench enabled).
    store_lookup_us =
      if multi? do
        _ = Store.put_trie("bench", trie)

        timed_us(fn ->
          Enum.each(ips, fn ip -> _ = Store.lookup(ip) end)
        end)
      else
        0
      end

    lookups_per_sec = 1_000 / (lookup_us / 1_000_000)

    swap_us =
      timed_us(fn ->
        Store.put_trie("bench", trie)
        Store.put_rows("bench", Enum.take(rows, min(100, prefix_count)))
      end)

    # Soft gates: pure Elixir should easily clear these on modern hardware.
    # Failures mean we revisit the Rustler NIF decision (design.md M1 gate).
    assert lookups_per_sec > 10_000,
           "lookup throughput too low: #{Float.round(lookups_per_sec, 1)}/s " <>
             "(build=#{build_us}us, lookups=#{lookup_us}us, n=#{prefix_count})"

    assert swap_us < 500_000,
           "persistent_term snapshot swap too slow: #{swap_us}us"

    IO.puts("""

    PrefixTags benchmark (n=#{prefix_count}, multi_source=#{multi?})
      build:              #{build_us} µs
      1000 trie lookups:  #{lookup_us} µs (#{Float.round(lookups_per_sec, 0)}/s)
      1000 store lookups: #{store_lookup_us} µs
      snapshot swap:      #{swap_us} µs
    """)
  end

  defp build_rows(n, source) do
    for i <- 0..(n - 1) do
      a = rem(div(i, 65_536), 223) + 1
      b = rem(div(i, 256), 256)
      c = rem(i, 256)
      mask = Enum.at([16, 20, 24, 28], rem(i, 4))

      %{
        prefix: "#{a}.#{b}.#{c}.0/#{mask}",
        tags: ["#{source}:#{rem(i, 64)}"],
        source: source
      }
    end
  end

  defp timed_us(fun) do
    {us, _} = :timer.tc(fun)
    us
  end
end
