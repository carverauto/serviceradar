defmodule Palisade.NetworkAddressPolicyTest do
  use ExUnit.Case, async: true

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
end
