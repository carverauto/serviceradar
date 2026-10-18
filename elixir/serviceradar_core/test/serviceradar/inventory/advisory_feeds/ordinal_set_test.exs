defmodule ServiceRadar.Inventory.AdvisoryFeeds.OrdinalSetTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.OrdinalSet

  test "membership and distinct count hold across word boundaries and sparse ordinals" do
    # 31/32/33 straddle one 32-bit word; the large ordinals land in sparse words.
    added = [0, 1, 31, 32, 33, 63, 64, 1_000_003, 4_294_967_296, 9_007_199_254_740_993]

    set = OrdinalSet.put_all(OrdinalSet.new(), added ++ Enum.reverse(added))

    assert OrdinalSet.size(set) == length(added)

    for ordinal <- added do
      assert OrdinalSet.member?(set, ordinal), "expected #{ordinal} to be a member"
    end

    for ordinal <- [2, 30, 34, 62, 65, 1_000_002, 1_000_004, 4_294_967_297] do
      refute OrdinalSet.member?(set, ordinal), "did not expect #{ordinal} to be a member"
    end
  end

  test "a full contiguous range is complete and its neighbours are not members" do
    set = OrdinalSet.put_all(OrdinalSet.new(), 1_000..5_999)

    assert OrdinalSet.size(set) == 5_000
    assert Enum.all?(1_000..5_999, &OrdinalSet.member?(set, &1))
    refute OrdinalSet.member?(set, 999)
    refute OrdinalSet.member?(set, 6_000)
  end
end
