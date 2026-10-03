defmodule ServiceRadar.Inventory.SourceRetiredExpiryTest do
  @moduledoc """
  Integration coverage for the source-retired grace pass (change `add-source-id-succession`,
  design D5, tasks 6.3 and 14.4): a record marked `source_retired` is soft-deleted once its
  grace period ends, unless an open de-duplication task names it or the pass is over the mass
  guard, and the tombstone it leaves is one only an operator restore revives: a sync update that
  reaches it through evidence is withheld.

  Each test marks its own records by setting `source_retired_at` directly (the mark is the
  pass's input; `SourceRetirementTest` covers how a retirement sets it) and runs passes scoped
  to its own uids, so it cannot touch another test's rows.
  """

  use ServiceRadar.DataCase, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.DeduplicationTask
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceCleanupSettings
  alias ServiceRadar.Inventory.DeviceCleanupWorker
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.Deduplication
  alias ServiceRadar.Inventory.SourceRetiredExpiry
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  # A test's scope is a handful of records, most of them due by construction, so the mass
  # guard is opened here and exercised on its own below.
  @settings %{
    source_retirement_enabled: true,
    source_retired_grace_days: 7,
    source_retirement_max_fraction: 1.0,
    source_retirement_guard_override: false,
    batch_size: 100
  }

  @operator %{id: "grace-test-operator", email: "operator@example.com", role: :operator}

  @doc false
  def forward_event([_, _, _, kind], measurements, metadata, parent) do
    send(parent, {:source_retired_expiry, kind, measurements, metadata})
  end

  @doc false
  def forward_fence_event(_event, measurements, metadata, {parent, device_id}) do
    if metadata.device_id == device_id do
      send(parent, {:identity_fence_retained, measurements, metadata})
    end
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok,
     actor: SystemActor.system(:source_retired_expiry_test),
     n: System.unique_integer([:positive, :monotonic])}
  end

  describe "grace deletion" do
    test "a record marked past its grace period is soft-deleted, and its address released",
         ctx do
      a = create_device(ctx, 1)
      mark(a, days_ago(8))
      assert %Device{metadata: %{"identity_state" => "source_retired"}} = reload(ctx, a)
      revision = reload(ctx, a).identity_revision
      attach_events(ctx)

      assert {:ok, %{deleted: 1, candidates: 1, held: 0}} = run(ctx, [a])

      deleted = reload(ctx, a)
      assert %DateTime{} = deleted.deleted_at
      assert deleted.deleted_reason == "source_retired"
      assert deleted.deleted_by == "system:source_retirement"
      assert deleted.ip == nil
      # The soft delete clears the mark and its mirror.
      assert deleted.source_retired_at == nil
      refute Map.has_key?(deleted.metadata || %{}, "identity_state")
      assert deleted.identity_revision > revision

      assert_received {:source_retired_expiry, :run, %{deleted: 1, candidates: 1, held: 0},
                       %{deleted_reason: "source_retired"}}
    end

    test "a record inside its grace period, or unmarked, is kept", ctx do
      a = create_device(ctx, 1)
      b = create_device(ctx, 2)
      mark(a, days_ago(6))

      assert {:ok, %{deleted: 0, candidates: 0, held: 0}} = run(ctx, [a, b])
      assert %Device{deleted_at: nil, source_retired_at: %DateTime{}} = reload(ctx, a)
      assert %Device{deleted_at: nil, source_retired_at: nil} = reload(ctx, b)

      # The grace period is the setting's.
      assert {:ok, %{deleted: 1}} =
               run(ctx, [a, b], %{@settings | source_retired_grace_days: 5})

      assert %Device{deleted_reason: "source_retired"} = reload(ctx, a)
      assert %Device{deleted_at: nil} = reload(ctx, b)
    end

    test "a record becomes due at deletes_after/2", ctx do
      a = create_device(ctx, 1)
      marked_at = days_ago(1)
      mark(a, marked_at)
      due = SourceRetiredExpiry.deletes_after(marked_at, 7)

      assert DateTime.diff(due, marked_at, :day) == 7

      assert {:ok, %{deleted: 0}} = run(ctx, [a], @settings, now: DateTime.add(due, -1, :second))
      assert %Device{deleted_at: nil} = reload(ctx, a)

      assert {:ok, %{deleted: 1}} = run(ctx, [a], @settings, now: due)
      assert %Device{deleted_reason: "source_retired"} = reload(ctx, a)
    end

    test "a pass walks every batch", ctx do
      records = for i <- 1..5, do: create_device(ctx, i)
      Enum.each(records, &mark(&1, days_ago(8)))

      assert {:ok, %{deleted: 5, candidates: 5}} =
               run(ctx, records, %{@settings | batch_size: 2})

      assert Enum.all?(records, &(reload(ctx, &1).deleted_reason == "source_retired"))
    end
  end

  describe "the review hold" do
    test "a record an open de-duplication task names is kept until the task closes", ctx do
      a = create_device(ctx, 1)
      b = create_device(ctx, 2)
      mark(a, days_ago(30))
      task = open_task(ctx, a, b)

      assert {:ok, %{deleted: 0, candidates: 0, held: 1}} = run(ctx, [a, b])
      assert %Device{deleted_at: nil, source_retired_at: %DateTime{}} = reload(ctx, a)
      assert SourceRetiredExpiry.held_for_review(a.uid) == {:ok, true}

      assert {:ok, %DeduplicationTask{status: :dismissed}} =
               Deduplication.dismiss(task, @operator)

      assert SourceRetiredExpiry.held_for_review(a.uid) == {:ok, false}

      assert {:ok, %{deleted: 1, held: 0}} = run(ctx, [a, b])
      assert %Device{deleted_reason: "source_retired"} = reload(ctx, a)
      assert %Device{deleted_at: nil} = reload(ctx, b)
    end
  end

  describe "the mass guard" do
    test "a pass over the fraction deletes nothing, logs the counts and emits telemetry", ctx do
      {due, uids} = mass_due(ctx, 0)
      attach_events(ctx)

      log =
        capture_log(fn ->
          assert {:error, {:mass_deletion_refused, %{candidates: 3, live: 4, max_fraction: 0.5}}} =
                   run(ctx, uids, guarded())
        end)

      assert log =~ "pass refused (mass_deletion)"
      assert log =~ "would delete up to 3 of 4 live records"

      assert_received {:source_retired_expiry, :refused, %{candidates: 3, live_devices: 4},
                       %{reason: :mass_deletion, max_fraction: 0.5}}

      refute_received {:source_retired_expiry, :run, _measurements, _metadata}

      for record <- due,
          do:
            assert(%Device{deleted_at: nil, source_retired_at: %DateTime{}} = reload(ctx, record))
    end

    test "the override admits one refused pass, which clears it", ctx do
      {due, uids} = mass_due(ctx, 0)

      {:ok, _stored} =
        DeviceCleanupSettings.update_settings(
          settings!(ctx.actor),
          %{source_retirement_guard_override: true},
          actor: ctx.actor
        )

      overridden = %{guarded() | source_retirement_guard_override: true}

      capture_log(fn -> assert {:ok, %{deleted: 3}} = run(ctx, uids, overridden) end)

      for record <- due,
          do: assert(%Device{deleted_reason: "source_retired"} = reload(ctx, record))

      assert {:ok, %DeviceCleanupSettings{source_retirement_guard_override: false}} =
               DeviceCleanupSettings.get_settings(actor: ctx.actor)

      # The override is spent: the next pass over the guard is refused, even under the
      # settings read before it was cleared.
      {other_due, other_uids} = mass_due(ctx, 10)

      capture_log(fn ->
        assert {:error, {:mass_deletion_refused, %{candidates: 3, live: 4}}} =
                 run(ctx, other_uids, overridden)
      end)

      for record <- other_due, do: assert(%Device{deleted_at: nil} = reload(ctx, record))
    end
  end

  describe "settings" do
    test "nothing is deleted while retirement is disabled, or with no settings", ctx do
      a = create_device(ctx, 1)
      mark(a, days_ago(30))

      assert {:ok, %{deleted: 0, candidates: 0, held: 0}} =
               run(ctx, [a], %{@settings | source_retirement_enabled: false})

      assert {:ok, %{deleted: 0, candidates: 0, held: 0}} = run(ctx, [a], %{})
      assert %Device{deleted_at: nil, source_retired_at: %DateTime{}} = reload(ctx, a)
    end
  end

  describe "the tombstone" do
    test "an evidence restore is refused; an operator restore revives it unmarked", ctx do
      a = create_device(ctx, 1)
      mark(a, days_ago(8))
      assert {:ok, %{deleted: 1}} = run(ctx, [a])
      tombstone = reload(ctx, a)

      # The restores a sweep, a discovery poll and an agent check-in use.
      assert_retained_refusal(restore(ctx, a, :restore, %{}))
      assert_retained_refusal(restore(ctx, a, :gateway_restore, %{ip: "192.0.2.1"}))
      assert %Device{deleted_reason: "source_retired"} = reload(ctx, a)

      assert %Ash.BulkResult{status: :success} =
               restore(ctx, a, :restore, %{allow_retained: true})

      restored = reload(ctx, a)
      assert restored.deleted_at == nil
      assert restored.source_retired_at == nil
      assert restored.identity_revision > tombstone.identity_revision
      assert revival_audit_reason(a.uid) == "source_retired"
    end

    # The MAC stays on the tombstone, so a sync update carrying it resolves there; the fence
    # withholds the update before anything is written, the tombstone's identifiers included.
    test "a sync update its MAC resolves to the tombstone is withheld", ctx do
      a = create_device(ctx, 1)
      mac = register_mac(ctx, a)
      mark(a, days_ago(8))
      assert {:ok, %{deleted: 1}} = run(ctx, [a])
      tombstone = reload(ctx, a)
      identifiers = identifier_rows(a)
      attach_fence_events(a)

      update = %{
        "mac" => mac,
        "ip" => "192.0.2.60",
        "hostname" => "sighting-#{ctx.n}",
        "source" => "netbox",
        "metadata" => %{"sync_service_id" => "grace-test-#{ctx.n}"}
      }

      assert :ok = SyncIngestor.ingest_updates([update], actor: ctx.actor)

      uid = a.uid

      assert_received {:identity_fence_retained, %{count: 1},
                       %{pipeline: :sync_ingestor, device_id: ^uid}}

      withheld = reload(ctx, a)
      assert withheld.deleted_at == tombstone.deleted_at
      assert withheld.deleted_reason == "source_retired"
      assert withheld.identity_revision == tombstone.identity_revision
      assert withheld.hostname == tombstone.hostname
      assert withheld.ip == nil
      assert identifier_rows(a) == identifiers
      assert revival_audit_reason(a.uid) == nil
    end
  end

  describe "the cleanup worker" do
    test "runs the grace pass under the stored settings, and deletes nothing without them",
         ctx do
      {:ok, _stored} =
        DeviceCleanupSettings.update_settings(
          settings!(ctx.actor),
          %{source_retirement_enabled: true, source_retired_grace_days: 7},
          actor: ctx.actor
        )

      # The worker's pass is not scoped to this test's records, so the mass guard judges the
      # one due record against at least these four live ones.
      [a, b, c, d] = for i <- 1..4, do: create_device(ctx, i)
      mark(a, days_ago(8))

      assert :ok = DeviceCleanupWorker.perform(%Oban.Job{args: %{"manual" => true}})

      assert %Device{deleted_reason: "source_retired"} = reload(ctx, a)
      for record <- [b, c, d], do: assert(%Device{deleted_at: nil} = reload(ctx, record))

      # Settings that cannot be read fail closed.
      mark(b, days_ago(8))
      Repo.query!("DELETE FROM platform.device_cleanup_settings WHERE key = 'default'")

      assert :ok = DeviceCleanupWorker.perform(%Oban.Job{args: %{"manual" => true}})
      assert %Device{deleted_at: nil, source_retired_at: %DateTime{}} = reload(ctx, b)
    end
  end

  defp run(ctx, records, settings \\ @settings, opts \\ []) do
    SourceRetiredExpiry.run(settings, ctx.actor, Keyword.put(opts, :uids, uids(records)))
  end

  defp guarded, do: %{@settings | source_retirement_max_fraction: 0.5}

  # Four live records, three of them due: deleting them all is more than half.
  defp mass_due(ctx, ip_base) do
    [_kept | due] = records = for i <- 1..4, do: create_device(ctx, ip_base + i)
    Enum.each(due, &mark(&1, days_ago(8)))
    {due, uids(records)}
  end

  defp uids(records), do: Enum.map(records, &uid/1)

  defp uid(%{uid: uid}), do: uid
  defp uid(uid) when is_binary(uid), do: uid

  defp create_device(ctx, i) do
    {:ok, device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        ip: "192.0.2.#{i}",
        hostname: "grace-#{ctx.n}-#{i}"
      })
      |> Ash.create(actor: ctx.actor)

    device
  end

  # A documentation MAC, one per test.
  defp register_mac(ctx, record) do
    mac =
      "00:00:5E:00:53:" <>
        (ctx.n |> rem(256) |> Integer.to_string(16) |> String.pad_leading(2, "0"))

    {:ok, _identifier} =
      DeviceIdentifier
      |> Ash.Changeset.for_create(:register, %{
        device_id: record.uid,
        identifier_type: :mac,
        identifier_value: String.replace(mac, ":", ""),
        partition: "default",
        confidence: :strong,
        source: "source_retired_expiry_test"
      })
      |> Ash.create(actor: ctx.actor)

    mac
  end

  defp identifier_rows(record) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT identifier_type, identifier_value, partition, last_seen, metadata
        FROM platform.device_identifiers
        WHERE device_id = $1
        ORDER BY identifier_type, identifier_value, partition
        """,
        [record.uid]
      )

    rows
  end

  # Marks the record as SourceRetirement does; the mirror trigger sets identity_state.
  defp mark(record, %DateTime{} = marked_at) do
    %{num_rows: 1} =
      Repo.query!("UPDATE platform.ocsf_devices SET source_retired_at = $2 WHERE uid = $1", [
        record.uid,
        DateTime.to_naive(marked_at)
      ])
  end

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days, :day)

  # open_for_decisions/1 returns :ok when the write fails too, so read the task back.
  defp open_task(ctx, a, b) do
    :ok =
      Deduplication.open_for_decisions([
        %{
          decision_kind: :succession_review,
          reason: "grace_test",
          device_uids: [a.uid, b.uid],
          evidence: %{}
        }
      ])

    {:ok, [%DeduplicationTask{status: :open} = task]} =
      DeduplicationTask.for_device(a.uid, actor: ctx.actor)

    task
  end

  # Through a read that includes tombstones, as every restore caller does: a single-record
  # update of a tombstone is refused as stale before any validation runs.
  defp restore(ctx, record, action, attrs) do
    Device
    |> Ash.Query.for_read(:read, %{include_deleted: true})
    |> Ash.Query.filter(uid == ^record.uid)
    |> Ash.bulk_update(action, attrs, actor: ctx.actor, return_errors?: true)
  end

  defp assert_retained_refusal(%Ash.BulkResult{} = result) do
    assert %Ash.BulkResult{status: :error, errors: [_ | _] = errors} = result
    assert Enum.any?(errors, &(Exception.message(&1) =~ "is a retained tombstone"))
  end

  defp reload(ctx, record) do
    {:ok, device} = Device.get_by_uid(record.uid, true, actor: ctx.actor)
    device
  end

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

  defp attach_events(ctx) do
    handler_id = "source-retired-expiry-events-#{ctx.n}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:serviceradar, :inventory, :source_retired_expiry, :run],
          [:serviceradar, :inventory, :source_retired_expiry, :refused]
        ],
        &__MODULE__.forward_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp attach_fence_events(record) do
    handler_id = "source-retired-expiry-fence-#{record.uid}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:serviceradar, :identity_fence, :retained],
        &__MODULE__.forward_fence_event/4,
        {self(), record.uid}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp settings!(actor) do
    case DeviceCleanupSettings.get_settings(actor: actor) do
      {:ok, %DeviceCleanupSettings{} = settings} -> settings
      _ -> DeviceCleanupSettings.create_settings!(%{}, actor: actor)
    end
  end
end
