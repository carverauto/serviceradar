defmodule ServiceRadar.ResultsRouterIntegrationTest do
  @moduledoc """
  Integration coverage for sync status ingestion through DIRE into inventory.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.{Device, DeviceIdentifier, IdentityReconciler}
  alias ServiceRadar.ResultsRouter
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    previous_async = Application.get_env(:serviceradar_core, :sync_ingestor_async)
    Application.put_env(:serviceradar_core, :sync_ingestor_async, false)

    on_exit(fn ->
      if is_nil(previous_async) do
        Application.delete_env(:serviceradar_core, :sync_ingestor_async)
      else
        Application.put_env(:serviceradar_core, :sync_ingestor_async, previous_async)
      end
    end)

    :ok
  end

  test "sync status update creates device and identifiers" do
    actor = system_actor()

    armis_id = "armis-#{System.unique_integer([:positive])}"
    ip_octet = rem(System.unique_integer([:positive]), 200) + 10
    ip = "10.0.0.#{ip_octet}"
    mac = "AA:BB:CC:DD:EE:#{mac_suffix()}"

    update = %{
      "ip" => ip,
      "mac" => mac,
      "hostname" => "edge-#{ip_octet}",
      "metadata" => %{"armis_device_id" => armis_id}
    }

    identity_update = %{
      device_id: nil,
      ip: ip,
      mac: mac,
      hostname: "edge-#{ip_octet}",
      partition: "default",
      metadata: %{"armis_device_id" => armis_id}
    }

    assert {:ok, expected_id} =
             IdentityReconciler.resolve_device_id(identity_update, actor: actor)

    status = %{
      source: "results",
      service_type: "sync",
      message: Jason.encode!([update])
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})

    assert {:ok, device} =
             Device.get_by_uid(expected_id, actor: actor)

    assert device.ip == ip
    assert device.hostname == "edge-#{ip_octet}"
    assert device.uid == expected_id

    identifier_query =
      DeviceIdentifier
      |> Ash.Query.for_read(:lookup, %{
        identifier_type: :armis_device_id,
        identifier_value: armis_id,
        partition: "default"
      })

    assert {:ok, [identifier | _]} =
             Ash.read(identifier_query, actor: actor)

    assert identifier.device_id == expected_id
  end

  defp system_actor do
    SystemActor.system(:test)
  end

  defp mac_suffix do
    System.unique_integer([:positive])
    |> rem(256)
    |> Integer.to_string(16)
    |> String.pad_leading(2, "0")
    |> String.upcase()
  end
end
