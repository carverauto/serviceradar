defmodule ServiceRadar.Inventory.Identity.AddressTest do
  @moduledoc """
  The ranking that decides which address a device presents.

  The cases that matter are the ones a string-prefix implementation gets wrong,
  because that is what this replaces: the fe80::/10 range does not stop at
  "fe80", an IPv4-mapped address is not global just because it starts with
  colons, and a CIDR or zone suffix must not make an address unparseable.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.Address

  describe "classify/1" do
    test "IPv4 families" do
      assert Address.classify("8.8.8.8") == :global
      assert Address.classify("152.117.116.178") == :global
      assert Address.classify("10.0.0.5") == :private
      assert Address.classify("192.168.1.1") == :private
      assert Address.classify("172.16.0.1") == :private
      assert Address.classify("172.31.255.254") == :private
      assert Address.classify("100.64.0.1") == :private
      assert Address.classify("127.0.0.1") == :loopback
      assert Address.classify("169.254.1.1") == :link_local
      assert Address.classify("0.0.0.0") == :unspecified
    end

    test "172.x outside 16..31 is NOT private" do
      # The bound is the whole point of RFC1918's /12: a prefix test on "172."
      # would wrongly claim these.
      assert Address.classify("172.15.0.1") == :global
      assert Address.classify("172.32.0.1") == :global
    end

    test "IPv6 families" do
      assert Address.classify("2001:4860:4860::8888") == :global
      assert Address.classify("::1") == :loopback
      assert Address.classify("::") == :unspecified
      assert Address.classify("fd2f:420a:24b1:1:f692:bfff:fe75:c72a") == :unique_local
      assert Address.classify("fe80::f692:bfff:fe75:c72b") == :link_local
    end

    test "the whole fe80::/10 range is link-local, not just fe80" do
      # A `String.starts_with?(value, "fe80")` test calls these global, which is
      # exactly the bug this module exists to prevent.
      assert Address.classify("fe90::1") == :link_local
      assert Address.classify("fea0::1") == :link_local
      assert Address.classify("febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff") == :link_local
      # fec0:: was site-local, deprecated, and is NOT in fe80::/10.
      assert Address.classify("fec0::1") == :global
    end

    test "the whole fc00::/7 range is unique-local" do
      assert Address.classify("fc00::1") == :unique_local
      assert Address.classify("fdff::1") == :unique_local
    end

    test "an IPv4-mapped address is judged as IPv4" do
      assert Address.classify("::ffff:192.168.1.1") == :private
      assert Address.classify("::ffff:127.0.0.1") == :loopback
      assert Address.classify("::ffff:8.8.8.8") == :global
    end

    test "zone and CIDR suffixes are tolerated" do
      assert Address.classify("fe80::1%eth0") == :link_local
      assert Address.classify("192.168.1.1/24") == :private
      assert Address.classify("  10.0.0.5  ") == :private
    end

    test "unparseable input is invalid rather than raising" do
      assert Address.classify("") == :invalid
      assert Address.classify("not-an-ip") == :invalid
      assert Address.classify("999.999.999.999") == :invalid
      assert Address.classify(nil) == :invalid
      assert Address.classify(12_345) == :invalid
    end
  end

  describe "ranking" do
    test "global beats private beats ULA beats link-local" do
      assert Address.rank("8.8.8.8") > Address.rank("10.0.0.5")
      assert Address.rank("10.0.0.5") > Address.rank("fd00::1")
      assert Address.rank("fd00::1") > Address.rank("fe80::1")
      assert Address.rank("fe80::1") > Address.rank("127.0.0.1")
    end

    test "loopback, unspecified and invalid are never usable" do
      assert Address.rank("127.0.0.1") == 0
      assert Address.rank("::1") == 0
      assert Address.rank("0.0.0.0") == 0
      assert Address.rank("garbage") == 0
    end
  end

  describe "best/1" do
    test "picks the strongest usable candidate" do
      assert Address.best(["fe80::1", "192.168.1.1", "fd00::1"]) == "192.168.1.1"
    end

    test "returns nil when nothing is usable, so callers keep what they have" do
      assert Address.best(["127.0.0.1", "::1", "0.0.0.0", "junk"]) == nil
      assert Address.best([]) == nil
    end

    test "ignores non-binary entries rather than raising" do
      assert Address.best([nil, 42, "10.0.0.1"]) == "10.0.0.1"
    end
  end

  describe "preferred_primary/2" do
    test "promotes a routable alias over a link-local primary" do
      # The #3905 case: 10 of 18 affected devices already hold the better
      # address and simply are not presenting it.
      assert Address.preferred_primary("fe80::f692:bfff:fe75:c72b", ["192.168.1.1"]) ==
               "192.168.1.1"
    end

    test "a device with only a link-local KEEPS it" do
      # The other 8. Blanking their address would trade a poor answer for none.
      assert Address.preferred_primary("fe80::1", []) == "fe80::1"
      assert Address.preferred_primary("fe80::1", ["127.0.0.1", "::1"]) == "fe80::1"
    end

    test "never demotes" do
      assert Address.preferred_primary("8.8.8.8", ["fe80::1", "10.0.0.1"]) == "8.8.8.8"
    end

    test "an equal-ranked candidate does not displace the current address" do
      # Ties must not swap, or two same-class addresses flap on every update.
      assert Address.preferred_primary("10.0.0.1", ["192.168.1.1"]) == "10.0.0.1"
    end

    test "a nil current address is replaced by any usable candidate" do
      assert Address.preferred_primary(nil, ["fe80::1"]) == "fe80::1"
    end
  end
end
