defmodule ServiceRadarWebNG.Topology.GodViewDevicePageTest do
  @moduledoc """
  God-view hydration used to keep one page of `Device.read`. 260 devices is
  one past that page.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.TestSupport
  alias ServiceRadarWebNG.Topology.GodViewStream

  @moduletag :integration
  @moduletag :web_ng_shared_fixture_db
  @batch 260
  @gateway_id "gw-god-view-page"

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:god_view_device_page)}
  end

  @tag timeout: 180_000
  test "fetch_devices/2 hydrates every requested uid", %{actor: actor} do
    devices = Enum.map(0..(@batch - 1), &create_device!(actor, &1))
    uids = Enum.map(devices, & &1.uid)

    assert {:ok, hydrated} = GodViewStream.fetch_devices(actor, uids)
    assert MapSet.equal?(MapSet.new(hydrated, & &1.uid), MapSet.new(uids))
  end

  defp create_device!(actor, index) do
    {:ok, device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "god-view-#{index}.example.com",
        ip: doc_ip(index),
        gateway_id: @gateway_id,
        partition: "default"
      })
      |> Ash.create(actor: actor)

    device
  end

  defp doc_ip(index) when index < 254, do: "192.0.2.#{index + 1}"
  defp doc_ip(index), do: "198.51.100.#{index - 253}"
end
