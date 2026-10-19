defmodule ServiceRadar.Repo.Migrations.AddMergedAvailabilityShadow do
  @moduledoc """
  Stage b (shadow) of `add-merged-device-availability`. Additive and catalog-only:

  * `availability_settings.expiry_watermark`: how far the expiry job has re-resolved
    devices whose evidence or per-agent results aged out. Null until the deployment
    enters `shadow`.
  * `device_availability_shadow.changed_at`: when the shadow state last changed. Stage a
    created the table and nothing has written it, so the column is added to an empty
    table.
  * `trg_device_agent_availability_invalidate` checks the mode first, so in `legacy` a
    ledger write costs one settings lookup and never the sweep-group TTL lookup.
  * `trg_ocsf_devices_availability_lifecycle_invalidate`: outside `legacy`, a new device
    or a restored tombstone is appended to the invalidation log. Every restore path
    (the `:restore` and `:gateway_restore` actions and the raw upsert that clears a
    tombstone) updates `deleted_at`, so the trigger reaches all of them.
  * `trg_sweep_groups_availability_invalidate`: outside `legacy`, changing a sweep
    group's interval or deleting the group (the ledger keeps its rows, which fall back to
    the default window) changes the freshness window of every ledger row in that group,
    so every device with a ledger row in the group is appended to the invalidation log. The expiry job cannot catch it: a shortened window can move an
    expiry behind its watermark, and a lengthened one makes stale rows fresh.

  Locking: the new triggers append with plain INSERTs, which wait on no other
  transaction's row locks; they add no lock edge.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    ALTER TABLE #{@prefix}.availability_settings
      ADD COLUMN expiry_watermark timestamp without time zone
    """)

    execute("""
    ALTER TABLE #{@prefix}.device_availability_shadow
      ADD COLUMN changed_at timestamp without time zone
    """)

    execute(invalidate_function(:mode_first))

    execute("""
    CREATE FUNCTION #{@prefix}.trg_ocsf_devices_availability_lifecycle_invalidate()
    RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF #{@prefix}.availability_mode() <> 'legacy' THEN
        INSERT INTO #{@prefix}.availability_invalidations (device_uid) VALUES (NEW.uid);
      END IF;

      RETURN NULL;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER trg_ocsf_devices_availability_insert_invalidate
    AFTER INSERT ON #{@prefix}.ocsf_devices
    FOR EACH ROW WHEN (NEW.deleted_at IS NULL)
    EXECUTE FUNCTION #{@prefix}.trg_ocsf_devices_availability_lifecycle_invalidate()
    """)

    execute("""
    CREATE TRIGGER trg_ocsf_devices_availability_restore_invalidate
    AFTER UPDATE OF deleted_at ON #{@prefix}.ocsf_devices
    FOR EACH ROW WHEN (OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL)
    EXECUTE FUNCTION #{@prefix}.trg_ocsf_devices_availability_lifecycle_invalidate()
    """)

    execute("""
    CREATE FUNCTION #{@prefix}.trg_sweep_groups_availability_invalidate()
    RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF #{@prefix}.availability_mode() = 'legacy' THEN
        RETURN NULL;
      END IF;

      INSERT INTO #{@prefix}.availability_invalidations (device_uid)
      SELECT DISTINCT device_uid FROM #{@prefix}.device_agent_availability
      WHERE sweep_group_id = CASE TG_OP WHEN 'DELETE' THEN OLD.id ELSE NEW.id END;

      RETURN NULL;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER trg_sweep_groups_availability_interval_invalidate
    AFTER UPDATE OF "interval" ON #{@prefix}.sweep_groups
    FOR EACH ROW WHEN (OLD."interval" IS DISTINCT FROM NEW."interval")
    EXECUTE FUNCTION #{@prefix}.trg_sweep_groups_availability_invalidate()
    """)

    execute("""
    CREATE TRIGGER trg_sweep_groups_availability_delete_invalidate
    AFTER DELETE ON #{@prefix}.sweep_groups
    FOR EACH ROW
    EXECUTE FUNCTION #{@prefix}.trg_sweep_groups_availability_invalidate()
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    for trigger <- [
          "trg_sweep_groups_availability_interval_invalidate",
          "trg_sweep_groups_availability_delete_invalidate"
        ] do
      execute("DROP TRIGGER IF EXISTS #{trigger} ON #{@prefix}.sweep_groups")
    end

    execute(
      "DROP FUNCTION IF EXISTS #{@prefix}.trg_sweep_groups_availability_invalidate()"
    )

    for trigger <- [
          "trg_ocsf_devices_availability_insert_invalidate",
          "trg_ocsf_devices_availability_restore_invalidate"
        ] do
      execute("DROP TRIGGER IF EXISTS #{trigger} ON #{@prefix}.ocsf_devices")
    end

    execute(
      "DROP FUNCTION IF EXISTS #{@prefix}.trg_ocsf_devices_availability_lifecycle_invalidate()"
    )

    execute(invalidate_function(:conditions_first))

    execute("ALTER TABLE #{@prefix}.device_availability_shadow DROP COLUMN IF EXISTS changed_at")

    execute("ALTER TABLE #{@prefix}.availability_settings DROP COLUMN IF EXISTS expiry_watermark")
  end

  # The ledger AFTER trigger of migration 20261019180000. `:mode_first` returns before any
  # other lookup in `legacy`; `:conditions_first` is that migration's original body.
  defp invalidate_function(order) do
    {mode_gate, append} =
      case order do
        :mode_first ->
          {"""
           IF #{@prefix}.availability_mode() = 'legacy' THEN
             RETURN NULL;
           END IF;
           """,
           """
           INSERT INTO #{@prefix}.availability_invalidations (device_uid)
           VALUES (NEW.device_uid);
           """}

        :conditions_first ->
          {"",
           """
           IF #{@prefix}.availability_mode() <> 'legacy' THEN
             INSERT INTO #{@prefix}.availability_invalidations (device_uid)
             VALUES (NEW.device_uid);
           END IF;
           """}
      end

    """
    CREATE OR REPLACE FUNCTION #{@prefix}.trg_device_agent_availability_invalidate()
    RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE
      now_utc timestamp without time zone := (now() AT TIME ZONE 'utc');
    BEGIN
      #{mode_gate}
      IF TG_OP = 'INSERT'
         OR NEW.device_uid IS DISTINCT FROM OLD.device_uid
         OR NEW.is_available IS DISTINCT FROM OLD.is_available
         OR NEW.consecutive_down IS DISTINCT FROM OLD.consecutive_down
         OR NEW.sweep_group_id IS DISTINCT FROM OLD.sweep_group_id
         OR (NEW.metadata ->> 'sweep_reporter_expectation')
              IS DISTINCT FROM (OLD.metadata ->> 'sweep_reporter_expectation')
         OR (OLD.checked_at < now_utc - interval '150 seconds'
             AND OLD.checked_at <
                 now_utc - #{@prefix}.availability_ledger_ttl(NEW.sweep_group_id) / 2)
      THEN
        #{append}
      END IF;

      RETURN NULL;
    END;
    $$
    """
  end
end
