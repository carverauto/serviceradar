defmodule ServiceRadar.Inventory.Identity.SourceReactivationTest do
  @moduledoc """
  Integration coverage for retired source ids reported again (change `add-source-id-succession`,
  design D6, tasks 7.1-7.3 and 14.5): a retired Armis id returns to the record that held it when
  exactly one holder qualifies, and is otherwise re-issued to a new record, which opens a
  de-duplication task naming the new record and the holders. Nothing merges two records.

  Every test retires an id through a real retirement pass and reports it again through the sync
  ingest, as an Armis sync run does.
  """

  use ServiceRadar.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.DeduplicationTask
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.DeviceSourceObservationIngestor
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Inventory.Identity.SourceReactivation
  alias ServiceRadar.Inventory.Identity.SourceRetirement
  alias ServiceRadar.Inventory.IdentityDecision
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Inventory.SourceRetiredExpiry
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  @prefix "platform"

  # N = 3 collections, T = 24 hours.
  @settings %{
    source_retirement_enabled: true,
    source_retirement_absent_collections: 3,
    source_retirement_min_absence_hours: 24,
    source_retirement_max_fraction: 0.5,
    source_retirement_guard_override: false
  }

  @grace_settings %{
    source_retirement_enabled: true,
    source_retired_grace_days: 7,
    source_retirement_max_fraction: 1.0,
    source_retirement_guard_override: false,
    batch_size: 100
  }

  @doc false
  def forward_event([_, _, _, kind], measurements, metadata, {parent, partition}) do
    if metadata.partition == partition do
      send(parent, {:source_reactivation, kind, measurements, metadata})
    end
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  # One Armis source instance per test. t0 lies ten days back, so the source times,
  # collections and passes a test places after it are in the past.
  setup do
    n = System.unique_integer([:positive, :monotonic])
    inst = "reactivation-test-#{n}"

    {:ok,
     actor: SystemActor.system(:source_reactivation_test),
     n: n,
     inst: inst,
     instance: %{partition: "default", source: "armis", source_instance: inst},
     id_partition: "default:armis:#{inst}",
     t0: DateTime.utc_now() |> DateTime.add(-10, :day) |> DateTime.truncate(:second)}
  end

  describe "a retired id reported again" do
    test "returns to its record when the source first saw the device at the same time", ctx do
      {_a, b} = retire_second(ctx)
      [armis_row, integration_row] = archived(ctx, b.source_id)
      revision = revision(b)
      attach_events(ctx)

      assert ingest!(ctx, 2, ip: "192.0.2.52").uid == b.uid

      assert typed_id_holder(:integration_id, integration_id(ctx, b.source_id), ctx.id_partition) ==
               b.uid

      assert archived(ctx, b.source_id) == []

      device = reload(ctx, b)
      assert device.deleted_at == nil
      assert device.source_retired_at == nil
      assert device.ip == "192.0.2.52"
      assert revision(b) > revision

      assert [decision] = decisions(ctx, :source_id_reactivated, b)
      assert decision.device_uids == [b.uid]
      assert decision.subject == b.source_id
      assert decision.reason == "source_id_reactivated"
      assert decision.source == "source_reactivation"

      assert %{
               "corroboration" => "first_seen",
               "first_seen_basis" => "source",
               "matched_macs" => ["00005E005302"],
               "observation" => true,
               "identifier_type" => "armis_device_id",
               "identifier_partition" => partition,
               "archive_reason" => "source_absent",
               "previous_holders" => previous_holders,
               "restored_tombstone" => false,
               "cleared_ip" => false,
               "was_marked_source_retired" => true,
               "archived_identifier_ids" => returned
             } = decision.evidence

      assert partition == ctx.id_partition
      assert previous_holders == [b.uid]
      assert returned == Enum.sort([armis_row.id, integration_row.id])

      {uid, source_id} = {b.uid, b.source_id}

      assert_received {:source_reactivation, :reactivated, %{count: 1},
                       %{
                         device_uid: ^uid,
                         identifier_type: :armis_device_id,
                         identifier_value: ^source_id,
                         corroboration: "first_seen",
                         restored_tombstone: false
                       }}

      refute_received {:source_reactivation, :reissued, _measurements, _metadata}
      assert decisions(ctx, :source_id_reissued, b) == []
      assert open_tasks(ctx, b) == []
    end

    test "returns on a shared hostname first seen no earlier than the id was last seen", ctx do
      {_a, b} = retire_second(ctx)

      # The source last saw the id at t0+5h. The device comes back first seen at that time,
      # under the record's hostname written differently.
      reported =
        ingest!(ctx, 2,
          ip: "192.0.2.52",
          first_seen: DateTime.add(ctx.t0, 5, :hour),
          hostname: "HOST02.example.com."
        )

      assert reported.uid == b.uid
      assert [decision] = decisions(ctx, :source_id_reactivated, b)
      assert decision.evidence["corroboration"] == "hostname"
      assert decision.evidence["first_seen_basis"] == "source"
    end

    test "is re-issued when a shared hostname was first seen while the id was still seen", ctx do
      {_a, b} = retire_second(ctx)
      [armis_row, _integration_row] = archived(ctx, b.source_id)

      # First seen at t0+2h, while the source still saw the id (until t0+5h): a clone.
      reported = ingest!(ctx, 2, ip: "192.0.2.52", first_seen: DateTime.add(ctx.t0, 2, :hour))

      # The uid the id derives is b's own, so the update goes to the uid derived from it and
      # the archived row.
      assert reported.uid == Ids.reissued_device_id(b.uid, [armis_row.id])
      assert [decision] = decisions(ctx, :source_id_reissued, b)
      assert decision.evidence["holders"] == %{b.uid => "not_corroborated"}
      assert decision.evidence["qualifying_holders"] == []
      assert decision.evidence["reissued_device_uid"] == reported.uid
      assert length(archived(ctx, b.source_id)) == 2
    end

    test "is re-issued to a new record when it shares no hardware MAC with the holder", ctx do
      {_a, b} = retire_second(ctx)
      [armis_row, _integration_row] = archived(ctx, b.source_id)
      attach_events(ctx)

      reported = ingest!(ctx, 2, ip: "192.0.2.52", mac: mac(22))

      assert reported.uid ==
               Ids.generate_deterministic_device_id(%{
                 armis_id: b.source_id,
                 integration_id: integration_id(ctx, b.source_id),
                 mac: normalized_mac(22),
                 partition: ctx.id_partition
               })

      # b keeps the id as history, and its mark.
      assert length(archived(ctx, b.source_id)) == 2
      assert %Device{deleted_at: nil, source_retired_at: %DateTime{}} = reload(ctx, b)
      assert %Device{deleted_at: nil} = reload(ctx, reported)

      assert [decision] = decisions(ctx, :source_id_reissued, b)
      assert decision.device_uids == Enum.sort([reported.uid, b.uid])
      assert decision.subject == b.source_id
      assert decision.reason == "source_id_reissued"
      assert decision.source == "source_reactivation"

      assert %{
               "identifier_type" => "armis_device_id",
               "identifier_partition" => partition,
               "archived_identifier_ids" => archived_ids,
               "holders" => holders,
               "qualifying_holders" => [],
               "reissued_device_uid" => reissued
             } = decision.evidence

      assert partition == ctx.id_partition
      assert archived_ids == [armis_row.id]
      assert holders == %{b.uid => "no_shared_mac"}
      assert reissued == reported.uid
      assert decisions(ctx, :source_id_reactivated, b) == []

      assert [task] = open_tasks(ctx, b)
      assert task.device_uids == Enum.sort([reported.uid, b.uid])
      assert task.category == "source_id_reissued"
      assert task.last_decision_kind == "source_id_reissued"

      {uid, holder} = {reported.uid, b.uid}

      assert_received {:source_reactivation, :reissued, %{count: 1},
                       %{device_uid: ^uid, holders: [^holder]}}

      refute_received {:source_reactivation, :reactivated, _measurements, _metadata}
    end

    test "is re-issued when the holder holds another id of the type", ctx do
      {_a, b} = retire_second(ctx)
      [armis_row, _integration_row] = archived(ctx, b.source_id)
      register(ctx, b, :armis_device_id, armis_id(ctx, 9))

      reported = ingest!(ctx, 2, ip: "192.0.2.52")

      assert reported.uid == Ids.reissued_device_id(b.uid, [armis_row.id])
      assert typed_id_holder(:armis_device_id, armis_id(ctx, 9), ctx.id_partition) == b.uid
      assert [decision] = decisions(ctx, :source_id_reissued, b)
      assert decision.evidence["holders"] == %{b.uid => "holds_current_id"}
      assert decision.evidence["qualifying_holders"] == []
    end

    test "is re-issued when two holders qualify", ctx do
      {a, b} = retire_second(ctx)
      [b_row, _integration_row] = archived(ctx, b.source_id)

      # The id is re-issued to c, which the source then stops reporting too.
      c = ingest!(ctx, 2, ip: "192.0.2.52", mac: mac(22))
      backdate(ctx, c)
      for k <- 5..7, do: collect(ctx, k, [a], hours: k)
      assert {:ok, %{status: :completed, retired: 1}} = retire(ctx, 200)

      [c_row] =
        for row <- archived(ctx, b.source_id),
            row.device_id == c.uid and row.identifier_type == "armis_device_id",
            do: row

      # Reported again with both records' MACs, it corroborates both. The first MAC is b's, so
      # the uid the id derives is b's own.
      reported = ingest!(ctx, 2, ip: "192.0.2.53", mac: "#{mac(2)},#{mac(22)}")

      assert reported.uid == Ids.reissued_device_id(b.uid, [b_row.id, c_row.id])

      # Newest first: this re-issue, then the one to c.
      assert [decision, to_c] = decisions(ctx, :source_id_reissued, b)
      assert to_c.evidence["reissued_device_uid"] == c.uid
      assert decision.evidence["reissued_device_uid"] == reported.uid
      assert decision.evidence["holders"] == %{b.uid => "qualified", c.uid => "qualified"}
      assert decision.evidence["qualifying_holders"] == Enum.sort([b.uid, c.uid])
      assert decision.device_uids == Enum.sort([reported.uid, b.uid, c.uid])
      assert decisions(ctx, :source_id_reactivated, b) == []
      assert decisions(ctx, :source_id_reactivated, c) == []
    end
  end

  describe "the source's last observation of the id" do
    test "corroborates the holder with the MAC the source reported for it", ctx do
      {_a, b} = retire_second(ctx, %{observed_mac: "00:00:5E:00:53:32"})

      assert ingest!(ctx, 2, ip: "192.0.2.52", mac: mac(32)).uid == b.uid

      assert [decision] = decisions(ctx, :source_id_reactivated, b)
      assert decision.evidence["observation"] == true
      assert decision.evidence["matched_macs"] == [normalized_mac(32)]
    end

    test "does not count once the source refreshed it after the id retired", ctx do
      {_a, b} = retire_second(ctx, %{observed_mac: "00:00:5E:00:53:32"})

      {1, _} =
        Repo.update_all(
          from(o in "device_source_observations",
            where: o.source_instance == ^ctx.inst and o.source_object_id == ^b.source_id
          ),
          [set: [last_observed_at: NaiveDateTime.add(NaiveDateTime.utc_now(), 60)]],
          prefix: @prefix
        )

      reported = ingest!(ctx, 2, ip: "192.0.2.52", mac: mac(32))

      refute reported.uid == b.uid
      assert [decision] = decisions(ctx, :source_id_reissued, b)
      assert decision.evidence["holders"] == %{b.uid => "no_shared_mac"}
    end
  end

  describe "a row archived before rows carried source times" do
    setup ctx do
      {_a, b} = retire_second(ctx)

      %{num_rows: 2} =
        Repo.query!(
          "UPDATE platform.device_identifier_archive " <>
            "SET metadata = metadata - 'source_first_seen_time' - 'source_last_seen_time' " <>
            "WHERE device_id = $1",
          [b.uid]
        )

      {:ok, b: b}
    end

    test "returns on the record's first-seen time", ctx do
      assert ingest!(ctx, 2, ip: "192.0.2.52").uid == ctx.b.uid

      assert [decision] = decisions(ctx, :source_id_reactivated, ctx.b)
      assert decision.evidence["corroboration"] == "first_seen"
      assert decision.evidence["first_seen_basis"] == "record"
    end

    test "does not return on a hostname alone", ctx do
      reported = ingest!(ctx, 2, ip: "192.0.2.52", first_seen: DateTime.add(ctx.t0, 6, :hour))

      refute reported.uid == ctx.b.uid
      assert [decision] = decisions(ctx, :source_id_reissued, ctx.b)
      assert decision.evidence["holders"] == %{ctx.b.uid => "not_corroborated"}
    end
  end

  describe "a holder that is a tombstone" do
    test "a source_retired tombstone is restored", ctx do
      {_a, b} = retire_second(ctx)
      mark(b, days_ago(8))

      assert {:ok, %{deleted: 1, candidates: 1, held: 0}} =
               SourceRetiredExpiry.run(@grace_settings, ctx.actor, uids: [b.uid])

      assert %Device{deleted_reason: "source_retired"} = reload(ctx, b)

      assert ingest!(ctx, 2, ip: "192.0.2.52").uid == b.uid

      assert %Device{deleted_at: nil, ip: "192.0.2.52"} = reload(ctx, b)
      assert revival_audit_reason(b.uid) == "source_retired"

      assert [decision] = decisions(ctx, :source_id_reactivated, b)
      assert decision.evidence["restored_tombstone"] == true
      assert decision.evidence["previous_deleted_reason"] == "source_retired"
      assert decision.evidence["cleared_ip"] == false
      assert decision.evidence["was_marked_source_retired"] == false
    end

    test "a tombstone is restored without the address another record took", ctx do
      {_a, b} = retire_second(ctx)

      {:ok, _deleted} =
        Device.soft_delete(reload(ctx, b), "stale_ephemeral", "test", actor: ctx.actor)

      assert %Device{ip: "192.0.2.12"} = reload(ctx, b)
      c = create_device(ctx, "192.0.2.12", "host03.example.com")

      assert ingest!(ctx, 2, ip: "192.0.2.52").uid == b.uid

      assert %Device{deleted_at: nil, ip: "192.0.2.52"} = reload(ctx, b)
      assert %Device{deleted_at: nil, ip: "192.0.2.12"} = reload(ctx, c)
      assert revival_audit_reason(b.uid) == "stale_ephemeral"

      assert [decision] = decisions(ctx, :source_id_reactivated, b)
      assert decision.evidence["restored_tombstone"] == true
      assert decision.evidence["previous_deleted_reason"] == "stale_ephemeral"
      assert decision.evidence["cleared_ip"] == true
    end

    test "a merged-away holder's id returns to its survivor", ctx do
      {_a, b} = retire_second(ctx)
      s = create_device(ctx, "192.0.2.40", "host04.example.com")

      assert :ok =
               MergeEngine.merge_devices(b.uid, s.uid, actor: ctx.actor, reason: "manual_merge")

      # The merge moved the archived rows to the survivor. A merge from before merges moved them
      # left them naming the merged-away record.
      {2, _} =
        Repo.update_all(
          from(a in "device_identifier_archive", where: a.device_id == ^s.uid),
          [set: [device_id: b.uid]],
          prefix: @prefix
        )

      assert ingest!(ctx, 2, ip: "192.0.2.52").uid == s.uid

      assert archived(ctx, b.source_id) == []
      assert %Device{deleted_reason: "merged"} = reload(ctx, b)
      assert [decision] = decisions(ctx, :source_id_reactivated, s)
      assert decision.device_uids == [s.uid]
      assert decision.evidence["previous_holders"] == [b.uid]
      assert decision.evidence["restored_tombstone"] == false
    end

    test "an id a merge moved to its survivor returns to the survivor", ctx do
      {_a, b} = retire_second(ctx)
      s = create_device(ctx, "192.0.2.40", "host04.example.com")

      assert :ok =
               MergeEngine.merge_devices(b.uid, s.uid, actor: ctx.actor, reason: "manual_merge")

      assert ingest!(ctx, 2, ip: "192.0.2.52").uid == s.uid

      assert [decision] = decisions(ctx, :source_id_reactivated, s)
      assert decision.evidence["previous_holders"] == [s.uid]
    end

    test "an id is re-issued when its merged-away holder has no survivor to follow", ctx do
      {_a, b} = retire_second(ctx)
      [armis_row, _integration_row] = archived(ctx, b.source_id)
      {:ok, _deleted} = Device.soft_delete(reload(ctx, b), "merged", "test", actor: ctx.actor)

      reported = ingest!(ctx, 2, ip: "192.0.2.52")

      assert reported.uid == Ids.reissued_device_id(b.uid, [armis_row.id])
      assert %Device{deleted_reason: "merged"} = reload(ctx, b)
      assert [decision] = decisions(ctx, :source_id_reissued, reported)
      assert decision.device_uids == [reported.uid]
      assert decision.evidence["holders"] == %{b.uid => "merged_tombstone"}
      assert decision.evidence["qualifying_holders"] == []
    end
  end

  describe "unarchive/2" do
    test "returns a row and its integration id to the holder", ctx do
      {_a, b} = retire_second(ctx)
      [armis_row, integration_row] = archived(ctx, b.source_id)
      revision = revision(b)

      assert [{integration_row.id, {:skipped, :not_source_identifier}}] ==
               SourceReactivation.unarchive([integration_row.id], actor: ctx.actor)

      assert [{armis_row.id, {:ok, b.uid}}] ==
               SourceReactivation.unarchive([armis_row.id],
                 actor: ctx.actor,
                 source: "rollback_test"
               )

      assert held?(ctx, b)

      assert typed_id_holder(:integration_id, integration_id(ctx, b.source_id), ctx.id_partition) ==
               b.uid

      assert archived(ctx, b.source_id) == []
      assert %Device{source_retired_at: nil} = reload(ctx, b)
      assert revision(b) > revision

      assert [decision] = decisions(ctx, :source_id_reactivated, b)
      assert decision.reason == "source_id_unarchived"
      assert decision.source == "rollback_test"
      assert decision.evidence["holder_deleted"] == false
      assert decision.evidence["previous_holders"] == [b.uid]

      assert decision.evidence["archived_identifier_ids"] ==
               Enum.sort([armis_row.id, integration_row.id])

      assert [{armis_row.id, {:skipped, :not_archived}}] ==
               SourceReactivation.unarchive([armis_row.id], actor: ctx.actor)
    end

    test "skips a row another record holds, and does not restore a tombstone", ctx do
      {_a, b} = retire_second(ctx)
      [armis_row, _integration_row] = archived(ctx, b.source_id)
      c = create_device(ctx, "192.0.2.40", "host04.example.com")
      register(ctx, c, :armis_device_id, b.source_id)

      assert [{armis_row.id, {:skipped, :claimed}}] ==
               SourceReactivation.unarchive([armis_row.id], actor: ctx.actor)

      assert length(archived(ctx, b.source_id)) == 2

      %{num_rows: 1} =
        Repo.query!(
          "DELETE FROM platform.device_identifiers " <>
            "WHERE device_id = $1 AND identifier_type = 'armis_device_id'",
          [c.uid]
        )

      {:ok, _deleted} =
        Device.soft_delete(reload(ctx, b), "stale_ephemeral", "test", actor: ctx.actor)

      assert [{armis_row.id, {:ok, b.uid}}] ==
               SourceReactivation.unarchive([armis_row.id], actor: ctx.actor)

      assert held?(ctx, b)
      assert %Device{deleted_at: %DateTime{}} = reload(ctx, b)
      assert [decision] = decisions(ctx, :source_id_reactivated, b)
      assert decision.evidence["holder_deleted"] == true
    end
  end

  describe "a return that fails" do
    test "withholds the updates until the next sync run", ctx do
      {a, b} = retire_second(ctx)
      [armis_row, _integration_row] = archived(ctx, b.source_id)
      revision = revision(b)
      attach_events(ctx)

      # A live row with the archived row's id: the return cannot move the row back.
      now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

      Repo.query!(
        "INSERT INTO platform.device_identifiers " <>
          "(id, device_id, identifier_type, identifier_value, partition, confidence, source, " <>
          "first_seen, last_seen) " <>
          "VALUES ($1, $2, 'mac', '00005E005399', 'default', 'strong', 'test', $3, $3)",
        [armis_row.id, a.uid, now]
      )

      log =
        capture_log(fn ->
          assert ingest!(ctx, 2, ip: "192.0.2.52").uid == nil
        end)

      assert log =~
               "withheld the updates of 1 retired source id(s) until the next sync run " <>
                 "(return_failed)"

      source_id = b.source_id

      assert_received {:source_reactivation, :withheld, %{updates: 1},
                       %{identifier_value: ^source_id, reason: :return_failed}}

      assert length(archived(ctx, b.source_id)) == 2
      assert revision(b) == revision
      assert %Device{source_retired_at: %DateTime{}} = reload(ctx, b)
      assert decisions(ctx, :source_id_reactivated, b) == []
      assert decisions(ctx, :source_id_reissued, b) == []

      Repo.query!("DELETE FROM platform.device_identifiers WHERE id = $1", [armis_row.id])

      assert ingest!(ctx, 2, ip: "192.0.2.52").uid == b.uid
      assert [_decision] = decisions(ctx, :source_id_reactivated, b)
    end
  end

  # Records a and b; b is absent from collections 2-4 and retired at t0+100h, which archives its
  # Armis id with the integration id derived from it and marks it source_retired. `observed` is
  # what the source last reported for b before it went absent.
  defp retire_second(ctx, observed \\ %{}) do
    a = ingest!(ctx, 1)
    b = ingest!(ctx, 2)
    Enum.each([a, b], &backdate(ctx, &1))

    collect(ctx, 1, [a, Map.merge(b, observed)], hours: 0)
    for k <- 2..4, do: collect(ctx, k, [a], hours: k)

    assert {:ok, %{status: :completed, retired: 1, marked: 1}} = retire(ctx, 100)
    refute held?(ctx, b)
    assert [_armis_row, _integration_row] = archived(ctx, b.source_id)

    {a, b}
  end

  defp armis_id(ctx, i), do: "#{ctx.n}0#{i}"

  defp integration_id(ctx, value),
    do: IntegrationIdentity.scoped_device_id("armis", ctx.inst, value)

  defp mac(i), do: "00:00:5e:00:53:" <> pad(i)
  defp normalized_mac(i), do: "00005E0053" <> pad(i)
  defp pad(i), do: String.pad_leading(Integer.to_string(i), 2, "0")

  # Armis device `i` as an Armis sync run reports it: first seen at t0, last seen at t0+5h.
  defp report(ctx, i, attrs) do
    source_id = armis_id(ctx, i)

    %{
      "ip" => Keyword.get(attrs, :ip, "192.0.2.#{10 + i}"),
      "mac" => Keyword.get(attrs, :mac, mac(i)),
      "hostname" => Keyword.get(attrs, :hostname, "host0#{i}.example.com"),
      "source" => "armis",
      "first_seen_time" => iso(Keyword.get(attrs, :first_seen, ctx.t0)),
      "last_seen_time" => iso(Keyword.get(attrs, :last_seen, DateTime.add(ctx.t0, 5, :hour))),
      "metadata" => %{
        "integration_type" => "armis",
        "armis_device_id" => source_id,
        "integration_id" => integration_id(ctx, source_id)
      },
      "sync_meta" => %{"sync_service_id" => ctx.inst}
    }
  end

  # Ingests device `i` and returns the record holding its Armis id afterwards (`uid` is nil
  # when none does).
  defp ingest!(ctx, i, attrs \\ []) do
    assert :ok = SyncIngestor.ingest_updates([report(ctx, i, attrs)], actor: ctx.actor)
    source_id = armis_id(ctx, i)
    %{uid: typed_id_holder(:armis_device_id, source_id, ctx.id_partition), source_id: source_id}
  end

  defp iso(%DateTime{} = time), do: DateTime.to_iso8601(time)

  # Backdates the sightings of the record's source identifiers to t0, so only the collections
  # decide when the source last reported it.
  defp backdate(ctx, record) do
    Repo.update_all(
      from(di in "device_identifiers",
        where: di.device_id == ^record.uid and di.partition == ^ctx.id_partition
      ),
      [set: [first_seen: DateTime.to_naive(ctx.t0), last_seen: DateTime.to_naive(ctx.t0)]],
      prefix: @prefix
    )
  end

  # Activates exact collection k of the instance, observed `hours` after t0, reporting
  # `present`.
  defp collect(ctx, k, present, opts) do
    collection_id = "#{ctx.inst}-c#{k}"
    content_hash = sha(collection_id)
    observed_at = DateTime.add(ctx.t0, Keyword.fetch!(opts, :hours), :hour)

    snapshot = %{
      partition: "default",
      source: "armis",
      source_instance: ctx.inst,
      collection_id: collection_id,
      content_hash: content_hash,
      query_hash: nil,
      observed_at: observed_at,
      metadata: %{"accounting_status" => "exact"}
    }

    observations =
      Enum.map(present, fn record ->
        %{
          device_id: record.uid,
          partition: "default",
          source: "armis",
          source_instance: ctx.inst,
          source_object_id: record.source_id,
          source_integration_id: "armis:source:#{ctx.inst}:#{record.source_id}",
          collection_id: collection_id,
          content_hash: content_hash,
          query_hash: nil,
          present: true,
          first_observed_at: observed_at,
          last_observed_at: observed_at,
          absent_since: nil,
          hostname: Map.get(record, :observed_hostname),
          ip: nil,
          mac: Map.get(record, :observed_mac),
          serial_number: nil,
          vendor_name: nil,
          model: nil,
          device_type: nil,
          site_name: nil,
          management_status: nil,
          metadata: %{}
        }
      end)

    assert :ok = DeviceSourceObservationIngestor.activate_resolved(snapshot, observations)
    snapshot
  end

  defp retire(ctx, hours) do
    SourceRetirement.run(ctx.instance,
      settings: @settings,
      now: DateTime.add(ctx.t0, hours, :hour),
      actor: ctx.actor
    )
  end

  defp create_device(ctx, ip, hostname) do
    {:ok, device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        ip: ip,
        hostname: hostname
      })
      |> Ash.create(actor: ctx.actor)

    device
  end

  defp register(ctx, record, type, value) do
    {:ok, _identifier} =
      DeviceIdentifier
      |> Ash.Changeset.for_create(:register, %{
        device_id: record.uid,
        identifier_type: type,
        identifier_value: value,
        partition: ctx.id_partition,
        confidence: :strong,
        source: "test"
      })
      |> Ash.create(actor: ctx.actor)
  end

  defp held?(ctx, record),
    do: typed_id_holder(:armis_device_id, record.source_id, ctx.id_partition) == record.uid

  defp typed_id_holder(type, value, partition) do
    Repo.one(
      from(di in "device_identifiers",
        where:
          di.identifier_type == ^Atom.to_string(type) and di.identifier_value == ^value and
            di.partition == ^partition,
        select: di.device_id
      ),
      prefix: @prefix
    )
  end

  # The archived rows of the Armis id `value` and of the integration id derived from it, the
  # Armis rows first.
  defp archived(ctx, value) do
    integration_id = integration_id(ctx, value)

    from(a in "device_identifier_archive",
      where:
        a.partition == ^ctx.id_partition and
          ((a.identifier_type == "armis_device_id" and a.identifier_value == ^value) or
             (a.identifier_type == "integration_id" and a.identifier_value == ^integration_id)),
      select: %{id: a.id, device_id: a.device_id, identifier_type: a.identifier_type}
    )
    |> Repo.all(prefix: @prefix)
    |> Enum.sort_by(&{&1.identifier_type, &1.id})
  end

  defp revision(record) do
    Repo.one(from(d in "ocsf_devices", where: d.uid == ^record.uid, select: d.identity_revision),
      prefix: @prefix
    )
  end

  defp reload(ctx, record) do
    {:ok, device} = Device.get_by_uid(record.uid, true, actor: ctx.actor)
    device
  end

  # Marks the record as SourceRetirement does, at `marked_at`.
  defp mark(record, %DateTime{} = marked_at) do
    %{num_rows: 1} =
      Repo.query!("UPDATE platform.ocsf_devices SET source_retired_at = $2 WHERE uid = $1", [
        record.uid,
        DateTime.to_naive(marked_at)
      ])
  end

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days, :day)

  defp revival_audit_reason(uid) do
    %{rows: rows} =
      Repo.query!(
        "SELECT previous_deleted_reason FROM platform.device_revival_audit WHERE device_uid = $1",
        [uid]
      )

    case rows do
      [[reason] | _] -> reason
      _ -> nil
    end
  end

  defp decisions(ctx, kind, record) do
    {:ok, decisions} = IdentityDecision.for_device(record.uid, actor: ctx.actor)
    Enum.filter(decisions, &(&1.decision_kind == kind))
  end

  defp open_tasks(ctx, record) do
    {:ok, tasks} = DeduplicationTask.for_device(record.uid, actor: ctx.actor)
    Enum.filter(tasks, &(&1.status == :open))
  end

  defp attach_events(ctx) do
    handler_id = "source-reactivation-events-#{ctx.n}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        for(
          kind <- [:reactivated, :reissued, :withheld],
          do: [:serviceradar, :inventory, :source_reactivation, kind]
        ),
        &__MODULE__.forward_event/4,
        {self(), ctx.id_partition}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp sha(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
end
