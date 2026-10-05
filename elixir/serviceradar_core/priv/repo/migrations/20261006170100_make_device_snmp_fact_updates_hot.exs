defmodule ServiceRadar.Repo.Migrations.MakeDeviceSnmpFactUpdatesHot do
  @moduledoc """
  Lets the per-poll upsert of `platform.device_snmp_facts` be a HOT update.

  Every SNMP poll rewrites each fact row in place, and every rewrite changes
  `collected_at`. A heap-only-tuple (HOT) update is possible only when no
  indexed column changes and the page has free space, so the
  `collected_at` index made every one of those updates write a new entry into
  every index on the table, and a full page made it move the row.

  The `collected_at` index has no reader: nothing queries facts by collection
  time. It is dropped (concurrently, so the fact writer keeps going), and the
  table's fillfactor is lowered so pages keep room for the in-place rewrite.
  The fillfactor applies to pages written from now on; existing pages gain the
  headroom as they are rewritten.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("DROP INDEX CONCURRENTLY IF EXISTS platform.device_snmp_facts_collected_at_index")
    execute("ALTER TABLE platform.device_snmp_facts SET (fillfactor = 80)")
  end

  def down do
    execute("ALTER TABLE platform.device_snmp_facts RESET (fillfactor)")

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS device_snmp_facts_collected_at_index
    ON platform.device_snmp_facts (collected_at)
    """)
  end
end
