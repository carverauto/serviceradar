#!/usr/bin/env bash

# Operator-safe topology reset + rebuild validation workflow.
#
# Default mode is read-only. Destructive cleanup requires:
#   --mode cleanup --apply --yes
#
# Examples:
#   ./scripts/topology-reset-rebuild.sh --mode status --lookback-minutes 60
#   ./scripts/topology-reset-rebuild.sh --mode cleanup --apply --yes
#   ./scripts/topology-reset-rebuild.sh --mode gates --lookback-minutes 30 \
#     --min-raw-links 20 --min-direct-edges 2 --max-inferred-ratio 0.95 \
#     --max-unresolved-endpoints 200 --max-edge-churn-ratio 0.40

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PSQL_BIN_DEFAULT="$ROOT_DIR/scripts/psql-cnpg.sh"
PSQL_BIN="${PSQL_BIN:-$PSQL_BIN_DEFAULT}"

MODE="status"
LOOKBACK_MINUTES="${LOOKBACK_MINUTES:-60}"
MIN_RAW_LINKS="${MIN_RAW_LINKS:-1}"
MIN_DIRECT_EDGES="${MIN_DIRECT_EDGES:-1}"
MAX_INFERRED_RATIO="${MAX_INFERRED_RATIO:-0.95}"
MAX_UNRESOLVED_ENDPOINTS="${MAX_UNRESOLVED_ENDPOINTS:-500}"
MAX_EDGE_CHURN_RATIO="${MAX_EDGE_CHURN_RATIO:-0.40}"
APPLY=false
YES=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --mode MODE                    status | cleanup | gates (default: status)
  --lookback-minutes N           Lookback window for status/gates (default: ${LOOKBACK_MINUTES})
  --min-raw-links N              Gate: minimum mapper_topology_links in lookback (default: ${MIN_RAW_LINKS})
  --min-direct-edges N           Gate: minimum CONNECTS_TO edges in AGE (default: ${MIN_DIRECT_EDGES})
  --max-inferred-ratio FLOAT     Gate: max inferred/direct+inferred ratio (default: ${MAX_INFERRED_RATIO})
  --max-unresolved-endpoints N   Gate: max unresolved endpoint IDs (default: ${MAX_UNRESOLVED_ENDPOINTS})
  --max-edge-churn-ratio FLOAT   Gate: max unique-pair churn ratio window-over-window (default: ${MAX_EDGE_CHURN_RATIO})
  --apply                        Execute destructive cleanup (only with --mode cleanup)
  --yes                          Confirm destructive cleanup (only with --mode cleanup)
  -h, --help                     Show this help

Env:
  PSQL_BIN                       psql wrapper command (default: scripts/psql-cnpg.sh)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    --lookback-minutes)
      LOOKBACK_MINUTES="$2"
      shift 2
      ;;
    --min-raw-links)
      MIN_RAW_LINKS="$2"
      shift 2
      ;;
    --min-direct-edges)
      MIN_DIRECT_EDGES="$2"
      shift 2
      ;;
    --max-inferred-ratio)
      MAX_INFERRED_RATIO="$2"
      shift 2
      ;;
    --max-unresolved-endpoints)
      MAX_UNRESOLVED_ENDPOINTS="$2"
      shift 2
      ;;
    --max-edge-churn-ratio)
      MAX_EDGE_CHURN_RATIO="$2"
      shift 2
      ;;
    --apply)
      APPLY=true
      shift
      ;;
    --yes)
      YES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! -x "$PSQL_BIN" && "$PSQL_BIN" == *"/"* ]]; then
  echo "psql wrapper not executable: $PSQL_BIN" >&2
  exit 1
fi

for n in "$LOOKBACK_MINUTES" "$MIN_RAW_LINKS" "$MIN_DIRECT_EDGES" "$MAX_UNRESOLVED_ENDPOINTS"; do
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "Expected integer, got: $n" >&2
    exit 1
  fi
done

