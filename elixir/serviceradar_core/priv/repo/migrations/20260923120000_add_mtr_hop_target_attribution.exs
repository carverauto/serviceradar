defmodule ServiceRadar.Repo.Migrations.AddMtrHopTargetAttribution do
  @moduledoc """
  Adds `target_ip` and `device_id` to `platform.mtr_hops` so hop-level metrics can
  be scoped to the devices they were measured against.

  ## Why the columns are needed at all

  Hop rows carried only `trace_id`. Every piece of device attribution --
  `target`, `target_ip`, `device_id`, `agent_id` -- lived on `mtr_traces`. SRQL
  cannot join entities, so hop-level loss and latency could not be restricted to a
  chosen set of devices by any query: the metrics and the identity sat on opposite
  sides of a join the query language cannot cross. Denormalising the target onto
  the hop row is what makes a device-scoped hop aggregate expressible.

  ## `target_ip` is the reliable key, `device_id` is not

  Both columns are added, but `target_ip` is the one to filter on. On the
  bulk-scheduled MTR path a trace's `device_id` holds the originating command's
  identifier rather than a device uid, so grouping hops by `device_id` yields one
  row per bulk command -- which looks like data and answers nothing. The existing
  device-details MTR tab already matches on `target_ip` for this reason.
  `device_id` is carried because it IS a true device uid on the single-run path,
  where it is the more precise key.

  ## Why there is no backfill in this migration

  `mtr_hops` is a TimescaleDB hypertable. A single `UPDATE ... FROM mtr_traces`
  across every chunk is the shape that exhausts a compute node's memory and gets it
  OOM-killed, and a long-running statement inside a migration is also what
  Postgres `statement_timeout` cancels -- leaving the migration half-applied and the
  advisory lock contended.

  So this migration is DDL only, which is fast and safe. Existing rows keep NULL
  attribution until the separate, resumable, chunk-batched backfill runs. A NULL
  `target_ip` means "not yet backfilled", which is why the columns are nullable and
  why the indexes below are partial: they stay small until the backfill populates
  them, and they never index the NULL majority during the transition.

  Hand-written, matching the existing pattern in this directory (`mix ash.codegen`
  is blocked on gitignored resource snapshots). Idempotent via `IF NOT EXISTS`, so
  it is safe against a partially-applied database.
  """
  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("""
    ALTER TABLE #{@prefix}.mtr_hops
      ADD COLUMN IF NOT EXISTS target_ip text
    """)

    execute("""
    ALTER TABLE #{@prefix}.mtr_hops
      ADD COLUMN IF NOT EXISTS device_id text
    """)

    # Partial, and ordered to match how the analytics queries read: filter on the
    # attribution key, restrict a time range, aggregate. Mirrors the shape of the
    # existing idx_mtr_hops_addr / idx_mtr_hops_asn partial indexes.
    execute("""
    CREATE INDEX IF NOT EXISTS idx_mtr_hops_target_ip
      ON #{@prefix}.mtr_hops (target_ip, "time" DESC)
      WHERE target_ip IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_mtr_hops_device_id
      ON #{@prefix}.mtr_hops (device_id, "time" DESC)
      WHERE device_id IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{@prefix}.idx_mtr_hops_device_id")
    execute("DROP INDEX IF EXISTS #{@prefix}.idx_mtr_hops_target_ip")

    execute("ALTER TABLE #{@prefix}.mtr_hops DROP COLUMN IF EXISTS device_id")
    execute("ALTER TABLE #{@prefix}.mtr_hops DROP COLUMN IF EXISTS target_ip")
  end
end
