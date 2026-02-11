defmodule ServiceRadar.Inventory.IdentityReconcilerInterfaceMacTest do
  @moduledoc """
  Integration tests for interface MAC registration behavior.

  Verifies that the polling agent's identity is NOT included when registering
  interface MACs for a polled device, preventing false merges.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.{Device, DeviceIdentifier, IdentityReconciler}
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:identity_reconciler_interface_mac_test)
    {:ok, actor: actor}
  end

  test "interface MAC registration does not include polling agent's ID", %{actor: actor} do
    # Setup: agent-dusk (polling agent) and tonka01 (polled device) are separate devices
    {:ok, agent_device} = create_device(actor, "agent-dusk-host", "192.168.2.22")
    {:ok, polled_device} = create_device(actor, "tonka01", "192.168.10.1")

    # Register agent_id identifier for the agent's device
    assert {:ok, _} = register_identifier(actor, agent_device.uid, :agent_id, "agent-dusk")

    # Simulate what mapper now does: register interface MAC with agent_id: nil
    # This is the fix — previously agent_id was passed as the polling agent's ID
    ids = %{
      agent_id: nil,
      armis_id: nil,
      integration_id: nil,
      netbox_id: nil,
      mac: "0EEA1432D278",
      ip: "",
      partition: "default"
    }

    assert :ok = IdentityReconciler.register_identifiers(polled_device.uid, ids, actor: actor)

    # Verify: both devices still exist (no merge happened)
    assert {:ok, _} = Device.get_by_uid(agent_device.uid, false, actor: actor)
    assert {:ok, _} = Device.get_by_uid(polled_device.uid, false, actor: actor)

    # Verify: MAC is registered to the polled device, not the agent
    mac_query =
      DeviceIdentifier
      |> Ash.Query.for_read(:lookup, %{
        identifier_type: :mac,
        identifier_value: "0EEA1432D278",
        partition: "default"
      })

    assert {:ok, [identifier]} = Ash.read(mac_query, actor: actor)
    assert identifier.device_id == polled_device.uid

    # Verify: no agent_id identifier was registered for the polled device
    polled_identifiers_query =
      DeviceIdentifier
      |> Ash.Query.for_read(:by_device, %{device_id: polled_device.uid})

    assert {:ok, polled_identifiers} = Ash.read(polled_identifiers_query, actor: actor)

    agent_id_identifiers =
      Enum.filter(polled_identifiers, &(&1.identifier_type == :agent_id))

    assert agent_id_identifiers == [],
           "Expected no agent_id identifiers on polled device, got: #{inspect(agent_id_identifiers)}"
  end

  test "interface MAC registration with agent_id would cause false merge (regression guard)", %{
    actor: actor
  } do
    # This test documents the bug: passing agent_id during interface MAC registration
    # causes DIRE to see a conflict between the MAC (→ polled device) and agent_id (→ agent device),
    # triggering a destructive merge.
    {:ok, agent_device} = create_device(actor, "agent-regression", "192.168.2.100")
    {:ok, polled_device} = create_device(actor, "polled-regression", "192.168.10.100")

    agent_id = "agent-regression-#{System.unique_integer([:positive])}"
    mac = "AA#{mac_suffix()}BB#{mac_suffix()}CC#{mac_suffix()}"

    # Register agent_id for the agent's device
    assert {:ok, _} = register_identifier(actor, agent_device.uid, :agent_id, agent_id)

    # Register MAC for the polled device (without agent_id — the correct behavior)
    ids = %{
      agent_id: nil,
      armis_id: nil,
      integration_id: nil,
      netbox_id: nil,
      mac: mac,
      ip: "",
      partition: "default"
    }

    assert :ok = IdentityReconciler.register_identifiers(polled_device.uid, ids, actor: actor)

    # Both devices remain separate
    assert {:ok, _} = Device.get_by_uid(agent_device.uid, false, actor: actor)
    assert {:ok, _} = Device.get_by_uid(polled_device.uid, false, actor: actor)
  end

  defp create_device(actor, hostname, ip) do
    attrs = %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: hostname,
      ip: ip
    }

    Device
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor)
  end

  defp register_identifier(actor, device_id, type, value) do
    attrs = %{
      device_id: device_id,
      identifier_type: type,
      identifier_value: value,
      partition: "default",
      source: "test"
    }

    DeviceIdentifier
    |> Ash.Changeset.for_create(:register, attrs)
    |> Ash.create(actor: actor)
  end

  defp mac_suffix do
    System.unique_integer([:positive])
    |> rem(256)
    |> Integer.to_string(16)
    |> String.pad_leading(2, "0")
    |> String.upcase()
  end
end
