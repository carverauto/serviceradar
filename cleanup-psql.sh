#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./cleanup-psql.sh [options]

Preview Armis-only inventory rows that should be cleaned up because every valid
IP parsed from the row is inside the configured Armis blacklist, or because the
row has no valid IP. Use --apply to soft-delete the previewed target rows.

Options:
  --namespace NS        Kubernetes namespace. Default: example-namespace
  --cluster NAME        CNPG cluster label value. Optional when only one primary exists.
  --pod POD             Use this pod instead of discovering the CNPG primary.
  --database DB         PostgreSQL database. Default: serviceradar
  --username USER       PostgreSQL user. Default: read from secret, then serviceradar
  --secret NAME         Kubernetes secret with database credentials.
                        Default: serviceradar-db-credentials
  --cidr CIDR           Blacklisted CIDR. Repeatable.
                        Default: 192.0.2.0/24 and 198.51.100.0/24
  --limit N             Preview row limit. Default: 200
  --apply               Soft-delete matching rows. Default is preview only.
  -h, --help            Show this help.

Examples:
  ./cleanup-psql.sh --namespace example-namespace
  ./cleanup-psql.sh --namespace example-namespace --cidr 192.0.2.0/24 --cidr 198.51.100.0/24 --apply
USAGE
}

namespace="example-namespace"
cluster=""
pod=""
database="serviceradar"
username=""
secret="serviceradar-db-credentials"
limit="200"
apply="false"
cidrs=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      namespace="${2:?--namespace requires a value}"
      shift 2
      ;;
    --cluster)
      cluster="${2:?--cluster requires a value}"
      shift 2
      ;;
    --pod)
      pod="${2:?--pod requires a value}"
      shift 2
      ;;
    --database)
      database="${2:?--database requires a value}"
      shift 2
      ;;
    --username)
      username="${2:?--username requires a value}"
      shift 2
      ;;
    --secret)
      secret="${2:?--secret requires a value}"
      shift 2
      ;;
    --cidr)
      cidrs+=("${2:?--cidr requires a value}")
      shift 2
      ;;
    --limit)
      limit="${2:?--limit requires a value}"
      shift 2
      ;;
    --apply)
      apply="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
  echo "--limit must be a positive integer" >&2
  exit 2
fi

if [[ ${#cidrs[@]} -eq 0 ]]; then
  cidrs=("192.0.2.0/24" "198.51.100.0/24")
fi

for cidr in "${cidrs[@]}"; do
  if [[ "$cidr" == *"'"* ]]; then
    echo "CIDR values must not contain single quotes: $cidr" >&2
    exit 2
  fi
done

if [[ -z "$pod" ]]; then
  selector="cnpg.io/instanceRole=primary"
  if [[ -n "$cluster" ]]; then
    selector="cnpg.io/cluster=${cluster},${selector}"
  fi

  pod="$(
    kubectl get pods -n "$namespace" -l "$selector" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | head -n 1
  )"
fi

if [[ -z "$pod" ]]; then
  echo "could not discover CNPG primary pod in namespace $namespace" >&2
  echo "try --cluster <name> or --pod <pod>" >&2
  exit 1
fi

if [[ -z "$username" ]]; then
  username="$(
    kubectl get secret "$secret" -n "$namespace" -o jsonpath='{.data.username}' 2>/dev/null \
      | base64 -d 2>/dev/null || true
  )"
  username="${username:-serviceradar}"
fi

password="$(
  kubectl get secret "$secret" -n "$namespace" -o jsonpath='{.data.password}' \
    | base64 -d
)"

blacklist_values=""
for cidr in "${cidrs[@]}"; do
  if [[ -n "$blacklist_values" ]]; then
    blacklist_values+=","
  fi
  blacklist_values+="('${cidr}'::cidr)"
done

cat >&2 <<EOF
Namespace: $namespace
CNPG pod:   $pod
Database:   $database
Username:   $username
Mode:       $([[ "$apply" == "true" ]] && echo "APPLY" || echo "PREVIEW")
CIDRs:      ${cidrs[*]}
EOF

common_sql=$(cat <<SQL
WITH blacklist(cidr) AS (
  VALUES
    ${blacklist_values}
),
armis AS (
  SELECT *
  FROM platform.ocsf_devices
  WHERE deleted_at IS NULL
    AND (
      metadata->>'integration_type' = 'armis'
      OR COALESCE(discovery_sources, ARRAY[]::text[]) && ARRAY['armis']::text[]
    )
    AND COALESCE(discovery_sources, ARRAY[]::text[]) <@ ARRAY['armis']::text[]
),
parts AS (
  SELECT d.uid, d.hostname, d.ip AS raw_ip, trim(part.ip) AS parsed_ip
  FROM armis d
  CROSS JOIN LATERAL regexp_split_to_table(COALESCE(d.ip, ''), E'[,;\\\\t\\\\n\\\\r ]+') AS part(ip)
),
classified AS (
  SELECT
    uid,
    hostname,
    raw_ip,
    count(*) FILTER (WHERE platform.try_inet(NULLIF(parsed_ip, '')) IS NOT NULL) AS valid_ip_count,
    count(*) FILTER (
      WHERE EXISTS (
        SELECT 1 FROM blacklist b
        WHERE platform.try_inet(NULLIF(parsed_ip, '')) <<= b.cidr
      )
    ) AS blacklisted_ip_count,
    array_agg(parsed_ip) FILTER (WHERE parsed_ip <> '') AS parsed_ips
  FROM parts
  GROUP BY uid, hostname, raw_ip
),
targets AS (
  SELECT uid
  FROM classified
  WHERE valid_ip_count = 0
     OR valid_ip_count = blacklisted_ip_count
)
SQL
)

preview_sql=$(cat <<SQL
\\pset pager off
\\echo 'Malformed Armis inventory rows, preview only'
SELECT uid, hostname, ip, discovery_sources, metadata->>'armis_device_id' AS armis_id
FROM platform.ocsf_devices
WHERE deleted_at IS NULL
  AND (
    metadata->>'integration_type' = 'armis'
    OR COALESCE(discovery_sources, ARRAY[]::text[]) && ARRAY['armis']::text[]
  )
  AND (
    ip LIKE '%,%'
    OR ip LIKE '%;%'
    OR platform.try_inet(NULLIF(ip, '')) IS NULL
  )
ORDER BY modified_time DESC NULLS LAST
LIMIT ${limit};

\\echo 'Cleanup target count'
${common_sql}
SELECT count(*) AS cleanup_target_count FROM targets;

\\echo 'Cleanup target preview'
${common_sql}
SELECT c.*
FROM classified c
JOIN targets t USING (uid)
ORDER BY c.raw_ip
LIMIT ${limit};
SQL
)

apply_sql=$(cat <<SQL
\\pset pager off
BEGIN;
${common_sql}
UPDATE platform.ocsf_devices d
SET
  deleted_at = now(),
  deleted_reason = 'armis blacklist cleanup',
  deleted_by = 'manual-prod-cleanup',
  modified_time = now()
FROM targets t
WHERE d.uid = t.uid
RETURNING d.uid, d.hostname, d.ip, d.discovery_sources;
COMMIT;
SQL
)

if [[ "$apply" == "true" ]]; then
  sql="$apply_sql"
else
  sql="$preview_sql"
fi

kubectl exec -i -n "$namespace" "$pod" -- env PGPASSWORD="$password" \
  psql -h 127.0.0.1 -U "$username" -d "$database" -v ON_ERROR_STOP=1 <<<"$sql"
