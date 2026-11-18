defmodule ServiceRadar.Inventory.RumPolicySyncUnitTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.RumPolicySync
  alias ServiceRadar.PrefixTags.PrefixTag
  alias Serviceradar.Rum.V1.WebPropertyRumPolicySnapshot

  describe "build_snapshot/3" do
    test "serializes web properties, property prefix_tags, and global prefix_tags into protobuf" do
      props = [
        %{
          id: "01900000-0000-7000-8000-000000000001",
          name: "Shop",
          canonical_origin: "https://shop.example.com",
          allowed_origins: ["https://checkout.example.com"],
          allowed_query_keys: ["tab", "page"],
          trace_propagate_origins: ["https://api.example.com"],
          rum_site_key: "sr_rum_aaaaaaaaaaaaaaaa",
          rum_enabled: true,
          rum_sample_rate: 0.5,
          anonymize_client_ip: true,
          environment: :production,
          prefix_tags: [%{"cidr" => "198.51.100.0/24", "tag" => "site:hq-01"}]
        }
      ]

      global_tags = [
        %PrefixTag{prefix: "203.0.113.0/24", tags: ["site:branch-02"], site: "branch-02"},
        %PrefixTag{prefix: "2001:db8:1::/48", tags: [], site: "dc-west"}
      ]

      snapshot = RumPolicySync.build_snapshot(props, global_tags, now_ms: 1_700_000_000_000)

      assert snapshot.version == 1_700_000_000_000
      assert snapshot.generated_at_unix_ms == 1_700_000_000_000
      assert length(snapshot.properties) == 1

      [policy] = snapshot.properties
      assert policy.web_property_id == "01900000-0000-7000-8000-000000000001"
      assert policy.canonical_origin == "https://shop.example.com"
      assert "https://shop.example.com" in policy.allowed_origins
      assert "https://checkout.example.com" in policy.allowed_origins
      assert policy.allowed_query_keys == ["tab", "page"]
      assert policy.trace_propagate_origins == ["https://api.example.com"]
      assert policy.rum_site_key == "sr_rum_aaaaaaaaaaaaaaaa"
      assert policy.rum_enabled == true
      assert policy.rum_sample_rate == 0.5
      assert policy.anonymize_client_ip == true
      assert policy.environment == "production"

      assert Enum.map(policy.prefix_tags, &{&1.cidr, &1.tag}) == [
               {"198.51.100.0/24", "site:hq-01"}
             ]

      assert Enum.map(snapshot.global_prefix_tags, &{&1.cidr, &1.tag}) == [
               {"203.0.113.0/24", "site:branch-02"},
               {"2001:db8:1::/48", "site:dc-west"}
             ]

      encoded = RumPolicySync.encode_snapshot(snapshot)
      decoded = WebPropertyRumPolicySnapshot.decode(encoded)
      assert decoded == snapshot
    end

    test "enforces strictly monotonic version across same-millisecond rotations" do
      prop = %{
        id: "01900000-0000-7000-8000-000000000002",
        name: "Docs",
        canonical_origin: "https://docs.example.com",
        rum_site_key: "sr_rum_bbbbbbbbbbbbbbbb"
      }

      first = RumPolicySync.build_snapshot([prop], [], prev_version: 0, now_ms: 1_700_000_000_500)

      second =
        RumPolicySync.build_snapshot([prop], [],
          prev_version: first.version,
          now_ms: 1_700_000_000_500
        )

      assert first.version == 1_700_000_000_500
      assert second.version == 1_700_000_000_501
    end

    test "omits entries with missing id or rum_site_key and reflects deletion" do
      valid = %{
        id: "01900000-0000-7000-8000-000000000003",
        name: "Valid",
        canonical_origin: "https://valid.example.com",
        rum_site_key: "sr_rum_cccccccccccccccc"
      }

      incomplete = %{id: "01900000-0000-7000-8000-000000000004", name: "NoKey", rum_site_key: nil}

      snap1 = RumPolicySync.build_snapshot([valid, incomplete], [])
      assert Enum.map(snap1.properties, & &1.web_property_id) == [valid.id]

      snap2 = RumPolicySync.build_snapshot([], [], prev_version: snap1.version)
      assert snap2.properties == []
      assert snap2.version > snap1.version
    end
  end
end
