defmodule ServiceRadar.Repo.Migrations.AddExposureSnapshotScopes do
  @moduledoc """
  Pending scopes for the single exposure snapshot publisher.

  Replaces the per-device `ExposureSnapshotWorker` Oban fan-out: demand paths
  write one row per scope here and ensure the singleton publisher job, which
  drains due rows oldest-first and exits when the table is empty. One row per
  scope (`scope_ord`, NULL for the fleet-wide scope), updated in place;
  completed rows persist as the publish ledger. The backfill converts
  incomplete publisher Oban rows into pending scope rows and deletes them, so
  no demand is lost and no old publisher job can run afterward.
  """

  use Ecto.Migration

  @table "exposure_snapshot_scopes"
  @worker "ServiceRadar.Inventory.ExposureSnapshotWorker"

  def up do
    schema = prefix() || "platform"

    execute("""
    CREATE TABLE #{schema}.#{@table} (
      id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      scope_ord BIGINT NULL,
      status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'publishing', 'preparing', 'failed', 'dead', 'complete')),
      generation_id BIGINT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      not_before TIMESTAMPTZ NOT NULL DEFAULT now(),
      error TEXT NULL,
      claimed_by BIGINT NULL,
      lease_expires_at TIMESTAMPTZ NULL,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX #{@table}_scope_ord_uidx ON #{schema}.#{@table} (scope_ord)
    NULLS NOT DISTINCT
    """)

    execute("""
    CREATE INDEX #{@table}_claim_idx ON #{schema}.#{@table} (status, not_before, id)
    """)

    execute("""
    INSERT INTO #{schema}.#{@table} (scope_ord, status)
    SELECT DISTINCT (args->>'device_ord')::bigint, 'pending'
    FROM #{schema}.oban_jobs
    WHERE worker = '#{@worker}' AND state IN ('available', 'scheduled', 'retryable')
    ON CONFLICT DO NOTHING
    """)

    execute("""
    DELETE FROM #{schema}.oban_jobs
    WHERE worker = '#{@worker}' AND state IN ('available', 'scheduled', 'retryable')
    """)
  end

  def down do
    schema = prefix() || "platform"

    execute("DROP TABLE #{schema}.#{@table}")
  end
end
