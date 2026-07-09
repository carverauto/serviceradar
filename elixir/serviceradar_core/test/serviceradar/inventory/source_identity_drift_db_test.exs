defmodule ServiceRadar.Inventory.SourceIdentityDriftDbTest do
  @moduledoc """
  DB-backed coverage for the decoupled drift audit/persist + cached read +
  reconcile path (the northbound conflict report moved off the per-run hot
  path into a periodic global `audit_and_persist/0`).
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.SourceIdentityDrift
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

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

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp unique_ip do
    a = System.unique_integer([:positive])
    "10.#{rem(div(a, 65_536), 60) + 60}.#{rem(div(a, 256), 256)}.#{rem(a, 254) + 1}"
  end
end
