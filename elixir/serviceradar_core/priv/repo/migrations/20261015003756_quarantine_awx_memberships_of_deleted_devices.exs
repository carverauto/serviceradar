defmodule ServiceRadar.Repo.Migrations.QuarantineAwxMembershipsOfDeletedDevices do
  @moduledoc """
  Quarantine an approved AWX host membership when its canonical device row is
  deleted, instead of failing the delete.

  `ansible_awx_host_memberships.canonical_device_uid` references
  `ocsf_devices(uid) ON DELETE SET NULL`, while the check constraint
  `ansible_awx_host_memberships_approved_link` requires an `approved` membership
  to keep a canonical device. The two contradict each other: deleting a device
  with an approved membership makes the foreign key action write a row the check
  rejects (SQLSTATE 23514), so the delete rolls back. The device purge in
  `ServiceRadar.Inventory.DeviceCleanupWorker` therefore never removed such a
  device and retried it on every run.

  An approved link whose device no longer exists is the state the membership
  reconciler already calls `quarantined`: an approved membership that loses its
  device match is quarantined, and the reconciler keeps a quarantined membership
  quarantined (approval accepts only a `proposed` one). The trigger applies that
  rule to the foreign key action, so a device that later matches the same AWX
  host never inherits the approval of a purged one.

  The trigger acts only when the referenced device row is gone. Application code
  that clears the device of an approved membership while the device still exists
  is still rejected by the check constraint.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION #{@prefix}.trg_ansible_awx_membership_device_deleted()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM #{@prefix}.ocsf_devices WHERE uid = OLD.canonical_device_uid
      ) THEN
        NEW.link_disposition := 'quarantined';
        NEW.link_evidence := NEW.link_evidence || jsonb_build_object(
          'canonical_device_deleted',
          jsonb_build_object(
            'device_uid', OLD.canonical_device_uid,
            'deleted_at', now() AT TIME ZONE 'utc'
          )
        );
        NEW.updated_at := now() AT TIME ZONE 'utc';
      END IF;

      RETURN NEW;
    END;
    $$;
    """)

    execute("""
    DROP TRIGGER IF EXISTS trg_ansible_awx_membership_device_deleted
    ON #{@prefix}.ansible_awx_host_memberships
    """)

    # WHEN-guarded so the function body runs only for an approved membership
    # whose device link is being cleared, which is the foreign key action.
    execute("""
    CREATE TRIGGER trg_ansible_awx_membership_device_deleted
    BEFORE UPDATE OF canonical_device_uid ON #{@prefix}.ansible_awx_host_memberships
    FOR EACH ROW
    WHEN (
      OLD.link_disposition = 'approved'
      AND NEW.link_disposition = 'approved'
      AND OLD.canonical_device_uid IS NOT NULL
      AND NEW.canonical_device_uid IS NULL
    )
    EXECUTE FUNCTION #{@prefix}.trg_ansible_awx_membership_device_deleted()
    """)
  end

  def down do
    execute("""
    DROP TRIGGER IF EXISTS trg_ansible_awx_membership_device_deleted
    ON #{@prefix}.ansible_awx_host_memberships
    """)

    execute("""
    DROP FUNCTION IF EXISTS #{@prefix}.trg_ansible_awx_membership_device_deleted()
    """)
  end
end
