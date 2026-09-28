defmodule ServiceRadar.Repo.Migrations.DropStarrocksPendingLoads do
  @moduledoc """
  Drops the warehouse-load outbox of the interface threshold worker.

  That worker was its only producer; it now publishes its events through
  JetStream, where EventWriter loads the warehouse and a failed load is
  redelivered by the broker. The table held warehouse copies only (CNPG kept
  the authoritative rows), and was written only while `events` was cut over to
  the warehouse. The migration refuses to drop a table that still holds rows,
  so no pending copy is discarded unseen.
  """
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF to_regclass('platform.starrocks_pending_loads') IS NOT NULL
         AND EXISTS (SELECT 1 FROM platform.starrocks_pending_loads) THEN
        RAISE EXCEPTION 'platform.starrocks_pending_loads still holds rows; replay or clear them before upgrading';
      END IF;
    END
    $$;
    """)

    execute("DROP TABLE IF EXISTS platform.starrocks_pending_loads")
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "platform.starrocks_pending_loads is not restored; recreate it from 20260920120000 if needed"
  end
end
