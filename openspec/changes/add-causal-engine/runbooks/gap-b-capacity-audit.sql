-- Gap B (add-causal-engine) — capacity coverage audit.
--
-- Purpose: quantify how often `speed_bps`/`if_speed` (the inputs to the
-- canonical edge `capacity_bps = min_non_zero(src,dst)` derivation in
-- network_discovery/topology_graph.ex) are populated, and how many canonical
-- topology edges currently have capacity_bps = 0. After the Gap B
-- eligibility-contract edit lands AND a full canonical-topology refresh runs,
-- `incorrectly_telemetry_eligible_true` MUST be 0 (an edge with capacity_bps=0
-- must have telemetry_eligible=false so the saturation causaloid C6 skips it).
--
-- Run read-only against CNPG, e.g.:
--   docker compose exec cnpg psql -U serviceradar -d serviceradar -f - < gap-b-capacity-audit.sql
--   kubectl exec <cnpg-pod> -- psql -U postgres -d serviceradar -f - < gap-b-capacity-audit.sql
-- Run BEFORE the edit to size the gap, and AFTER (post topology refresh) to confirm 0 violations.

WITH interface_speed_audit AS (
  SELECT
    COUNT(*) AS total_interfaces,
    COUNT(*) FILTER (
      WHERE (speed_bps IS NULL OR speed_bps = 0)
        AND (if_speed IS NULL OR if_speed = 0)
    ) AS no_speed_count,
    COUNT(DISTINCT device_id) AS distinct_devices,
    COUNT(DISTINCT device_id) FILTER (
      WHERE (speed_bps IS NULL OR speed_bps = 0)
        AND (if_speed IS NULL OR if_speed = 0)
    ) AS devices_without_any_speed,
    MAX(timestamp) AS latest_discovery
  FROM platform.discovered_interfaces
),
capacity_zero_edges AS (
  SELECT
    COUNT(*) AS canonical_edges_with_zero_capacity,
    COUNT(*) FILTER (WHERE telemetry_eligible = true)  AS incorrectly_eligible_zero_cap,
    COUNT(*) FILTER (WHERE telemetry_eligible = false) AS correctly_ineligible_zero_cap
  FROM platform_graph."CANONICAL_TOPOLOGY"
  WHERE capacity_bps = 0
)
SELECT 'Interface Speed Audit' AS audit_section,
  jsonb_build_object(
    'total_interfaces', i.total_interfaces,
    'interfaces_missing_both_speeds', i.no_speed_count,
    'pct_missing_capacity', ROUND(100.0 * i.no_speed_count / NULLIF(i.total_interfaces, 0), 2),
    'distinct_devices_with_interfaces', i.distinct_devices,
    'devices_with_zero_capacity_only', i.devices_without_any_speed,
    'latest_discovery_timestamp', i.latest_discovery
  ) AS audit_data
FROM interface_speed_audit i
UNION ALL
SELECT 'Canonical Edge Capacity-Eligibility Gap',
  jsonb_build_object(
    'edges_with_zero_capacity_bps', c.canonical_edges_with_zero_capacity,
    'incorrectly_telemetry_eligible_true', c.incorrectly_eligible_zero_cap,
    'correctly_telemetry_eligible_false', c.correctly_ineligible_zero_cap,
    'gap_b_violation_count', c.incorrectly_eligible_zero_cap,
    'spec_requirement',
      'capacity_bps=0 (neither endpoint has speed_bps or if_speed) => telemetry_eligible MUST be false'
  )
FROM capacity_zero_edges c;
