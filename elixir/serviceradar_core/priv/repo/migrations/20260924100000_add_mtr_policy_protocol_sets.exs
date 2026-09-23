defmodule ServiceRadar.Repo.Migrations.AddMtrPolicyProtocolSets do
  @moduledoc """
  Lets an MTR policy probe with a set of protocols instead of one.

  `baseline_protocols` is backfilled from `baseline_protocol`, which stays in
  place (and in step with the first protocol of the set) so a rollback keeps
  working; it is dropped in a later migration. Bulk job target rows gain the
  protocol, because a multi-protocol job traces each target once per protocol.
  """
  use Ecto.Migration

  def up do
    schema = prefix() || "platform"

    execute("""
    ALTER TABLE #{schema}.mtr_policies
      ADD COLUMN IF NOT EXISTS baseline_protocols TEXT[] NOT NULL DEFAULT ARRAY['icmp']::text[],
      ADD COLUMN IF NOT EXISTS tcp_port INTEGER NOT NULL DEFAULT 443
    """)

    execute("""
    UPDATE #{schema}.mtr_policies
       SET baseline_protocols = ARRAY[lower(baseline_protocol)]::text[]
     WHERE lower(baseline_protocol) IN ('icmp', 'udp', 'tcp')
    """)

    execute("""
    ALTER TABLE #{schema}.mtr_bulk_job_targets
      ADD COLUMN IF NOT EXISTS protocol TEXT NOT NULL DEFAULT 'icmp'
    """)

    # Rows written before this migration belong to single-protocol jobs; give
    # them the protocol their job actually ran.
    execute("""
    UPDATE #{schema}.mtr_bulk_job_targets t
       SET protocol = lower(c.payload ->> 'protocol')
      FROM #{schema}.agent_commands c
     WHERE c.command_id = t.command_id
       AND lower(c.payload ->> 'protocol') IN ('udp', 'tcp')
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS mtr_bulk_job_targets_command_target_protocol_index
      ON #{schema}.mtr_bulk_job_targets (command_id, target, protocol)
    """)

    execute("DROP INDEX IF EXISTS #{schema}.mtr_bulk_job_targets_command_id_target_index")
  end

  def down do
    schema = prefix() || "platform"

    # Collapse a multi-protocol job back to one row per target before the
    # narrower unique index returns.
    execute("""
    DELETE FROM #{schema}.mtr_bulk_job_targets t
     USING #{schema}.mtr_bulk_job_targets keep
     WHERE t.command_id = keep.command_id
       AND t.target = keep.target
       AND t.protocol > keep.protocol
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS mtr_bulk_job_targets_command_id_target_index
      ON #{schema}.mtr_bulk_job_targets (command_id, target)
    """)

    execute(
      "DROP INDEX IF EXISTS #{schema}.mtr_bulk_job_targets_command_target_protocol_index"
    )

    execute("ALTER TABLE #{schema}.mtr_bulk_job_targets DROP COLUMN IF EXISTS protocol")

    execute("""
    ALTER TABLE #{schema}.mtr_policies
      DROP COLUMN IF EXISTS tcp_port,
      DROP COLUMN IF EXISTS baseline_protocols
    """)
  end
end
