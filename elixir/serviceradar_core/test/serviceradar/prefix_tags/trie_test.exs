defmodule ServiceRadar.PrefixTags.TrieTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadar.PrefixTags.Trie

  describe "lookup/2 LPM chain" do
    test "overlapping prefixes return full chain most-specific first" do
      trie =
        Trie.build([
          %{prefix: "10.1.0.0/16", tags: ["site:austin"], source: "manual"},
          %{prefix: "10.1.2.0/24", tags: ["role:guest-wifi"], source: "manual"}
        ])

      chain = Trie.lookup(trie, "10.1.2.3")
      tags = Enum.flat_map(chain, & &1.tags)

      assert tags == ["role:guest-wifi", "site:austin"]
      assert hd(chain).prefix == "10.1.2.0/24"
      assert List.last(chain).prefix == "10.1.0.0/16"
    end

    test "no matching prefix returns empty list" do
      trie = Trie.build([%{prefix: "10.0.0.0/8", tags: ["internal"]}])
      assert Trie.lookup(trie, "192.168.1.1") == []
    end

    test "exact host /32 match" do
      trie = Trie.build([%{prefix: "203.0.113.10/32", tags: ["host:lab-gw"]}])
      assert [%{tags: ["host:lab-gw"]}] = Trie.lookup(trie, "203.0.113.10")
      assert Trie.lookup(trie, "203.0.113.11") == []
    end

    test "IPv6 LPM" do
      trie =
        Trie.build([
          %{prefix: "2001:db8::/32", tags: ["lab"]},
          %{prefix: "2001:db8:1::/48", tags: ["site:dc1"]}
        ])

      chain = Trie.lookup(trie, "2001:db8:1::5")
      assert Enum.flat_map(chain, & &1.tags) == ["site:dc1", "lab"]
    end

    test "default route /0 matches everything in family" do
      trie = Trie.build([%{prefix: "0.0.0.0/0", tags: ["any"]}])
      assert [%{tags: ["any"]}] = Trie.lookup(trie, "8.8.8.8")
    end

    test "stats report counts" do
      trie =
        Trie.build([
          %{prefix: "10.0.0.0/8", tags: ["a"]},
          %{prefix: "2001:db8::/32", tags: ["b"]}
        ])

      assert Trie.stats(trie) == %{
               ipv4_prefixes: 1,
               ipv6_prefixes: 1,
               total_prefixes: 2
             }
    end

    test "invalid IP yields empty" do
      trie = Trie.build([%{prefix: "10.0.0.0/8", tags: ["a"]}])
      assert Trie.lookup(trie, "not-an-ip") == []
    end

    test "same prefix with distinct VRFs both match (no clobber)" do
      trie =
        Trie.build([
          %{prefix: "10.0.0.0/8", tags: ["vrf:a"], vrf: "corp", source: "netbox"},
          %{prefix: "10.0.0.0/8", tags: ["vrf:b"], vrf: "guest", source: "netbox"}
        ])

      chain = Trie.lookup(trie, "10.1.2.3")
      tags = chain |> Enum.flat_map(& &1.tags) |> Enum.sort()
      vrfs = chain |> Enum.map(& &1.vrf) |> Enum.sort()

      assert tags == ["vrf:a", "vrf:b"]
      assert vrfs == ["corp", "guest"]
      assert Trie.stats(trie).ipv4_prefixes == 2
    end

    test "same prefix+vrf merges tags instead of dropping" do
      trie =
        Trie.build([
          %{prefix: "10.0.0.0/8", tags: ["a"], vrf: "corp"},
          %{prefix: "10.0.0.0/8", tags: ["b"], vrf: "corp"}
        ])

      chain = Trie.lookup(trie, "10.1.2.3")
      assert length(chain) == 1
      assert Enum.sort(hd(chain).tags) == ["a", "b"]
      assert Trie.stats(trie).ipv4_prefixes == 1
    end
  end

  describe "LPM equivalence vs SQL masklen oracle" do
    test "randomized IPv4 prefix sets match oracle ordering" do
      # Pure Elixir oracle mirrors: inet <<= cidr ORDER BY masklen DESC
      for seed <- 1..20 do
        :rand.seed(:exsss, {seed, seed * 2, seed * 3})
        rows = random_ipv4_rows(8)
        trie = Trie.build(rows)
        ip = random_ipv4()

        trie_prefixes = Enum.map(Trie.lookup(trie, ip), & &1.prefix)
        oracle_prefixes = oracle_match(rows, ip)

        assert trie_prefixes == oracle_prefixes,
               "seed=#{seed} ip=#{ip}\ntrie=#{inspect(trie_prefixes)}\noracle=#{inspect(oracle_prefixes)}"
      end
    end
  end

  describe "Store persistent_term swap" do
    setup do
      on_exit(fn -> Store.clear() end)
      Store.clear()
      :ok
    end

    test "lookup hits active snapshot" do
      Store.put_rows([%{prefix: "10.0.0.0/8", tags: ["internal"], source: "manual"}])
      assert [%{tags: ["internal"]}] = Store.lookup("10.1.2.3")
    end

    test "IPv4-mapped IPv6 addresses match IPv4 prefixes" do
      Store.put_rows("manual", [
        %{prefix: "10.1.2.0/24", tags: ["site:lab"], source: "manual"}
      ])

      assert [%{tags: ["site:lab"]}] = Store.lookup("::ffff:10.1.2.3")
    end

    test "concurrent first-time source registrations keep all sources" do
      parent = self()

      for src <- ["manual", "provider", "ti"] do
        spawn(fn ->
          Store.put_rows(src, [%{prefix: "10.0.0.0/8", tags: [src], source: src}])
          send(parent, :done)
        end)
      end

      for _ <- 1..3, do: assert_receive(:done, 2_000)

      sources = MapSet.new(Store.sources())
      assert MapSet.subset?(MapSet.new(["manual", "provider", "ti"]), sources)

      chain = Store.lookup("10.1.2.3")
      assert length(chain) == 3
      assert Enum.sort(Enum.map(chain, & &1.source)) == ["manual", "provider", "ti"]
    end

    test "dynamically named sources appear in sources/0 and aggregate lookup" do
      Store.put_rows("custom", [
        %{prefix: "203.0.113.0/24", tags: ["custom:zone"], source: "custom"}
      ])

      assert Store.loaded?("custom")
      assert "custom" in Store.sources()
      assert [%{tags: ["custom:zone"], source: "custom"}] = Store.lookup("203.0.113.10")
      assert Store.lookup("203.0.113.10", "custom") != []

      Store.clear()
      refute "custom" in Store.sources()
      assert Store.lookup("203.0.113.10") == []
    end

    test "an explicit clear is not loaded while a registered empty snapshot is" do
      Store.put_rows("provider", [])
      assert Store.loaded?("provider")

      Store.clear("provider")
      refute Store.loaded?("provider")
    end

    test "source registry survives the process that first registered a source" do
      parent = self()

      # Ephemeral process registers a custom source then exits (old bug: its
      # caller-owned ETS table vanished on exit). With no supervised Registry,
      # aggregate lookup falls back to the persistent registration handle.
      spawn(fn ->
        Store.put_rows("ephemeral", [
          %{prefix: "198.51.100.0/24", tags: ["ephemeral:zone"], source: "ephemeral"}
        ])

        send(parent, :registered)
      end)

      assert_receive :registered, 2_000
      # Give the owner process time to fully exit.
      Process.sleep(50)

      assert "ephemeral" in Store.sources()
      assert Store.lookup("198.51.100.10") != []
      assert Store.lookup("198.51.100.10", "ephemeral") != []
    end

    test "snapshot swap under concurrent lookups" do
      Store.put_rows("manual", [%{prefix: "10.0.0.0/8", tags: ["v1"], source: "manual"}])

      parent = self()

      readers =
        for i <- 1..20 do
          spawn(fn ->
            results =
              for _ <- 1..200 do
                Store.lookup("10.1.2.3")
              end

            send(parent, {:done, i, results})
          end)
        end

      # Mid-flight swap
      Process.sleep(5)
      Store.put_rows("manual", [%{prefix: "10.0.0.0/8", tags: ["v2"], source: "manual"}])

      for _ <- readers do
        assert_receive {:done, _i, results}, 5_000

        for chain <- results do
          tags = Enum.flat_map(chain, & &1.tags)
          # Spec: concurrent swap never yields an empty chain for a covered IP.
          assert tags in [["v1"], ["v2"]]
        end
      end

      assert [%{tags: ["v2"]}] = Store.lookup("10.1.2.3")
    end

    test "unchanged rows retain the active trie without another swap" do
      handler_id = "prefix-tags-unchanged-swap-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:serviceradar, :prefix_tags, :swap],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:prefix_tags_swap, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      rows = [
        %{prefix: "203.0.113.0/24", tags: ["provider:fixture"], source: "provider"}
      ]

      version = Store.put_rows("provider", rows)
      assert_receive {:prefix_tags_swap, %{source: "provider", version: ^version}}

      assert Store.put_rows("provider", rows) == version
      refute_receive {:prefix_tags_swap, %{source: "provider"}}, 100
      assert [%{tags: ["provider:fixture"]}] = Store.lookup("203.0.113.10", "provider")
    end

    test "changed rows replace the active trie after an unchanged input" do
      first = [%{prefix: "203.0.113.0/24", tags: ["provider:first"], source: "provider"}]
      second = [%{prefix: "203.0.113.0/24", tags: ["provider:second"], source: "provider"}]

      version = Store.put_rows("provider", first)
      assert Store.put_rows("provider", first) == version
      assert Store.put_rows("provider", second) == version + 1
      assert [%{tags: ["provider:second"]}] = Store.lookup("203.0.113.10", "provider")
    end

    test "per-source swap leaves other sources untouched" do
      Store.put_rows("provider", [
        %{prefix: "10.0.0.0/8", tags: ["provider:aws"], source: "provider"}
      ])

      Store.put_rows("netbox", [
        %{prefix: "10.1.2.0/24", tags: ["site:austin"], source: "netbox"}
      ])

      before_provider = Store.active_version("provider")

      Store.put_rows("netbox", [
        %{prefix: "10.1.2.0/24", tags: ["site:austin-dc"], source: "netbox"}
      ])

      assert Store.active_version("provider") == before_provider

      chain = Store.lookup("10.1.2.3")
      tags = Enum.flat_map(chain, & &1.tags)
      assert "site:austin-dc" in tags
      assert "provider:aws" in tags
      # More-specific /24 before /8
      assert hd(tags) == "site:austin-dc"
    end

    test "stats report per-source breakdown" do
      Store.put_rows("manual", [%{prefix: "10.0.0.0/8", tags: ["a"], source: "manual"}])
      Store.put_rows("netbox", [%{prefix: "2001:db8::/32", tags: ["b"], source: "netbox"}])

      stats = Store.stats()
      assert stats.total_prefixes == 2
      assert stats.sources["manual"].ipv4_prefixes == 1
      assert stats.sources["netbox"].ipv6_prefixes == 1
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp random_ipv4_rows(n) do
    for i <- 1..n do
      a = :rand.uniform(223)
      b = :rand.uniform(255) - 1
      c = :rand.uniform(255) - 1
      mask = Enum.random([8, 12, 16, 20, 24])
      prefix = network_string({a, b, c, 0}, mask)
      %{prefix: prefix, tags: ["t#{i}"], source: "test"}
    end
  end

  defp random_ipv4 do
    a = :rand.uniform(223)
    b = :rand.uniform(256) - 1
    c = :rand.uniform(256) - 1
    d = :rand.uniform(256) - 1
    {a, b, c, d} |> :inet.ntoa() |> to_string()
  end

  defp oracle_match(rows, ip_str) do
    {:ok, ip} = :inet.parse_address(String.to_charlist(ip_str))

    rows
    |> Enum.filter(fn %{prefix: p} -> ip_in_prefix?(ip, p) end)
    |> Enum.sort_by(fn %{prefix: p} -> -masklen(p) end)
    |> Enum.map(fn %{prefix: p} -> normalize_prefix_string(p) end)
  end

  defp ip_in_prefix?(ip, prefix) do
    {net, mask} = parse_prefix_parts(prefix)
    {:ok, net_bits} = address_bits(net)
    {:ok, ip_bits} = address_bits(ip)
    Enum.take(net_bits, mask) == Enum.take(ip_bits, mask)
  end

  defp masklen(prefix) do
    {_net, mask} = parse_prefix_parts(prefix)
    mask
  end

  defp parse_prefix_parts(prefix) do
    [addr, mask_s] = String.split(prefix, "/", parts: 2)
    {:ok, net} = :inet.parse_address(String.to_charlist(addr))
    {mask, ""} = Integer.parse(mask_s)
    {net, mask}
  end

  defp normalize_prefix_string(prefix) do
    {net, mask} = parse_prefix_parts(prefix)
    network_string(net, mask)
  end

  defp network_string(addr, mask) do
    {:ok, bits} = address_bits(addr)
    family = if tuple_size(addr) == 4, do: :ipv4, else: :ipv6
    width = if family == :ipv4, do: 32, else: 128
    net_bits = Enum.take(bits, mask) ++ List.duplicate(0, width - mask)
    net_addr = bits_to_tuple(net_bits, family)
    ip = net_addr |> :inet.ntoa() |> to_string()
    "#{ip}/#{mask}"
  end

  defp address_bits({a, b, c, d}) do
    bits =
      for byte <- [a, b, c, d],
          shift <- 7..0//-1,
          do: Bitwise.&&&(Bitwise.>>>(byte, shift), 1)

    {:ok, bits}
  end

  defp address_bits({a, b, c, d, e, f, g, h}) do
    bits =
      for part <- [a, b, c, d, e, f, g, h],
          byte <- [Bitwise.&&&(Bitwise.>>>(part, 8), 0xFF), Bitwise.&&&(part, 0xFF)],
          shift <- 7..0//-1,
          do: Bitwise.&&&(Bitwise.>>>(byte, shift), 1)

    {:ok, bits}
  end

  defp bits_to_tuple(bits, :ipv4) do
    bits
    |> Enum.chunk_every(8)
    |> Enum.map(fn chunk -> Enum.reduce(chunk, 0, fn bit, acc -> acc * 2 + bit end) end)
    |> List.to_tuple()
  end

  defp bits_to_tuple(bits, :ipv6) do
    bits
    |> Enum.chunk_every(16)
    |> Enum.map(fn chunk -> Enum.reduce(chunk, 0, fn bit, acc -> acc * 2 + bit end) end)
    |> List.to_tuple()
  end
end
