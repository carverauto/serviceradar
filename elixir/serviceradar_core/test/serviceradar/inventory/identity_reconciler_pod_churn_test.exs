defmodule ServiceRadar.Inventory.IdentityReconcilerPodChurnTest do
  @moduledoc """
  E2E coverage for task 6.5 (`refactor-device-identity-reconciliation`):
  kubernetes agent pod churn must not mint duplicate devices.

  Simulates a k8s pod redeploy: an agent with a stable `agent_id` enrolls
  (device created + identifiers registered), then re-enrolls with a NEW pod
  IP, a NEW hostname suffix, and a fresh pod interface MAC. The re-enrollment
  must resolve to the SAME canonical device (no duplicate), and
  `ocsf_agents.device_uid` must stay unchanged.

  Also covers the tombstone-resurrection interplay: after the agent's device
  was merged away, a re-enrollment through the public path must land on the
  merge survivor (follow_canonical_device_id semantics) instead of
  resurrecting the tombstone.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:pod_churn_test)
    unique = System.unique_integer([:positive])

    {:ok, actor: actor, unique: unique}
  end

  test "pod redeploy (new IP + hostname suffix) resolves to the same canonical device",
       %{actor: actor, unique: unique} do
    agent_id = "pod-churn-agent-#{unique}"
    mac_node = unique_mac(unique, 0)
    mac_new_pod = unique_mac(unique, 1)
    ip_first = unique_ip()
    ip_second = unique_ip()
    refute ip_first == ip_second

    :ok = AgentGatewaySync.upsert_agent(agent_id, %{host: ip_first, capabilities: ["sysmon"]})

    attrs_first = enroll_attrs("pod-churn-host-#{unique}-aaaaa", ip_first, [mac_node])
    assert {:ok, device_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs_first)

    # Enrollment registered agent_id + host MAC identifiers on the device.
    assert identifier_owners(actor, :agent_id, agent_id) == [device_uid]
    assert identifier_owners(actor, :mac, mac_node) == [device_uid]

    {:ok, %Agent{device_uid: linked_first}} = Agent.get_by_uid(agent_id, actor: actor)
    assert linked_first == device_uid

    # Pod redeploy: new pod IP, new hostname suffix, fresh pod interface MAC.
    attrs_second =
      enroll_attrs("pod-churn-host-#{unique}-bbbbb", ip_second, [mac_node, mac_new_pod])

    assert {:ok, device_uid_after} =
             AgentGatewaySync.ensure_device_for_agent(agent_id, attrs_second)

    # Same canonical device — no duplicate minted.
    assert device_uid_after == device_uid
    assert [%Device{uid: ^device_uid}] = live_devices_for_agent(actor, agent_id)

    # ocsf_agents.device_uid unchanged.
    {:ok, %Agent{device_uid: linked_second}} = Agent.get_by_uid(agent_id, actor: actor)
    assert linked_second == device_uid

    # agent_id identifier still points only at the canonical device.
    assert identifier_owners(actor, :agent_id, agent_id) == [device_uid]

    # New pod facts landed on the same device, including the fresh pod MAC.
    {:ok, device} = Device.get_by_uid(device_uid, false, actor: actor)
    assert device.hostname == "pod-churn-host-#{unique}-bbbbb"
    assert device.ip == ip_second
    assert identifier_owners(actor, :mac, mac_new_pod) == [device_uid]
  end

  test "re-enrollment after the agent device was merged away lands on the survivor",
       %{actor: actor, unique: unique} do
    agent_id = "pod-churn-merge-agent-#{unique}"
    ip_first = unique_ip()
    ip_second = unique_ip()

    :ok = AgentGatewaySync.upsert_agent(agent_id, %{host: ip_first, capabilities: ["sysmon"]})

    attrs_first = enroll_attrs("pod-churn-merge-#{unique}-aaaaa", ip_first, [])
    assert {:ok, original_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs_first)

    # An operator merges the agent device into a survivor record.
    {:ok, survivor} = create_device(actor, "pod-churn-survivor-#{unique}")

    assert :ok =
             IdentityReconciler.merge_devices(original_uid, survivor.uid,
               actor: actor,
               reason: "manual_merge"
             )

    # The original device is tombstoned and maps to the survivor.
    assert {:ok, %Device{deleted_at: %DateTime{}}} =
             Device.get_by_uid(original_uid, true, actor: actor)

    assert IdentityReconciler.follow_canonical_device_id(original_uid, actor) == survivor.uid

    # Pod churn re-enrollment must land on the survivor, not resurrect the
    # tombstoned device.
    attrs_second = enroll_attrs("pod-churn-merge-#{unique}-bbbbb", ip_second, [])

    assert {:ok, resolved_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs_second)
    assert resolved_uid == survivor.uid

    {:ok, %Agent{device_uid: linked}} = Agent.get_by_uid(agent_id, actor: actor)
    assert linked == survivor.uid

    # Tombstone stays dead; identifiers point only at the survivor.
    assert {:ok, %Device{deleted_at: %DateTime{}}} =
             Device.get_by_uid(original_uid, true, actor: actor)

    assert identifier_owners(actor, :agent_id, agent_id) == [survivor.uid]
  end

  defp enroll_attrs(hostname, source_ip, host_macs) do
    %{
      hostname: hostname,
      os: "linux",
      arch: "amd64",
      partition: "default",
      source_ip: source_ip,
      capabilities: ["sysmon"],
      host_macs: host_macs
    }
  end

  defp identifier_owners(actor, type, value) do
    DeviceIdentifier
    |> Ash.Query.filter(identifier_type == ^type and identifier_value == ^value)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.device_id)
    |> Enum.uniq()
  end

  defp live_devices_for_agent(actor, agent_id) do
    Device
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(agent_id == ^agent_id)
    |> Ash.read!(actor: actor)
    |> case do
      %{results: results} -> results
      results when is_list(results) -> results
    end
  end

  defp create_device(actor, hostname) do
    attrs = %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: hostname,
      name: hostname,
      ip: nil
    }

    Device
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor)
  end

  # Globally-unique OUI prefix (not locally administered) so the MACs count
  # as strong identifiers; uniqueness comes from the test's unique integer.
  defp unique_mac(unique, offset) do
    suffix =
      (unique * 8 + offset)
      |> rem(0x1000000)
      |> Integer.to_string(16)
      |> String.pad_leading(6, "0")
      |> String.upcase()

    "001B2C" <> suffix
  end

  defp unique_ip do
    a = System.unique_integer([:positive])
    "10.#{rem(div(a, 65_536), 200) + 1}.#{rem(div(a, 256), 256)}.#{rem(a, 254) + 1}"
  end
end
