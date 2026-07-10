defmodule ServiceRadar.Inventory.IdentityReconcilerMergeGuardTest do
  @moduledoc """
  Integration coverage for merge stability guards:

  - distinct agent identities veto any automatic merge (including IP-alias
    driven merges), and the conflicting alias is invalidated
  - a device pair that merged within the cooldown window is not re-merged
    (oscillation breaker), in either direction
  - merged-away device IDs resolve to their canonical survivor instead of
    being resurrected
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.MergeAudit
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:identity_reconciler_merge_guard_test)
    handler_id = "merge-guard-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:serviceradar, :identity_reconciler, :merge, :guard_blocked],
          [:serviceradar, :identity_reconciler, :alias, :invalidated],
          [:serviceradar, :identity_reconciler, :agent_link, :reassign_blocked]
        ],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry_event, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, actor: actor}
  end

  describe "distinct agent identity guard" do
    test "blocks merging two devices bound to different agents", %{actor: actor} do
      {:ok, device_a} = create_device(actor, "guard-host-a")
      {:ok, device_b} = create_device(actor, "guard-host-b")

      {:ok, _} = register_identifier(actor, device_a.uid, :agent_id, unique("agent-a"))
      {:ok, _} = register_identifier(actor, device_b.uid, :agent_id, unique("agent-b"))

      assert {:error, {:merge_blocked, :distinct_agent_identity}} =
               IdentityReconciler.merge_devices(device_a.uid, device_b.uid,
                 actor: actor,
                 reason: "ip_alias_conflict"
               )

      assert_received {:telemetry_event,
                       [:serviceradar, :identity_reconciler, :merge, :guard_blocked], %{count: 1},
                       %{guard: :distinct_agent_identity}}

      assert {:ok, %Device{deleted_at: nil}} =
               Device.get_by_uid(device_a.uid, false, actor: actor)

      assert {:ok, %Device{deleted_at: nil}} =
               Device.get_by_uid(device_b.uid, false, actor: actor)
    end

    test "manual merges bypass the guard", %{actor: actor} do
      {:ok, device_a} = create_device(actor, "manual-host-a")
      {:ok, device_b} = create_device(actor, "manual-host-b")

      {:ok, _} = register_identifier(actor, device_a.uid, :agent_id, unique("agent-ma"))
      {:ok, _} = register_identifier(actor, device_b.uid, :agent_id, unique("agent-mb"))

      assert :ok =
               IdentityReconciler.merge_devices(device_a.uid, device_b.uid,
                 actor: actor,
                 reason: "manual_merge"
               )
    end

    test "resolution invalidates a confirmed alias that conflicts with agent identity",
         %{actor: actor} do
      agent_a = unique("agent-alias-a")
      agent_b = unique("agent-alias-b")
      ip = unique_ip()

      {:ok, alias_owner} = create_device(actor, "alias-owner")
      {:ok, updating_device} = create_device(actor, "alias-updater")

      {:ok, _} = register_identifier(actor, alias_owner.uid, :agent_id, agent_a)
      {:ok, _} = register_identifier(actor, updating_device.uid, :agent_id, agent_b)

      {:ok, alias_state} = create_confirmed_alias(actor, alias_owner.uid, ip)

      # An update for the OTHER agent arriving from the aliased IP must not
      # merge the two agent devices; it must stale the poisoned alias.
      assert {:ok, resolved} =
               IdentityReconciler.resolve_device_id(
                 %{
                   device_id: nil,
                   ip: ip,
                   mac: nil,
                   partition: "default",
                   metadata: %{"agent_id" => agent_b}
                 },
                 actor: actor
               )

      assert resolved == updating_device.uid

      assert {:ok, %Device{deleted_at: nil}} =
               Device.get_by_uid(alias_owner.uid, false, actor: actor)

      assert_received {:telemetry_event,
                       [:serviceradar, :identity_reconciler, :alias, :invalidated], _,
                       %{alias_ip: ^ip}}

      assert {:ok, %DeviceAliasState{state: :stale}} = Ash.get(DeviceAliasState, alias_state.id)
    end

    test "resolution invalidates a confirmed alias across distinct MAC identity",
         %{actor: actor} do
      mac_a = unique_mac()
      mac_b = unique_mac()
      ip = unique_ip()

      {:ok, alias_owner} = create_device(actor, "alias-owner-mac")
      {:ok, updating_device} = create_device(actor, "alias-updater-mac")

      {:ok, _} = register_identifier(actor, alias_owner.uid, :mac, mac_a)
      {:ok, _} = register_identifier(actor, updating_device.uid, :mac, mac_b)

      {:ok, alias_state} = create_confirmed_alias(actor, alias_owner.uid, ip)

      # A recycled IP must never merge two devices on distinct hardware
      # (different MACs) — the network-agnostic tell of pod/DHCP churn. The
      # poisoned alias is staled instead of merging the two devices.
      assert {:ok, resolved} =
               IdentityReconciler.resolve_device_id(
                 %{
                   device_id: nil,
                   ip: ip,
                   mac: mac_b,
                   partition: "default",
                   metadata: %{}
                 },
                 actor: actor
               )

      assert resolved == updating_device.uid

      assert {:ok, %Device{deleted_at: nil}} =
               Device.get_by_uid(alias_owner.uid, false, actor: actor)

      assert {:ok, %DeviceAliasState{state: :stale}} = Ash.get(DeviceAliasState, alias_state.id)
    end
  end

  describe "agent-link anchor guard (prevent-at-source)" do
    test "a merge does not repoint an agent onto a survivor owned by a different agent",
         %{actor: actor} do
      agent_uid = unique("agent-anchor")
      other_agent_uid = unique("agent-other")

      # The agent's stable behavioral anchor: a device reciprocally owned by
      # it (ocsf_devices.agent_id == agent uid).
      {:ok, anchor_device} = create_device_owned_by(actor, "anchor-host", agent_uid)

      # The device the agent currently links to, about to be merged away. It
      # carries no agent identity, so the merge guard itself does not fire —
      # only the reassignment anchor guard is exercised.
      {:ok, from_device} = create_device(actor, "anchor-from")

      # The merge survivor, reciprocally owned by a DIFFERENT agent.
      {:ok, to_device} = create_device_owned_by(actor, "anchor-to", other_agent_uid)

      {:ok, _agent} = create_agent(actor, agent_uid, from_device.uid)

      # Manual reason bypasses the merge guard; the merge proceeds and would
      # normally drag every agent on `from` over to `to`.
      assert :ok =
               IdentityReconciler.merge_devices(from_device.uid, to_device.uid,
                 actor: actor,
                 reason: "manual_merge"
               )

      # The agent was NOT welded onto the foreign-owned survivor.
      {:ok, agent} = Agent.get_by_uid(agent_uid, actor: actor)
      refute agent.device_uid == to_device.uid

      assert_received {:telemetry_event,
                       [:serviceradar, :identity_reconciler, :agent_link, :reassign_blocked],
                       %{count: 1}, %{agent_uid: ^agent_uid, to_device_id: to_uid}}

      assert to_uid == to_device.uid

      # The anchor device remains live and reciprocally owned.
      assert {:ok, %Device{deleted_at: nil}} =
               Device.get_by_uid(anchor_device.uid, false, actor: actor)
    end

    test "a merge still repoints an agent with no conflicting anchor", %{actor: actor} do
      agent_uid = unique("agent-clean")

      {:ok, from_device} = create_device(actor, "clean-from")
      {:ok, to_device} = create_device(actor, "clean-to")

      {:ok, _agent} = create_agent(actor, agent_uid, from_device.uid)

      assert :ok =
               IdentityReconciler.merge_devices(from_device.uid, to_device.uid,
                 actor: actor,
                 reason: "manual_merge"
               )

      # No conflicting anchor -> default reassignment behavior is preserved.
      {:ok, agent} = Agent.get_by_uid(agent_uid, actor: actor)
      assert agent.device_uid == to_device.uid

      refute_received {:telemetry_event,
                       [:serviceradar, :identity_reconciler, :agent_link, :reassign_blocked], _,
                       _}
    end
  end

  describe "merge cooldown (oscillation breaker)" do
    test "blocks re-merging a pair that merged within the window, in either direction",
         %{actor: actor} do
      {:ok, device_x} = create_device(actor, "cooldown-x")
      {:ok, device_y} = create_device(actor, "cooldown-y")

      {:ok, _} =
        IdentityReconciler.record_merge(device_x.uid, device_y.uid, "ip_alias_conflict",
          actor: actor
        )

      assert {:error, {:merge_blocked, :merge_cooldown}} =
               IdentityReconciler.merge_devices(device_x.uid, device_y.uid,
                 actor: actor,
                 reason: "ip_alias_conflict"
               )

      assert {:error, {:merge_blocked, :merge_cooldown}} =
               IdentityReconciler.merge_devices(device_y.uid, device_x.uid,
                 actor: actor,
                 reason: "identifier_conflict"
               )

      assert_received {:telemetry_event,
                       [:serviceradar, :identity_reconciler, :merge, :guard_blocked], %{count: 1},
                       %{guard: :merge_cooldown}}
    end

    test "manual merges bypass the cooldown", %{actor: actor} do
      {:ok, device_x} = create_device(actor, "cooldown-manual-x")
      {:ok, device_y} = create_device(actor, "cooldown-manual-y")

      {:ok, _} =
        IdentityReconciler.record_merge(device_x.uid, device_y.uid, "ip_alias_conflict",
          actor: actor
        )

      assert :ok =
               IdentityReconciler.merge_devices(device_x.uid, device_y.uid,
                 actor: actor,
                 reason: "manual_merge"
               )
    end
  end

  describe "canonical follow (tombstone resurrection protection)" do
    test "a merged-away sr: ID resolves to the canonical survivor", %{actor: actor} do
      {:ok, device_from} = create_device(actor, "follow-from")
      {:ok, device_to} = create_device(actor, "follow-to")

      assert :ok =
               IdentityReconciler.merge_devices(device_from.uid, device_to.uid,
                 actor: actor,
                 reason: "manual_merge"
               )

      assert IdentityReconciler.follow_canonical_device_id(device_from.uid, actor) ==
               device_to.uid

      # An update still carrying the merged-away ID resolves to the survivor
      # instead of resurrecting the tombstone.
      assert {:ok, resolved} =
               IdentityReconciler.resolve_device_id(
                 %{
                   device_id: device_from.uid,
                   ip: nil,
                   mac: nil,
                   partition: "default",
                   metadata: %{}
                 },
                 actor: actor
               )

      assert resolved == device_to.uid
    end

    test "a live (recreated) device is returned unchanged", %{actor: actor} do
      {:ok, device_live} = create_device(actor, "follow-live")

      assert IdentityReconciler.follow_canonical_device_id(device_live.uid, actor) ==
               device_live.uid
    end

    test "an unmerge audit is cooldown evidence, not a canonical redirect", %{actor: actor} do
      {:ok, survivor} = create_device(actor, "unmerge-survivor")
      {:ok, split} = create_device(actor, "unmerge-split")

      assert {:ok, _audit} =
               MergeAudit.record(
                 %{
                   from_device_id: survivor.uid,
                   to_device_id: split.uid,
                   reason: "unmerge",
                   source: "test"
                 },
                 actor: actor
               )

      assert {:ok, _deleted} =
               survivor
               |> Ash.Changeset.for_update(:soft_delete, %{
                 deleted_reason: "test",
                 deleted_by: "test"
               })
               |> Ash.update(actor: actor)

      assert IdentityReconciler.follow_canonical_device_id(survivor.uid, actor) == survivor.uid
    end

    test "unmerge rows are not canonical lineage for survivor metric history", %{actor: actor} do
      {:ok, survivor} = create_device(actor, "lineage-survivor")
      {:ok, merged_away} = create_device(actor, "lineage-merged-away")
      {:ok, current_split} = create_device(actor, "lineage-current-split")

      assert {:ok, _audit} =
               MergeAudit.record(
                 %{
                   from_device_id: merged_away.uid,
                   to_device_id: survivor.uid,
                   reason: "manual_merge",
                   source: "test"
                 },
                 actor: actor
               )

      assert {:ok, _audit} =
               MergeAudit.record(
                 %{
                   from_device_id: current_split.uid,
                   to_device_id: survivor.uid,
                   reason: "unmerge",
                   source: "test"
                 },
                 actor: actor
               )

      assert {:ok, lineage} = MergeAudit.get_merged_from(survivor.uid, actor: actor)
      assert Enum.map(lineage, & &1.from_device_id) == [merged_away.uid]
      refute Enum.any?(lineage, &(&1.from_device_id == current_split.uid))
    end

    test "legacy null-reason merge audits remain canonical redirects", %{actor: actor} do
      {:ok, merged} = create_device(actor, "legacy-null-merge")
      {:ok, survivor} = create_device(actor, "legacy-null-survivor")

      assert {:ok, _audit} =
               MergeAudit.record(
                 %{
                   from_device_id: merged.uid,
                   to_device_id: survivor.uid,
                   reason: nil,
                   source: "legacy"
                 },
                 actor: actor
               )

      assert {:ok, _deleted} =
               merged
               |> Ash.Changeset.for_update(:soft_delete, %{
                 deleted_reason: "legacy_merge",
                 deleted_by: "test"
               })
               |> Ash.update(actor: actor)

      assert IdentityReconciler.follow_canonical_device_id(merged.uid, actor) == survivor.uid
    end
  end

  describe "atomic MAC registration" do
    test "registers each atomic MAC and never the comma blob", %{actor: actor} do
      {:ok, device} = create_device(actor, "atomic-mac-host")

      mac_a = unique_mac()
      mac_b = unique_mac()

      ids =
        IdentityReconciler.extract_strong_identifiers(%{
          device_id: device.uid,
          ip: nil,
          mac: "#{mac_a},#{mac_b}",
          partition: "default",
          metadata: %{}
        })

      assert :ok = IdentityReconciler.register_identifiers(device.uid, ids, actor: actor)

      {:ok, identifiers} =
        DeviceIdentifier
        |> Ash.Query.filter(device_id == ^device.uid and identifier_type == :mac)
        |> Ash.read(actor: actor)

      values = identifiers |> Enum.map(& &1.identifier_value) |> Enum.sort()

      assert values == Enum.sort([mac_a, mac_b])
      refute Enum.any?(values, &String.contains?(&1, ","))
    end

    test "legacy blob identifier rows still resolve the device", %{actor: actor} do
      {:ok, device} = create_device(actor, "legacy-blob-host")

      mac_a = unique_mac()
      mac_b = unique_mac()
      blob = "#{mac_a},#{mac_b}"

      # Simulate a pre-validation identifier row holding the raw blob value.
      {:ok, _} = register_identifier(actor, device.uid, :mac, blob)

      ids =
        IdentityReconciler.extract_strong_identifiers(%{
          device_id: nil,
          ip: nil,
          mac: blob,
          partition: "default",
          metadata: %{}
        })

      assert {:ok, resolved} = IdentityReconciler.lookup_by_strong_identifiers(ids, actor)
      assert resolved == device.uid
    end
  end

  defp create_device(actor, hostname) do
    attrs = %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: unique(hostname),
      ip: nil
    }

    Device
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor)
  end

  defp create_device_owned_by(actor, hostname, agent_uid) do
    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: unique(hostname),
      ip: nil,
      agent_id: agent_uid
    })
    |> Ash.create(actor: actor)
  end

  defp create_agent(actor, agent_uid, device_uid) do
    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      %{
        uid: agent_uid,
        name: "Anchor Guard Test #{agent_uid}",
        host: "127.0.0.1",
        port: 50_051,
        device_uid: device_uid
      },
      actor: actor
    )
    |> Ash.create()
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

  defp create_confirmed_alias(actor, device_id, ip) do
    {:ok, alias_state} =
      DeviceAliasState
      |> Ash.Changeset.for_create(:detect, %{
        device_id: device_id,
        alias_type: :ip,
        alias_value: ip,
        partition: "default"
      })
      |> Ash.create(actor: actor)

    alias_state
    |> Ash.Changeset.for_update(:confirm, %{})
    |> Ash.update(actor: actor)
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp unique_ip do
    a = System.unique_integer([:positive])
    "10.#{rem(div(a, 65_536), 200) + 1}.#{rem(div(a, 256), 256)}.#{rem(a, 254) + 1}"
  end

  defp unique_mac do
    suffix =
      [:positive]
      |> System.unique_integer()
      |> rem(0x1000000)
      |> Integer.to_string(16)
      |> String.pad_leading(6, "0")
      |> String.upcase()

    # 02 prefix would be locally administered; use a globally-unique OUI.
    "001A2B" <> suffix
  end
end
