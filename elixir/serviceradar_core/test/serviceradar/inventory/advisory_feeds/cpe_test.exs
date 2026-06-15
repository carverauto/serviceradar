defmodule ServiceRadar.Inventory.AdvisoryFeeds.CpeTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.Cpe

  describe "parse/1" do
    test "parses a standard CPE 2.3 string into normalized components" do
      assert {:ok, components} =
               Cpe.parse("cpe:2.3:a:openssl:openssl:3.0.13:*:*:*:*:*:*:*")

      assert components.part == "a"
      assert components.vendor == "openssl"
      assert components.product == "openssl"
      assert components.version == "3.0.13"
    end

    test "lower-cases components" do
      assert {:ok, %{vendor: "microsoft", product: "windows"}} =
               Cpe.parse("cpe:2.3:o:Microsoft:Windows:10:*:*:*:*:*:*:*")
    end

    test "preserves ANY (*) and NA (-) special values" do
      assert {:ok, %{version: "*"}} =
               Cpe.parse("cpe:2.3:a:vendor:product:*:*:*:*:*:*:*:*")
    end

    test "unescapes escaped colons and dots in components" do
      assert {:ok, %{product: "foo:bar", version: "1.2.3"}} =
               Cpe.parse("cpe:2.3:a:vendor:foo\\:bar:1.2.3:*:*:*:*:*:*:*")
    end

    test "rejects non-2.3 CPE strings" do
      assert :error = Cpe.parse("cpe:/a:openssl:openssl:1.0.0")
      assert :error = Cpe.parse("not-a-cpe")
      assert :error = Cpe.parse("")
    end
  end

  describe "parse_components/1" do
    test "returns nil components on failure" do
      assert %{part: nil, vendor: nil, product: nil, version: nil} =
               Cpe.parse_components("garbage")
    end
  end

  describe "component_match?/2" do
    test "ANY and NA on the advisory side match anything" do
      assert Cpe.component_match?("*", "openssl")
      assert Cpe.component_match?("-", "openssl")
      assert Cpe.component_match?(nil, "openssl")
    end

    test "case-insensitive equality otherwise" do
      assert Cpe.component_match?("OpenSSL", "openssl")
      refute Cpe.component_match?("openssl", "libressl")
    end
  end
end
