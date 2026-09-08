#!/usr/bin/env bash

# Build an AI-friendly topology diagnostics bundle from CNPG/Postgres.
# Usage:
#   ./scripts/topology-ai-dump.sh [--hours 24] [--topology-limit 10000] [--out-dir /path]
#
# Connection defaults use scripts/psql-cnpg.sh, which reads .env/CNPG_* vars.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PSQL_BIN_DEFAULT="$ROOT_DIR/scripts/psql-cnpg.sh"
PSQL_BIN="${PSQL_BIN:-$PSQL_BIN_DEFAULT}"
K8S_NAMESPACE=""
K8S_POD=""
K8S_DB_SECRET="${K8S_DB_SECRET:-cnpg-superuser}"
K8S_DB_USER="${K8S_DB_USER:-}"
K8S_DB_NAME="${K8S_DB_NAME:-serviceradar}"

HOURS="${HOURS:-24}"
TOPOLOGY_LIMIT="${TOPOLOGY_LIMIT:-10000}"
SAMPLE_LIMIT="${SAMPLE_LIMIT:-500}"
OUT_DIR=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --hours N            Lookback window in hours (default: ${HOURS})
  --topology-limit N   Max rows for raw topology export (default: ${TOPOLOGY_LIMIT})
  --sample-limit N     Max rows for sample files (default: ${SAMPLE_LIMIT})
  --out-dir PATH       Output directory (default: ./tmp/topology-ai-dump-<timestamp>)
  --k8s-namespace NS   Run psql via kubectl exec in CNPG primary pod
  --k8s-pod POD        Explicit CNPG pod name (optional with --k8s-namespace)
  --k8s-db-secret NAME K8s secret containing .data.password (default: cnpg-superuser)
  --k8s-db-user USER   DB user for k8s mode (default: username from secret, else postgres)
  --k8s-db-name NAME   DB name for k8s mode (default: serviceradar)
  -h, --help           Show this help

Env:
  PSQL_BIN             psql wrapper/command (default: scripts/psql-cnpg.sh)
  K8S_DB_SECRET        Secret name fallback for k8s mode
  K8S_DB_USER          DB user fallback for k8s mode
  K8S_DB_NAME          DB name fallback for k8s mode
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hours)
      HOURS="$2"
      shift 2
      ;;
    --topology-limit)
      TOPOLOGY_LIMIT="$2"
      shift 2
      ;;
    --sample-limit)
      SAMPLE_LIMIT="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --k8s-namespace)
      K8S_NAMESPACE="$2"
      shift 2
      ;;
    --k8s-pod)
      K8S_POD="$2"
      shift 2
      ;;
    --k8s-db-secret)
      K8S_DB_SECRET="$2"
      shift 2
      ;;
    --k8s-db-user)
      K8S_DB_USER="$2"
      shift 2
      ;;
    --k8s-db-name)
      K8S_DB_NAME="$2"
      shift 2
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

for n in "$HOURS" "$TOPOLOGY_LIMIT" "$SAMPLE_LIMIT"; do
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "Expected positive integer, got: $n" >&2
    exit 1
  fi
  if [[ "$n" -eq 0 ]]; then
    echo "Expected non-zero integer, got: $n" >&2
    exit 1
  fi
done

if [[ -z "$OUT_DIR" ]]; then
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  OUT_DIR="$ROOT_DIR/tmp/topology-ai-dump-$ts"
fi

mkdir -p "$OUT_DIR"

