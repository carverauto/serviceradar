defmodule ServiceRadar.Inventory.DeviceRevivalAuditDbTest do
  @moduledoc """
  The revival audit trigger must survive future migrations.

  Clearing `deleted_at` also clears `deleted_by` and `deleted_reason`, so a device
  that was deliberately deleted and then revived is otherwise indistinguishable
  from one never deleted -- the revival destroys the evidence of the deletion. On
  2026-08-23 a phantom device was soft-deleted twice by hand and silently revived
  both times.

  The trigger is enforced in the database rather than in an Ash change module
  because one of the three writers that clear the tombstone
  (`Inventory.Sync.DeviceWrites`) does it through a raw Ecto `on_conflict` that
  never builds a changeset. This test therefore drives the table DIRECTLY with SQL
  -- exercising the same layer that writer uses, and the layer an Ash-level test
  would miss.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Repo

  @moduletag :integration

  defp uid, do: "sr:revival-audit-test-#{System.unique_integer([:positive])}"

  defp audit_rows(device_uid) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT previous_deleted_by, previous_deleted_reason
        FROM platform.device_revival_audit
        WHERE device_uid = $1
        ORDER BY event_id
        """,
        [device_uid]
      )

    rows
  end

  defp insert_device(device_uid) do
    # `uid` is the only NOT NULL column without a default, so this is the minimal
    # insert -- naming more columns just creates ways for this test to fail for
    # reasons unrelated to the trigger.
    Repo.query!("INSERT INTO platform.ocsf_devices (uid) VALUES ($1)", [device_uid])
  end

  defp soft_delete(device_uid, by, reason) do
    Repo.query!(
      """
      UPDATE platform.ocsf_devices
      SET deleted_at = now(), deleted_by = $2, deleted_reason = $3
      WHERE uid = $1
      """,
      [device_uid, by, reason]
    )
  end

  defp revive(device_uid) do
    Repo.query!(
      """
      UPDATE platform.ocsf_devices
      SET deleted_at = NULL, deleted_by = NULL, deleted_reason = NULL
      WHERE uid = $1
      """,
      [device_uid]
    )
  end

  test "a revival records the tombstone it destroys" do
    device_uid = uid()
    insert_device(device_uid)

    soft_delete(device_uid, "phantom-cleanup", "phantom APIPA record")
    assert audit_rows(device_uid) == [], "a deletion is not a revival and must not audit"

    revive(device_uid)

    assert [["phantom-cleanup", "phantom APIPA record"]] = audit_rows(device_uid),
           "the reason the revival cleared from the device row must survive here"
  end

  test "an ordinary update on a live device does not audit" do
    device_uid = uid()
    insert_device(device_uid)

    Repo.query!("UPDATE platform.ocsf_devices SET deleted_by = $2 WHERE uid = $1", [
      device_uid,
      "noise"
    ])

    assert audit_rows(device_uid) == []
  end

  test "repeat revivals each get a row" do
    # The pattern that actually occurred: deleted, revived, deleted again, revived
    # again. One row per revival is what makes "my cleanup keeps being undone"
    # legible instead of invisible.
    device_uid = uid()
    insert_device(device_uid)

    soft_delete(device_uid, "cleanup-1", "first attempt")
    revive(device_uid)
    soft_delete(device_uid, "cleanup-2", "second attempt")
    revive(device_uid)

    assert [["cleanup-1", "first attempt"], ["cleanup-2", "second attempt"]] =
             audit_rows(device_uid)
  end
end
