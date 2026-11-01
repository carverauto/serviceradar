defmodule ServiceRadar.Repo.Migrations.AllowMissedSweepExecutionSlots do
  @moduledoc """
  A scheduled sweep slot can close without a committed batch.

  `missed_offline` is a slot whose assignment was still active and whose lease
  still had a later scheduled slot. `missed_exhausted` is a closed slot whose
  lease was not extended, or whose assignment was no longer active. The mark
  looks up committed batches by execution id, so that column needs an index
  the primary key cannot serve.
  """

  use Ecto.Migration

  @slots "sweep_execution_slots"
  @batches "edge_sweep_batch_slots"

  def up do
    schema = prefix() || "platform"

    execute("""
    ALTER TABLE #{schema}.#{@slots}
      DROP CONSTRAINT IF EXISTS sweep_execution_slots_state_chk
    """)

    execute("""
    ALTER TABLE #{schema}.#{@slots}
      ADD CONSTRAINT sweep_execution_slots_state_chk
      CHECK (state IN ('scheduled', 'dropped', 'missed_offline', 'missed_exhausted'))
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS sweep_execution_slots_collection_due_idx
      ON #{schema}.#{@slots} (collection_expires)
      WHERE state = 'scheduled'
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS edge_sweep_batch_slots_execution_id_idx
      ON #{schema}.#{@batches} (execution_id)
    """)
  end

  def down do
    schema = prefix() || "platform"

    execute("""
    UPDATE #{schema}.#{@slots}
      SET state = 'scheduled'
      WHERE state IN ('missed_offline', 'missed_exhausted')
    """)

    execute("""
    ALTER TABLE #{schema}.#{@slots}
      DROP CONSTRAINT IF EXISTS sweep_execution_slots_state_chk
    """)

    execute("""
    ALTER TABLE #{schema}.#{@slots}
      ADD CONSTRAINT sweep_execution_slots_state_chk
      CHECK (state IN ('scheduled', 'dropped'))
    """)

    execute("DROP INDEX IF EXISTS #{schema}.sweep_execution_slots_collection_due_idx")
    execute("DROP INDEX IF EXISTS #{schema}.edge_sweep_batch_slots_execution_id_idx")
  end
end