if [[ -n "$K8S_NAMESPACE" ]]; then
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "kubectl is required for --k8s-namespace mode" >&2
    exit 1
  fi

  if [[ -z "$K8S_POD" ]]; then
    K8S_POD="$(kubectl get pod -n "$K8S_NAMESPACE" \
      -l cnpg.io/instanceRole=primary \
      -o jsonpath='{.items[0].metadata.name}')"
  fi

  if [[ -z "$K8S_POD" ]]; then
    echo "Could not locate a CNPG primary pod in namespace $K8S_NAMESPACE" >&2
    exit 1
  fi

  K8S_DB_PASSWORD="$(kubectl get secret "$K8S_DB_SECRET" -n "$K8S_NAMESPACE" \
    -o jsonpath='{.data.password}' | base64 -d)"

  if [[ -z "$K8S_DB_USER" ]]; then
    K8S_DB_USER="$(kubectl get secret "$K8S_DB_SECRET" -n "$K8S_NAMESPACE" \
      -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || true)"
    if [[ -z "$K8S_DB_USER" ]]; then
      K8S_DB_USER="postgres"
    fi
  fi

  if [[ -z "$K8S_DB_PASSWORD" ]]; then
    echo "Failed to resolve DB password from secret $K8S_DB_SECRET in namespace $K8S_NAMESPACE" >&2
    exit 1
  fi

  PSQL_BASE=(
    kubectl exec -i -n "$K8S_NAMESPACE" "$K8S_POD" --
    env "PGPASSWORD=$K8S_DB_PASSWORD"
    psql -h 127.0.0.1 -U "$K8S_DB_USER" -d "$K8S_DB_NAME" -X -v ON_ERROR_STOP=1 -P pager=off
  )
else
  if [[ ! -x "$PSQL_BIN" && "$PSQL_BIN" == *"/"* ]]; then
    echo "psql wrapper not executable: $PSQL_BIN" >&2
    exit 1
  fi
  PSQL_BASE=("$PSQL_BIN" -X -v ON_ERROR_STOP=1 -P pager=off)
fi

run_json() {
  local name="$1"
  local sql="$2"
  local file="$OUT_DIR/${name}.json"

  "${PSQL_BASE[@]}" -Atqc "SELECT COALESCE(jsonb_pretty(jsonb_agg(to_jsonb(row))), '[]'::jsonb::text) FROM (${sql}) row;" > "$file"
}

run_txt() {
  local name="$1"
  local sql="$2"
  local file="$OUT_DIR/${name}.txt"

  "${PSQL_BASE[@]}" -c "$sql" > "$file"
}

write_empty_json() {
  local name="$1"
  echo "[]" > "$OUT_DIR/${name}.json"
}

table_exists() {
  local table_name="$1"
  local present
  present="$("${PSQL_BASE[@]}" -Atqc "SELECT to_regclass('${table_name}') IS NOT NULL;")"
  [[ "$present" == "t" ]]
}

cat > "$OUT_DIR/README.md" <<README
# Topology AI Dump

