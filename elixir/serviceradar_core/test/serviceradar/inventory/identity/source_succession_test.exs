defmodule ServiceRadar.Inventory.Identity.SourceSuccessionTest do
  @moduledoc """
  Source succession (add-source-id-succession D3 and D4): the reconciler merges a record whose
  Armis id retired into the record holding the device's current id, when the evidence is strong
  enough, and records a review when it is not. The worlds are built through
  `ServiceRadar.DireTrace`, which drives the real sync, collection and retirement paths; the
  traces of `dire_resolution_trace_test.exs` cover the model's view, these the details it does
  not express. `SourceSuccession.classify/1` is pure, so the cases the harness cannot build are
  constructed snapshots.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.DireTrace
  alias ServiceRadar.Inventory.DeduplicationTask
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.Deduplication
  alias ServiceRadar.Inventory.Identity.DuplicateSweep
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Inventory.Identity.ReconciliationRun
  alias ServiceRadar.Inventory.Identity.SourceCorroboration
  alias ServiceRadar.Inventory.Identity.SourceSuccession
  alias ServiceRadar.Inventory.IdentityDecision
  alias ServiceRadar.Inventory.MergeAudit
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  @world %{
    phys: ["h1"],
    ifaces: %{"x1" => %{phys: "h1", mac: "m1"}},
    src_of: %{"h1" => "a1"},
    armis_macs: true,
    rekeys: true,
    src_ids: ["a1", "a2"],
    hw_ids: ["m1"],
    laa_ids: [],
    ips: ["p1"],
    observers: ["Armis"]
  }

  # The partition and the source times of the constructed snapshots.
  @partition "default:armis:classify-source"
  @first_seen ~U[2026-01-01 00:00:00Z]
  @last_seen ~U[2026-02-01 00:00:00Z]
  @later ~U[2026-02-02 00:00:00Z]

  @doc false
  def write_after_lock(_event, _measurements, %{query: query}, {parent, write}) do
    if self() == parent and not Process.get(:written_after_lock, false) and
         String.contains?(query, "FOR NO KEY UPDATE") do
      Process.put(:written_after_lock, true)
      write.()
    end
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:source_succession_test)}
  end

  # Armis reports device h1 under a1, re-keys it to a2 and reports it under a2 alone until a1 is
  # due to retire. a1's record keeps m1; a2's record holds a2 and the address.
  defp rekey(actor, overrides \\ %{}) do
    "source_succession_test"
    |> DireTrace.start(Map.merge(@world, overrides), actor)
    |> DireTrace.lease("x1", "p1")
    |> DireTrace.collect()
    |> DireTrace.rekey("h1", "a2")
    |> DireTrace.collect()
    |> DireTrace.collect()
    |> DireTrace.collect()
  end

  # The same once a1 has retired, which leaves a1's record holding the retired id.
  defp rekeyed(actor, overrides \\ %{}), do: actor |> rekey(overrides) |> retired()

  defp retired(trace) do
    trace = DireTrace.retire(trace)
    DireTrace.stop(trace)

    world = %{
      predecessor: uid!(trace, "a1"),
      successor: uid!(trace, "a2"),
      current: trace.real.src["a2"]
    }

    # The re-key lands a2 on a record created in a later second (DireTrace.rekey/3), so a1's
    # record is the one created first.
    assert DateTime.before?(
             device(world.predecessor, trace.actor).created_time,
             device(world.successor, trace.actor).created_time
           )

    world
  end

  defp uid!(trace, name),
    do: Enum.find_value(trace.names, fn {uid, n} -> n == name && uid end) || flunk(name)

  defp device(uid, actor) do
    {:ok, device} = Device.get_by_uid(uid, true, actor: actor)
    device
  end

  defp reviews(uids, actor) do
    uids = Enum.sort(uids)

    IdentityDecision
    |> Ash.Query.filter(decision_kind == :succession_review)
    |> Ash.read!(actor: actor)
    |> Enum.filter(&(Enum.sort(&1.device_uids) == uids))
  end

  # Removes a time the sync stored for an id, as a source that never reported it leaves it.
  defp remove_time!(table, uid, key) do
    assert %{num_rows: 1} =
             Repo.query!(
               "UPDATE platform.#{table} SET metadata = metadata - CAST($2 AS text) " <>
                 "WHERE device_id = $1 AND identifier_type = 'armis_device_id' " <>
                 "AND metadata ->> CAST($2 AS text) IS NOT NULL",
               [uid, key]
             )
  end

  # Moves a record's creation an hour before another's, as when another source created the
  # record that the source's new id later landed on.
  defp created_before!(uid, other) do
    assert %{num_rows: 1} =
             Repo.query!(
               "UPDATE platform.ocsf_devices SET created_time = " <>
                 "(SELECT created_time - interval '1 hour' FROM platform.ocsf_devices " <>
                 "WHERE uid = $2) WHERE uid = $1",
               [uid, other]
             )
  end

  # m1 links the pair, but nothing corroborates it, so the pass records it for review.
  defp assert_overlapping_hostname(world, actor) do
    assert {:ok, %{merged: 0, reviewed: 1}} =
             SourceSuccession.run(actor: actor, max_successions: 10)

    assert device(world.successor, actor).deleted_at == nil

    assert [%IdentityDecision{reason: "overlapping_hostname"} = decision] =
             reviews([world.predecessor, world.successor], actor)

    assert [%{"linking_macs" => [_], "corroboration" => []}] = decision.evidence["pairs"]
  end

  defp succession(world),
    do: %{
      identifier_type: :armis_device_id,
      partitions: partitions(world, SystemActor.system(:source_succession_test)),
      predecessor: world.predecessor,
      successor: world.successor
    }

  defp partitions(world, actor) do
    DeviceIdentifier
    |> Ash.Query.filter(device_id == ^world.successor and identifier_type == :armis_device_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.partition)
  end

  test "merges into the record created first, which takes the current id, the source's metadata and the address",
       %{actor: actor} do
    world = rekeyed(actor)
    before = device(world.successor, actor)
    assert device(world.predecessor, actor).source_retired_at

    assert {:ok, %{merged: 1, skipped: 0, deferred: 0}} =
             SourceSuccession.run(actor: actor, max_successions: 10)

    survivor = device(world.predecessor, actor)
    assert survivor.deleted_at == nil
    assert device(world.successor, actor).deleted_at
    assert survivor.ip == before.ip
    assert survivor.metadata["armis_device_id"] == world.current
    # The trigger clears the mark once the record holds a current id again (D5).
    assert survivor.source_retired_at == nil

    assert [%DeviceIdentifier{device_id: owner}] =
             DeviceIdentifier
             |> Ash.Query.filter(
               identifier_type == :armis_device_id and identifier_value == ^world.current
             )
             |> Ash.read!(actor: actor)

    assert owner == world.predecessor

    assert {:ok, [audit]} = MergeAudit.get_merged_to(world.successor, actor: actor)
    assert audit.reason == "source_succession"
    assert audit.to_device_id == world.predecessor
    assert audit.details["predecessor"] == world.predecessor
    assert audit.details["successor"] == world.successor
    assert [%{"field" => "first_seen"}] = audit.details["corroboration"]
    assert [%{"collection_ids" => [_ | _]}] = audit.details["retired_ids"]
    assert audit.details["succession"]["ip_transferred"]
  end

  test "a successor created first survives, keeping the current id and its address",
       %{actor: actor} do
    world = rekeyed(actor)
    created_before!(world.successor, world.predecessor)
    before = device(world.successor, actor)

    assert {:ok, %{merged: 1}} = SourceSuccession.run(actor: actor, max_successions: 10)

    assert device(world.predecessor, actor).deleted_at
    survivor = device(world.successor, actor)
    assert survivor.deleted_at == nil
    assert survivor.ip == before.ip
    assert survivor.metadata["armis_device_id"] == world.current

    assert {:ok, [audit]} = MergeAudit.get_merged_to(world.predecessor, actor: actor)
    assert audit.reason == "source_succession"
    assert audit.to_device_id == world.successor
    assert audit.details["predecessor"] == world.predecessor
    refute audit.details["succession"]["ip_transferred"]
  end

  test "marks the de-duplication task the sync opened for the pair merged", %{actor: actor} do
    world = rekeyed(actor)
    key = DeduplicationTask.candidate_key([world.predecessor, world.successor])

    task_status = fn ->
      DeduplicationTask
      |> Ash.Query.filter(candidate_key == ^key)
      |> Ash.read!(actor: actor)
      |> Enum.map(&{&1.status, &1.merged_into})
    end

    # The a2 sync found a1's record by hostname and opened the task (policy_block).
    assert [{:open, nil}] = task_status.()
    assert {:ok, %{merged: 1}} = SourceSuccession.run(actor: actor, max_successions: 10)
    assert [{:merged, survivor}] = task_status.()
    assert survivor == world.predecessor
  end

  test "an unmerge restores the successor, records the pair distinct, and the next pass leaves it",
       %{actor: actor} do
    world = rekeyed(actor)
    before = device(world.successor, actor)
    assert {:ok, %{merged: 1}} = SourceSuccession.run(actor: actor, max_successions: 10)

    assert :ok = MergeEngine.unmerge_device(world.successor, actor: actor)

    restored = device(world.successor, actor)
    assert restored.deleted_at == nil
    assert restored.ip == before.ip
    survivor = device(world.predecessor, actor)
    assert survivor.ip != before.ip
    assert survivor.metadata["armis_device_id"] != world.current
    assert Deduplication.asserted_distinct?(world.predecessor, world.successor)

    assert {:ok, %{merged: 0}} = SourceSuccession.run(actor: actor, max_successions: 10)
    assert device(world.successor, actor).deleted_at == nil
  end

  test "a run records its succession merges apart from its duplicate merges, and its cap",
       %{actor: actor} do
    world = rekeyed(actor)

    # The duplicate pass is refused the pair, whose records hold two ids of one source; the
    # succession pass merges it.
    assert {:ok, stats} = DuplicateSweep.reconcile_duplicates(actor: actor, max_successions: 7)
    assert %{merges: 0, succession_merges: 1, max_successions_configured: 7} = stats
    assert device(world.successor, actor).deleted_at

    [run | _] =
      ReconciliationRun
      |> Ash.Query.for_read(:recent, %{}, actor: actor)
      |> Ash.read!()

    assert %{merges: 0, succession_merges: 1, max_successions_configured: 7} = run
  end

  test "a cap of zero merges nothing and defers the pair", %{actor: actor} do
    world = rekeyed(actor)

    assert {:ok, %{merged: 0, deferred: 1, max_successions: 0}} =
             SourceSuccession.run(actor: actor, max_successions: 0)

    assert device(world.successor, actor).deleted_at == nil
  end

  test "without a MAC, agreement on hostname and first-seen time records a review and merges nothing",
       %{actor: actor} do
    world = rekeyed(actor, %{armis_macs: false})

    assert {:ok, %{merged: 0, reviewed: 1}} =
             SourceSuccession.run(actor: actor, max_successions: 10)

    assert device(world.successor, actor).deleted_at == nil

    assert [%IdentityDecision{reason: "corroborated_without_mac"} = decision] =
             reviews([world.predecessor, world.successor], actor)

    assert [%{"corroboration" => [%{"field" => "first_seen"}]}] = decision.evidence["pairs"]
  end

  test "a randomized MAC links nothing, so agreement on hostname and first-seen time records a review",
       %{actor: actor} do
    world = rekeyed(actor, %{hw_ids: [], laa_ids: ["m1"]})

    assert {:ok, %{merged: 0, reviewed: 1}} =
             SourceSuccession.run(actor: actor, max_successions: 10)

    assert device(world.successor, actor).deleted_at == nil

    assert [%IdentityDecision{reason: "corroborated_without_mac"} = decision] =
             reviews([world.predecessor, world.successor], actor)

    assert [%{"shared_macs" => [], "linking_macs" => []}] = decision.evidence["pairs"]
  end

  test "before the old id retires, the pass merges nothing and records nothing", %{actor: actor} do
    trace = rekey(actor)

    assert {:ok, %{merged: 0, reviewed: 0, deferred: 0}} =
             SourceSuccession.run(actor: actor, max_successions: 10)

    world = retired(trace)
    assert {:ok, %{merged: 1}} = SourceSuccession.run(actor: actor, max_successions: 10)
    assert device(world.successor, actor).deleted_at
  end

  test "a hostname alone corroborates only when the new id was first seen after the old one was last seen",
       %{actor: actor} do
    later = rekeyed(actor, %{new_first_seen_ids: ["a2"]})
    assert {:ok, %{merged: 1}} = SourceSuccession.run(actor: actor, max_successions: 10)
    assert {:ok, [audit]} = MergeAudit.get_merged_to(later.successor, actor: actor)
    assert [%{"field" => "hostname"}] = audit.details["corroboration"]
  end

  # Each world below merges on its hostname while the times are in place (the test above).
  test "a missing first-seen time fails the time guard, so the hostname does not corroborate",
       %{actor: actor} do
    world = rekeyed(actor, %{new_first_seen_ids: ["a2"]})
    remove_time!("device_identifiers", world.successor, "source_first_seen_time")
    assert_overlapping_hostname(world, actor)
  end

  test "a missing last-seen time fails the time guard, so the hostname does not corroborate",
       %{actor: actor} do
    world = rekeyed(actor, %{new_first_seen_ids: ["a2"]})
    remove_time!("device_identifier_archive", world.predecessor, "source_last_seen_time")
    assert_overlapping_hostname(world, actor)
  end

  # Two cloned machines share m1 and a hostname: Armis reports A under a1 and B under a2, then
  # stops reporting A, whose a1 retires.
  test "cloned machines in the source at once are recorded for review", %{actor: actor} do
    world =
      Map.merge(@world, %{
        phys: ["h1", "h2"],
        ifaces: %{"x1" => %{phys: "h1", mac: "m1"}, "x2" => %{phys: "h2", mac: "m1"}},
        src_of: %{"h1" => "a1", "h2" => "a2"},
        host_of: %{"h1" => "h0", "h2" => "h0"},
        ips: ["p1", "p2"]
      })

    trace =
      "source_succession_test"
      |> DireTrace.start(world, actor)
      |> DireTrace.lease("x1", "p1")
      |> DireTrace.lease("x2", "p2")
      |> DireTrace.collect()
      |> DireTrace.rekey("h1", "NoId")
      |> DireTrace.collect()
      |> DireTrace.collect()
      |> DireTrace.collect()
      |> DireTrace.retire()

    DireTrace.stop(trace)

    # B was first seen while A was still being seen, so the hostname fails the time guard.
    assert_overlapping_hostname(
      %{predecessor: uid!(trace, "a1"), successor: uid!(trace, "a2")},
      actor
    )
  end

  test "the merge path refuses the reason without its pair and a pair under another reason",
       %{actor: actor} do
    world = rekeyed(actor)
    succession = succession(world)

    assert {:error, :succession_required} =
             MergeEngine.merge_devices(world.successor, world.predecessor,
               actor: actor,
               reason: "source_succession"
             )

    assert {:error, :succession_mismatch} =
             MergeEngine.merge_devices(world.successor, world.predecessor,
               actor: actor,
               reason: "source_succession",
               succession: %{succession | predecessor: "sr:another-record"}
             )

    assert {:error, :succession_reason_mismatch} =
             MergeEngine.merge_devices(world.successor, world.predecessor,
               actor: actor,
               reason: "duplicate",
               succession: succession
             )

    assert device(world.successor, actor).deleted_at == nil
  end

  test "a succession no longer successive is refused under the locks", %{actor: actor} do
    world = rekeyed(actor)
    succession = succession(world)

    assert :ok = SourceSuccession.revalidate(succession, actor)

    assert {:error, {:succession_stale, :scope_changed}} =
             SourceSuccession.revalidate(%{succession | partitions: ["elsewhere"]}, actor)

    assert {:error, {:succession_stale, :not_predecessor}} =
             SourceSuccession.revalidate(
               %{succession | predecessor: world.successor, successor: world.predecessor},
               actor
             )

    # Outside the scopes where the one id retired and the other is current, the source-authority
    # guard still refuses the merge, before revalidation.
    assert {:error, {:merge_blocked, :source_authority_conflict}} =
             MergeEngine.merge_devices(world.successor, world.predecessor,
               actor: actor,
               reason: "source_succession",
               succession: %{succession | partitions: ["elsewhere"]}
             )
  end

  test "a pair that went stale after the plan is skipped as stale, not failed", %{actor: actor} do
    world = rekeyed(actor)
    assert %{successive: [pair]} = SourceSuccession.plan(actor: actor)
    [pair] = SourceSuccession.with_collections([pair])

    # The successor lost its current id after the plan, so the pair is no longer successive;
    # only the check under the locks reads that.
    assert %{num_rows: 1} =
             Repo.query!(
               "DELETE FROM platform.device_identifiers " <>
                 "WHERE device_id = $1 AND identifier_type = 'armis_device_id'",
               [world.successor]
             )

    assert {:error, :stale, {:succession_stale, :not_successive}} =
             SourceSuccession.merge_pair(pair, actor)

    assert device(world.predecessor, actor).deleted_at == nil
    assert device(world.successor, actor).deleted_at == nil
    assert {:ok, []} = MergeAudit.get_merged_to(pair.merged, actor: actor)
  end

  test "a source conflict the locked guard finds blocks the merge and is recorded",
       %{actor: actor} do
    source_id = Ecto.UUID.generate()
    survivor = create_record!(actor)
    merged = create_record!(actor)
    register_armis_id!(actor, survivor.uid, source_id)

    # A sync gives the merged record an id of the same source after the unlocked guard passed.
    after_lock(fn -> register_armis_id!(actor, merged.uid, source_id) end)

    assert {:error, {:source_authority_conflict, conflict}} =
             MergeEngine.merge_devices(merged.uid, survivor.uid,
               actor: actor,
               reason: "duplicate"
             )

    assert Process.get(:written_after_lock)
    assert conflict.device_ids == Enum.sort([merged.uid, survivor.uid])
    assert device(merged.uid, actor).deleted_at == nil
    assert {:ok, []} = MergeAudit.get_merged_to(merged.uid, actor: actor)

    assert [_decision] =
             IdentityDecision
             |> Ash.Query.filter(
               decision_kind == :source_block and reason == "source_authority_conflict"
             )
             |> Ash.read!(actor: actor)
             |> Enum.filter(&(Enum.sort(&1.device_uids) == conflict.device_ids))
  end

  # Runs `write` once, in the test process, right after the merge transaction locks the records.
  defp after_lock(write) do
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        id,
        [:service_radar, :repo, :query],
        &__MODULE__.write_after_lock/4,
        {self(), write}
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp create_record!(actor) do
    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: "source-succession-test",
      ip: TestSupport.unique_device_ip()
    })
    |> Ash.create!(actor: actor)
  end

  defp register_armis_id!(actor, device_uid, source_id) do
    DeviceIdentifier
    |> Ash.Changeset.for_create(:register, %{
      device_id: device_uid,
      identifier_type: :armis_device_id,
      identifier_value: Integer.to_string(System.unique_integer([:positive])),
      partition: "default",
      source: "armis",
      metadata: %{"sync_service_id" => source_id}
    })
    |> Ash.create!(actor: actor)
  end

  describe "classify/1" do
    test "a retired record linked to two current records that each corroborate it is not one-to-one" do
      retired = retired_record("sr:retired", ["00:00:5E:00:53:0A", "00:00:5E:00:53:0B"])
      first = current_record("sr:current-1", ["00:00:5E:00:53:0A"], "host-1", @first_seen)
      second = current_record("sr:current-2", ["00:00:5E:00:53:0B"], "host-2", @first_seen)

      assert %{successive: [], reviews: [review]} =
               SourceSuccession.classify(snapshot([retired], [first, second]))

      assert review.reason == :not_one_to_one
      assert review.device_uids == ["sr:current-1", "sr:current-2", "sr:retired"]

      assert [%{"successor" => "sr:current-1"}, %{"successor" => "sr:current-2"}] =
               review.decision.evidence["pairs"]
    end

    test "a hostname another current record of the source holds does not corroborate" do
      retired = retired_record("sr:retired", ["00:00:5E:00:53:0A"])
      successor = current_record("sr:current-1", ["00:00:5E:00:53:0A"], "host-a", @later)
      holder = current_record("sr:current-2", ["00:00:5E:00:53:0B"], "host-a", @later)

      assert %{successive: [%{successor: "sr:current-1", survivor: "sr:retired"}], reviews: []} =
               SourceSuccession.classify(snapshot([retired], [successor]))

      assert %{successive: [], reviews: [review]} =
               SourceSuccession.classify(snapshot([retired], [successor, holder]))

      assert review.reason == :overlapping_hostname
      assert review.device_uids == ["sr:current-1", "sr:retired"]
    end

    test "the record created first survives, whichever side it is on, and of two created together the lower uid" do
      retired = retired_record("sr:retired", ["00:00:5E:00:53:0A"])
      current = current_record("sr:current-1", ["00:00:5E:00:53:0A"], "host-a", @later)

      survivor = fn retired_created, current_created ->
        predecessors = [put_in(retired.device.created_time, retired_created)]
        currents = [put_in(current.device.created_time, current_created)]

        assert %{successive: [pair]} =
                 SourceSuccession.classify(snapshot(predecessors, currents))

        pair.survivor
      end

      assert survivor.(@first_seen, @later) == "sr:retired"
      assert survivor.(@later, @first_seen) == "sr:current-1"
      assert survivor.(@later, @later) == "sr:current-1"
    end
  end

  # A record whose id retired, named host-a and seen by the source from @first_seen to @last_seen.
  defp retired_record(uid, macs) do
    %{
      uid: uid,
      device: %{uid: uid, created_time: @first_seen, first_seen_time: @first_seen},
      macs: SourceCorroboration.hardware_macs(macs),
      names: MapSet.new(["host-a"]),
      agents: MapSet.new(),
      scopes: %{
        @partition => %{
          rows: [
            %{id: "#{uid}-row", value: "#{uid}-id", partition: @partition, archived_at: @later}
          ],
          firsts: [%{time: @first_seen, basis: "source"}],
          last_seen: @last_seen
        }
      }
    }
  end

  defp current_record(uid, macs, name, first_seen) do
    %{
      uid: uid,
      device: %{uid: uid, created_time: @later, first_seen_time: first_seen},
      values: [{"#{uid}-id", @partition}],
      macs: SourceCorroboration.hardware_macs(macs),
      names: MapSet.new([name]),
      agents: MapSet.new(),
      scopes: %{@partition => %{firsts: [first_seen], first_seen: first_seen}}
    }
  end

  # The hostname holders are the current records, as the pass reads them.
  defp snapshot(retired, current) do
    holders =
      current
      |> Enum.flat_map(fn record -> Enum.map(record.names, &{{@partition, &1}, record.uid}) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {key, uids} -> {key, MapSet.new(uids)} end)

    %{
      predecessors: Map.new(retired, &{&1.uid, &1}),
      currents: Map.new(current, &{&1.uid, &1}),
      hostname_holders: holders,
      distinct: MapSet.new()
    }
  end
end
