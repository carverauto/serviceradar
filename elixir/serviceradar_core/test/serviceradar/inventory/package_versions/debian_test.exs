defmodule ServiceRadar.Inventory.PackageVersions.DebianTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.PackageVersions.Debian

  @policy_cases [
    {"1:1.0-1", "2.0-99", :gt},
    {"0:1.0", "1.0", :eq},
    {"1.0~rc1-1", "1.0-1", :lt},
    {"1.0-1~deb12u1", "1.0-1", :lt},
    {"1.0-1ubuntu1+esm2", "1.0-1ubuntu1", :gt},
    {"42.0~test1-0ubuntu99.10", "42.0~test1-0ubuntu99.8", :gt},
    {"1.0", "1.0-0", :eq},
    {"1.001-1", "1.1-1", :eq},
    {"1.0a", "1.0+", :lt}
  ]

  test "matches the Debian Policy conformance table" do
    for {left, right, expected} <- @policy_cases do
      assert Debian.compare(left, right) == {:ok, expected}
    end
  end

  test "rejects malformed Debian versions" do
    for version <- [
          "",
          " ",
          "-1",
          "1.0-",
          "-1:1.0",
          "+1:1.0",
          "one:1.0",
          "1:1:1.0",
          "1.0/1"
        ] do
      assert Debian.compare(version, "1.0") == {:error, :invalid_version}
      assert Debian.compare("1.0", version) == {:error, :invalid_version}
    end
  end

  test "rejects versions containing trailing or interior newlines without raising" do
    for version <- ["1\n:1.0", "1.0\n", "1.0\n-1", "1.0-1\n", "1.0-\n1"] do
      assert Debian.compare(version, "1.0") == {:error, :invalid_version}
      assert Debian.compare("1.0", version) == {:error, :invalid_version}
    end
  end

  test "is antisymmetric for valid Debian versions" do
    versions = [
      "1.0~rc1-1",
      "1.0-1",
      "1.0-1ubuntu1",
      "1.0-1ubuntu1+esm2",
      "1:1.0-1",
      "2.0-99"
    ]

    for left <- versions, right <- versions do
      assert {:ok, ordering} = Debian.compare(left, right)
      assert Debian.compare(right, left) == {:ok, inverse(ordering)}
    end
  end

  test "preserves transitive and equivalent Debian ordering edges" do
    assert {:ok, :lt} = Debian.compare("1.0~rc1-1", "1.0-1")
    assert {:ok, :lt} = Debian.compare("1.0-1", "1.0-1ubuntu1")
    assert {:ok, :lt} = Debian.compare("1.0~rc1-1", "1.0-1ubuntu1")

    for {left, right} <- [
          {"1.0", "1.0-0"},
          {"0:1.001-0001", "1.1-1"},
          {"0001:1.0", "1:1.0"}
        ] do
      assert Debian.compare(left, right) == {:ok, :eq}
      assert Debian.compare(right, left) == {:ok, :eq}
    end
  end

  defp inverse(:lt), do: :gt
  defp inverse(:eq), do: :eq
  defp inverse(:gt), do: :lt
end
