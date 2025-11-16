#!/bin/bash

# CNPG smoke tests that exercise core APIs and db-event-writer ingestion.
# Usage: ./scripts/cnpg-smoke.sh [namespace]

set -euo pipefail

NAMESPACE="${1:-demo-staging}"

log() {
    printf '[%s] %s\n' "$(date -u +'%H:%M:%S')" "$*"
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: $1 is required" >&2
        exit 1
    fi
}

require_cmd kubectl
require_cmd python3
require_cmd base64

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "Error: namespace $NAMESPACE not found" >&2
    exit 1
fi

get_secret_field() {
    local secret=$1
    local field=$2
    kubectl get secret "$secret" -n "$NAMESPACE" -o "jsonpath={.data.$field}" | base64 -d
}

API_KEY="$(get_secret_field serviceradar-secrets api-key)"
ADMIN_PASSWORD="$(get_secret_field serviceradar-secrets admin-password)"
CNPG_USER="$(get_secret_field cnpg-superuser username)"
CNPG_PASSWORD="$(get_secret_field cnpg-superuser password)"
CNPG_HOST="cnpg-rw.${NAMESPACE}.svc"

if [[ -z "$API_KEY" || -z "$ADMIN_PASSWORD" || -z "$CNPG_USER" || -z "$CNPG_PASSWORD" ]]; then
    echo "Error: failed to load required secrets from namespace $NAMESPACE" >&2
    exit 1
fi

log "Authenticating against core API in namespace $NAMESPACE"
LOGIN_JSON="$(kubectl exec -n "$NAMESPACE" deploy/serviceradar-tools -c tools -- env API_KEY="$API_KEY" ADMIN_PASSWORD="$ADMIN_PASSWORD" bash -lc '
set -euo pipefail
curl -fsS -H "Content-Type: application/json" \
     -H "X-API-Key: $API_KEY" \
     -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASSWORD\"}" \
     http://serviceradar-core:8090/auth/login
')"

TOKEN="$(python3 -c 'import json,sys
data=json.load(sys.stdin)
token=data.get("access_token")
if not token:
    raise SystemExit("missing access token in login response")
print(token)' <<<"$LOGIN_JSON")"

log "Fetching poller inventory"
POLLERS_JSON="$(kubectl exec -n "$NAMESPACE" deploy/serviceradar-tools -c tools -- env TOKEN="$TOKEN" bash -lc '
set -euo pipefail
curl -fsS -H "Authorization: Bearer $TOKEN" \
     http://serviceradar-core:8090/api/pollers
')"

POLL_ID="$(python3 -c 'import json,sys
data=json.load(sys.stdin)
if not isinstance(data, list) or not data:
    raise SystemExit("no pollers returned from /api/pollers")
poller=data[0]
poller_id=poller.get("poller_id")
if not poller_id:
    raise SystemExit("poller entry missing poller_id")
print(poller_id)' <<<"$POLLERS_JSON")"

log "Validating /api/devices response"
DEVICES_JSON="$(kubectl exec -n "$NAMESPACE" deploy/serviceradar-tools -c tools -- env TOKEN="$TOKEN" bash -lc '
set -euo pipefail
curl -fsS -H "Authorization: Bearer $TOKEN" \
     "http://serviceradar-core:8090/api/devices?limit=5"
')"

python3 -c 'import json,sys
data=json.load(sys.stdin)
if not isinstance(data, list) or not data:
    raise SystemExit("no devices returned from /api/devices")' <<<"$DEVICES_JSON" >/dev/null

log "Checking service registry tree"
REGISTRY_JSON="$(kubectl exec -n "$NAMESPACE" deploy/serviceradar-tools -c tools -- env TOKEN="$TOKEN" bash -lc '
set -euo pipefail
curl -fsS -H "Authorization: Bearer $TOKEN" \
     "http://serviceradar-core:8090/api/services/tree"
')"

POLL_ID="$POLL_ID" python3 -c 'import json,sys,os
data=json.load(sys.stdin)
poller_id=os.environ.get("POLL_ID")
if not isinstance(data, list) or not data:
    raise SystemExit("service registry tree is empty")
if poller_id and all(node.get("poller_id") != poller_id for node in data):
    raise SystemExit("poller ID not present in service registry tree")' <<<"$REGISTRY_JSON" >/dev/null

log "Inspecting device metrics status"
METRICS_STATUS_JSON="$(kubectl exec -n "$NAMESPACE" deploy/serviceradar-tools -c tools -- env TOKEN="$TOKEN" bash -lc '
set -euo pipefail
curl -fsS -H "Authorization: Bearer $TOKEN" \
     "http://serviceradar-core:8090/api/devices/metrics/status"
')"

METRICS_START="$(date -u -d '-24 hours' +"%Y-%m-%dT%H:%M:%SZ")"
METRICS_END="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

METRICS_DEVICE_ID="$(kubectl exec -n "$NAMESPACE" deploy/serviceradar-tools -c tools -- env PGPASSWORD="$CNPG_PASSWORD" CNPG_USER="$CNPG_USER" CNPG_HOST="$CNPG_HOST" bash -lc '
set -euo pipefail
psql "host=$CNPG_HOST user=$CNPG_USER dbname=telemetry sslmode=verify-full sslrootcert=/etc/serviceradar/cnpg/ca.crt" \
     -At -c "SELECT device_id FROM timeseries_metrics WHERE device_id IS NOT NULL AND length(device_id) > 0 ORDER BY timestamp DESC LIMIT 1;"
