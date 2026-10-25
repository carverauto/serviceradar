defmodule ServiceRadar.Repo.Migrations.AddAvailabilityModeControl do
  @moduledoc """
  Automatic progression of merged device availability (`add-merged-device-availability`,
  design Decision 10, "Automatic progression"). Columns on the single
  `availability_settings` row only.

  * `mode_control`: the deployment's control, `auto` (core moves `legacy` to `shadow` and
    cuts over when the readiness conditions hold), `hold_legacy` or `hold_shadow`.
    Every existing row takes `auto`, so upgraded installs progress on their own.
  * `mode_control_pin`: the `SERVICERADAR_AVAILABILITY_MODE_CONTROL` value core runs
    with, recorded by `ServiceRadar.Inventory.Availability.ProgressionWorker` so the
    settings UI, which runs in another release, can show the control as pinned.
  * `shadow_entered_at` and `shadow_resolved_at`: when the deployment entered `shadow`,
    and when the last full shadow resolution that started after that finished.
  * `readiness` and `readiness_checked_at`: the last readiness evaluation, for status.

  A deployment already in `shadow` gets `shadow_entered_at` from `updated_at`, which
  the mode switch sets and nothing else changes, so it is no earlier than the entry.

  serviceradar:allow-startup-maintenance - the one UPDATE writes the single settings row.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    ALTER TABLE #{@prefix}.availability_settings
      ADD COLUMN mode_control text NOT NULL DEFAULT 'auto'
        CHECK (mode_control IN ('auto', 'hold_legacy', 'hold_shadow')),
      ADD COLUMN mode_control_pin text,
      ADD COLUMN shadow_entered_at timestamp without time zone,
      ADD COLUMN shadow_resolved_at timestamp without time zone,
      ADD COLUMN readiness jsonb,
      ADD COLUMN readiness_checked_at timestamp without time zone
    """)

    execute("""
    UPDATE #{@prefix}.availability_settings
    SET shadow_entered_at = updated_at
    WHERE singleton AND mode = 'shadow'
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    ALTER TABLE #{@prefix}.availability_settings
      DROP COLUMN IF EXISTS mode_control,
      DROP COLUMN IF EXISTS mode_control_pin,
      DROP COLUMN IF EXISTS shadow_entered_at,
      DROP COLUMN IF EXISTS shadow_resolved_at,
      DROP COLUMN IF EXISTS readiness,
      DROP COLUMN IF EXISTS readiness_checked_at
    """)
  end
end
