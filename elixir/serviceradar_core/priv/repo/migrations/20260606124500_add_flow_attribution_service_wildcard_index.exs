defmodule ServiceRadar.Repo.Migrations.AddFlowAttributionServiceWildcardIndex do
  @moduledoc false
  use Ecto.Migration

  @schema "platform"
  @table "flow_process_attributions"

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_flow_process_attributions_service_wildcard
      ON #{@schema}.#{@table} (partition, proto, local_ip, local_port, observed_at DESC)
      WHERE remote_port = 0
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{@schema}.idx_flow_process_attributions_service_wildcard")
  end
end