Generated at (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Lookback window: ${HOURS}h
Topology row limit: ${TOPOLOGY_LIMIT}
Sample limit: ${SAMPLE_LIMIT}

This bundle is intended for AI/code agents diagnosing topology issues.
Sensitive values are redacted where possible (UniFi API keys are not exported).

## Files
README

run_json "00_metadata" "
  SELECT
    now() AT TIME ZONE 'utc' AS generated_at_utc,
    current_database() AS database_name,
    current_user AS database_user,
    current_schema AS current_schema,
    current_setting('search_path') AS search_path,
    ${HOURS}::int AS lookback_hours,
    ${TOPOLOGY_LIMIT}::int AS topology_limit,
    ${SAMPLE_LIMIT}::int AS sample_limit
"

run_txt "01_schema_relevant_columns" "
  SELECT
    table_schema,
    table_name,
    ordinal_position,
    column_name,
    data_type
  FROM information_schema.columns
  WHERE table_schema = 'platform'
    AND table_name IN (
      'mapper_jobs',
      'mapper_job_seeds',
      'mapper_unifi_controllers',
      'mapper_snmp_credentials',
      'mapper_topology_links',
      'discovered_interfaces',
      'ocsf_devices'
    )
  ORDER BY table_name, ordinal_position;
"

run_json "10_mapper_jobs" "
  SELECT
    id,
    name,
    description,
    enabled,
    interval,
    partition,
    agent_id,
    discovery_mode,
    discovery_type,
    concurrency,
    timeout,
    retries,
    options,
    last_run_at,
    last_run_status,
    last_run_interface_count,
    last_run_error,
    inserted_at,
    updated_at
  FROM platform.mapper_jobs
  ORDER BY enabled DESC, updated_at DESC NULLS LAST, name
"

run_json "11_mapper_job_seeds" "
  SELECT
    s.id,
    s.mapper_job_id,
    j.name AS mapper_job_name,
    s.seed,
    s.inserted_at,
    s.updated_at
  FROM platform.mapper_job_seeds s
  LEFT JOIN platform.mapper_jobs j ON j.id = s.mapper_job_id
  ORDER BY j.name NULLS LAST, s.seed
"

run_json "12_mapper_unifi_controllers" "
  SELECT
    c.id,
    c.mapper_job_id,
    j.name AS mapper_job_name,
    c.name,
    c.base_url,
    c.insecure_skip_verify,
    c.inserted_at,
    c.updated_at
  FROM platform.mapper_unifi_controllers c
  LEFT JOIN platform.mapper_jobs j ON j.id = c.mapper_job_id
  ORDER BY j.name NULLS LAST, c.base_url
"

if table_exists "platform.mapper_snmp_credentials"; then
  run_json "13_mapper_snmp_credentials" "
    SELECT
      sc.id,
      sc.mapper_job_id,
      j.name AS mapper_job_name,
      sc.version,
      sc.username,
      sc.inserted_at,
      sc.updated_at,
      to_jsonb(sc) - ARRAY[
        'id',
        'mapper_job_id',
        'version',
        'username',
        'inserted_at',
        'updated_at',
        'community',
        'auth_passphrase',
        'privacy_passphrase',
        'auth_password',
        'priv_password',
        'password'
      ] AS extra
    FROM platform.mapper_snmp_credentials sc
    LEFT JOIN platform.mapper_jobs j ON j.id = sc.mapper_job_id
    ORDER BY j.name NULLS LAST, sc.version, sc.username NULLS LAST
  "
else
  write_empty_json "13_mapper_snmp_credentials"
fi

run_txt "20_topology_funnel_counts" "
  WITH recent AS (
    SELECT *
    FROM platform.mapper_topology_links
    WHERE timestamp >= now() - make_interval(hours => ${HOURS})
  )
  SELECT
    COUNT(*) AS raw_links,
    COUNT(DISTINCT CONCAT_WS('|', COALESCE(local_device_id, ''), COALESCE(neighbor_device_id, ''), COALESCE(protocol, ''))) AS distinct_directed_triples,
    COUNT(DISTINCT CONCAT_WS('|',
      LEAST(COALESCE(local_device_id, COALESCE(local_device_ip, '')), COALESCE(neighbor_device_id, COALESCE(neighbor_mgmt_addr, ''))),
      GREATEST(COALESCE(local_device_id, COALESCE(local_device_ip, '')), COALESCE(neighbor_device_id, COALESCE(neighbor_mgmt_addr, ''))),
      COALESCE(protocol, '')
    )) AS distinct_undirected_pairs_with_protocol,
    COUNT(DISTINCT local_device_ip) AS distinct_local_device_ips,
    COUNT(DISTINCT COALESCE(local_device_id, local_device_ip)) AS distinct_local_ids,
    COUNT(DISTINCT COALESCE(neighbor_device_id, neighbor_mgmt_addr, neighbor_chassis_id, neighbor_system_name)) AS distinct_neighbor_ids
  FROM recent;
"

run_txt "21_topology_counts_by_protocol" "
  SELECT
    COALESCE(protocol, '<null>') AS protocol,
    COUNT(*) AS links
  FROM platform.mapper_topology_links
  WHERE timestamp >= now() - make_interval(hours => ${HOURS})
  GROUP BY 1
  ORDER BY 2 DESC, 1;
"

run_txt "22_topology_counts_by_evidence" "
  SELECT
    COALESCE(metadata->>'evidence_class', '<null>') AS evidence_class,
    COUNT(*) AS links
  FROM platform.mapper_topology_links
  WHERE timestamp >= now() - make_interval(hours => ${HOURS})
  GROUP BY 1
  ORDER BY 2 DESC, 1;
"

run_txt "23_topology_counts_by_protocol_and_evidence" "
  SELECT
    COALESCE(protocol, '<null>') AS protocol,
    COALESCE(metadata->>'evidence_class', '<null>') AS evidence_class,
    COUNT(*) AS links
  FROM platform.mapper_topology_links
  WHERE timestamp >= now() - make_interval(hours => ${HOURS})
  GROUP BY 1,2
  ORDER BY 3 DESC, 1, 2;
"

run_txt "24_topology_counts_by_local_ip" "
  SELECT
    COALESCE(local_device_ip, '<null>') AS local_device_ip,
    COUNT(*) AS links
  FROM platform.mapper_topology_links
  WHERE timestamp >= now() - make_interval(hours => ${HOURS})
  GROUP BY 1
  ORDER BY 2 DESC, 1
  LIMIT ${SAMPLE_LIMIT};
"

run_txt "30_orphan_links_by_device_id" "
  WITH recent AS (
    SELECT *
    FROM platform.mapper_topology_links
    WHERE timestamp >= now() - make_interval(hours => ${HOURS})
  )
  SELECT
    COUNT(*) FILTER (WHERE local_device_id IS NOT NULL AND d_local.uid IS NULL) AS local_id_orphans,
    COUNT(*) FILTER (WHERE neighbor_device_id IS NOT NULL AND d_neighbor.uid IS NULL) AS neighbor_id_orphans,
    COUNT(*) FILTER (WHERE local_if_index IS NULL OR local_if_index <= 0) AS missing_or_zero_local_ifindex,
    COUNT(*) FILTER (WHERE COALESCE(neighbor_mgmt_addr, '') = '') AS missing_neighbor_mgmt_addr
  FROM recent r
  LEFT JOIN platform.ocsf_devices d_local
    ON d_local.uid = r.local_device_id AND d_local.deleted_at IS NULL
  LEFT JOIN platform.ocsf_devices d_neighbor
    ON d_neighbor.uid = r.neighbor_device_id AND d_neighbor.deleted_at IS NULL;
"

run_json "31_orphan_link_samples" "
  WITH recent AS (
    SELECT *
    FROM platform.mapper_topology_links
    WHERE timestamp >= now() - make_interval(hours => ${HOURS})
  )
  SELECT
    r.timestamp,
    r.protocol,
    r.local_device_id,
    r.local_device_ip,
    r.local_if_index,
    r.local_if_name,
    r.neighbor_device_id,
    r.neighbor_mgmt_addr,
    r.neighbor_chassis_id,
    r.neighbor_port_id,
    r.neighbor_system_name,
    r.metadata
  FROM recent r
  LEFT JOIN platform.ocsf_devices d_local
    ON d_local.uid = r.local_device_id AND d_local.deleted_at IS NULL
  LEFT JOIN platform.ocsf_devices d_neighbor
    ON d_neighbor.uid = r.neighbor_device_id AND d_neighbor.deleted_at IS NULL
  WHERE
    (r.local_device_id IS NOT NULL AND d_local.uid IS NULL)
    OR (r.neighbor_device_id IS NOT NULL AND d_neighbor.uid IS NULL)
    OR r.local_if_index IS NULL
    OR r.local_if_index <= 0
    OR COALESCE(r.neighbor_mgmt_addr, '') = ''
  ORDER BY r.timestamp DESC
  LIMIT ${SAMPLE_LIMIT}
"

run_json "40_topology_rows_recent" "
  SELECT
    timestamp,
    agent_id,
    gateway_id,
    partition,
    protocol,
    local_device_ip,
    local_device_id,
    local_if_index,
    local_if_name,
    neighbor_device_id,
    neighbor_chassis_id,
    neighbor_port_id,
    neighbor_port_descr,
    neighbor_system_name,
    neighbor_mgmt_addr,
    metadata,
    created_at
  FROM platform.mapper_topology_links
  WHERE timestamp >= now() - make_interval(hours => ${HOURS})
  ORDER BY timestamp DESC
  LIMIT ${TOPOLOGY_LIMIT}
"

run_json "50_ocsf_devices_recent" "
  SELECT
    uid,
    ip,
    name,
    hostname,
    mac,
    type,
    type_id,
    vendor_name,
    model,
    is_available,
    last_seen_time,
    deleted_at,
    metadata
  FROM platform.ocsf_devices
  ORDER BY last_seen_time DESC NULLS LAST
  LIMIT ${TOPOLOGY_LIMIT}
"

run_json "51_discovered_interfaces_recent" "
  SELECT
    timestamp,
    device_id,
    device_ip,
    if_index,
    if_name,
    if_descr,
    if_alias,
    if_type,
    if_speed,
    if_admin_status,
    if_oper_status,
    metadata
  FROM platform.discovered_interfaces
  WHERE timestamp >= now() - make_interval(hours => ${HOURS})
  ORDER BY timestamp DESC
  LIMIT ${TOPOLOGY_LIMIT}
"

run_txt "60_topology_link_freshness" "
  SELECT
    MIN(timestamp) AS min_ts,
    MAX(timestamp) AS max_ts,
    COUNT(*) AS rows
  FROM platform.mapper_topology_links
  WHERE timestamp >= now() - make_interval(hours => ${HOURS});
"

BUNDLE="$OUT_DIR/ai_bundle.txt"
{
  echo "# ServiceRadar Topology AI Bundle"
  echo
  echo "Generated (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "Lookback hours: ${HOURS}"
  echo "Topology limit: ${TOPOLOGY_LIMIT}"
  echo "Sample limit: ${SAMPLE_LIMIT}"
  echo

  for f in \
    00_metadata.json \
    01_schema_relevant_columns.txt \
    10_mapper_jobs.json \
    11_mapper_job_seeds.json \
    12_mapper_unifi_controllers.json \
    13_mapper_snmp_credentials.json \
    20_topology_funnel_counts.txt \
    21_topology_counts_by_protocol.txt \
    22_topology_counts_by_evidence.txt \
    23_topology_counts_by_protocol_and_evidence.txt \
    24_topology_counts_by_local_ip.txt \
    30_orphan_links_by_device_id.txt \
    31_orphan_link_samples.json \
    40_topology_rows_recent.json \
    50_ocsf_devices_recent.json \
    51_discovered_interfaces_recent.json \
    60_topology_link_freshness.txt
  do
    if [[ -f "$OUT_DIR/$f" ]]; then
      echo "## FILE: $f"
      echo
      cat "$OUT_DIR/$f"
      echo
      echo
    fi
  done
} > "$BUNDLE"

cat >> "$OUT_DIR/README.md" <<'README_FILES'
- ai_bundle.txt (single stitched file for agent sharing)
- 00_metadata.json
- 01_schema_relevant_columns.txt
- 10_mapper_jobs.json
- 11_mapper_job_seeds.json
- 12_mapper_unifi_controllers.json
- 13_mapper_snmp_credentials.json
- 20_topology_funnel_counts.txt
- 21_topology_counts_by_protocol.txt
- 22_topology_counts_by_evidence.txt
- 23_topology_counts_by_protocol_and_evidence.txt
- 24_topology_counts_by_local_ip.txt
- 30_orphan_links_by_device_id.txt
- 31_orphan_link_samples.json
- 40_topology_rows_recent.json
- 50_ocsf_devices_recent.json
- 51_discovered_interfaces_recent.json
- 60_topology_link_freshness.txt
README_FILES

echo "Topology AI dump created at: $OUT_DIR"
echo "Bundle file: $BUNDLE"
