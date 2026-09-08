defmodule ServiceRadar.Repo.Migrations.CreateFlowProcessAttributionCurrent do
  @moduledoc """
  Creates the current-state staging table for netprobe flow/process attribution.

  The original flow_process_attributions table is append-only. This table keeps
  one current row per attribution tuple/process identity so repeated socket
  observations refresh correlation state without writing duplicate hot-path rows.
  """
  use Ecto.Migration

  @legacy_table "flow_process_attributions"
  @table "flow_process_attribution_current"

  def up do
    schema = prefix() || "platform"

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.#{@table} (
      observed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
      inserted_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
      partition        TEXT        NOT NULL DEFAULT 'default',
      attribution_key  TEXT        NOT NULL,
      agent_id         TEXT,
      proto            INTEGER     NOT NULL,
      local_ip         TEXT        NOT NULL,
      local_port       INTEGER     NOT NULL DEFAULT 0,
      remote_ip        TEXT        NOT NULL,
      remote_port      INTEGER     NOT NULL DEFAULT 0,
      pid              INTEGER,
      comm             TEXT,
      cmdline          TEXT,
      uid              INTEGER,
      container_id     TEXT,
      workload_identity JSONB,
      CONSTRAINT flow_process_attribution_current_unique
        UNIQUE (partition, attribution_key)
    )
    """)

    execute("""
    INSERT INTO #{schema}.#{@table} (
      observed_at,
      inserted_at,
      updated_at,
      partition,
      attribution_key,
      agent_id,
      proto,
      local_ip,
      local_port,
      remote_ip,
      remote_port,
      pid,
      comm,
      cmdline,
      uid,
      container_id,
      workload_identity
    )
    SELECT DISTINCT ON (partition, attribution_key)
      observed_at,
      now(),
      now(),
      partition,
      attribution_key,
      agent_id,
      proto,
      local_ip,
      local_port,
      remote_ip,
      remote_port,
      pid,
      comm,
      cmdline,
      uid,
      container_id,
      workload_identity
    FROM (
      SELECT
        observed_at,
        partition,
        md5(concat_ws(chr(31),
          coalesce(agent_id, ''),
          proto::text,
          local_ip,
          local_port::text,
          remote_ip,
          remote_port::text,
          coalesce(pid::text, ''),
          coalesce(uid::text, ''),
          coalesce(container_id, ''),
          coalesce(comm, '')
        )) AS attribution_key,
        agent_id,
        proto,
        local_ip,
        local_port,
        remote_ip,
        remote_port,
        pid,
        comm,
        cmdline,
        uid,
        container_id,
        workload_identity
      FROM #{schema}.#{@legacy_table}
      WHERE observed_at >= now() - interval '1 hour'
    ) recent
    ORDER BY partition, attribution_key, observed_at DESC
    ON CONFLICT (partition, attribution_key) DO NOTHING
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_flow_process_attr_current_observed_at
      ON #{schema}.#{@table} (observed_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_flow_process_attr_current_exact_ports
      ON #{schema}.#{@table}
        (partition, proto, local_ip, remote_ip, local_port, remote_port, observed_at DESC)
      WHERE proto NOT IN (1, 58)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_flow_process_attr_current_exact_no_ports
      ON #{schema}.#{@table}
        (partition, proto, local_ip, remote_ip, observed_at DESC)
      WHERE proto IN (1, 58)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_flow_process_attr_current_udp_service
      ON #{schema}.#{@table}
        (partition, proto, local_ip, remote_ip, remote_port, observed_at DESC)
      WHERE proto = 17 AND remote_port > 0
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_flow_process_attr_current_remote_ports
      ON #{schema}.#{@table}
        (partition, proto, remote_ip, remote_port, observed_at DESC, agent_id, local_ip)
      WHERE proto NOT IN (1, 58)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_flow_process_attr_current_remote_no_ports
      ON #{schema}.#{@table}
        (partition, proto, remote_ip, observed_at DESC, agent_id, local_ip)
      WHERE proto IN (1, 58)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_flow_process_attr_current_service_wildcard
      ON #{schema}.#{@table} (partition, proto, local_ip, local_port, observed_at DESC)
      WHERE remote_port = 0
    """)
  end

  def down do
    schema = prefix() || "platform"
    execute("DROP TABLE IF EXISTS #{schema}.#{@table}")
  end
end
