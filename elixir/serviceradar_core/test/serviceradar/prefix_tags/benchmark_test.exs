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
    # Keep the default suite fast: full 500k only when explicitly requested.
    prefix_count =
      case System.get_env("PREFIX_TAG_BENCH_SIZE") do
        nil -> 5_000
        raw -> String.to_integer(raw)
      end

    rows = build_rows(prefix_count)
    build_us = timed_us(fn -> Trie.build(rows) end)
    trie = Trie.build(rows)

    assert Trie.stats(trie).total_prefixes == prefix_count

    ips = for i <- 1..1_000, do: "10.#{rem(i, 250)}.#{rem(div(i, 250), 250)}.#{rem(i, 250)}"

    lookup_us =
      timed_us(fn ->
        Enum.each(ips, fn ip -> _ = Trie.lookup(trie, ip) end)
      end)

    lookups_per_sec = 1_000 / (lookup_us / 1_000_000)

    swap_us =
      timed_us(fn ->
        Store.put_trie(trie)
        Store.put_rows(Enum.take(rows, min(100, prefix_count)))
      end)

    # Soft gates: pure Elixir should easily clear these on modern hardware.
    # Failures mean we revisit the Rustler NIF decision (design.md M1 gate).
    assert lookups_per_sec > 10_000,
           "lookup throughput too low: #{Float.round(lookups_per_sec, 1)}/s " <>
             "(build=#{build_us}us, lookups=#{lookup_us}us, n=#{prefix_count})"

    assert swap_us < 500_000,
           "persistent_term snapshot swap too slow: #{swap_us}us"

    IO.puts("""

    PrefixTags benchmark (n=#{prefix_count})
      build:          #{build_us} µs
      1000 lookups:   #{lookup_us} µs (#{Float.round(lookups_per_sec, 0)}/s)
      snapshot swap:  #{swap_us} µs
    """)
  end

  defp build_rows(n) do
    for i <- 0..(n - 1) do
      a = rem(div(i, 65_536), 223) + 1
      b = rem(div(i, 256), 256)
      c = rem(i, 256)
      mask = Enum.at([16, 20, 24, 28], rem(i, 4))

      %{
        prefix: "#{a}.#{b}.#{c}.0/#{mask}",
        tags: ["bench:#{rem(i, 64)}"],
        source: "bench"
      }
    end
  end

  defp timed_us(fun) do
    {us, _} = :timer.tc(fun)
    us
  end
end
