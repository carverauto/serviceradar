defmodule ServiceRadar.Types.CidrTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Types.Cidr

  describe "dump_to_embedded/2" do
    test "dumps string CIDRs to JSON-encodable normalized strings and round-trips through cast_input/3" do
      for {input, expected} <- [
            {"192.0.2.0/24", "192.0.2.0/24"},
            {"198.51.100.10", "198.51.100.10/32"},
            {"2001:db8::/32", "2001:db8::/32"}
          ] do
        assert {:ok, dumped} = Ash.Type.dump_to_embedded(Cidr, input)
        assert dumped == expected
        assert {:ok, json} = Jason.encode(dumped)
        assert {:ok, decoded} = Jason.decode(json)
        assert {:ok, ^expected} = Ash.Type.cast_input(Cidr, decoded, [])
      end
    end

    test "dumps Postgrex.INET structs to JSON-encodable strings and round-trips through cast_input/3" do
      ipv4 = %Postgrex.INET{address: {192, 0, 2, 0}, netmask: 24}
      ipv6 = %Postgrex.INET{address: {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0}, netmask: 32}

      for {inet, expected} <- [{ipv4, "192.0.2.0/24"}, {ipv6, "2001:db8::/32"}] do
        assert {:ok, dumped} = Ash.Type.dump_to_embedded(Cidr, inet)
        assert dumped == expected
        assert {:ok, json} = Jason.encode(dumped)
        assert {:ok, decoded} = Jason.decode(json)
        assert {:ok, ^expected} = Ash.Type.cast_input(Cidr, decoded, [])
      end
    end

    test "returns {:ok, nil} for nil" do
      assert {:ok, nil} = Ash.Type.dump_to_embedded(Cidr, nil)
      assert {:ok, "null"} = Jason.encode(nil)
      assert {:ok, nil} = Ash.Type.cast_input(Cidr, nil, [])
    end

    test "returns :error for invalid values" do
      for invalid <- ["not-a-cidr", "192.0.2.0/33", "", 123, %{}] do
        assert :error = Ash.Type.dump_to_embedded(Cidr, invalid)
      end
    end
  end
end
