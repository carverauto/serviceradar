defmodule ServiceRadar.Repo.Migrations.OptimizeOtxRetrohuntAndResetCursor do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_time_src_ip
    ON platform.ocsf_network_activity ("time" DESC, src_endpoint_ip)
    WHERE src_endpoint_ip IS NOT NULL AND src_endpoint_ip <> ''
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_time_dst_ip
    ON platform.ocsf_network_activity ("time" DESC, dst_endpoint_ip)
    WHERE dst_endpoint_ip IS NOT NULL AND dst_endpoint_ip <> ''
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_threat_intel_indicators_source_type_seen
    ON platform.threat_intel_indicators (source, indicator_type, last_seen_at DESC)
    WHERE indicator_type IN ('cidr', 'ipv4', 'ipv6')
    """)

    execute("""
    UPDATE platform.plugin_assignments AS assignment
    SET
      params =
        jsonb_set(
          jsonb_set(
            jsonb_set(
              jsonb_set(
                assignment.params - 'cursor_next',
                '{types}',
                to_jsonb('IPv4,IPv6,CIDR'::text),
                true
              ),
              '{limit}',
              to_jsonb(1000),
              true
            ),
            '{page}',
            to_jsonb(1),
            true
          ),
          '{cursor_complete}',
          'false'::jsonb,
          true
        )
        || jsonb_build_object('run_nonce', floor(extract(epoch from now()))::bigint),
      updated_at = now()
    FROM platform.plugin_packages AS package
    WHERE assignment.plugin_package_id = package.id
      AND package.plugin_id = 'alienvault-otx-threat-intel'
      AND (
        assignment.params->>'cursor_next' LIKE '%limit=100%'
        OR COALESCE((assignment.params->>'limit')::int, 0) < 1000
      )
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.idx_threat_intel_indicators_source_type_seen")
    execute("DROP INDEX IF EXISTS platform.idx_ocsf_network_activity_time_dst_ip")
    execute("DROP INDEX IF EXISTS platform.idx_ocsf_network_activity_time_src_ip")
  end
end
