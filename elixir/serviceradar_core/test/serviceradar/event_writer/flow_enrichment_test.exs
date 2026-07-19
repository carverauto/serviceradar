defmodule ServiceRadar.EventWriter.FlowEnrichmentTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.EventWriter.FlowEnrichment
  alias ServiceRadar.PrefixTags.Store

  setup do
    previous_flag = Application.get_env(:serviceradar_core, :prefix_tag_enrichment_enabled)

    on_exit(fn ->
      restore_env(:prefix_tag_enrichment_enabled, previous_flag)
      Store.clear()
    end)

    Store.clear()
    :ok
  end

  describe "decode_tcp_flags/1" do
    test "decodes SYN+ACK" do
      assert FlowEnrichment.decode_tcp_flags(18) == ["ACK", "SYN"]
    end

    test "returns empty for nil" do
      assert FlowEnrichment.decode_tcp_flags(nil) == []
    end
  end

  describe "service_label/2" do
    test "maps common TCP ports" do
      assert FlowEnrichment.service_label(6, 443) == "HTTPS"
      assert FlowEnrichment.service_label(6, 4222) == "NATS"
    end

    test "maps common UDP ports" do
      assert FlowEnrichment.service_label(17, 53) == "DNS"
      assert FlowEnrichment.service_label(17, 6343) == "sFlow"
    end

    test "maps fallback labels from the bundled services registry" do
      assert FlowEnrichment.service_label(6, 4369) == "EPMD"
    end
  end

  describe "direction_label/2" do
    test "classifies bidirectional" do
      assert FlowEnrichment.direction_label(100, 200) == "bidirectional"
    end

    test "classifies ingress" do
      assert FlowEnrichment.direction_label(100, 0) == "ingress"
    end

    test "classifies egress" do
      assert FlowEnrichment.direction_label(0, 100) == "egress"
    end
  end

  describe "normalize_mac/1" do
    test "normalizes separators and prefix length" do
      assert FlowEnrichment.normalize_mac("00:11:22:33:44:55") == "001122334455"
      assert FlowEnrichment.normalize_mac("0011.2233.4455/24") == "001122334455"
    end
  end

  describe "enrich/1" do
    test "enriches core protocol/port/tcp/direction fields without database lookups" do
      enriched =
        FlowEnrichment.enrich(%{
          protocol_num: 6,
          tcp_flags: 18,
          dst_port: 443,
          bytes_in: 12,
          bytes_out: 45,
          src_ip: "10.0.0.1",
          dst_ip: "10.0.0.2",
          src_mac: "00:11:22:33:44:55",
          dst_mac: "66:77:88:99:aa:bb"
        })

      assert enriched.protocol_name == "TCP"
      assert enriched.protocol_source == "iana"
      assert enriched.tcp_flags_labels == ["ACK", "SYN"]
      assert enriched.dst_service_label == "HTTPS"
      assert enriched.dst_service_source == "iana"
      assert enriched.direction_label == "bidirectional"
      assert enriched.src_mac == "001122334455"
      assert enriched.dst_mac == "66778899AABB"
      refute Map.has_key?(enriched, :src_prefix_tags)
      refute Map.has_key?(enriched, :dst_prefix_tags)
    end

    test "does not mark unknown numeric ports as IANA service matches" do
      enriched =
        FlowEnrichment.enrich(%{
          protocol_num: 6,
          dst_port: 32_760
        })

      assert enriched.dst_service_label == nil
      assert enriched.dst_service_source == "unknown"
    end

    test "when flag is on, attaches most-specific-first prefix tags with provenance" do
      Application.put_env(:serviceradar_core, :prefix_tag_enrichment_enabled, true)

      Store.put_rows([
        %{prefix: "10.1.0.0/16", tags: ["site:austin"], source: "netbox"},
        %{prefix: "10.1.2.0/24", tags: ["role:guest-wifi"], source: "netbox"}
      ])

      enriched =
        FlowEnrichment.enrich(%{
          protocol_num: 6,
          dst_port: 443,
          src_ip: "192.0.2.1",
          dst_ip: "10.1.2.3"
        })

      assert enriched.dst_prefix_tags == ["role:guest-wifi", "site:austin"]
      assert enriched.dst_prefix_tags_source == "netbox"
      assert enriched.src_prefix_tags == nil
      assert enriched.src_prefix_tags_source == nil
    end

    test "lookup engine error is fail-open (untagged, no raise)" do
      Application.put_env(:serviceradar_core, :prefix_tag_enrichment_enabled, true)
      Application.put_env(:serviceradar_core, :prefix_tags_engine, __MODULE__.BoomEngine)

      on_exit(fn ->
        Application.delete_env(:serviceradar_core, :prefix_tags_engine)
      end)

      # Install a version so active_trie is non-nil and engine is consulted.
      Store.put_trie("manual", :boom)

      enriched =
        FlowEnrichment.enrich(%{
          protocol_num: 6,
          src_ip: "10.0.0.1",
          dst_ip: "10.0.0.2"
        })

      assert enriched.src_prefix_tags == nil
      assert enriched.dst_prefix_tags == nil
    end

    test "provider trie flag serves hosting provider without SQL path" do
      Application.put_env(:serviceradar_core, :prefix_tag_provider_trie_enabled, true)

      on_exit(fn ->
        Application.put_env(:serviceradar_core, :prefix_tag_provider_trie_enabled, false)
      end)

      Store.put_rows("provider", [
        %{prefix: "203.0.113.0/24", tags: ["provider:ExampleCloud"], source: "provider"}
      ])

      assert FlowEnrichment.provider_for_ip("203.0.113.10") == "ExampleCloud"
      assert FlowEnrichment.provider_for_ip("198.51.100.1") == nil
    end

    test "geo tag derivation is fail-open when MMDB absent" do
      Application.put_env(:serviceradar_core, :prefix_tag_enrichment_enabled, true)
      Application.put_env(:serviceradar_core, :geo_tag_derivation_enabled, true)

      on_exit(fn ->
        Application.put_env(:serviceradar_core, :geo_tag_derivation_enabled, false)
      end)

      # No MMDB in unit tests — must not raise and must leave untagged or trie-only.
      enriched =
        FlowEnrichment.enrich(%{
          protocol_num: 6,
          src_ip: "8.8.8.8",
          dst_ip: "1.1.1.1"
        })

      assert is_map(enriched)
      # geo tags may be nil/absent when lookup fails
      refute Map.get(enriched, :src_prefix_tags) in [["geo:country:us"]]
    end
  end

  defmodule BoomEngine do
    @behaviour ServiceRadar.PrefixTags.Engine

    def build(_), do: :boom
    def lookup(_trie, _ip), do: raise("boom")
    def stats(_), do: %{ipv4_prefixes: 0, ipv6_prefixes: 0, total_prefixes: 0}
  end

  describe "with_provider_cache/2" do
    test "deduplicates provider lookups within the scoped batch cache" do
      calls = start_supervised!({Agent, fn -> [] end})

      lookup = fn %Postgrex.INET{} = inet ->
        key = inet_key(inet)
        Agent.update(calls, &[key | &1])
        "provider:#{key}"
      end

      result =
        FlowEnrichment.with_provider_cache(
          fn ->
            [
              FlowEnrichment.provider_for_ip(" 203.0.113.10 "),
              FlowEnrichment.provider_for_ip("203.0.113.10"),
              FlowEnrichment.provider_for_ip("2001:DB8::1"),
              FlowEnrichment.provider_for_ip("2001:db8:0:0:0:0:0:1"),
              FlowEnrichment.provider_for_ip("198.51.100.8")
            ]
          end,
          provider_lookup: lookup
        )

      assert result == [
               "provider:203.0.113.10/32",
               "provider:203.0.113.10/32",
               "provider:2001:db8::1/128",
               "provider:2001:db8::1/128",
               "provider:198.51.100.8/32"
             ]

      assert Agent.get(calls, &Enum.reverse/1) == [
               "203.0.113.10/32",
               "2001:db8::1/128",
               "198.51.100.8/32"
             ]
    end
  end

  defp inet_key(%Postgrex.INET{address: address, netmask: netmask}) do
    "#{address |> :inet.ntoa() |> to_string()}/#{netmask}"
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
