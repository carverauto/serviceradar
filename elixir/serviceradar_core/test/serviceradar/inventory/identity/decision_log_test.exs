defmodule ServiceRadar.Inventory.Identity.DecisionLogTest do
  @moduledoc """
  Every identity decision that blocks, declines or overrides a merge leaves a persisted
  `platform.identity_decisions` row (requirement "Identity Decisions Are Never Silent", #4613).

  Each test drives the real decision path -- MergeEngine, MergePolicy, SourceAuthorityGuard,
  AliasGuard -- and reads the row back. The DIRE resolution traces
  (`dire_resolution_trace_test.exs`) cover the same rows on the ingestion paths.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.AliasGuard
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Inventory.IdentityDecision
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:decision_log_test)}
  end

  describe "MergePolicy refusals" do
    test "a refused randomized-MAC match set is recorded as a policy block", %{actor: actor} do
      a = create_device!(actor)
      b = create_device!(actor)

      matches = [
        {:mac, %{value: laa_mac(), device_id: a.uid}},
        {:mac, %{value: laa_mac(), device_id: b.uid}}
      ]

      MergeEngine.merge_conflicting_devices(a.uid, [a.uid, b.uid], matches, actor)

      assert [decision] = decisions_for(actor, a.uid)
      assert decision.decision_kind == :policy_block
      assert decision.reason == "mac_only_conflict"
      assert decision.device_uids == Enum.sort([a.uid, b.uid])
      assert decision.source == "identifier_conflict"
      assert decision.occurrence_count == 1
      assert length(decision.evidence["identifiers"]) == 2

      assert live?(actor, a.uid) and live?(actor, b.uid), "the refused merge did not happen"
    end

    test "the same refusal again counts on its record instead of adding one", %{actor: actor} do
      a = create_device!(actor)
      b = create_device!(actor)
      matches = [{:mac, %{value: laa_mac(), device_id: a.uid}}]

      MergeEngine.merge_conflicting_devices(a.uid, [a.uid, b.uid], matches, actor)
      [first] = decisions_for(actor, a.uid)

      MergeEngine.merge_conflicting_devices(a.uid, [b.uid, a.uid], matches, actor)
      assert [again] = decisions_for(actor, a.uid)

      assert again.id == first.id
      assert again.occurrence_count == 2
      assert again.first_decided_at == first.first_decided_at
      assert DateTime.compare(again.last_decided_at, first.last_decided_at) in [:gt, :eq]
    end
  end

  describe "globally-unique MAC evidence (#4612)" do
    test "records merge on it, and a randomized-MAC link drops out as a recorded block", %{
      actor: actor
    } do
      a = create_device!(actor)
      b = create_device!(actor)
      c = create_device!(actor)

      matches = [
        {:mac, %{value: uaa_mac(), device_id: a.uid}},
        {:mac, %{value: uaa_mac(), device_id: b.uid}},
        {:mac, %{value: laa_mac(), device_id: c.uid}}
      ]

      MergeEngine.merge_conflicting_devices(a.uid, [a.uid, b.uid, c.uid], matches, actor)

      refute live?(actor, b.uid), "the record sharing a globally-unique MAC converged"
      assert live?(actor, a.uid) and live?(actor, c.uid)

      assert [decision] = decisions_for(actor, c.uid)
      assert decision.decision_kind == :policy_block
      assert decision.reason == "randomized_mac_link"
      assert decision.device_uids == Enum.sort([a.uid, c.uid])
    end
  end

  describe "MergeEngine guards" do
    test "distinct agent identities refuse the merge and record a guard block", %{actor: actor} do
      a = create_device!(actor)
      b = create_device!(actor)
      register!(actor, a.uid, :agent_id, "decision-log-agent-#{unique()}")
      register!(actor, b.uid, :agent_id, "decision-log-agent-#{unique()}")

      assert {:error, {:merge_blocked, :distinct_agent_identity}} =
               MergeEngine.merge_devices(a.uid, b.uid,
                 actor: actor,
                 reason: "identifier_conflict"
               )

      assert [decision] = decisions_for(actor, a.uid)
      assert decision.decision_kind == :guard_block
      assert decision.reason == "distinct_agent_identity"
      assert decision.device_uids == Enum.sort([a.uid, b.uid])
      assert decision.evidence["merge_reason"] == "identifier_conflict"
    end

    test "different source-authoritative ids refuse the merge and record a source block",
         %{actor: actor} do
      a = create_device!(actor)
      b = create_device!(actor)
      register!(actor, a.uid, :armis_device_id, "9#{unique()}")
      register!(actor, b.uid, :armis_device_id, "9#{unique()}")

      assert {:error, {:merge_blocked, :source_authority_conflict}} =
               MergeEngine.merge_devices(a.uid, b.uid,
                 actor: actor,
                 reason: "identifier_conflict"
               )

      assert [decision] = decisions_for(actor, a.uid)
      assert decision.decision_kind == :source_block
      assert decision.reason == "source_authority_conflict"
      assert decision.device_uids == Enum.sort([a.uid, b.uid])
      assert map_size(decision.evidence["source_ids"]) == 2
    end

    test "an administrative merge is not a decision to record", %{actor: actor} do
      a = create_device!(actor)
      b = create_device!(actor)

      assert :ok = MergeEngine.merge_devices(a.uid, b.uid, actor: actor, reason: "manual_merge")
      assert decisions_for(actor, a.uid) == []
    end
  end

  describe "AliasGuard" do
    test "invalidating a conflicting alias records the decision and its address", %{actor: actor} do
      owner = create_device!(actor)
      other = create_device!(actor)
      ip = unique_ip()
      create_alias_state!(actor, owner.uid, ip)

      assert :ok = AliasGuard.invalidate_ip_alias(ip, "default", owner.uid, other.uid, actor)

      assert [decision] = decisions_for(actor, owner.uid)
      assert decision.decision_kind == :alias_invalidated
      assert decision.subject == ip
      assert decision.device_uids == Enum.sort([owner.uid, other.uid])
      assert decision.evidence["staled_alias_count"] == 1
    end

    test "nothing to invalidate is no decision", %{actor: actor} do
      owner = create_device!(actor)
      other = create_device!(actor)

      assert :ok =
               AliasGuard.invalidate_ip_alias(unique_ip(), "default", owner.uid, other.uid, actor)

      assert decisions_for(actor, owner.uid) == []
    end
  end

  defp decisions_for(actor, uid) do
    {:ok, decisions} = IdentityDecision.for_device(uid, actor: actor)
    decisions
  end

  defp live?(actor, uid) do
    match?({:ok, %Device{deleted_at: nil}}, Device.get_by_uid(uid, true, actor: actor))
  end

  defp create_device!(actor) do
    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: "decision-log-test",
      ip: unique_ip()
    })
    |> Ash.create!(actor: actor)
  end

  defp register!(actor, uid, type, value) do
    DeviceIdentifier
    |> Ash.Changeset.for_create(:register, %{
      device_id: uid,
      identifier_type: type,
      identifier_value: value,
      partition: "default",
      source: "test"
    })
    |> Ash.create!(actor: actor)
  end

  defp create_alias_state!(actor, uid, ip) do
    DeviceAliasState
    |> Ash.Changeset.for_create(:detect, %{
      device_id: uid,
      alias_type: :ip,
      alias_value: ip,
      partition: "default"
    })
    |> Ash.create!(actor: actor)
  end

  defp unique, do: System.unique_integer([:positive])

  # Documentation-range addresses (RFC 5737) and locally-administered MACs under the
  # documentation OUI (RFC 7042), so no fixture value can name a real network. Consecutive
  # unique integers keep the values of one test distinct.
  defp unique_ip, do: "203.0.113.#{rem(unique(), 254) + 1}"

  # Globally-unique (universally administered) MACs under the documentation OUI.
  defp uaa_mac do
    "00:00:5E:00:53:" <> Base.encode16(<<rem(unique(), 256)>>)
  end

  defp laa_mac do
    "02:00:5E:00:53:" <> Base.encode16(<<rem(unique(), 256)>>)
  end
end
