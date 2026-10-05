defmodule ServiceRadar.Inventory.Identity.IdsReissuedDeviceIdTest do
  @moduledoc """
  Unit coverage for `Ids.reissued_device_id/2`, the uid a re-issued source id's update is
  written to when the uid the id derives is taken (change `add-source-id-succession`, design D6).
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.Ids

  @derived "sr:00000000-0000-4000-8000-000000000001"

  test "is a device uid, and not the derived one" do
    uid = Ids.reissued_device_id(@derived, [1, 2])

    assert uid =~ ~r/\Asr:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    refute uid == @derived
  end

  # A retried batch must write the same record, whatever order it read the archive rows in.
  test "is deterministic in the derived uid and the set of archive rows" do
    assert Ids.reissued_device_id(@derived, [1, 2]) == Ids.reissued_device_id(@derived, [1, 2])
    assert Ids.reissued_device_id(@derived, [2, 1]) == Ids.reissued_device_id(@derived, [1, 2])
  end

  test "differs for another derived uid or other archive rows" do
    uid = Ids.reissued_device_id(@derived, [1, 2])

    refute Ids.reissued_device_id("sr:00000000-0000-4000-8000-000000000002", [1, 2]) == uid
    refute Ids.reissued_device_id(@derived, [1, 3]) == uid
    refute Ids.reissued_device_id(@derived, [1]) == uid
    refute Ids.reissued_device_id(@derived, []) == uid
  end
end
