defmodule Palisade.NetworkAddressPolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Palisade.NetworkAddressPolicy

  describe "private_or_loopback_ip?/1" do
    test "blocks private, local, and special-use IPv4 ranges" do
      for ip <- [
            {0, 0, 0, 0},
            {0, 1, 2, 3},
            {10, 0, 0, 1},
            {100, 64, 0, 1},
            {100, 127, 255, 255},
            {172, 16, 0, 1},
            {172, 31, 255, 255},
            {192, 168, 0, 1},
            {127, 0, 0, 1},
            {169, 254, 169, 254},
            {192, 0, 0, 1},
            {192, 0, 2, 1},
            {192, 88, 99, 1},
            {198, 18, 0, 1},
            {198, 19, 255, 255},
            {198, 51, 100, 1},
            {203, 0, 113, 1},
            {224, 0, 0, 1},
            {239, 255, 255, 255},
            {240, 0, 0, 1},
            {255, 255, 255, 255}
          ] do
        assert NetworkAddressPolicy.private_or_loopback_ip?(ip), "expected #{inspect(ip)} blocked"
      end
    end

    test "allows public IPv4 ranges" do
      for ip <- [
            {1, 1, 1, 1},
            {8, 8, 8, 8},
            {100, 128, 0, 1},
            {172, 15, 0, 1},
            {172, 32, 0, 1},
            {198, 20, 0, 1}
          ] do
        refute NetworkAddressPolicy.private_or_loopback_ip?(ip), "expected #{inspect(ip)} allowed"
      end
    end

    test "blocks loopback, unspecified, ULA, link-local, and multicast IPv6" do
      for ip <- [
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0, 0, 0, 0, 0, 0, 0, 0},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1},
            {0xFC00, 0, 0, 0, 0, 0, 0, 1},
            {0xFD00, 0, 0, 0, 0, 0, 0, 1},
            {0xFF00, 0, 0, 0, 0, 0, 0, 1}
          ] do
        assert NetworkAddressPolicy.private_or_loopback_ip?(ip), "expected #{inspect(ip)} blocked"
      end
    end

    test "blocks IPv4-mapped IPv6 when the embedded IPv4 address is blocked" do
      for ip <- [
            {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001},
            {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001},
            {0, 0, 0, 0, 0, 0xFFFF, 0x6440, 0x0001},
            {0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE},
            {0, 0, 0, 0, 0, 0xFFFF, 0xE000, 0x0001}
          ] do
        assert NetworkAddressPolicy.private_or_loopback_ip?(ip), "expected #{inspect(ip)} blocked"
      end
    end

    test "allows IPv4-mapped IPv6 when the embedded IPv4 address is public" do
      refute NetworkAddressPolicy.private_or_loopback_ip?({0, 0, 0, 0, 0, 0xFFFF, 0x0101, 0x0101})
    end

    test "allows public IPv6" do
      refute NetworkAddressPolicy.private_or_loopback_ip?(
               {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}
             )
    end

    test "fails closed for invalid inputs" do
      assert NetworkAddressPolicy.private_or_loopback_ip?({1, 2, 3})
      assert NetworkAddressPolicy.private_or_loopback_ip?("not a tuple")
      assert NetworkAddressPolicy.private_or_loopback_ip?(nil)
    end
  end

  describe "validate_public_host/1" do
    test "rejects IPv4-mapped cloud metadata literal" do
      assert {:error, :disallowed_host} =
               NetworkAddressPolicy.validate_public_host("::ffff:169.254.169.254")
    end
  end

  describe "cidr_contains?/2 and ip_in_any_cidr?/2" do
    test "match an address inside an IPv4 or IPv6 CIDR" do
      assert NetworkAddressPolicy.cidr_contains?({10, 1, 2, 3}, "10.0.0.0/8")
      assert NetworkAddressPolicy.cidr_contains?({192, 168, 1, 10}, "192.168.0.0/16")
      assert NetworkAddressPolicy.cidr_contains?({0xFD00, 0, 0, 0, 0, 0, 0, 1}, "fd00::/8")
      assert NetworkAddressPolicy.cidr_contains?({8, 8, 8, 8}, "0.0.0.0/0")
    end

    test "do not match outside the CIDR, across address families, or for an invalid CIDR" do
      refute NetworkAddressPolicy.cidr_contains?({8, 8, 8, 8}, "10.0.0.0/8")
      refute NetworkAddressPolicy.cidr_contains?({11, 0, 0, 0}, "10.0.0.0/8")
      refute NetworkAddressPolicy.cidr_contains?({10, 1, 2, 3}, "fd00::/8")
      refute NetworkAddressPolicy.cidr_contains?({10, 1, 2, 3}, "invalid")
      refute NetworkAddressPolicy.cidr_contains?({10, 1, 2, 3}, "10.0.0.0/33")
    end

    test "match when any CIDR in the list contains the address" do
      assert NetworkAddressPolicy.ip_in_any_cidr?({10, 0, 0, 4}, ["192.168.0.0/16", "10.0.0.0/8"])
      refute NetworkAddressPolicy.ip_in_any_cidr?({8, 8, 8, 8}, ["192.168.0.0/16", "10.0.0.0/8"])
      refute NetworkAddressPolicy.ip_in_any_cidr?({8, 8, 8, 8}, [])
    end

    test "match an IPv4-mapped IPv6 address against the IPv4 CIDR it falls in" do
      mapped = {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0005}

      assert NetworkAddressPolicy.ip_in_any_cidr?(mapped, ["10.0.0.0/8"])
      assert NetworkAddressPolicy.cidr_contains?(mapped, "::ffff:0:0/96")
      refute NetworkAddressPolicy.cidr_contains?(mapped, "192.168.0.0/16")
    end

    test "match an IPv4 address against an IPv4 CIDR written in mapped form" do
      assert NetworkAddressPolicy.cidr_contains?({10, 0, 0, 5}, "::ffff:10.0.0.0/104")
      refute NetworkAddressPolicy.cidr_contains?({11, 0, 0, 5}, "::ffff:10.0.0.0/104")
    end

    test "do not match a plain IPv4 address against a native IPv6 CIDR" do
      refute NetworkAddressPolicy.cidr_contains?({10, 0, 0, 5}, "::/0")
    end

    test "never match malformed addresses or CIDR lists" do
      refute NetworkAddressPolicy.cidr_contains?({256, 0, 0, 1}, "0.0.0.0/0")
      refute NetworkAddressPolicy.cidr_contains?({-1, 0, 0, 1}, "0.0.0.0/0")
      refute NetworkAddressPolicy.cidr_contains?({1, 2, 3}, "0.0.0.0/0")
      refute NetworkAddressPolicy.cidr_contains?("10.0.0.1", "10.0.0.0/8")
      refute NetworkAddressPolicy.cidr_contains?({10, 0, 0, 1}, :not_a_cidr)
      refute NetworkAddressPolicy.cidr_contains?({10, 0, 0, 1}, "10.0.0.0/-1")
      refute NetworkAddressPolicy.cidr_contains?({10, 0, 0, 1}, "10.0.0.0/8x")
      refute NetworkAddressPolicy.ip_in_any_cidr?({10, 0, 0, 1}, nil)
      refute NetworkAddressPolicy.ip_in_any_cidr?({10, 0, 0, 1}, [nil, 7, "garbage"])
    end
  end

  describe "CIDR matching properties" do
    property "an IPv4 address matches a CIDR exactly when its leading bits equal the base's" do
      check all(ip <- ipv4(), base <- ipv4(), bits <- integer(0..32)) do
        expected = prefix(ipv4_int(ip), 32, bits) == prefix(ipv4_int(base), 32, bits)
        assert NetworkAddressPolicy.cidr_contains?(ip, cidr(base, bits)) == expected
      end
    end

    property "an IPv6 address matches a CIDR exactly when its leading bits equal the base's" do
      check all(ip <- ipv6(), base <- ipv6(), bits <- integer(0..128)) do
        expected = prefix(ipv6_int(ip), 128, bits) == prefix(ipv6_int(base), 128, bits)
        assert NetworkAddressPolicy.cidr_contains?(ip, cidr(base, bits)) == expected
      end
    end

    property "an address is always inside its own /32 or /128 and inside /0 of its family" do
      check all(ip <- one_of([ipv4(), ipv6()])) do
        full = if tuple_size(ip) == 4, do: 32, else: 128
        assert NetworkAddressPolicy.cidr_contains?(ip, cidr(ip, full))
        assert NetworkAddressPolicy.cidr_contains?(ip, cidr(ip, 0))
      end
    end

    property "an IPv4-mapped address matches the same IPv4 CIDRs as its IPv4 address" do
      check all(ip <- ipv4(), base <- ipv4(), bits <- integer(0..32)) do
        cidr = cidr(base, bits)

        assert NetworkAddressPolicy.cidr_contains?(mapped(ip), cidr) ==
                 NetworkAddressPolicy.cidr_contains?(ip, cidr)
      end
    end

    property "a prefix length outside the family's range never matches" do
      check all(ip <- ipv4(), bits <- one_of([integer(33..200), integer(-50..-1)])) do
        refute NetworkAddressPolicy.cidr_contains?(ip, "#{:inet.ntoa(ip)}/#{bits}")
      end
    end

    property "arbitrary CIDR text never raises" do
      check all(ip <- one_of([ipv4(), ipv6()]), text <- string(:printable, max_length: 48)) do
        assert is_boolean(NetworkAddressPolicy.cidr_contains?(ip, text))
      end
    end
  end

  defp ipv4, do: tuple({integer(0..255), integer(0..255), integer(0..255), integer(0..255)})

  defp ipv6 do
    segment = integer(0..0xFFFF)
    tuple({segment, segment, segment, segment, segment, segment, segment, segment})
  end

  defp mapped({a, b, c, d}), do: {0, 0, 0, 0, 0, 0xFFFF, (a <<< 8) + b, (c <<< 8) + d}

  defp cidr(ip, bits), do: "#{:inet.ntoa(ip)}/#{bits}"

  defp prefix(_int, _size, 0), do: 0
  defp prefix(int, size, bits), do: int >>> (size - bits)

  defp ipv4_int({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d

  defp ipv6_int(ip) do
    ip |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> (acc <<< 16) + part end)
  end
end
