defmodule ServiceRadar.Inventory.DeviceInvalidationTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Inventory.DevicePubSub

  setup do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    if is_nil(Process.whereis(ServiceRadar.PubSub)) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    Phoenix.PubSub.subscribe(ServiceRadar.PubSub, DevicePubSub.invalidation_topic())
    :ok
  end

  test "bulk hints carry every identity in bounded messages without device records" do
    ids = Enum.map(1..1_001, &"synthetic-device-#{&1}")
    assert :ok = DevicePubSub.broadcast_invalidated(ids)

    received =
      Enum.flat_map(1..3, fn _ ->
        assert_receive {:devices_invalidated, batch}
        assert length(batch) <= 500
        batch
      end)

    assert received == ids
    refute_received {:devices_invalidated, _}
  end

  test "all device lifecycle events invalidate current-state readers" do
    device = %{uid: "synthetic-device-a", is_available: true}
    assert :ok = DevicePubSub.broadcast_created(device)
    assert_receive {:devices_invalidated, ["synthetic-device-a"]}
    assert :ok = DevicePubSub.broadcast_updated(%{device | is_available: false})
    assert_receive {:devices_invalidated, ["synthetic-device-a"]}
    assert :ok = DevicePubSub.broadcast_deleted(device)
    assert_receive {:devices_invalidated, ["synthetic-device-a"]}

    assert :ok = DevicePubSub.broadcast_invalidated([nil, "", 0])
    refute_received {:devices_invalidated, _}
  end

  test "oversized input emits a bounded prefix and an explicit reconciliation hint" do
    ids = Enum.map(1..5_001, &"synthetic-device-#{&1}")
    assert :ok = DevicePubSub.broadcast_invalidated(ids)

    received =
      Enum.flat_map(1..10, fn _ ->
        assert_receive {:devices_invalidated, batch}
        assert length(batch) == 500
        batch
      end)

    assert received == Enum.take(ids, 5_000)
    assert_receive :devices_rescan
    refute_received {:devices_invalidated, _}

    assert :ok = DevicePubSub.broadcast_invalidated([String.duplicate("x", 524_289)])
    assert_receive :devices_rescan
    refute_received {:devices_invalidated, _}
  end
end
