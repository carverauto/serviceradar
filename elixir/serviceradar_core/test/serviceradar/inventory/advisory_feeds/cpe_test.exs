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

    test "retains all eleven CPE 2.3 components" do
      assert {:ok,
              %{
                part: "a",
                vendor: "vendor",
                product: "product",
                version: "1.2.3",
                update: "update-1",
                edition: "enterprise",
                language: "en-us",
                sw_edition: "cloud",
                target_sw: "linux",
                target_hw: "x86-64",
                other: "other"
              }} =
               Cpe.parse(
                 "cpe:2.3:a:Vendor:Product:1.2.3:Update-1:Enterprise:EN-US:Cloud:Linux:X86-64:Other"
               )
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

    test "rejects formatted strings without exactly eleven valid components" do
      assert :error = Cpe.parse("cpe:2.3:a")
      assert :error = Cpe.parse("cpe:2.3:a:vendor:product:1:*:*:*:*:*:*")
      assert :error = Cpe.parse("cpe:2.3:a:vendor:product:1:*:*:*:*:*:*:*:extra")
      assert :error = Cpe.parse("cpe:2.3:x:vendor:product:1:*:*:*:*:*:*:*")
      assert :error = Cpe.parse("cpe:2.3:a::product:1:*:*:*:*:*:*:*")
    end

    test "rejects escaped standalone logical values instead of turning them into ANY or NA" do
      assert :error = Cpe.parse("cpe:2.3:a:vendor:product:\\*:*:*:*:*:*:*:*")
      assert :error = Cpe.parse("cpe:2.3:a:vendor:product:\\-:*:*:*:*:*:*:*")
    end

    test "rejects invalid UTF-8 components without raising" do
      malformed = "cpe:2.3:a:vendor:" <> <<255>> <> ":1:*:*:*:*:*:*:*"
      assert :error = Cpe.parse(malformed)
    end
  end

  describe "parse_components/1" do
    test "returns nil components on failure" do
      assert %{part: nil, vendor: nil, product: nil, version: nil} =
               Cpe.parse_components("garbage")
    end
  end

  describe "component_match?/2" do
    test "ANY on the advisory side matches anything" do
      assert Cpe.component_match?("*", "openssl")
      assert Cpe.component_match?("*", "-")
      assert Cpe.component_match?(nil, "openssl")
    end

    test "NA matches only NA and is disjoint from concrete values" do
      assert Cpe.component_match?("-", "-")
      refute Cpe.component_match?("-", "starling_fetch")
      refute Cpe.component_match?("-", nil)
    end

    test "case-insensitive equality otherwise" do
      assert Cpe.component_match?("OpenSSL", "openssl")
      refute Cpe.component_match?("openssl", "libressl")
    end
  end
end
