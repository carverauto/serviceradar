defmodule ServiceRadar.PrefixTags.NativeEngineTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.PrefixTags.Native
  alias ServiceRadar.PrefixTags.NativeEngine
  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadar.PrefixTags.Trie

  defmodule NoBuildEngine do
    @moduledoc false
    def build(_), do: raise("unchanged snapshot rebuilt")
    defdelegate stats(resource), to: NativeEngine
    defdelegate lookup(resource, ip), to: NativeEngine
  end

  setup do
    previous = Application.get_env(:serviceradar_core, :prefix_tags_engine)
    Application.put_env(:serviceradar_core, :prefix_tags_engine, NativeEngine)
    Store.clear()

    on_exit(fn ->
      Store.clear()

      if previous,
        do: Application.put_env(:serviceradar_core, :prefix_tags_engine, previous),
        else: Application.delete_env(:serviceradar_core, :prefix_tags_engine)
    end)
  end

  test "native snapshots match the Elixir chain and structured metadata contract" do
    rows = [
      %{prefix: "0.0.0.0/0", tags: ["default"]},
      %{
        prefix: "192.0.2.19/24",
        tags: ["a"],
        source: "manual",
        severity: 2,
        indicator_count: 1,
        expires_at: ~U[2030-01-01 00:00:00.123Z],
        feed_sources: ["alpha"]
      },
      %{
        prefix: "192.0.2.99/24",
        tags: ["a", "b"],
        source: "manual",
        severity: 4,
        indicator_count: 2,
        expires_at: ~U[2030-02-01 00:00:00Z],
        feed_sources: ["beta"]
      },
      %{prefix: "192.0.2.0/24", vrf: "isolated", tags: ["variant"]},
      %{prefix: "192.0.2.7/32", tags: ["host"]},
      %{prefix: "2001:db8::/32", tags: ["v6"]},
      %{prefix: "2001:db8:1::/48", tags: ["nested"]},
      %{prefix: "2001:db8:1::1/128", tags: ["host6"]},
      %{prefix: "bad-prefix", tags: ["ignored"]},
      %{"prefix" => "198.51.100.9", "tags" => "single"}
    ]

    native = NativeEngine.build(rows)
    elixir = Trie.build(rows)
    assert is_reference(native)
    assert NativeEngine.stats(native) == Trie.stats(elixir)

    for ip <- [
          "192.0.2.7",
          "192.0.2.80",
          "::ffff:192.0.2.7",
          {192, 0, 2, 7},
          "2001:db8:1::1",
          "2001:db8:2::1",
          "198.51.100.9",
          "203.0.113.3",
          "bad",
          nil
        ] do
      assert NativeEngine.lookup(native, ip) == Trie.lookup(elixir, ip)
    end
  end

  test "member expiry survives the boundary without losing precision" do
    member = %{
      source: "feed",
      source_slug: "feed",
      severity: 3,
      expires_at: ~U[2030-01-01 00:00:00.123Z],
      indicator_count: 1,
      tags: ["ti:feed"]
    }

    rows = [
      %{prefix: "192.0.2.0/24", tags: ["ti:feed"], indicators: [member]},
      %{
        prefix: "192.0.2.0/24",
        tags: ["ti:peer"],
        indicators: [%{member | source: "peer", expires_at: nil}]
      }
    ]

    assert NativeEngine.lookup(NativeEngine.build(rows), "192.0.2.1") ==
             Trie.lookup(Trie.build(rows), "192.0.2.1")
  end

  test "fingerprint skip calls no builder and swaps preserve old resources" do
    rows = [%{prefix: "192.0.2.0/24", tags: ["old"]}]
    version = Store.put_rows("manual", rows)
    old = Store.active_trie("manual")
    Application.put_env(:serviceradar_core, :prefix_tags_engine, NoBuildEngine)
    assert Store.put_rows("manual", rows) == version
    assert Store.active_trie("manual") == old
    Application.put_env(:serviceradar_core, :prefix_tags_engine, NativeEngine)
    assert Store.put_rows("manual", [%{prefix: "192.0.2.0/24", tags: ["new"]}]) == version + 1
    assert [%{tags: ["old"]}] = NativeEngine.lookup(old, "192.0.2.1")
    assert [%{tags: ["new"]}] = Store.lookup("192.0.2.1", "manual")
  end

  test "concurrent publications expose complete generations and keep held resources alive" do
    Store.put_rows("manual", [%{prefix: "192.0.2.0/24", tags: ["original"]}])
    original = Store.active_trie("manual")

    writers =
      for writer <- 1..4 do
        Task.async(fn ->
          for generation <- 1..10 do
            tag = "generation:#{writer}:#{generation}"

            Store.put_rows("manual", [
              %{prefix: "192.0.2.0/24", tags: [tag]},
              %{prefix: "192.0.2.1/32", tags: [tag]}
            ])

            assert [%{tags: [same]}, %{tags: [same]}] = Store.lookup("192.0.2.1", "manual")
          end
        end)
      end

    Enum.each(writers, &Task.await(&1, 15_000))
    assert [%{tags: ["original"]}] = NativeEngine.lookup(original, "192.0.2.1")
  end

  test "finalized and panicked builders cannot be appended or published again" do
    assert {:ok, builder} = Native.new_builder()
    assert {:ok, snapshot} = Native.finish(builder)
    assert {:error, _} = Native.append(builder, [])
    assert {:error, _} = Native.finish(builder)
    assert NativeEngine.lookup(snapshot, "192.0.2.1") == []

    assert {:ok, failing} = Native.new_builder()
    # Count overflow is a real checked native failure, not a test-only panic hook.
    row = %{
      prefix: "192.0.2.0/24",
      tags: [],
      source: nil,
      vrf: nil,
      severity: nil,
      indicator_count: 18_446_744_073_709_551_615,
      expires_at: nil,
      feed_sources: nil,
      indicators: nil
    }

    assert {:ok, true} = Native.append(failing, [row])

    assert {:error, "prefix trie operation panicked"} =
             Native.append(failing, [%{row | indicator_count: 1}])

    assert {:error, _} = Native.finish(failing)
    assert {:error, _} = Native.append(failing, [])
  end

  @tag timeout: 120_000
  test "a mostly IPv6 provider-scale stream keeps the builder BEAM heap bounded" do
    parent = self()
    started = System.monotonic_time(:millisecond)

    {pid, monitor} =
      spawn_monitor(fn ->
        rows =
          Stream.map(0..262_143, fn id ->
            %{
              prefix:
                "2001:db8:#{Integer.to_string(div(id, 65_536), 16)}:#{Integer.to_string(rem(id, 65_536), 16)}::/64",
              tags: ["provider:example"]
            }
          end)

        resource = NativeEngine.build(rows)
        send(parent, {:built, self(), resource})
      end)

    {resource, peak} = await_build(pid, monitor, 0, System.monotonic_time(:millisecond) + 110_000)
    assert is_reference(resource)
    assert NativeEngine.stats(resource).total_prefixes == 262_144
    assert [%{tags: ["provider:example"]}] = NativeEngine.lookup(resource, "2001:db8:3:ffff::1")

    IO.puts(
      "native prefix build: 262144 rows, #{System.monotonic_time(:millisecond) - started}ms, peak builder BEAM #{peak} bytes"
    )

    assert peak < 64 * 1024 * 1024, "builder BEAM memory peaked at #{peak} bytes"
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  defp await_build(pid, monitor, peak, deadline) do
    peak =
      case Process.info(pid, :memory) do
        {:memory, memory} -> max(peak, memory)
        nil -> peak
      end

    receive do
      {:built, ^pid, resource} ->
        {resource, peak}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        flunk("native builder exited: #{inspect(reason)}")
    after
      1 ->
        if System.monotonic_time(:millisecond) >= deadline do
          Process.exit(pid, :kill)
          flunk("native builder exceeded deadline")
        end

        await_build(pid, monitor, peak, deadline)
    end
  end
end
