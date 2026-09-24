defmodule ServiceRadar.Repo.Migrations.AddMtrTraceDepthFields do
  @moduledoc """
  Separates an MTR trace's probed depth from the deepest hop that answered, and
  records the TCP destination port and per-hop ICMP Destination Unreachable
  code. All columns are nullable so traces from older agents stay valid.
  """
  use Ecto.Migration

  def up do
    schema = prefix() || "platform"

    execute("""
    ALTER TABLE #{schema}.mtr_traces
      ADD COLUMN IF NOT EXISTS probed_hops INTEGER,
      ADD COLUMN IF NOT EXISTS last_responding_hop INTEGER,
      ADD COLUMN IF NOT EXISTS tcp_port INTEGER
    """)

    execute("""
    ALTER TABLE #{schema}.mtr_hops
      ADD COLUMN IF NOT EXISTS unreachable_code INTEGER
    """)
  end

  def down do
    schema = prefix() || "platform"

    execute("""
    ALTER TABLE #{schema}.mtr_hops
      DROP COLUMN IF EXISTS unreachable_code
    """)

    execute("""
    ALTER TABLE #{schema}.mtr_traces
      DROP COLUMN IF EXISTS tcp_port,
      DROP COLUMN IF EXISTS last_responding_hop,
      DROP COLUMN IF EXISTS probed_hops
    """)
  end
end
