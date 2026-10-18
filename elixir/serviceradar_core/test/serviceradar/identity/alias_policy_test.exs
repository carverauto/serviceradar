defmodule ServiceRadar.Identity.AliasPolicyTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ServiceRadar.Identity.AliasPolicy
  alias ServiceRadar.Identity.DeviceLookup
  alias ServiceRadar.Inventory.Identity.AliasGuard
  alias ServiceRadar.Inventory.Identity.Resolver
  alias ServiceRadar.Inventory.Sync.Lookups

  describe "valid_alias_ip?/1" do
    test "accepts routable addresses of both families" do
      for ip <- [
            "152.117.116.178",
            "192.168.1.1",
            "2001:470:c0b5:1::1",
            "fd2f:420a:24b1:1:f692:bfff:fe75:c72a",
            "fc00::1"
          ] do
        assert AliasPolicy.valid_alias_ip?(ip), "expected #{ip} to be aliasable"
      end
    end

    test "rejects loopback and unspecified in both families" do
      for ip <- ["127.0.0.1", "127.1.2.3", "::1", "::", "0.0.0.0", "", nil] do
        refute AliasPolicy.valid_alias_ip?(ip), "expected #{inspect(ip)} to be rejected"
      end
    end

    test "rejects the whole fe80::/10 range, not just fe80::" do
      # fe80::/10 spans first-hextet fe80..febf. A guard written against only
      # 0xFE80 would let fe81:: through, and unique-local fd00::/8 sits directly
      # below the range while global unicast 2000::/3 sits far above -- both must
      # stay aliasable.
      for ip <- ["fe80::1", "fe80::f692:bfff:fe75:c72a", "fe81::1", "feb0::1", "febf::1"] do
        refute AliasPolicy.valid_alias_ip?(ip), "expected #{ip} to be rejected as link-local"
      end

      for ip <- ["fec0::1", "fd00::1", "2001:db8::1"] do
        assert AliasPolicy.valid_alias_ip?(ip), "expected #{ip} to remain aliasable"
      end
    end

    test "rejects IPv4 link-local (APIPA)" do
      for ip <- ["169.254.0.1", "169.254.255.254"] do
        refute AliasPolicy.valid_alias_ip?(ip), "expected #{ip} to be rejected"
      end

      assert AliasPolicy.valid_alias_ip?("169.253.0.1")
      assert AliasPolicy.valid_alias_ip?("169.255.0.1")
    end

    test "rejects non-addresses and non-binaries" do
      for value <- ["not-an-ip", "hostname.local", "1.2.3.4.5", :atom, 42, %{}] do
        refute AliasPolicy.valid_alias_ip?(value)
      end
    end

    test "rejects IPv4-mapped loopback and link-local" do
      refute AliasPolicy.valid_alias_ip?("::ffff:169.254.1.1")
      refute AliasPolicy.valid_alias_ip?("::ffff:127.0.0.1")
      assert AliasPolicy.valid_alias_ip?("::ffff:192.168.1.1")
      assert AliasPolicy.valid_alias_ip?("::ffff:8.8.8.8")
    end

    test "rejects IPv4 limited and directed broadcast addresses while keeping valid .255 hosts and /31-/32" do
      refute AliasPolicy.valid_alias_ip?("255.255.255.255")
      refute AliasPolicy.valid_alias_ip?("::ffff:255.255.255.255")
      refute AliasPolicy.valid_alias_ip?("192.0.2.255/24")
      refute AliasPolicy.valid_alias_ip?("198.51.101.255/23")
      refute AliasPolicy.valid_alias_ip?("192.0.2.255", ["192.0.2.1/24"])
      refute AliasPolicy.valid_alias_ip?("198.51.101.255", ["198.51.100.0/23"])

      # A .255 address inside a /16 is a valid host, not the /16 broadcast (203.0.255.255).
      assert AliasPolicy.valid_alias_ip?("203.0.113.255/16")
      assert AliasPolicy.valid_alias_ip?("203.0.113.255", ["203.0.113.1/16"])

      # /31 (RFC 3021) and /32 have no directed broadcast address.
      assert AliasPolicy.valid_alias_ip?("192.0.2.3/31")
      assert AliasPolicy.valid_alias_ip?("198.51.100.255/32")
      assert AliasPolicy.valid_alias_ip?("192.0.2.3", ["192.0.2.2/31"])
      assert AliasPolicy.valid_alias_ip?("198.51.100.255", ["198.51.100.255/32"])
    end

    test "interface_known_cidrs/2 extracts explicit CIDRs and infers same-interface .255 broadcast pairs" do
      assert AliasPolicy.interface_known_cidrs(["192.0.2.1", "192.0.2.255"]) == ["192.0.2.0/24"]

      # When an explicit /16 covers 203.0.113.255, no /24 is inferred.
      cidrs =
        AliasPolicy.interface_known_cidrs(
          ["203.0.113.1", "203.0.113.255"],
          %{"ip_cidrs" => "203.0.113.1/16,203.0.113.255/16"}
        )

      assert cidrs == ["203.0.113.1/16", "203.0.113.255/16"]
      assert AliasPolicy.valid_alias_ip?("203.0.113.255", cidrs)
    end
  end

  describe "identity readers fail closed on leftover link-local and broadcast aliases" do
    test "Resolver.lookup_alias_device_id does not treat fe80:: or broadcast as merge evidence" do
      assert {:ok, nil} = Resolver.lookup_alias_device_id("fe80::1", "default", nil)
      assert {:ok, nil} = Resolver.lookup_alias_device_id("169.254.1.1", "default", nil)
      assert {:ok, nil} = Resolver.lookup_alias_device_id("::ffff:169.254.1.1", "default", nil)
      assert {:ok, nil} = Resolver.lookup_alias_device_id("255.255.255.255", "default", nil)
      assert {:ok, nil} = Resolver.lookup_alias_device_id("192.0.2.255/24", "default", nil)
    end

    test "AliasGuard does not merge on a link-local or broadcast IP" do
      assert :ok =
               AliasGuard.maybe_merge_ip_alias_device(
                 "sr:a",
                 %{ip: "fe80::1", partition: "default"},
                 nil
               )

      assert :ok =
               AliasGuard.maybe_merge_ip_alias_device(
                 "sr:a",
                 %{ip: "255.255.255.255", partition: "default"},
                 nil
               )
    end

    test "DeviceLookup skips leftover link-local and broadcast alias values" do
      assert DeviceLookup.lookup_detected_aliases_by_ip(
               ["fe80::1", "169.254.0.1", "255.255.255.255", "192.0.2.255/24"],
               []
             ) == %{}
    end

    test "Lookups skips leftover link-local and broadcast alias values" do
      assert Lookups.lookup_alias_device_ids_by_ip([
               "fe80::1",
               "169.254.0.1",
               "255.255.255.255",
               "192.0.2.255/24"
             ]) == %{}
    end
  end
end
