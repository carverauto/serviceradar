defmodule ServiceRadar.Inventory.InterfaceCanonicalAddressesTest do
  @moduledoc """
  `primary_ip` is `ip_addresses[1]`, so the array's order is a semantic, not a
  presentation detail.

  Today that order is whatever the collector happened to serialise. One real
  interface produced 12 distinct textual values for 3 distinct address sets --
  nine pure permutations -- so `primary_ip` already changes between polls at
  random, and every stored row is byte-distinct even when nothing changed.

  These tests pin both halves: the set is stable regardless of input order, and
  the address a caller gets as "primary" is the most reachable one rather than
  the luckiest one.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Interface

  test "a reordered input yields an identical result" do
    # The 12-values-for-3-sets case. Without this, a reshuffle is indistinguishable
    # from a real change.
    a = ["152.117.116.178", "fd2f:420a:24b1:1::1", "fe80::f692:bfff:fe75:c72a"]
    b = ["fe80::f692:bfff:fe75:c72a", "152.117.116.178", "fd2f:420a:24b1:1::1"]
    c = ["fd2f:420a:24b1:1::1", "fe80::f692:bfff:fe75:c72a", "152.117.116.178"]

    assert Interface.canonical_ip_addresses(a) == Interface.canonical_ip_addresses(b)
    assert Interface.canonical_ip_addresses(b) == Interface.canonical_ip_addresses(c)
  end

  test "the most reachable address becomes primary" do
    # primary_ip = ip_addresses[1]. Ordering by routability makes "primary" mean
    # something; alphabetical ordering would make it mean nothing -- and would
    # pick 10.0.0.5 over 192.168.1.1 purely on digits.
    assert ["152.117.116.178" | _] =
             Interface.canonical_ip_addresses([
               "fe80::1",
               "fd00::1",
               "152.117.116.178",
               "192.168.1.1"
             ])
  end

  test "a private address outranks ULA and link-local" do
    assert ["192.168.1.1" | rest] =
             Interface.canonical_ip_addresses(["fe80::1", "fd00::1", "192.168.1.1"])

    assert rest == ["fd00::1", "fe80::1"]
  end

  test "an interface with only link-local addresses keeps them" do
    # Common for a switch port with no L3 config. Dropping them would lose the
    # only evidence the interface exists on the wire.
    result = Interface.canonical_ip_addresses(["fe80::2", "fe80::1"])

    assert result == ["fe80::1", "fe80::2"]
  end

  test "duplicates and blanks are removed" do
    assert Interface.canonical_ip_addresses([
             "10.0.0.1",
             "10.0.0.1",
             "  10.0.0.1  ",
             "",
             "   "
           ]) == ["10.0.0.1"]
  end

  test "non-list and non-binary input does not raise" do
    assert Interface.canonical_ip_addresses(nil) == []
    assert Interface.canonical_ip_addresses("10.0.0.1") == []
    assert Interface.canonical_ip_addresses([nil, 42, "10.0.0.1"]) == ["10.0.0.1"]
  end

  test "the order is total, so equal-ranked addresses do not flap" do
    input = ["10.0.0.9", "10.0.0.1", "10.0.0.5"]

    assert Interface.canonical_ip_addresses(input) ==
             Interface.canonical_ip_addresses(Enum.reverse(input))
  end
end
