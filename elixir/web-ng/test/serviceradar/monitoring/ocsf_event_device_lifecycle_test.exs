defmodule ServiceRadar.Monitoring.OcsfEventDeviceLifecycleTest do
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias Ash.Error.Invalid
  alias ServiceRadar.Monitoring.OcsfEvent

  test "suppresses device-scoped operational events for inactive devices" do
    device = device_fixture(%{is_active: false})

    result =
      OcsfEvent
      |> Ash.Changeset.for_create(:record, event_attrs(device.uid), actor: system_actor())
      |> Ash.create()

    assert {:error, %Invalid{} = error} = result
    assert Exception.message(error) =~ "device is marked out of service"
  end

  test "records device-scoped operational events for active devices" do
    device = device_fixture(%{is_active: true})

    assert {:ok, event} =
             OcsfEvent
             |> Ash.Changeset.for_create(:record, event_attrs(device.uid), actor: system_actor())
             |> Ash.create()

    assert event.device["uid"] == device.uid
  end

  defp event_attrs(device_uid) do
    %{
      class_uid: 1001,
      category_uid: 1,
      type_uid: 100_101,
      activity_id: 1,
      activity_name: "Health Check",
      severity_id: 2,
      severity: "Low",
      message: "device health changed",
      device: %{"uid" => device_uid},
      metadata: %{"source" => "test"}
    }
  end
end
