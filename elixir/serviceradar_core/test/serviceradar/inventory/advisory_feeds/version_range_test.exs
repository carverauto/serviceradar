defmodule ServiceRadar.Inventory.AdvisoryFeeds.VersionRangeTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.VersionRange

  describe "from_cpe_match/1" do
    test "normalizes versionStartIncluding + versionEndExcluding" do
      assert {:ok, bounds} =
               VersionRange.from_cpe_match(%{
                 "versionStartIncluding" => "1.0.0",
                 "versionEndExcluding" => "2.0.0"
               })

      assert bounds.version_start == "1.0.0"
      assert bounds.version_start_inclusive == true
      assert bounds.version_end == "2.0.0"
      assert bounds.version_end_inclusive == false
    end

    test "normalizes versionStartExcluding + versionEndIncluding" do
      assert {:ok, bounds} =
               VersionRange.from_cpe_match(%{
                 "versionStartExcluding" => "1.0.0",
                 "versionEndIncluding" => "2.0.0"
               })

      assert bounds.version_start_inclusive == false
      assert bounds.version_end_inclusive == true
    end

    test "treats blank / wildcard bounds as absent" do
      assert {:ok, bounds} =
               VersionRange.from_cpe_match(%{"versionStartIncluding" => "*"})

      assert bounds.version_start == nil
      assert bounds.version_start_inclusive == nil
    end

    test "rejects simultaneous inclusive and exclusive bounds on the same side" do
      assert {:error, :ambiguous_version_start} =
               VersionRange.from_cpe_match(%{
                 "versionStartIncluding" => "1.0",
                 "versionStartExcluding" => "1.1"
               })

      assert {:error, :ambiguous_version_end} =
               VersionRange.from_cpe_match(%{
                 "versionEndIncluding" => "2.0",
                 "versionEndExcluding" => "2.1"
               })
    end

    test "rejects present non-string bounds instead of treating them as absent" do
      for {key, value} <- [
            {"versionStartIncluding", 1},
            {"versionStartExcluding", true},
            {"versionEndIncluding", %{}},
            {"versionEndExcluding", []}
          ] do
        assert {:error, {:invalid_version_bound, ^key}} =
                 VersionRange.from_cpe_match(%{key => value})
      end
    end
  end

  describe "satisfies?/2" do
    test "fully unbounded matches anything (including a nil version)" do
      assert {:ok, bounds} = VersionRange.from_cpe_match(%{})
      assert VersionRange.satisfies?("1.0.0", bounds)
      assert VersionRange.satisfies?(nil, bounds)
    end

    test "version inside >= 1.0 < 2.0 is matched" do
      assert {:ok, bounds} =
               VersionRange.from_cpe_match(%{
                 "versionStartIncluding" => "1.0",
                 "versionEndExcluding" => "2.0"
               })

      assert VersionRange.satisfies?("1.4", bounds)
      assert VersionRange.satisfies?("1.0", bounds)
    end

    test "version outside >= 1.0 < 2.0 is NOT matched (the 5000-cap / version-blind bug fix)" do
      assert {:ok, bounds} =
               VersionRange.from_cpe_match(%{
                 "versionStartIncluding" => "1.0",
                 "versionEndExcluding" => "2.0"
               })

      refute VersionRange.satisfies?("2.5", bounds)
      refute VersionRange.satisfies?("0.9", bounds)
      # exclusive upper bound: 2.0 itself is excluded
      refute VersionRange.satisfies?("2.0", bounds)
    end

    test "inclusive upper bound includes the boundary" do
      assert {:ok, bounds} =
               VersionRange.from_cpe_match(%{"versionEndIncluding" => "2.0"})

      assert VersionRange.satisfies?("2.0", bounds)
      refute VersionRange.satisfies?("2.0.1", bounds)
    end

    test "a bounded range cannot be evaluated without an installed version" do
      assert {:ok, bounds} =
               VersionRange.from_cpe_match(%{"versionEndExcluding" => "2.0"})

      refute VersionRange.satisfies?(nil, bounds)
      refute VersionRange.satisfies?("", bounds)
    end
  end

  describe "compare/2" do
    test "numeric dotted comparison" do
      assert VersionRange.compare("1.2.0", "1.10.0") == :lt
      assert VersionRange.compare("2.0", "1.9.9") == :gt
      assert VersionRange.compare("1.0.0", "1.0") == :eq
    end

    test "lexical fallback for non-numeric tails" do
      assert VersionRange.compare("1.0.0-rc1", "1.0.0-rc2") == :lt
    end
  end
end
