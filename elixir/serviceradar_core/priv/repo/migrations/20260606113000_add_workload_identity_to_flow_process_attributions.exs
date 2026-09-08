defmodule ServiceRadar.Repo.Migrations.AddWorkloadIdentityToFlowProcessAttributions do
  @moduledoc false
  use Ecto.Migration

  @schema "platform"
  @table "flow_process_attributions"

  def up do
    execute("""
    ALTER TABLE #{@schema}.#{@table}
      ADD COLUMN IF NOT EXISTS workload_identity JSONB
    """)
  end

  def down do
    execute("""
    ALTER TABLE #{@schema}.#{@table}
      DROP COLUMN IF EXISTS workload_identity
    """)
  end
end