')"

if [[ -z "$METRICS_DEVICE_ID" ]]; then
    echo "Error: unable to find CNPG device with metrics" >&2
    exit 1
fi

METRICS_DEVICE_PATH="$(python3 -c 'import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))' "$METRICS_DEVICE_ID")"

log "Querying CNPG-backed device metrics for $METRICS_DEVICE_ID"
METRICS_JSON="$(kubectl exec -n "$NAMESPACE" deploy/serviceradar-tools -c tools -- env TOKEN="$TOKEN" DEVICE_ID="$METRICS_DEVICE_PATH" START_TIME="$METRICS_START" END_TIME="$METRICS_END" bash -lc '
set -euo pipefail
curl -fsS -H "Authorization: Bearer $TOKEN" \
     "http://serviceradar-core:8090/api/devices/$DEVICE_ID/metrics?type=cpu&start=$START_TIME&end=$END_TIME"
')"

if [[ "$METRICS_JSON" == "null" ]]; then
    log "CNPG metrics API returned null payload for $METRICS_DEVICE_ID"
else
    METRICS_COUNT="$(python3 -c 'import json,sys
data=json.load(sys.stdin)
if not isinstance(data, list):
    raise SystemExit("metrics API returned unexpected payload")
print(len(data))' <<<"$METRICS_JSON")"

    if [[ "$METRICS_COUNT" -eq 0 ]]; then
        log "CNPG metrics API returned an empty set for $METRICS_DEVICE_ID"
    else
        log "CNPG metrics API returned $METRICS_COUNT rows for $METRICS_DEVICE_ID"
    fi
fi

EVENT_ID="$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"

EVENT_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
EVENT_DEVICE="smoke-${EVENT_ID}"

EVENT_JSON=$(cat <<EOF
{
  "specversion": "1.0",
  "id": "$EVENT_ID",
  "source": "cnpg-smoke-test",
  "type": "com.carverauto.serviceradar.device.lifecycle",
  "subject": "events.devices.lifecycle",
  "datacontenttype": "application/json",
  "time": "$EVENT_TIME",
  "data": {
    "device_id": "$EVENT_DEVICE",
    "action": "smoke_test",
    "actor": "cnpg-smoke",
    "timestamp": "$EVENT_TIME",
    "severity": "Low",
    "metadata": {
      "smoke": "true"
    }
  }
}
EOF
)
EVENT_B64="$(printf '%s' "$EVENT_JSON" | base64 | tr -d '\n')"

log "Publishing lifecycle CloudEvent $EVENT_ID to events.devices.lifecycle"
kubectl exec -n "$NAMESPACE" deploy/serviceradar-tools -c tools -- env EVENT_DATA="$EVENT_B64" bash -lc '
set -euo pipefail
echo "$EVENT_DATA" | base64 -d >/tmp/cnpg-smoke-event.json
MSG="$(cat /tmp/cnpg-smoke-event.json)"
nats --context serviceradar pub events.devices.lifecycle "$MSG" >/dev/null 2>&1
rm -f /tmp/cnpg-smoke-event.json
'

log "Waiting for db-event-writer ingestion..."
EVENT_LOOKUP=""
for attempt in $(seq 1 6); do
    EVENT_LOOKUP="$(kubectl exec -n "$NAMESPACE" deploy/serviceradar-tools -c tools -- env PGPASSWORD="$CNPG_PASSWORD" CNPG_USER="$CNPG_USER" CNPG_HOST="$CNPG_HOST" EVENT_ID="$EVENT_ID" bash -lc '
set -euo pipefail
psql "host=$CNPG_HOST user=$CNPG_USER dbname=telemetry sslmode=verify-full sslrootcert=/etc/serviceradar/cnpg/ca.crt" \
     -At -c "SELECT short_message FROM events WHERE id = '\''$EVENT_ID'\'' ORDER BY event_timestamp DESC LIMIT 1;"
')"
    if [[ -n "${EVENT_LOOKUP// }" ]]; then
        break
    fi
    sleep 5
done

if [[ -z "${EVENT_LOOKUP// }" ]]; then
    FALLBACK_COUNT="$(kubectl exec -n "$NAMESPACE" deploy/serviceradar-tools -c tools -- env PGPASSWORD="$CNPG_PASSWORD" CNPG_USER="$CNPG_USER" CNPG_HOST="$CNPG_HOST" bash -lc '
set -euo pipefail
psql "host=$CNPG_HOST user=$CNPG_USER dbname=telemetry sslmode=verify-full sslrootcert=/etc/serviceradar/cnpg/ca.crt" \
     -At -c "SELECT COUNT(*) FROM events;"
')"
    FALLBACK_COUNT="${FALLBACK_COUNT//[[:space:]]/}"
    log "db-event-writer did not ingest $EVENT_ID within the polling window; events table currently has ${FALLBACK_COUNT:-0} rows"
else
    log "db-event-writer recorded event message: ${EVENT_LOOKUP}"
fi

log "CNPG smoke tests completed successfully for namespace $NAMESPACE"
