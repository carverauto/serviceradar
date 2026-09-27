defmodule ServiceRadar.NetworkDiscovery.WorldInventoryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkDiscovery.WorldInventory

  @moduletag :db_free

  test "stored classification controls visibility independently of hostname" do
    cases = [
      {12, "workstation", 0},
      {10, "unknown", 1},
      {9, nil, 1},
      {11, nil, 1},
      {13, nil, 1},
      {14, nil, 1},
      {15, nil, 1},
      {0, "Router", 0},
      {nil, "Access Point", 1},
      {99, "wireless_controller", 1},
      {99, "load-balancer", 1},
      {99, "Hypervisor", 1},
      {99, "unknown", 2},
      {0, nil, 2},
      {2, "router", 2}
    ]

    for {type_id, type, expected} <- cases do
      assert %{id: "sr:device01", importance: ^expected} =
               WorldInventory.project(%{
                 uid: "sr:device01",
                 type_id: type_id,
                 type: type,
                 hostname: "router01.example.com"
               })
    end
  end

  test "display labels stay valid bounded UTF-8 without truncating identity" do
    id = "sr:" <> String.duplicate("x", 270)

    assert %{id: ^id, label: label} =
             WorldInventory.project(%{uid: id, name: String.duplicate("é", 127) <> "界", hostname: "host01.example.com"})

    assert label == String.duplicate("é", 127)
    assert String.valid?(label)
    assert byte_size(label) == 254

    assert %{label: "host02.example.com"} =
             WorldInventory.project(%{uid: "sr:device02", name: "  ", hostname: "host02.example.com"})

    assert %{id: ^id, label: fallback} = WorldInventory.project(%{uid: id})
    assert fallback == "sr:" <> String.duplicate("x", 253)
  end
end
