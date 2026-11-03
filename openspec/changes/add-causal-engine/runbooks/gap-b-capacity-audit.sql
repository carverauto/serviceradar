-- Gap B (add-causal-engine) — capacity coverage audit.
--
-- Purpose: quantify how often `speed_bps`/`if_speed` (the inputs to the
-- canonical edge `capacity_bps = min_non_zero(src,dst)` derivation in
-- network_discovery/topology_graph.ex) are populated, and how many canonical
-- topology edges currently have capacity_bps = 0. After the Gap B
-- eligibility-contract edit lands AND a full canonical-topology refresh runs,
-- `incorrectly_eligible` MUST be 0 (an edge with capacity_bps=0 must have
-- telemetry_eligible=false so the saturation causaloid C6 skips it).
--
-- The audit has two halves, because the inputs and the edges live in
-- different stores:
--
-- 1. Interface speed coverage (CNPG): the SQL below. Run it read-only, e.g.:
--      docker compose exec cnpg psql -U serviceradar -d serviceradar -f - < gap-b-capacity-audit.sql
--      kubectl exec <cnpg-pod> -- psql -U postgres -d serviceradar -f - < gap-b-capacity-audit.sql
--
-- 2. Canonical edge capacity-eligibility gap (Dgraph): canonical edges are
--    Dgraph `TopologyEdge` nodes with topo.kind = "CANONICAL_TOPOLOGY". Run
--    this read-only DQL through SRQL `in:graph` (query bar, query API or MCP;
--    needs DGRAPH_URL). An absent topo.capacity_bps counts as 0:
--
--      in:graph dql:'{
--        zero_capacity(func: eq(topo.kind, "CANONICAL_TOPOLOGY"))
--          @filter(eq(topo.capacity_bps, 0) OR NOT has(topo.capacity_bps)) {
--          count(uid)
--        }
--        incorrectly_eligible(func: eq(topo.kind, "CANONICAL_TOPOLOGY"))
--          @filter((eq(topo.capacity_bps, 0) OR NOT has(topo.capacity_bps))
--                  AND eq(topo.telemetry_eligible, true)) {
--          count(uid)
--        }
--        correctly_ineligible(func: eq(topo.kind, "CANONICAL_TOPOLOGY"))
--          @filter((eq(topo.capacity_bps, 0) OR NOT has(topo.capacity_bps))
--                  AND NOT eq(topo.telemetry_eligible, true)) {
--          count(uid)
--        }
--        violations(func: eq(topo.kind, "CANONICAL_TOPOLOGY"), first: 50)
--          @filter((eq(topo.capacity_bps, 0) OR NOT has(topo.capacity_bps))
--                  AND eq(topo.telemetry_eligible, true)) {
--          topo.link_key
--          topo.capacity_bps
--          topo.if_index_ab
--          topo.if_index_ba
--          topo.if_name_ab
--          topo.if_name_ba
--        }
--      }'
--
--    `incorrectly_eligible` is the Gap B violation count; `violations` lists
--    a sample of offending edges with the interface indexes to check against
--    platform.discovered_interfaces.
--
-- Run both halves BEFORE the edit to size the gap, and AFTER (post topology
-- refresh) to confirm 0 violations.

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
FROM interface_speed_audit i;
