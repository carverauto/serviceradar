defmodule ServiceRadar.Repo.Migrations.AddAttributedFlowActivityIndexes do
  @moduledoc """
  Adds narrow lookup indexes for attributed-flow OCSF rows.

  Attributed flow pages filter platform.ocsf_network_activity by the JSON event
  type before sorting or aggregating recent rows. A partial index keeps those
  queries from scanning generic NetFlow rows in the same hypertable chunks.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @schema "platform"
  @table "ocsf_network_activity"

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_attributed_flow_time
    ON #{@schema}.#{@table} (time DESC)
    WHERE (ocsf_payload ->> 'event_type') = 'attributed_flow'
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_attributed_flow_status_time
    ON #{@schema}.#{@table} (
      (CASE
        WHEN (ocsf_payload -> 'attribution' ->> 'pid') IS NULL THEN 'unmatched'
        ELSE 'attributed'
      END),
      time DESC
    )
    WHERE (ocsf_payload ->> 'event_type') = 'attributed_flow'
    """)
  end

  def down do
    execute(
      "DROP INDEX IF EXISTS #{@schema}.idx_ocsf_network_activity_attributed_flow_status_time"
    )

    execute("DROP INDEX IF EXISTS #{@schema}.idx_ocsf_network_activity_attributed_flow_time")
  end
end
