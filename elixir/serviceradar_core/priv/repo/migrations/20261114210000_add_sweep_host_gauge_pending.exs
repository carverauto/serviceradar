defmodule ServiceRadar.Repo.Migrations.AddSweepHostGaugePending do
  @moduledoc """
  Adds `platform.sweep_host_gauge_pending` (OpenSpec fix-device-availability-timeline,
  design Decision 1): one marker per projected leased sweep batch whose derived per-host
  gauges have not yet been published.

  The EdgeRecord projection inserts the marker in its ledger transaction, the committed
  publish deletes it, and `ServiceRadar.Edge.SweepHostGaugeSweeper` republishes any marker
  older than its grace period. `batch` is the batch's protobuf, zlib-compressed, so a
  republish rebuilds exactly the same messages and points. The `inserted_at` index serves
  the sweeper's oldest-first, bounded scan.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS platform.sweep_host_gauge_pending (
      event_id uuid PRIMARY KEY,
      agent_id text NOT NULL,
      gateway_id text,
      partition text,
      batch bytea NOT NULL,
      inserted_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS sweep_host_gauge_pending_inserted_at_idx
      ON platform.sweep_host_gauge_pending (inserted_at)
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS platform.sweep_host_gauge_pending")
  end
end
