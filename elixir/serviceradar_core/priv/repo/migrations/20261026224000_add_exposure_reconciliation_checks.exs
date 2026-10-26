defmodule ServiceRadar.Repo.Migrations.AddExposureReconciliationChecks do
  @moduledoc "Bounded comparison/repair metadata, never an exposure query projection."
  use Ecto.Migration

  def up do
    create table(:exposure_reconciliation_checks, primary_key: false, prefix: "platform") do
      # Zero is the fleet enumeration checkpoint. Real device ordinals start at one.
      add :device_ord, :bigint, primary_key: true
      add :status, :text, null: false, default: "deferred"
      add :control, :map, null: false, default: %{}
      add :checked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:exposure_reconciliation_checks, :exposure_reconciliation_ordinal,
      prefix: "platform", check: "device_ord BETWEEN 0 AND 4294967295")
    create constraint(:exposure_reconciliation_checks, :exposure_reconciliation_status,
      prefix: "platform", check: "status IN ('scanning', 'matched', 'mismatch', 'deferred')")

    create index(:exposure_reconciliation_checks, [:status, :device_ord], prefix: "platform")
  end
  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM platform.exposure_reconciliation_checks
        WHERE status <> 'matched' OR jsonb_array_length(COALESCE(control->'repairs', '[]'::jsonb)) > 0) THEN
        RAISE EXCEPTION 'Settle exposure reconciliation before downgrading';
      END IF;
    END $$
    """)
    drop table(:exposure_reconciliation_checks, prefix: "platform")
  end

end
