defmodule ServiceRadar.Inventory.SourceIdentityDriftDbTest do
  @moduledoc """
  DB-backed coverage for the decoupled drift audit/persist + cached read +
  reconcile path (the northbound conflict report moved off the per-run hot
  path into a periodic global `audit_and_persist/0`).
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.SourceIdentityDrift
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration
  @oversized_batch_count 3_500

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:source_identity_drift_db_test)}
  end

  test "audit_and_persist persists a metadata disagreement that source_conflict_report reads back",
       %{actor: actor} do
    source_id = unique("drift-src")
    typed_id = unique("armis-typed")
    device = create_disagreeing_device!(actor, source_id, typed_id, unique("armis-stale"))

    assert %{audited_count: audited} = SourceIdentityDrift.audit_and_persist()
    assert audited >= 1

    report = SourceIdentityDrift.source_conflict_report(%{id: source_id})

    assert report["total_count"] >= 1
    assert Map.has_key?(report["categories"], "metadata_identifier_disagreement")
    assert Enum.any?(report["examples"], &(&1["device_uid"] == device.uid))
    assert conflict_status(device.uid, "metadata_identifier_disagreement") == "open"
  end

  test "audit_and_persist reconciles a resolved conflict to 'cleared' and drops it from the read",
       %{actor: actor} do
    source_id = unique("drift-src")
    typed_id = unique("armis-typed")
    device = create_disagreeing_device!(actor, source_id, typed_id, unique("armis-stale"))

    assert %{} = SourceIdentityDrift.audit_and_persist()
    assert conflict_status(device.uid, "metadata_identifier_disagreement") == "open"

    # Repair the metadata to match the typed identifier -> no more disagreement.
    update_metadata!(actor, device, %{
      "sync_service_id" => source_id,
      "integration_type" => "armis",
      "armis_device_id" => typed_id
    })

    assert %{cleared_count: cleared} = SourceIdentityDrift.audit_and_persist()
    assert cleared >= 1
    assert conflict_status(device.uid, "metadata_identifier_disagreement") == "cleared"

    report = SourceIdentityDrift.source_conflict_report(%{id: source_id})
    refute Enum.any?(report["examples"], &(&1["device_uid"] == device.uid))
  end

  # The repair WRITE path had no coverage at all, which is how a double-encoded
  # jsonb parameter reached production: `Jason.encode!(patch)` bound to
  # `metadata = ... || $2::jsonb` made Postgrex encode the binary a second time,
  # storing a jsonb string scalar. `object || string` builds an ARRAY rather
  # than merging, so the repair silently destroyed the very metadata it was
  # fixing and every later read raised `cannot load [...] as type :map`.
  test "repair_armis rewrites the metadata identifier and keeps metadata a jsonb object",
       %{actor: actor} do
    source_id = unique("drift-src")
    typed_id = unique("armis-typed")
    stale_id = unique("armis-stale")
    device = create_disagreeing_device!(actor, source_id, typed_id, stale_id)

    assert %{applied_repairs: applied} =
             SourceIdentityDrift.repair_armis(
               apply: true,
               source_id: source_id,
               actor: "drift_db_test"
             )

    assert Enum.any?(applied, &(&1.device_uid == device.uid))

    # The column must still be an object. Before the fix this was "array".
    assert metadata_typeof(device.uid) == "object"

    metadata = device_metadata(device.uid)

    # A merge, not a replace: the repaired identifier wins and the untouched
    # keys survive.
    assert metadata["armis_device_id"] == typed_id
    assert metadata["sync_service_id"] == source_id
    assert metadata["integration_type"] == "armis"

    # The audit trail is a nested object, not a re-encoded JSON string.
    assert %{"prior" => prior, "repaired" => repaired} = metadata["source_identity_repair"]
    assert prior["armis_device_id"] == stale_id
    assert repaired["armis_device_id"] == typed_id

    # The resolution audit written to the conflict row has the same hazard.
    assert repair_audit_typeof(device.uid) in ["object", nil]

    # Reading the device back through Ash is what actually broke in production.
    assert %{metadata: loaded} = Ash.get!(Device, device.uid, actor: actor)
    assert is_map(loaded)
  end

  test "audit and repair preserve scoped integration identities", %{actor: actor} do
    source_id = unique("drift-src")
    typed_id = unique("armis-typed")
    scoped_id = "armis:#{source_id}:device:#{typed_id}"
    device = create_disagreeing_device!(actor, source_id, typed_id, typed_id)
    metadata = Map.put(device.metadata, "integration_id", scoped_id)
    device = update_metadata!(actor, device, metadata)

    SourceIdentityDrift.audit_and_persist()
    assert conflict_status(device.uid, "metadata_identifier_disagreement") == nil
    assert %{repairs: []} = SourceIdentityDrift.repair_armis(source_id: source_id)

    update_metadata!(actor, device, Map.put(metadata, "armis_device_id", unique("stale")))

    assert %{applied_repairs: [repair]} =
             SourceIdentityDrift.repair_armis(apply: true, source_id: source_id)

    assert repair.device_uid == device.uid
    repaired = device_metadata(device.uid)
    assert repaired["armis_device_id"] == typed_id
    assert repaired["integration_id"] == scoped_id
    assert repaired["source_identity_repair"]["repaired"]["integration_id"] == scoped_id
    assert %{repairs: []} = SourceIdentityDrift.repair_armis(source_id: source_id)
  end

  test "reconcile leaves sync-written active_ip_conflict rows open" do
    source_id = unique("drift-src")
    device_uid = "sr:" <> Ecto.UUID.generate()

    :ok =
      SourceIdentityDrift.record_conflicts([
        %{
          source_type: "armis",
          source_id: source_id,
          source_identifier_type: "armis_device_id",
          source_identifier_value: unique("armis-ip"),
          device_uid: device_uid,
          current_ip: "203.0.113.5",
          conflict_category: "active_ip_conflict",
          conflicting_identifiers: %{},
          proposed_action: "preserve_source_identity_drop_conflicting_ip",
          confidence: "high",
          metadata: %{}
        }
      ])

    assert conflict_status(device_uid, "active_ip_conflict") == "open"

    # A full audit that does not re-detect this row must NOT clear it: the
    # active-IP category is written by sync ingestion, not the audit.
    assert %{} = SourceIdentityDrift.audit_and_persist()
    assert conflict_status(device_uid, "active_ip_conflict") == "open"
  end

  test "record_conflicts chunks statements below PostgreSQL's bind parameter limit" do
    source_id = unique("bulk-source")
    conflicts = bulk_conflicts(source_id, @oversized_batch_count)

    assert :ok = SourceIdentityDrift.record_conflicts(conflicts)

    assert conflict_count(source_id, "metadata_identifier_disagreement") ==
             @oversized_batch_count
  end

  test "record_conflicts rolls back earlier chunks when a later chunk fails" do
    source_id = unique("rollback-source")

    conflicts =
      source_id
      |> bulk_conflicts(@oversized_batch_count)
      |> List.update_at(-1, &Map.put(&1, :metadata, %{"not_json" => self()}))

    assert {:error, _reason} = SourceIdentityDrift.record_conflicts(conflicts)
    assert conflict_count(source_id, "metadata_identifier_disagreement") == 0
  end

  test "audit persistence failure does not clear previously open audit conflicts" do
    source_id = unique("failed-audit-source")
    device_uid = "sr:" <> Ecto.UUID.generate()

    open_conflict =
      source_id
      |> conflict("metadata_identifier_disagreement", unique("armis-stale"))
      |> Map.put(:device_uid, device_uid)

    assert :ok = SourceIdentityDrift.record_conflicts([open_conflict])
    assert conflict_status(device_uid, "metadata_identifier_disagreement") == "open"

    assert {:error, :forced_persist_failure} =
             SourceIdentityDrift.audit_and_persist(
               audit_fun: fn -> %{conflicts: [], summary: %{}} end,
               persist_fun: fn [] -> {:error, :forced_persist_failure} end
             )

    assert conflict_status(device_uid, "metadata_identifier_disagreement") == "open"
  end

  test "source_conflict_report is scoped to the source; blank-source conflicts do not leak" do
    source_a = unique("src-a")
    other_source = unique("src-b")

    :ok =
      SourceIdentityDrift.record_conflicts([
        conflict(source_a, "metadata_identifier_disagreement", unique("armis-a")),
        # A conflict with no source linkage must not be attributed to any source.
        conflict(nil, "metadata_identifier_disagreement", unique("armis-blank"))
      ])

    report_a = SourceIdentityDrift.source_conflict_report(%{id: source_a})
    assert report_a["total_count"] >= 1

    # A fresh unrelated source sees neither source_a's nor the blank-source rows.
    report_other = SourceIdentityDrift.source_conflict_report(%{id: other_source})
    assert report_other["total_count"] == 0
  end

  test "source_conflict_report counts non-withholding categories in total but not skipped" do
    source_id = unique("src-mix")

    :ok =
      SourceIdentityDrift.record_conflicts([
        conflict(source_id, "metadata_identifier_disagreement", unique("armis-withhold")),
        conflict(source_id, "typed_id_on_multiple_devices", unique("armis-shared"))
      ])

    report = SourceIdentityDrift.source_conflict_report(%{id: source_id})

    assert report["total_count"] == 2
    # Only the withholding category counts toward skipped; the shared-id one can
    # still be sent, so it must not inflate the skip count.
    assert report["skipped_count"] == 1
    assert report["categories"]["typed_id_on_multiple_devices"] == 1
    assert report["categories"]["metadata_identifier_disagreement"] == 1
    assert SourceIdentityDrift.withheld_conflict_count(report) == 1
  end

  test "source_conflict_report counts one skipped device once across duplicate conflicts" do
    source_id = unique("src-duplicate-withheld")
    device_uid = "sr:" <> Ecto.UUID.generate()

    :ok =
      SourceIdentityDrift.record_conflicts([
        source_id
        |> conflict("metadata_identifier_disagreement", unique("armis-meta"))
        |> Map.put(:device_uid, device_uid),
        source_id
        |> conflict("split_typed_generic_identifier", unique("armis-split"))
        |> Map.put(:device_uid, device_uid)
      ])

    report = SourceIdentityDrift.source_conflict_report(%{id: source_id})

    assert report["total_count"] == 2
    assert report["skipped_count"] == 1
  end

  defp conflict(source_id, category, identifier_value) do
    %{
      source_type: "armis",
      source_id: source_id,
      source_identifier_type: "armis_device_id",
      source_identifier_value: identifier_value,
      device_uid: "sr:" <> Ecto.UUID.generate(),
      conflict_category: category,
      conflicting_identifiers: %{},
      proposed_action: "manual_review",
      confidence: "ambiguous",
      metadata: %{}
    }
  end

  defp create_disagreeing_device!(actor, source_id, typed_id, stale_id) do
    device =
      create_device!(actor, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: unique("drift-host"),
        ip: unique_ip(),
        metadata: %{
          "sync_service_id" => source_id,
          "integration_type" => "armis",
          "armis_device_id" => stale_id
        }
      })

    register!(actor, device.uid, :armis_device_id, typed_id, %{"sync_service_id" => source_id})
    device
  end

  defp create_device!(actor, attrs) do
    Device
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp register!(actor, device_uid, type, value, metadata) do
    DeviceIdentifier
    |> Ash.Changeset.for_create(
      :register,
      %{
        device_id: device_uid,
        identifier_type: type,
        identifier_value: value,
        partition: "default",
        confidence: :strong,
        metadata: metadata
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp update_metadata!(actor, device, metadata) do
    device
    |> Ash.Changeset.for_update(:update, %{metadata: metadata}, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp conflict_status(device_uid, category) do
    %{rows: rows} =
      Repo.query!(
        "SELECT status FROM platform.source_identity_conflicts " <>
          "WHERE device_uid = $1 AND conflict_category = $2 " <>
          "ORDER BY last_detected_at DESC LIMIT 1",
        [device_uid, category]
      )

    case rows do
      [[status] | _] -> status
      _ -> nil
    end
  end

  # Asserted on directly rather than through Ash: a double-encoded jsonb
  # parameter changes the column's JSON *type*, and loading it through Ash is
  # exactly what raises instead of reporting the shape.
  defp metadata_typeof(device_uid) do
    single_value(
      "SELECT jsonb_typeof(metadata) FROM platform.ocsf_devices WHERE uid = $1",
      [device_uid]
    )
  end

  defp device_metadata(device_uid) do
    single_value("SELECT metadata FROM platform.ocsf_devices WHERE uid = $1", [device_uid])
  end

  defp repair_audit_typeof(device_uid) do
    single_value(
      "SELECT jsonb_typeof(repair_audit) FROM platform.source_identity_conflicts " <>
        "WHERE device_uid = $1 AND repair_audit IS NOT NULL LIMIT 1",
      [device_uid]
    )
  end

  defp single_value(sql, params) do
    case Repo.query!(sql, params) do
      %{rows: [[value] | _]} -> value
      _ -> nil
    end
  end

  defp conflict_count(source_id, category) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.source_identity_conflicts " <>
          "WHERE source_id = $1 AND conflict_category = $2",
        [source_id, category]
      )

    count
  end

  defp bulk_conflicts(source_id, count) do
    for index <- 1..count do
      source_id
      |> conflict("metadata_identifier_disagreement", "armis-bulk-#{index}")
      |> Map.put(:device_uid, "sr:bulk-#{source_id}-#{index}")
    end
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp unique_ip do
    a = System.unique_integer([:positive])
    "10.#{rem(div(a, 65_536), 60) + 60}.#{rem(div(a, 256), 256)}.#{rem(a, 254) + 1}"
  end
end
