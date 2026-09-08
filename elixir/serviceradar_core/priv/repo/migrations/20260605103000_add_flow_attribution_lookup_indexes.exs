defmodule ServiceRadar.Repo.Migrations.AddFlowAttributionLookupIndexes do
  @moduledoc """
  Adds endpoint-specific lookup indexes for flow attribution correlation.

  The correlator probes from each recent NetFlow row into matching process
  attributions. These indexes keep that lookup bounded by tuple fields and time
  instead of scanning all recent attributions for the same partition/protocol.
  """
  use Ecto.Migration

  @table "flow_process_attributions"

  def up do
    schema = prefix() || "platform"

    execute("""
    CREATE INDEX IF NOT EXISTS idx_flow_process_attributions_exact_ports
      ON #{schema}.#{@table}
        (partition, proto, local_ip, remote_ip, local_port, remote_port, observed_at DESC)
      WHERE proto NOT IN (1, 58)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_flow_process_attributions_exact_no_ports
      ON #{schema}.#{@table}
        (partition, proto, local_ip, remote_ip, observed_at DESC)
      WHERE proto IN (1, 58)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_flow_process_attributions_udp_service
      ON #{schema}.#{@table}
        (partition, proto, local_ip, remote_ip, remote_port, observed_at DESC)
      WHERE proto = 17 AND remote_port > 0
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_flow_process_attributions_remote_ports
      ON #{schema}.#{@table}
        (partition, proto, remote_ip, remote_port, observed_at DESC, agent_id, local_ip)
      WHERE proto NOT IN (1, 58)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_flow_process_attributions_remote_no_ports
      ON #{schema}.#{@table}
        (partition, proto, remote_ip, observed_at DESC, agent_id, local_ip)
      WHERE proto IN (1, 58)
    """)
  end

  def down do
    schema = prefix() || "platform"

    execute("DROP INDEX IF EXISTS #{schema}.idx_flow_process_attributions_remote_no_ports")
    execute("DROP INDEX IF EXISTS #{schema}.idx_flow_process_attributions_remote_ports")
    execute("DROP INDEX IF EXISTS #{schema}.idx_flow_process_attributions_udp_service")
    execute("DROP INDEX IF EXISTS #{schema}.idx_flow_process_attributions_exact_no_ports")
    execute("DROP INDEX IF EXISTS #{schema}.idx_flow_process_attributions_exact_ports")
  end
end