if ! [[ "$MAX_INFERRED_RATIO" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "Expected float for --max-inferred-ratio, got: $MAX_INFERRED_RATIO" >&2
  exit 1
fi

if ! [[ "$MAX_EDGE_CHURN_RATIO" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "Expected float for --max-edge-churn-ratio, got: $MAX_EDGE_CHURN_RATIO" >&2
  exit 1
fi

run_sql() {
  "$PSQL_BIN" -X -v ON_ERROR_STOP=1 -Atqc "$1"
}

sql_metrics() {
  cat <<SQL
WITH lookback AS (
  SELECT now() - make_interval(mins => ${LOOKBACK_MINUTES}::int) AS cutoff
),
raw AS (
  SELECT COUNT(*)::bigint AS raw_links
  FROM platform.mapper_topology_links l
  CROSS JOIN lookback
  WHERE l.timestamp >= lookback.cutoff
),
pairs AS (
  SELECT COUNT(*)::bigint AS unique_pairs
  FROM (
    SELECT DISTINCT
      LEAST(
        COALESCE(NULLIF(l.local_device_id, ''), NULLIF(l.local_device_ip, '')),
        COALESCE(NULLIF(l.neighbor_device_id, ''), NULLIF(l.neighbor_mgmt_addr, ''))
      ) AS a,
      GREATEST(
        COALESCE(NULLIF(l.local_device_id, ''), NULLIF(l.local_device_ip, '')),
        COALESCE(NULLIF(l.neighbor_device_id, ''), NULLIF(l.neighbor_mgmt_addr, ''))
      ) AS b
    FROM platform.mapper_topology_links l
    CROSS JOIN lookback
    WHERE l.timestamp >= lookback.cutoff
  ) x
  WHERE x.a IS NOT NULL AND x.b IS NOT NULL AND x.a <> x.b
),
graph_counts AS (
  SELECT
    COALESCE(SUM(CASE WHEN rel = 'CONNECTS_TO' THEN cnt ELSE 0 END), 0)::bigint AS direct_edges,
    COALESCE(SUM(CASE WHEN rel = 'INFERRED_TO' THEN cnt ELSE 0 END), 0)::bigint AS inferred_edges,
    COALESCE(SUM(CASE WHEN rel = 'ATTACHED_TO' THEN cnt ELSE 0 END), 0)::bigint AS attachment_edges
  FROM (
    SELECT
      (result::jsonb ->> 'relation') AS rel,
      ((result::jsonb ->> 'count')::bigint) AS cnt
    FROM (
      SELECT ag_catalog.agtype_to_text(v) AS result
      FROM ag_catalog.cypher('platform_graph', \$\$
        MATCH ()-[r]->()
        WHERE r.ingestor = 'mapper_topology_v1'
          AND type(r) IN ['CONNECTS_TO', 'INFERRED_TO', 'ATTACHED_TO']
        RETURN {relation: type(r), count: count(r)} AS v
      \$\$) AS q(v agtype)
    ) rows
  ) c
),
unresolved AS (
  SELECT COUNT(*)::bigint AS unresolved_endpoints
  FROM (
    SELECT DISTINCT ids.uid
    FROM (
      SELECT l.local_device_id AS uid
      FROM platform.mapper_topology_links l
      CROSS JOIN lookback
      WHERE l.timestamp >= lookback.cutoff
        AND l.local_device_id IS NOT NULL
        AND btrim(l.local_device_id) <> ''
      UNION
      SELECT l.neighbor_device_id AS uid
      FROM platform.mapper_topology_links l
      CROSS JOIN lookback
      WHERE l.timestamp >= lookback.cutoff
        AND l.neighbor_device_id IS NOT NULL
        AND btrim(l.neighbor_device_id) <> ''
    ) ids
    LEFT JOIN platform.ocsf_devices d
      ON d.uid = ids.uid
      AND d.deleted_at IS NULL
    WHERE d.uid IS NULL
  ) unresolved_ids
)
SELECT
  jsonb_build_object(
    'lookback_minutes', ${LOOKBACK_MINUTES}::int,
    'raw_links', raw.raw_links,
    'unique_pairs', pairs.unique_pairs,
    'final_direct', graph_counts.direct_edges,
    'final_inferred', graph_counts.inferred_edges,
    'final_attachment', graph_counts.attachment_edges,
    'final_edges', (graph_counts.direct_edges + graph_counts.inferred_edges + graph_counts.attachment_edges),
    'unresolved_endpoints', unresolved.unresolved_endpoints
  )::text
FROM raw, pairs, graph_counts, unresolved;
SQL
}

sql_metrics_row() {
  cat <<SQL
WITH lookback AS (
  SELECT now() - make_interval(mins => ${LOOKBACK_MINUTES}::int) AS cutoff
),
raw AS (
  SELECT COUNT(*)::bigint AS raw_links
  FROM platform.mapper_topology_links l
  CROSS JOIN lookback
  WHERE l.timestamp >= lookback.cutoff
),
graph_counts AS (
  SELECT
    COALESCE(SUM(CASE WHEN rel = 'CONNECTS_TO' THEN cnt ELSE 0 END), 0)::bigint AS direct_edges,
    COALESCE(SUM(CASE WHEN rel = 'INFERRED_TO' THEN cnt ELSE 0 END), 0)::bigint AS inferred_edges
  FROM (
    SELECT
      (result::jsonb ->> 'relation') AS rel,
      ((result::jsonb ->> 'count')::bigint) AS cnt
    FROM (
      SELECT ag_catalog.agtype_to_text(v) AS result
      FROM ag_catalog.cypher('platform_graph', \$\$
        MATCH ()-[r]->()
        WHERE r.ingestor = 'mapper_topology_v1'
          AND type(r) IN ['CONNECTS_TO', 'INFERRED_TO', 'ATTACHED_TO']
        RETURN {relation: type(r), count: count(r)} AS v
      \$\$) AS q(v agtype)
    ) rows
  ) c
),
unresolved AS (
  SELECT COUNT(*)::bigint AS unresolved_endpoints
  FROM (
    SELECT DISTINCT ids.uid
    FROM (
      SELECT l.local_device_id AS uid
      FROM platform.mapper_topology_links l
      CROSS JOIN lookback
      WHERE l.timestamp >= lookback.cutoff
        AND l.local_device_id IS NOT NULL
        AND btrim(l.local_device_id) <> ''
      UNION
      SELECT l.neighbor_device_id AS uid
      FROM platform.mapper_topology_links l
      CROSS JOIN lookback
      WHERE l.timestamp >= lookback.cutoff
        AND l.neighbor_device_id IS NOT NULL
        AND btrim(l.neighbor_device_id) <> ''
    ) ids
    LEFT JOIN platform.ocsf_devices d
      ON d.uid = ids.uid
      AND d.deleted_at IS NULL
    WHERE d.uid IS NULL
  ) unresolved_ids
)
SELECT raw.raw_links, graph_counts.direct_edges, graph_counts.inferred_edges, unresolved.unresolved_endpoints
FROM raw, graph_counts, unresolved;
SQL
}

sql_edge_churn_ratio() {
  cat <<SQL
WITH windows AS (
  SELECT
    now() - make_interval(mins => ${LOOKBACK_MINUTES}::int) AS current_cutoff,
    now() - make_interval(mins => (${LOOKBACK_MINUTES}::int * 2)) AS previous_cutoff
),
current_pairs AS (
  SELECT DISTINCT
    LEAST(
      COALESCE(NULLIF(l.local_device_id, ''), NULLIF(l.local_device_ip, '')),
      COALESCE(NULLIF(l.neighbor_device_id, ''), NULLIF(l.neighbor_mgmt_addr, ''))
    ) AS a,
    GREATEST(
      COALESCE(NULLIF(l.local_device_id, ''), NULLIF(l.local_device_ip, '')),
      COALESCE(NULLIF(l.neighbor_device_id, ''), NULLIF(l.neighbor_mgmt_addr, ''))
    ) AS b
  FROM platform.mapper_topology_links l
  CROSS JOIN windows w
  WHERE l.timestamp >= w.current_cutoff
),
previous_pairs AS (
  SELECT DISTINCT
    LEAST(
      COALESCE(NULLIF(l.local_device_id, ''), NULLIF(l.local_device_ip, '')),
      COALESCE(NULLIF(l.neighbor_device_id, ''), NULLIF(l.neighbor_mgmt_addr, ''))
    ) AS a,
    GREATEST(
      COALESCE(NULLIF(l.local_device_id, ''), NULLIF(l.local_device_ip, '')),
      COALESCE(NULLIF(l.neighbor_device_id, ''), NULLIF(l.neighbor_mgmt_addr, ''))
    ) AS b
  FROM platform.mapper_topology_links l
  CROSS JOIN windows w
  WHERE l.timestamp >= w.previous_cutoff
    AND l.timestamp < w.current_cutoff
),
current_valid AS (
  SELECT a, b FROM current_pairs WHERE a IS NOT NULL AND b IS NOT NULL AND a <> b
),
previous_valid AS (
  SELECT a, b FROM previous_pairs WHERE a IS NOT NULL AND b IS NOT NULL AND a <> b
),
counts AS (
  SELECT
    (SELECT COUNT(*) FROM current_valid) AS current_count,
    (SELECT COUNT(*) FROM previous_valid) AS previous_count,
    (
      SELECT COUNT(*)
      FROM (
        SELECT COALESCE(c.a, p.a) AS a, COALESCE(c.b, p.b) AS b
        FROM current_valid c
        FULL OUTER JOIN previous_valid p
          ON c.a = p.a AND c.b = p.b
        WHERE c.a IS NULL OR p.a IS NULL
      ) diff
    ) AS changed_count
)
SELECT CASE
  WHEN GREATEST(previous_count, 1) = 0 THEN '0'
  ELSE ROUND(changed_count::numeric / GREATEST(previous_count, 1)::numeric, 6)::text
END
FROM counts;
SQL
}

print_status() {
  echo "Topology status:"
  run_sql "$(sql_metrics)"
}

cleanup_topology() {
  if [[ "$APPLY" != true || "$YES" != true ]]; then
    echo "Refusing destructive cleanup without --apply --yes" >&2
    echo "Nothing changed."
    return 2
  fi

  echo "Pre-cleanup status:"
  run_sql "$(sql_metrics)"

  run_sql "
BEGIN;
DELETE FROM platform.mapper_topology_links;
SELECT ag_catalog.cypher('platform_graph', \$\$
  MATCH ()-[r]->()
  WHERE r.ingestor = 'mapper_topology_v1'
    AND type(r) IN ['CONNECTS_TO', 'INFERRED_TO', 'ATTACHED_TO']
  DELETE r
\$\$);
COMMIT;
"

  echo "Post-cleanup status:"
  run_sql "$(sql_metrics)"
}

run_gates() {
  metrics_row="$(run_sql "$(sql_metrics_row)")"

  IFS='|' read -r raw_links direct_edges inferred_edges unresolved_endpoints <<< "$metrics_row"

  total_edges=$((direct_edges + inferred_edges))
  if (( total_edges == 0 )); then
    inferred_ratio="0"
  else
    inferred_ratio="$(run_sql "SELECT ROUND(${inferred_edges}::numeric / ${total_edges}::numeric, 6)::text;")"
  fi

  edge_churn_ratio="$(run_sql "$(sql_edge_churn_ratio)")"

  failures=0

  if (( raw_links < MIN_RAW_LINKS )); then
    echo "GATE FAIL: raw_links ${raw_links} < ${MIN_RAW_LINKS}" >&2
    failures=$((failures + 1))
  fi

  if (( direct_edges < MIN_DIRECT_EDGES )); then
    echo "GATE FAIL: final_direct ${direct_edges} < ${MIN_DIRECT_EDGES}" >&2
    failures=$((failures + 1))
  fi

  if ! run_sql "SELECT (${inferred_ratio}::numeric <= ${MAX_INFERRED_RATIO}::numeric)::text;" | grep -q '^t$'; then
    echo "GATE FAIL: inferred_ratio ${inferred_ratio} > ${MAX_INFERRED_RATIO}" >&2
    failures=$((failures + 1))
  fi

  if (( unresolved_endpoints > MAX_UNRESOLVED_ENDPOINTS )); then
    echo "GATE FAIL: unresolved_endpoints ${unresolved_endpoints} > ${MAX_UNRESOLVED_ENDPOINTS}" >&2
    failures=$((failures + 1))
  fi

  if ! run_sql "SELECT (${edge_churn_ratio}::numeric <= ${MAX_EDGE_CHURN_RATIO}::numeric)::text;" | grep -q '^t$'; then
    echo "GATE FAIL: edge_churn_ratio ${edge_churn_ratio} > ${MAX_EDGE_CHURN_RATIO}" >&2
    failures=$((failures + 1))
  fi

  echo "Gate metrics:"
  run_sql "$(sql_metrics)"
  echo "{\"inferred_ratio\": ${inferred_ratio}, \"edge_churn_ratio\": ${edge_churn_ratio}}"

  if (( failures > 0 )); then
    echo "Gate check failed (${failures} failure(s))." >&2
    return 1
  fi

  echo "Gate check passed."
}

case "$MODE" in
  status)
    print_status
    ;;
  cleanup)
    cleanup_topology
    ;;
  gates)
    run_gates
    ;;
  *)
    echo "Invalid mode: $MODE" >&2
    usage
    exit 1
    ;;
esac
