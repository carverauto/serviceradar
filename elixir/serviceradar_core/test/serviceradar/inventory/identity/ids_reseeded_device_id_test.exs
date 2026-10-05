defmodule ServiceRadar.Inventory.Identity.IdsReseededDeviceIdTest do
  @moduledoc """
  Unit coverage for `Ids.reseeded_device_id/1`, the uid a sweep seed takes when the uid its
  address derives redirects to a merge survivor (change `add-source-id-succession`, task 9.7).
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.Ids

  @derived "sr:5eed5eed-a1b2-4c3d-8e4f-a5b6c7d8e9f0"

  test "is a device uid, and not the derived one" do
    uid = Ids.reseeded_device_id(@derived)

    assert uid =~ ~r/\Asr:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    refute uid == @derived
  end

  # Every sweep of the address must seed the same record.
  test "is deterministic in the derived uid" do
    assert Ids.reseeded_device_id(@derived) == Ids.reseeded_device_id(@derived)
  end

  test "differs for another derived uid, and from the re-issued uid of the same one" do
    uid = Ids.reseeded_device_id(@derived)

    refute Ids.reseeded_device_id("sr:5eed5eed-a1b2-4c3d-8e4f-a5b6c7d8e9f1") == uid
    refute Ids.reissued_device_id(@derived, []) == uid
  end

  # The sweep walks the chain until a uid resolves to itself, so no uid may repeat in it.
  test "applied again, gives a chain of distinct uids" do
    chain = @derived |> Stream.iterate(&Ids.reseeded_device_id/1) |> Enum.take(9)

    assert chain |> Enum.uniq() |> length() == 9
  end
end
