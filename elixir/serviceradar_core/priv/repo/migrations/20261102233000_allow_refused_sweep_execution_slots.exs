defmodule ServiceRadar.Repo.Migrations.AllowRefusedSweepExecutionSlots do
  @moduledoc """
  An agent can refuse to run a leased sweep slot (`SweepLeaseSlotRefusal`).

  `refused` is terminal: the miss mark only moves `scheduled` slots, and a
  projecting batch reopens only missed ones. The refusal keeps its typed reason,
  the capability markers the agent named and its bounded detail text.
  """

  use Ecto.Migration

  @slots "sweep_execution_slots"

  def up do
    schema = prefix() || "platform"

    execute("""
    ALTER TABLE #{schema}.#{@slots}
      DROP CONSTRAINT IF EXISTS sweep_execution_slots_state_chk
    """)

    execute("""
    ALTER TABLE #{schema}.#{@slots}
      ADD CONSTRAINT sweep_execution_slots_state_chk
      CHECK (state IN ('scheduled', 'dropped', 'missed_offline', 'missed_exhausted', 'refused'))
    """)

    execute("""
    ALTER TABLE #{schema}.#{@slots}
      ADD COLUMN IF NOT EXISTS refusal_reason TEXT,
      ADD COLUMN IF NOT EXISTS refusal_unavailable_capabilities TEXT[],
      ADD COLUMN IF NOT EXISTS refusal_detail TEXT
    """)
  end

  def down do
    schema = prefix() || "platform"

    execute("""
    UPDATE #{schema}.#{@slots}
      SET state = 'missed_exhausted'
      WHERE state = 'refused'
    """)

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
    ALTER TABLE #{schema}.#{@slots}
      DROP COLUMN IF EXISTS refusal_reason,
      DROP COLUMN IF EXISTS refusal_unavailable_capabilities,
      DROP COLUMN IF EXISTS refusal_detail
    """)
  end
end
