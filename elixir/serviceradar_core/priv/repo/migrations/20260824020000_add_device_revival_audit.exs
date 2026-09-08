defmodule ServiceRadar.Repo.Migrations.AddDeviceRevivalAudit do
  @moduledoc """
  Records every time a soft-deleted device is brought back to life.

  Clearing `deleted_at` also clears `deleted_by` and `deleted_reason`, so a record
  that was deliberately deleted and then revived becomes indistinguishable from
  one that was never deleted. The evidence of the deletion is destroyed by the
  revival itself.

  That is not hypothetical. On 2026-08-23 a phantom device (`169.254.0.1`, an
  APIPA address a switch reported on its own interface) was soft-deleted twice by
  hand and came back both times: a sweep re-adopted the record as a target and
  revived it, and each revival wiped the reason field the cleanup had written. The
  operator had no way to tell the deletion had been undone rather than never
  applied.

  ## Why a trigger and not an Ash change module

  Three code paths clear the tombstone, and they do not share a layer:

    * `Device` action `:gateway_sync` -- routine ingest, not an explicit restore
    * `Device` action `:restore`
    * `Inventory.Sync.DeviceWrites` -- a raw Ecto `on_conflict` update inside a
      bulk upsert, which never builds an Ash changeset at all

  An Ash change module cannot see the third by construction, and the first two run
  through `Ash.bulk_update`, where `Ash.Changeset.get_attribute/2` may return stale
  data or raise (AGENTS.md, Ash section) -- so it could not reliably read the prior
  tombstone even where it is visible. A trigger sits below all three, and below the
  fourth writer nobody has written yet.

  ## Append-only, with no rejection logic

  The trigger only inserts and returns. It contains no validation and no condition
  under which it refuses a revival, so it gives nobody a motive to switch it off --
  an audit that can fail an ingest grows a bypass flag, and the bypass becomes the
  default. This schema already carries `platform.skip_inventory_rollup` for exactly
  that reason.

  Being precise rather than reassuring: this is an AFTER trigger, so a raised
  exception WOULD abort the surrounding write. It cannot raise in practice -- the
  WHEN guard proves `OLD.deleted_at IS NOT NULL`, `NEW.uid` is the primary key and
  therefore non-null, and every other audit column is nullable -- but "it has no
  rejection logic" is the accurate claim, not "it can never fail a write". If the
  audit table is ever dropped without dropping the trigger, revivals start failing.
  Drop both together (`down/0` does).

  Cost is below noise: `ocsf_devices` already carries an UNCONDITIONAL per-row
  trigger (`trg_ocsf_devices_inventory_rollup`) which itself compares
  `OLD.deleted_at` to `NEW.deleted_at`. This one is WHEN-guarded, so PostgreSQL
  evaluates the predicate without entering plpgsql on the overwhelming majority of
  updates that are not revivals.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:device_revival_audit, primary_key: false, prefix: @prefix) do
      add(:event_id, :bigserial, primary_key: true)
      add(:device_uid, :text, null: false)

      # The tombstone as it stood immediately before the revival. These are the
      # values the revival is about to destroy, which is the entire point.
      add(:previous_deleted_at, :utc_datetime_usec, null: false)
      add(:previous_deleted_by, :text)
      add(:previous_deleted_reason, :text)

      add(:revived_at, :utc_datetime_usec, null: false)

      # Postgres `application_name` of the reviving connection. Not an identity
      # claim -- it is a hint about WHICH writer did it, which is what turns
      # "something revived this" into a place to look.
      add(:revived_by_application, :text)
    end

    create(index(:device_revival_audit, [:device_uid, :revived_at], prefix: @prefix))
    create(index(:device_revival_audit, [:revived_at], prefix: @prefix))

    execute("""
    CREATE OR REPLACE FUNCTION #{@prefix}.trg_ocsf_devices_revival_audit()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
    BEGIN
      INSERT INTO #{@prefix}.device_revival_audit (
        device_uid,
        previous_deleted_at,
        previous_deleted_by,
        previous_deleted_reason,
        revived_at,
        revived_by_application
      ) VALUES (
        NEW.uid,
        OLD.deleted_at,
        OLD.deleted_by,
        OLD.deleted_reason,
        now(),
        current_setting('application_name', true)
      );

      RETURN NULL;
    END;
    $$;
    """)

    execute("""
    DROP TRIGGER IF EXISTS trg_ocsf_devices_revival_audit ON #{@prefix}.ocsf_devices
    """)

    # AFTER, so a failure here cannot roll back the device write, and FOR EACH ROW
    # with a WHEN guard so the function body is entered only on an actual revival.
    execute("""
    CREATE TRIGGER trg_ocsf_devices_revival_audit
    AFTER UPDATE ON #{@prefix}.ocsf_devices
    FOR EACH ROW
    WHEN (OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL)
    EXECUTE FUNCTION #{@prefix}.trg_ocsf_devices_revival_audit()
    """)
  end

  def down do
    execute("""
    DROP TRIGGER IF EXISTS trg_ocsf_devices_revival_audit ON #{@prefix}.ocsf_devices
    """)

    execute("""
    DROP FUNCTION IF EXISTS #{@prefix}.trg_ocsf_devices_revival_audit()
    """)

    drop(table(:device_revival_audit, prefix: @prefix))
  end
end
