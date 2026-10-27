defmodule ServiceRadar.Repo.Migrations.ConvergeMergedAvailability do
  @moduledoc """
  Converges every deployment on merged device availability and removes the staged
  rollout (`simplify-merged-availability-rollout`). Before this release a deployment was
  in one of the modes `legacy`, `shadow`, `cutover` or `authoritative`; afterwards there
  is no mode, and every deployment behaves as `authoritative` did: the merged resolver
  owns `ocsf_devices.is_available` and `availability_state`, and the legacy writers record
  their value only in `device_availability_legacy`, which canonical Armis northbound
  sources with `legacy` semantics push.

  In order, in one transaction:

  1. In `legacy` and `shadow` only, every device that has no compatibility row gets one
     from its `is_available`, which in those modes is the legacy writers' value. Rows
     that exist are left alone: the legacy writers' trigger has kept them, and a row
     differs from the column only after an unfinished rollback, where the row is the
     legacy value. `ON CONFLICT DO NOTHING` also leaves a row a concurrent legacy write
     created meanwhile. In `cutover` and `authoritative` the table was seeded at cutover
     and the column holds the merged value, so nothing is copied.
  2. In `legacy` and `shadow` only, every Armis source with `merged` northbound semantics
     and no availability agent selected is set to `legacy`, with one row per source in
     the append-only `integration_source_availability_semantics_changes`. Such a source
     was created after merged availability shipped but has so far pushed the mirror of
     `is_available`, which is the legacy writers' value; `legacy` semantics keep pushing
     exactly that value from the compatibility store seeded in step 1, instead of the
     merged value it would otherwise switch to on this upgrade. This is the one change
     of a source's semantics that is not the operator's adopt action. A source with an
     agent selected, and every source of an install already at `cutover` or
     `authoritative`, is untouched.
  3. One `ServiceRadar.Inventory.Availability.ReconcileWorker` job is enqueued: a full
     resolve of every live device, then a rollup rebuild, and, for a deployment not yet
     `authoritative`, the one reconciliation summary and recovery events.
  4. The mirror trigger and the compatibility table's update trigger are dropped (only
     the legacy writers write the table now; its insert trigger stays, so every new
     device has a row), and the invalidation triggers append without a mode check.
  5. The shadow table, the mode, the mode control and the progression's bookkeeping
     columns, and `availability_mode()` are dropped; the expiry watermark starts now
     where the deployment never had one.
  6. Waiting jobs of the retired rollout workers are deleted.

  Per-agent ledger rows (`device_agent_availability`) are not touched.

  serviceradar:allow-startup-maintenance - step 1 inserts one row per device that has
  none, and only in `legacy` or `shadow` (a one-time filter; elsewhere it reads no device
  row); it never updates a device row or waits on a writer's row lock. The
  integration-source UPDATE writes only Armis sources in `merged` semantics with no
  agent, again only in `legacy` or `shadow`. The settings UPDATE writes the single
  settings row, including the one-time convergence marker; the empty-install check
  stops at the first device row. The DELETE removes only waiting jobs of the
  four retired workers. Every DDL statement runs under the 5 s lock timeout.
  """

  use Ecto.Migration

  @prefix "platform"
  @now_utc "(now() AT TIME ZONE 'utc')"
  @reconcile_worker "ServiceRadar.Inventory.Availability.ReconcileWorker"
  @flip_reason "preserved the pre-cutover northbound value on upgrade: a merged source " <>
                 "on an install that never cut over pushed the legacy mirror. Not identical " <>
                 "only where a legacy rollback restore had not finished, or the stage-a " <>
                 "projection of availability_state was incomplete, at upgrade"
  @retired_workers [
    "ServiceRadar.Inventory.Availability.CaptureBackfillWorker",
    "ServiceRadar.Inventory.Availability.CutoverWorker",
    "ServiceRadar.Inventory.Availability.ProgressionWorker",
    "ServiceRadar.Inventory.Availability.ShadowEntryWorker"
  ]

  def up, do: Enum.each(statements(), &execute/1)

  @doc """
  The migration's statements, in order. Public so a test can run them inside a
  transaction against a database it has put into a pre-upgrade state.
  """
  def statements do
    [
      "SET LOCAL lock_timeout = '5s'",
      """
      INSERT INTO #{@prefix}.device_availability_legacy AS legacy (device_uid, is_available, updated_at)
      SELECT d.uid, d.is_available, #{@now_utc}
      FROM #{@prefix}.ocsf_devices AS d
      WHERE #{@prefix}.availability_mode() IN ('legacy', 'shadow')
        AND NOT EXISTS (
          SELECT 1 FROM #{@prefix}.device_availability_legacy AS l WHERE l.device_uid = d.uid
        )
      ORDER BY d.uid
      ON CONFLICT (device_uid) DO NOTHING
      """,
      """
      CREATE TABLE #{@prefix}.integration_source_availability_semantics_changes (
        id bigserial PRIMARY KEY,
        integration_source_id uuid NOT NULL,
        from_semantics text NOT NULL,
        to_semantics text NOT NULL,
        reason text NOT NULL,
        changed_at timestamp without time zone NOT NULL DEFAULT #{@now_utc}
      )
      """,
      """
      WITH flipped AS (
        UPDATE #{@prefix}.integration_sources AS s
        SET northbound_availability_semantics = 'legacy'
        WHERE #{@prefix}.availability_mode() IN ('legacy', 'shadow')
          AND s.source_type = 'armis'
          AND s.northbound_availability_semantics = 'merged'
          AND NULLIF(btrim(s.northbound_availability_source_agent_id), '') IS NULL
        RETURNING s.id
      )
      INSERT INTO #{@prefix}.integration_source_availability_semantics_changes
        (integration_source_id, from_semantics, to_semantics, reason)
      SELECT id, 'merged', 'legacy', '#{@flip_reason}' FROM flipped
      """,
      """
      INSERT INTO #{@prefix}.oban_jobs (state, queue, worker, args, max_attempts)
      SELECT 'available', 'maintenance', '#{@reconcile_worker}',
             jsonb_build_object(
               'phase', 'reconcile',
               'announce', #{@prefix}.availability_mode() <> 'authoritative'
             ),
             20
      """,
      "DROP TRIGGER IF EXISTS trg_ocsf_devices_availability_mirror ON #{@prefix}.ocsf_devices",
      "DROP FUNCTION IF EXISTS #{@prefix}.trg_ocsf_devices_availability_mirror()",
      "DROP TRIGGER IF EXISTS trg_ocsf_devices_availability_legacy_update ON #{@prefix}.ocsf_devices",
      """
      CREATE OR REPLACE FUNCTION #{@prefix}.trg_ocsf_devices_availability_legacy()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        INSERT INTO #{@prefix}.device_availability_legacy AS legacy
          (device_uid, is_available, updated_at)
        VALUES (NEW.uid, NEW.is_available, #{@now_utc})
        ON CONFLICT (device_uid) DO UPDATE
          SET is_available = EXCLUDED.is_available,
              updated_at = EXCLUDED.updated_at
          WHERE legacy.is_available IS DISTINCT FROM EXCLUDED.is_available;

        RETURN NULL;
      END;
      $$
      """
    ] ++
      invalidate_device_functions() ++
      [
        """
        CREATE OR REPLACE FUNCTION #{@prefix}.trg_sweep_groups_availability_invalidate()
        RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          INSERT INTO #{@prefix}.availability_invalidations (device_uid)
          SELECT DISTINCT device_uid FROM #{@prefix}.device_agent_availability
          WHERE sweep_group_id = CASE TG_OP WHEN 'DELETE' THEN OLD.id ELSE NEW.id END;

          RETURN NULL;
        END;
        $$
        """,

        # The ledger AFTER trigger of migration 20261019190000 without its mode gate.
        """
        CREATE OR REPLACE FUNCTION #{@prefix}.trg_device_agent_availability_invalidate()
        RETURNS trigger LANGUAGE plpgsql AS $$
        DECLARE
          now_utc timestamp without time zone := #{@now_utc};
        BEGIN
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
            INSERT INTO #{@prefix}.availability_invalidations (device_uid)
            VALUES (NEW.device_uid);
          END IF;

          RETURN NULL;
        END;
        $$
        """,
        """
        CREATE OR REPLACE FUNCTION #{@prefix}.trg_device_vantage_expectations_invalidate()
        RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'INSERT' THEN
            INSERT INTO #{@prefix}.availability_invalidations (device_uid) VALUES (NEW.device_uid);
          ELSIF TG_OP = 'DELETE' THEN
            INSERT INTO #{@prefix}.availability_invalidations (device_uid) VALUES (OLD.device_uid);
          ELSE
            INSERT INTO #{@prefix}.availability_invalidations (device_uid) VALUES (OLD.device_uid);

            IF NEW.device_uid IS DISTINCT FROM OLD.device_uid THEN
              INSERT INTO #{@prefix}.availability_invalidations (device_uid) VALUES (NEW.device_uid);
            END IF;
          END IF;

          RETURN NULL;
        END;
        $$
        """,
        "DROP TABLE IF EXISTS #{@prefix}.device_availability_shadow",
        """
        INSERT INTO #{@prefix}.availability_settings (singleton) VALUES (true)
        ON CONFLICT (singleton) DO NOTHING
        """,
        """
        ALTER TABLE #{@prefix}.availability_settings
          ADD COLUMN IF NOT EXISTS converged_at timestamp without time zone
        """,
        """
        UPDATE #{@prefix}.availability_settings
        SET converged_at = #{@now_utc}
        WHERE singleton AND converged_at IS NULL
          AND (#{@prefix}.availability_mode() = 'authoritative'
               OR NOT EXISTS (SELECT 1 FROM #{@prefix}.ocsf_devices))
        """,
        """
        UPDATE #{@prefix}.availability_settings
        SET expiry_watermark = COALESCE(expiry_watermark, #{@now_utc}),
            updated_at = #{@now_utc}
        WHERE singleton
        """,
        """
        ALTER TABLE #{@prefix}.availability_settings
          DROP COLUMN IF EXISTS mode,
          DROP COLUMN IF EXISTS mode_control,
          DROP COLUMN IF EXISTS mode_control_pin,
          DROP COLUMN IF EXISTS shadow_entered_at,
          DROP COLUMN IF EXISTS shadow_resolved_at,
          DROP COLUMN IF EXISTS readiness,
          DROP COLUMN IF EXISTS readiness_checked_at
        """,
        "DROP FUNCTION IF EXISTS #{@prefix}.availability_mode()",
        """
        DELETE FROM #{@prefix}.oban_jobs
        WHERE worker IN (#{Enum.map_join(@retired_workers, ", ", &"'#{&1}'")})
          AND state IN ('available', 'scheduled', 'retryable')
        """
      ]
  end

  defp invalidate_device_functions do
    for function <- [
          "trg_ocsf_devices_availability_pin_invalidate",
          "trg_ocsf_devices_availability_lifecycle_invalidate"
        ] do
      """
      CREATE OR REPLACE FUNCTION #{@prefix}.#{function}()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        INSERT INTO #{@prefix}.availability_invalidations (device_uid) VALUES (NEW.uid);
        RETURN NULL;
      END;
      $$
      """
    end
  end

  def down do
    raise "Merged availability convergence is not reversible: the availability modes and " <>
            "the shadow table no longer exist in this release; deploy a compatible forward migration"
  end
end
