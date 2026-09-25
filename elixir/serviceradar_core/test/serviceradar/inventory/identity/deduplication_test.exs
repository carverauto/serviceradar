defmodule ServiceRadar.Inventory.Identity.DeduplicationTest do
  @moduledoc """
  De-duplication tasks (#4604): every decision that leaves two devices unreconciled opens or
  updates exactly one task for that device set, and an operator's merge / mark-distinct /
  dismiss is recorded and enforced.

  Each blocking path is driven through its real entry point (MergeEngine, MergePolicy,
  SourceAuthorityGuard, AliasGuard, the sync device write, the duplicate sweep).
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.DeduplicationTask
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.DistinctDeviceAssertion
  alias ServiceRadar.Inventory.Identity.AliasGuard
  alias ServiceRadar.Inventory.Identity.DecisionLog
  alias ServiceRadar.Inventory.Identity.Deduplication
  alias ServiceRadar.Inventory.Identity.DuplicateSweep
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Inventory.IdentityDecision
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  @operator %{id: "dedup-test-operator", email: "operator@example.com", role: :operator}
  @viewer %{id: "dedup-test-viewer", email: "viewer@example.com", role: :viewer}

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:deduplication_test)}
  end

  describe "every blocking path opens exactly one task per candidate set" do
    test "a MergePolicy refusal", %{actor: actor} do
      [a, b] = devices(actor, 2)
      policy_block(a, b, actor)

      assert [%DeduplicationTask{category: "policy_block", status: :open} = task] =
               tasks_for(a.uid)

      assert task.device_uids == Enum.sort([a.uid, b.uid])
      assert task.last_reason == "mac_only_conflict"
    end

    test "a merge guard refusal (distinct agents)", %{actor: actor} do
      [a, b] = devices(actor, 2)
      register!(actor, a.uid, :agent_id, "dedup-agent-#{unique()}")
      register!(actor, b.uid, :agent_id, "dedup-agent-#{unique()}")

      assert {:error, {:merge_blocked, :distinct_agent_identity}} =
               MergeEngine.merge_devices(a.uid, b.uid,
                 actor: actor,
                 reason: "identifier_conflict"
               )

      assert [%DeduplicationTask{category: "guard_block", last_reason: "distinct_agent_identity"}] =
               tasks_for(a.uid)
    end

    test "a source-authority conflict", %{actor: actor} do
      [a, b] = devices(actor, 2)
      register!(actor, a.uid, :armis_device_id, "9#{unique()}")
      register!(actor, b.uid, :armis_device_id, "9#{unique()}")

      assert {:error, {:merge_blocked, :source_authority_conflict}} =
               MergeEngine.merge_devices(a.uid, b.uid,
                 actor: actor,
                 reason: "identifier_conflict"
               )

      assert [%DeduplicationTask{category: "source_block"}] = tasks_for(a.uid)
    end

    test "an invalidated IP alias", %{actor: actor} do
      [owner, other] = devices(actor, 2)
      ip = unique_ip()
      create_alias_state!(actor, owner.uid, ip)

      assert :ok = AliasGuard.invalidate_ip_alias(ip, "default", owner.uid, other.uid, actor)

      assert [%DeduplicationTask{category: "alias_invalidated"} = task] = tasks_for(owner.uid)
      assert task.device_uids == Enum.sort([owner.uid, other.uid])
    end

    test "an active-IP conflict on the sync path", %{actor: actor} do
      ip = unique_ip()
      first = "7#{unique()}"
      second = "7#{unique()}"

      assert :ok = SyncIngestor.ingest_updates([armis_update(first, ip)], actor: actor)
      assert :ok = SyncIngestor.ingest_updates([armis_update(second, ip)], actor: actor)

      first_uid = owner_of!(actor, first)
      second_uid = owner_of!(actor, second)

      assert [%DeduplicationTask{category: "ip_conflict"} = task] = tasks_for(second_uid)
      assert task.device_uids == Enum.sort([first_uid, second_uid])
    end

    test "an ambiguous duplicate component from the scheduled sweep", %{actor: actor} do
      [a, b, c] = devices(actor, 3)

      DuplicateSweep.record_blocked_components([%{device_ids: [a.uid, b.uid, c.uid]}])

      assert [%DeduplicationTask{category: "component_block"} = task] = tasks_for(b.uid)
      assert task.device_uids == Enum.sort([a.uid, b.uid, c.uid])
    end

    test "every blocked component of a sweep, past the capture limit, gets a task" do
      components =
        for _ <- 1..105 do
          %{device_ids: ["sr:" <> Ecto.UUID.generate(), "sr:" <> Ecto.UUID.generate()]}
        end

      DuplicateSweep.record_blocked_components(components)

      for %{device_ids: [first, _]} <- components do
        assert [%DeduplicationTask{category: "component_block"}] = tasks_for(first)
      end
    end

    test "a source-authoritative override", %{actor: actor} do
      [a, b] = devices(actor, 2)

      DecisionLog.record(:source_override, "source_id_governs_identity", [a.uid, b.uid],
        source: "resolver"
      )

      assert [%DeduplicationTask{category: "source_override"}] = tasks_for(a.uid)
    end

    test "a repeat, in any order, counts on the same task", %{actor: actor} do
      [a, b] = devices(actor, 2)
      policy_block(a, b, actor)
      policy_block(b, a, actor)

      assert [%DeduplicationTask{occurrence_count: 2}] = tasks_for(a.uid)
    end

    test "a decision about one device opens nothing", %{actor: actor} do
      [a] = devices(actor, 1)
      DecisionLog.record(:policy_block, "mac_only_conflict", [a.uid])

      assert tasks_for(a.uid) == []
    end
  end

  describe "mark distinct" do
    test "every automatic merge path, the scheduled backfill included, refuses the pair",
         %{actor: actor} do
      [a, b] = devices(actor, 2)
      policy_block(a, b, actor)
      [task] = tasks_for(a.uid)

      assert {:ok, %DeduplicationTask{status: :distinct, resolved_by: "operator@example.com"}} =
               Deduplication.mark_distinct(task, @operator, note: "two printers")

      assert Deduplication.asserted_distinct?(a.uid, b.uid)
      assert Deduplication.asserted_distinct?(b.uid, a.uid)

      for reason <- ["identifier_backfill", "identifier_conflict", "ip_alias_conflict"] do
        assert {:error, {:merge_blocked, :asserted_distinct}} =
                 MergeEngine.merge_devices(a.uid, b.uid, actor: actor, reason: reason)
      end

      assert live?(actor, a.uid) and live?(actor, b.uid)
    end

    test "a later refusal is recorded but does not reopen the task", %{actor: actor} do
      [a, b] = devices(actor, 2)
      policy_block(a, b, actor)
      [task] = tasks_for(a.uid)
      {:ok, _} = Deduplication.mark_distinct(task, @operator)

      {:error, _} =
        MergeEngine.merge_devices(a.uid, b.uid, actor: actor, reason: "identifier_conflict")

      policy_block(a, b, actor)

      assert [%DeduplicationTask{status: :distinct}] = tasks_for(a.uid)

      assert Enum.any?(decisions_for(actor, a.uid), fn d ->
               d.decision_kind == :guard_block and d.reason == "asserted_distinct"
             end)
    end

    test "an administrative merge still goes through", %{actor: actor} do
      [a, b] = devices(actor, 2)
      policy_block(a, b, actor)
      [task] = tasks_for(a.uid)
      {:ok, _} = Deduplication.mark_distinct(task, @operator)

      assert :ok = MergeEngine.merge_devices(a.uid, b.uid, actor: actor, reason: "manual_merge")
    end
  end

  describe "merge" do
    test "merges every other device into the survivor and records it", %{actor: actor} do
      [a, b, c] = devices(actor, 3)
      DuplicateSweep.record_blocked_components([%{device_ids: [a.uid, b.uid, c.uid]}])
      [task] = tasks_for(a.uid)

      assert {:ok, %DeduplicationTask{status: :merged, merged_into: survivor}} =
               Deduplication.merge(task, b.uid, @operator, note: "one device")

      assert survivor == b.uid
      assert live?(actor, b.uid)
      assert %Device{deleted_reason: "merged"} = device(actor, a.uid)
      assert %Device{deleted_reason: "merged"} = device(actor, c.uid)
    end

    test "a retry after a partial merge finishes the rest", %{actor: actor} do
      [a, b, c] = devices(actor, 3)
      DuplicateSweep.record_blocked_components([%{device_ids: [a.uid, b.uid, c.uid]}])
      [task] = tasks_for(a.uid)

      assert :ok = MergeEngine.merge_devices(a.uid, b.uid, actor: actor, reason: "manual_merge")

      assert {:ok, %DeduplicationTask{status: :merged, merged_into: survivor}} =
               Deduplication.merge(task, b.uid, @operator)

      assert survivor == b.uid
      assert live?(actor, b.uid)
      assert %Device{deleted_reason: "merged"} = device(actor, a.uid)
      assert %Device{deleted_reason: "merged"} = device(actor, c.uid)
    end

    test "the survivor must be one of the task's devices", %{actor: actor} do
      [a, b, outsider] = devices(actor, 3)
      policy_block(a, b, actor)
      [task] = tasks_for(a.uid)

      assert {:error, {:survivor_not_in_task, _}} =
               Deduplication.merge(task, outsider.uid, @operator)

      assert [%DeduplicationTask{status: :open}] = tasks_for(a.uid)
    end

    test "a viewer cannot resolve a task", %{actor: actor} do
      [a, b] = devices(actor, 2)
      policy_block(a, b, actor)
      [task] = tasks_for(a.uid)

      assert {:error, :forbidden} = Deduplication.merge(task, a.uid, @viewer)
      assert {:error, :forbidden} = Deduplication.mark_distinct(task, @viewer)
      assert live?(actor, a.uid) and live?(actor, b.uid)
    end
  end

  describe "dismiss" do
    test "a dismissed task stays dismissed as decisions repeat, until reopened", %{actor: actor} do
      [a, b] = devices(actor, 2)
      policy_block(a, b, actor)
      [task] = tasks_for(a.uid)

      assert {:ok, %DeduplicationTask{status: :dismissed}} =
               Deduplication.dismiss(task, @operator)

      policy_block(a, b, actor)

      assert [%DeduplicationTask{status: :dismissed, occurrence_count: 2} = task] =
               tasks_for(a.uid)

      assert {:ok, %DeduplicationTask{status: :open}} =
               task |> Ash.Changeset.for_update(:reopen, %{}, actor: @operator) |> Ash.update()
    end

    test "only an open task can be resolved", %{actor: actor} do
      [a, b] = devices(actor, 2)
      policy_block(a, b, actor)
      [task] = tasks_for(a.uid)
      {:ok, dismissed} = Deduplication.dismiss(task, @operator)

      assert {:error, {:task_not_open, :dismissed}} =
               Deduplication.mark_distinct(dismissed, @operator)
    end
  end

  test "distinct assertions store the pair in one order", %{actor: actor} do
    [a, b] = devices(actor, 2)
    [low, high] = Enum.sort([a.uid, b.uid])

    for {x, y} <- [{high, low}, {low, high}] do
      DistinctDeviceAssertion
      |> Ash.Changeset.for_create(:assert, %{device_a: x, device_b: y}, actor: @operator)
      |> Ash.create!()
    end

    assert [%DistinctDeviceAssertion{device_a: ^low, device_b: ^high}] =
             DistinctDeviceAssertion
             |> Ash.Query.filter(device_a == ^low)
             |> Ash.read!(actor: actor)
  end

  # ---------------------------------------------------------------------------------------

  defp policy_block(a, b, actor) do
    matches = [
      {:mac, %{value: laa_mac(), device_id: a.uid}},
      {:mac, %{value: laa_mac(), device_id: b.uid}}
    ]

    MergeEngine.merge_conflicting_devices(a.uid, [a.uid, b.uid], matches, actor)
  end

  defp tasks_for(uid) do
    {:ok, tasks} =
      DeduplicationTask.for_device(uid, actor: SystemActor.system(:deduplication_test))

    tasks
  end

  defp decisions_for(actor, uid) do
    {:ok, decisions} = IdentityDecision.for_device(uid, actor: actor)
    decisions
  end

  defp device(actor, uid) do
    {:ok, device} = Device.get_by_uid(uid, true, actor: actor)
    device
  end

  defp live?(actor, uid), do: is_nil(device(actor, uid).deleted_at)

  defp devices(actor, n) do
    for _ <- 1..n do
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "dedup-test",
        ip: unique_ip()
      })
      |> Ash.create!(actor: actor)
    end
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

  defp owner_of!(actor, armis_id) do
    [identifier | _] =
      DeviceIdentifier
      |> Ash.Query.filter(identifier_type == :armis_device_id and identifier_value == ^armis_id)
      |> Ash.read!(actor: actor)

    identifier.device_id
  end

  defp armis_update(armis_id, ip) do
    %{
      "ip" => ip,
      "hostname" => "dedup-armis-#{armis_id}",
      "source" => "armis",
      "metadata" => %{
        "integration_type" => "armis",
        "armis_device_id" => armis_id,
        "integration_id" => "armis:dedup-test:device:#{armis_id}"
      }
    }
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

  # Benchmarking-range addresses (RFC 2544, 198.18.0.0/15) and locally-administered MACs
  # under the documentation OUI (RFC 7042). A monotonic counter over a /15 keeps two devices
  # in one test from wrapping onto the same address, and keeps this module out of the
  # 198.51.100.0/24 block that other async tests share.
  defp unique_ip do
    n = System.unique_integer([:positive, :monotonic])
    "198.#{18 + rem(div(n, 65_024), 2)}.#{rem(div(n, 254), 256)}.#{rem(n, 254) + 1}"
  end

  defp laa_mac, do: "02:00:5E:00:53:" <> Base.encode16(<<rem(unique(), 256)>>)
end
