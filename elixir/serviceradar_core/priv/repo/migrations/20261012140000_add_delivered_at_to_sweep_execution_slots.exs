defmodule ServiceRadar.Repo.Migrations.AddDeliveredAtToSweepExecutionSlots do
  @moduledoc """
  When a lease push last carried each pre-minted execution to its agent.

  `delivered_at` is null until a push carries the slot. The delivery cursor only
  names a position in the schedule, so a slot minted behind it — the re-minted
  slots of a restored horizon, a mint retried after an error — would never be
  sent by a tail push, which starts at the cursor. An unrun slot with no
  `delivered_at` behind the cursor is what makes the next push a full window
  instead. Slots delivered before this column existed read as never carried, so
  each assignment takes one full push after the upgrade and is marked from
  there.
  """
  use Ecto.Migration

  @table "sweep_execution_slots"

  def up do
    schema = prefix() || "platform"

    execute("""
    ALTER TABLE #{schema}.#{@table}
      ADD COLUMN IF NOT EXISTS delivered_at TIMESTAMPTZ
    """)
  end

  def down do
    schema = prefix() || "platform"

    execute("""
    ALTER TABLE #{schema}.#{@table}
      DROP COLUMN IF EXISTS delivered_at
    """)
  end
end
