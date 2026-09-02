defmodule ServiceRadar.Inventory.AgentLinkRepairWorkerTest do
  @moduledoc """
  Integration coverage for periodic agent-to-device link repair (DIRE task 6.2).
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.AgentLinkRepairWorker
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
    actor = SystemActor.system(:agent_link_repair_worker_test)
    {:ok, actor: actor}
  end

  test "repoints agent and agent_id identifier from tombstoned device to canonical survivor",
       %{actor: actor} do
    {:ok, device_a} = create_device(actor)
    {:ok, device_b} = create_device(actor)

    # Merge A into B (manual reason bypasses merge guards): A becomes a
    # tombstone with a merge-audit trail pointing at B.
    assert :ok =
             IdentityReconciler.merge_devices(device_a.uid, device_b.uid,
               reason: "manual_test_repair",
               actor: actor
             )

    # Simulate drift: an agent row still pointing at the tombstoned device,
    # with its agent_id identifier also still on the tombstoned device.
    agent_uid = unique_agent_uid()
    {:ok, _agent} = create_agent(actor, agent_uid, device_a.uid)
    {:ok, _identifier} = upsert_agent_identifier(actor, agent_uid, device_a.uid)

    handler_id = attach_repair_telemetry(agent_uid)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    AgentLinkRepairWorker.run_repair()

    {:ok, agent} = Agent.get_by_uid(agent_uid, actor: actor)
    assert agent.device_uid == device_b.uid

    assert [identifier] = agent_identifiers(actor, agent_uid)
    assert identifier.device_id == device_b.uid

    assert_received {:repaired, %{repair: :device_link, from: from_a, to: to_b}}
    assert from_a == device_a.uid
    assert to_b == device_b.uid

    assert_received {:repaired, %{repair: :identifier, from: ident_from, to: ident_to}}
    assert ident_from == device_a.uid
    assert ident_to == device_b.uid
  end

  test "is idempotent: a repaired agent is not repaired again", %{actor: actor} do
    {:ok, device_a} = create_device(actor)
    {:ok, device_b} = create_device(actor)

    assert :ok =
             IdentityReconciler.merge_devices(device_a.uid, device_b.uid,
               reason: "manual_test_repair",
               actor: actor
             )

    agent_uid = unique_agent_uid()
    {:ok, _agent} = create_agent(actor, agent_uid, device_a.uid)
    {:ok, _identifier} = upsert_agent_identifier(actor, agent_uid, device_a.uid)

    AgentLinkRepairWorker.run_repair()

    handler_id = attach_repair_telemetry(agent_uid)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    AgentLinkRepairWorker.run_repair()

    {:ok, agent} = Agent.get_by_uid(agent_uid, actor: actor)
    assert agent.device_uid == device_b.uid

    refute_received {:repaired, _}
  end

  test "leaves agents linked to live devices untouched", %{actor: actor} do
    {:ok, device} = create_device(actor)

    agent_uid = unique_agent_uid()
    {:ok, _agent} = create_agent(actor, agent_uid, device.uid)
    {:ok, _identifier} = upsert_agent_identifier(actor, agent_uid, device.uid)

    handler_id = attach_repair_telemetry(agent_uid)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    AgentLinkRepairWorker.run_repair()

    {:ok, agent} = Agent.get_by_uid(agent_uid, actor: actor)
    assert agent.device_uid == device.uid

    assert [identifier] = agent_identifiers(actor, agent_uid)
    assert identifier.device_id == device.uid

    refute_received {:repaired, _}
  end

  test "repoints an unavailable agent mislinked to a live device owned by another agent",
       %{actor: actor} do
    # dusk pathology: the agent's OWN host device carries its agent_id
    # reciprocally, but the agent row points at a DIFFERENT live device that is
    # reciprocally owned by another agent.
    agent_uid = unique_agent_uid()
    other_agent_uid = unique_agent_uid()

    {:ok, own_device} = create_device_owned_by(actor, agent_uid)
    {:ok, wrong_device} = create_device_owned_by(actor, other_agent_uid)

    {:ok, _agent} = create_unavailable_agent(actor, agent_uid, wrong_device.uid)
    # agent_id identifier (the strong anchor) sits on the agent's own device.
    {:ok, _identifier} = upsert_agent_identifier(actor, agent_uid, own_device.uid)

    handler_id = attach_repair_telemetry(agent_uid)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    AgentLinkRepairWorker.run_repair()

    {:ok, agent} = Agent.get_by_uid(agent_uid, actor: actor)
    assert agent.device_uid == own_device.uid

    assert_received {:repaired, %{repair: :mislink, from: from, to: to}}
    assert from == wrong_device.uid
    assert to == own_device.uid
  end

  test "does not follow a tombstone into a survivor that conflicts with the agent's anchor",
       %{actor: actor} do
    # The agent points at a tombstoned device whose canonical survivor is
    # reciprocally owned by a DIFFERENT agent. Following the tombstone would
    # re-create the mislink, so the worker repoints to the agent's own anchor.
    agent_uid = unique_agent_uid()
    other_agent_uid = unique_agent_uid()

    {:ok, own_device} = create_device_owned_by(actor, agent_uid)
    {:ok, from_device} = create_device(actor)
    {:ok, survivor} = create_device_owned_by(actor, other_agent_uid)

    # Manual merge tombstones from_device with a trail pointing at survivor.
    assert :ok =
             IdentityReconciler.merge_devices(from_device.uid, survivor.uid,
               reason: "manual_test_repair",
               actor: actor
             )

    {:ok, _agent} = create_unavailable_agent(actor, agent_uid, from_device.uid)
    {:ok, _identifier} = upsert_agent_identifier(actor, agent_uid, own_device.uid)

    handler_id = attach_repair_telemetry(agent_uid)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    AgentLinkRepairWorker.run_repair()

    {:ok, agent} = Agent.get_by_uid(agent_uid, actor: actor)
    # Repointed to the agent's own anchor, NOT the conflicting survivor.
    assert agent.device_uid == own_device.uid
    refute agent.device_uid == survivor.uid

    assert_received {:repaired, %{repair: :mislink, to: to}}
    assert to == own_device.uid
  end

  test "leaves an ambiguous mislink untouched and emits mislink_unresolved telemetry",
       %{actor: actor} do
    # The linked device is owned by another agent (a real mislink), but the
    # agent has TWO anchor devices -> no single unambiguous target -> do no harm.
    agent_uid = unique_agent_uid()
    other_agent_uid = unique_agent_uid()

    {:ok, anchor_a} = create_device_owned_by(actor, agent_uid)
    {:ok, anchor_b} = create_device_owned_by(actor, agent_uid)
    {:ok, wrong_device} = create_device_owned_by(actor, other_agent_uid)

    {:ok, _agent} = create_unavailable_agent(actor, agent_uid, wrong_device.uid)
    # Two agent_id identifiers -> two anchor devices, intentionally ambiguous.
    {:ok, _} = upsert_agent_identifier(actor, agent_uid, anchor_a.uid)
    {:ok, _} = upsert_agent_identifier(actor, agent_uid, anchor_b.uid)

    handler_id = attach_repair_telemetry(agent_uid)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    unresolved_handler = attach_mislink_unresolved_telemetry(agent_uid)
    on_exit(fn -> :telemetry.detach(unresolved_handler) end)

    AgentLinkRepairWorker.run_repair()

    {:ok, agent} = Agent.get_by_uid(agent_uid, actor: actor)
    # Untouched: still linked to the wrong device (do no harm on ambiguity).
    assert agent.device_uid == wrong_device.uid

    refute_received {:repaired, %{repair: :mislink}}
    assert_received {:mislink_unresolved, %{device_uid: device_uid}}
    assert device_uid == wrong_device.uid
  end

  test "leaves a correctly-linked agent on its reciprocally-owned device untouched",
       %{actor: actor} do
    agent_uid = unique_agent_uid()
    {:ok, own_device} = create_device_owned_by(actor, agent_uid)

    {:ok, _agent} = create_agent(actor, agent_uid, own_device.uid)
    {:ok, _identifier} = upsert_agent_identifier(actor, agent_uid, own_device.uid)

    handler_id = attach_repair_telemetry(agent_uid)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    AgentLinkRepairWorker.run_repair()

    {:ok, agent} = Agent.get_by_uid(agent_uid, actor: actor)
    assert agent.device_uid == own_device.uid

    refute_received {:repaired, %{repair: :mislink}}
  end

  test "registers a missing agent_id identifier for a live-linked agent", %{actor: actor} do
    {:ok, device} = create_device(actor)

    agent_uid = unique_agent_uid()
    {:ok, _agent} = create_agent(actor, agent_uid, device.uid)

    handler_id = attach_repair_telemetry(agent_uid)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    AgentLinkRepairWorker.run_repair()

    assert [identifier] = agent_identifiers(actor, agent_uid)
    assert identifier.device_id == device.uid
    assert identifier.identifier_type == :agent_id
    assert identifier.source == "agent_link_repair"

    assert_received {:repaired, %{repair: :identifier_registered, to: to}}
    assert to == device.uid
  end

  defp create_device(actor) do
    uid = "sr:" <> Ecto.UUID.generate()
    seed = System.unique_integer([:positive, :monotonic])

    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: uid,
      ip: "10.77.#{rem(seed, 250) + 1}.#{rem(div(seed, 250), 250) + 1}",
      hostname: "repair-test-#{seed}"
    })
    |> Ash.create(actor: actor)
  end

  defp create_agent(actor, agent_uid, device_uid) do
    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      %{
        uid: agent_uid,
        name: "Link Repair Test #{agent_uid}",
        host: "127.0.0.1",
        port: 50_051,
        device_uid: device_uid
      },
      actor: actor
    )
    |> Ash.create()
  end

  defp create_unavailable_agent(actor, agent_uid, device_uid) do
    with {:ok, agent} <- create_agent(actor, agent_uid, device_uid) do
      agent
      |> Ash.Changeset.for_update(:mark_unavailable, %{reason: "test"})
      |> Ash.update(actor: actor)
    end
  end

  # A device that reciprocally declares it is reported BY the given agent
  # (the behavioral anchor: ocsf_devices.agent_id == agent uid).
  defp create_device_owned_by(actor, agent_uid) do
    uid = "sr:" <> Ecto.UUID.generate()
    seed = System.unique_integer([:positive, :monotonic])

    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: uid,
      ip: "10.78.#{rem(seed, 250) + 1}.#{rem(div(seed, 250), 250) + 1}",
      hostname: "owned-#{seed}",
      agent_id: agent_uid
    })
    |> Ash.create(actor: actor)
  end

  defp upsert_agent_identifier(actor, agent_uid, device_uid) do
    DeviceIdentifier
    |> Ash.Changeset.for_create(:upsert, %{
      device_id: device_uid,
      identifier_type: :agent_id,
      identifier_value: agent_uid,
      partition: "default",
      confidence: :strong,
      source: "test"
    })
    |> Ash.create(actor: actor)
  end

  defp agent_identifiers(actor, agent_uid) do
    DeviceIdentifier
    |> Ash.Query.filter(identifier_type == :agent_id and identifier_value == ^agent_uid)
    |> Ash.read!(actor: actor)
  end

  defp attach_repair_telemetry(agent_uid) do
    handler_id = "agent-link-repair-test-#{agent_uid}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:serviceradar, :agent_link_repair, :repaired],
        fn _event, _measurements, metadata, _config ->
          if metadata.agent_uid == agent_uid do
            send(parent, {:repaired, metadata})
          end
        end,
        nil
      )

    handler_id
  end

  defp attach_mislink_unresolved_telemetry(agent_uid) do
    handler_id = "agent-link-mislink-unresolved-test-#{agent_uid}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:serviceradar, :agent_link_repair, :mislink_unresolved],
        fn _event, _measurements, metadata, _config ->
          if metadata.agent_uid == agent_uid do
            send(parent, {:mislink_unresolved, metadata})
          end
        end,
        nil
      )

    handler_id
  end

  defp unique_agent_uid do
    "link-repair-agent-#{System.unique_integer([:positive, :monotonic])}"
  end
end
