defmodule ServiceRadar.Repo.Migrations.RetainExposureDeliveryInputs do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE platform.exposure_delivery_batches
      ADD COLUMN phase text NOT NULL DEFAULT 'legacy',
      ADD COLUMN operation_id uuid,
      ADD COLUMN payload_hash text,
      ADD COLUMN recovery_position bigint,
      ADD CONSTRAINT exposure_delivery_phase CHECK (
        phase IN ('legacy', 'capturing', 'applying', 'complete', 'snapshot_required')
      ),
      ADD CONSTRAINT exposure_delivery_identity CHECK (
        (operation_id IS NULL AND payload_hash IS NULL AND phase = 'legacy') OR
        (operation_id IS NOT NULL AND payload_hash IS NOT NULL AND payload_hash ~ '^[0-9a-f]{64}$')
      ),
      ADD CONSTRAINT exposure_delivery_position CHECK (
        (phase IN ('applying', 'complete') AND recovery_position IS NOT NULL AND recovery_position > 0) OR
        (phase IN ('legacy', 'capturing', 'snapshot_required') AND recovery_position IS NULL)
      )
    """)
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM platform.exposure_delivery_batches WHERE phase <> 'legacy' OR operation_id IS NOT NULL) THEN
        RAISE EXCEPTION 'Finish exposure recovery journals before downgrading';
      END IF;
    END $$
    """)

    execute("""
    ALTER TABLE platform.exposure_delivery_batches
      DROP CONSTRAINT exposure_delivery_position,
      DROP CONSTRAINT exposure_delivery_identity,
      DROP CONSTRAINT exposure_delivery_phase,
      DROP COLUMN recovery_position,
      DROP COLUMN payload_hash,
      DROP COLUMN operation_id,
      DROP COLUMN phase
    """)
  end
end
