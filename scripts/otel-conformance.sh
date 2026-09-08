#!/usr/bin/env bash
#
# otel-conformance.sh - external OTLP producer conformance harness.
#
# Sends a known workload through telemetrygen (traces, logs, metrics) at the
# given OTLP/gRPC endpoint, then prints -- and, when PSQL_DSN is set, runs --
# the SQL that proves every signal landed in CNPG.
#
# Workload:
#   traces:  5 traces, 3 child spans each, status code Error
#   logs:    10 log records
#   metrics: 6 Sum data points (telemetrygen's default metric name is "gen")
#
# Usage:
#   OTLP_ENDPOINT=<host:4317> [TG_FLAGS=...] [SERVICE_NAME=...] [PSQL_DSN=...] \
#     ./scripts/otel-conformance.sh [--kubectl|--docker]
#
# Examples:
#   # Against the demo LoadBalancer, skipping private-CA verification:
#   OTLP_ENDPOINT=23.138.124.20:4317 TG_FLAGS="--otlp-insecure-skip-verify" \
#     ./scripts/otel-conformance.sh
#
#   # Full verification against CNPG:
#   OTLP_ENDPOINT=23.138.124.20:4317 TG_FLAGS="--otlp-insecure-skip-verify" \
#     PSQL_DSN="postgres://user:pass@db:5432/serviceradar" ./scripts/otel-conformance.sh
#
#   # In-cluster without docker (telemetrygen runs via `kubectl run`):
#   OTLP_ENDPOINT=serviceradar-log-collector:4317 \
#     TG_FLAGS="--otlp-insecure-skip-verify" ./scripts/otel-conformance.sh --kubectl
#
# Environment:
#   OTLP_ENDPOINT    (required) host:port of the OTLP/gRPC listener.
#   TG_FLAGS         Extra telemetrygen flags appended to every run, e.g.
#                    "--otlp-insecure-skip-verify" (private CA, quick tests),
#                    "--ca-cert /certs/serviceradar-root.pem" (mounted CA), or
#                    "--otlp-insecure" (plaintext listener).
#   SERVICE_NAME     Resource service.name to send (default: ext-conformance-$RANDOM).
#   PSQL_DSN         When set, verification SQL runs via psql and the script exits
#                    nonzero if any check returns zero. When unset, SQL is only printed.
#   TG_IMAGE         telemetrygen image (default: ghcr.io/open-telemetry/
#                    opentelemetry-collector-contrib/telemetrygen:latest).
#   DOCKER_RUN_FLAGS Extra flags for `docker run`, e.g. "--network host" when the
#                    endpoint is localhost, or "-v $PWD/certs:/certs:ro" for --ca-cert.
#   VERIFY_ATTEMPTS  SQL poll attempts (default 10). Trace summaries refresh on a
#                    2-minute cron, so the default budget is ~3 minutes.
#   VERIFY_DELAY_SECS  Delay between attempts (default 20).

set -euo pipefail

TG_IMAGE="${TG_IMAGE:-ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest}"
SERVICE_NAME="${SERVICE_NAME:-ext-conformance-$RANDOM}"
VERIFY_ATTEMPTS="${VERIFY_ATTEMPTS:-10}"
VERIFY_DELAY_SECS="${VERIFY_DELAY_SECS:-20}"
RUNNER="docker"

usage() {
  # Print the leading comment block (everything between the shebang and the
  # first non-comment line) with the "# " prefix stripped.
  awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --kubectl) RUNNER="kubectl" ;;
    --docker) RUNNER="docker" ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [ -z "${OTLP_ENDPOINT:-}" ]; then
  echo "ERROR: OTLP_ENDPOINT is required (e.g. OTLP_ENDPOINT=23.138.124.20:4317)" >&2
  exit 2
fi

if [ "$RUNNER" = "docker" ] && ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found; install docker or use --kubectl" >&2
  exit 2
fi
if [ "$RUNNER" = "kubectl" ] && ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found" >&2
  exit 2
fi

# Intentional word-splitting of the flag strings into arrays.
read -r -a TG_EXTRA <<< "${TG_FLAGS:-}"
read -r -a DOCKER_EXTRA <<< "${DOCKER_RUN_FLAGS:-}"

case "$OTLP_ENDPOINT" in
  localhost*|127.0.0.1*)
    if [ "$RUNNER" = "docker" ]; then
      echo "NOTE: OTLP_ENDPOINT points at localhost; inside the telemetrygen container" >&2
      echo "      that is the container itself. Consider DOCKER_RUN_FLAGS='--network host'" >&2
      echo "      or OTLP_ENDPOINT=host.docker.internal:4317." >&2
    fi
    ;;
esac

run_telemetrygen() {
  signal="$1"
  shift
  echo ">>> telemetrygen ${signal} ($*)"
  if [ "$RUNNER" = "kubectl" ]; then
    kubectl run "otel-conformance-${signal}-$$" --rm -i --restart=Never \
      --image="$TG_IMAGE" -- "$signal" "$@"
  else
    docker run --rm ${DOCKER_EXTRA[@]+"${DOCKER_EXTRA[@]}"} "$TG_IMAGE" "$signal" "$@"
  fi
}

common_args=(--otlp-endpoint "$OTLP_ENDPOINT" --service "$SERVICE_NAME")
if [ "${#TG_EXTRA[@]}" -gt 0 ]; then
  common_args+=("${TG_EXTRA[@]}")
fi

echo "OTLP endpoint : $OTLP_ENDPOINT"
echo "Service name  : $SERVICE_NAME"
echo "Runner        : $RUNNER"
echo

run_telemetrygen traces "${common_args[@]}" --traces 5 --child-spans 3 --status-code Error
run_telemetrygen logs "${common_args[@]}" --logs 10
run_telemetrygen metrics "${common_args[@]}" --metrics 6 --metric-type Sum

# Escape single quotes for safe SQL literal interpolation.
svc_sql="${SERVICE_NAME//\'/\'\'}"

check_labels=(
  "otel_traces span count"
  "otel_traces distinct trace count"
  "otel_trace_summaries summed span_count"
  "logs record count"
  "otel_metric_points 'gen' point count"
)
check_queries=(
  "SELECT count(*) FROM otel_traces WHERE service_name = '${svc_sql}';"
  "SELECT count(DISTINCT trace_id) FROM otel_traces WHERE service_name = '${svc_sql}';"
  "SELECT COALESCE(sum(span_count), 0) FROM otel_trace_summaries WHERE root_service_name = '${svc_sql}';"
  "SELECT count(*) FROM logs WHERE service_name = '${svc_sql}';"
  "SELECT count(*) FROM otel_metric_points WHERE metric_name = 'gen' AND service_name = '${svc_sql}';"
)

echo
echo "Verification SQL (service_name = '${SERVICE_NAME}'):"
i=0
while [ "$i" -lt "${#check_queries[@]}" ]; do
  echo "  -- ${check_labels[$i]}"
  echo "  ${check_queries[$i]}"
  i=$((i + 1))
done

if [ -z "${PSQL_DSN:-}" ]; then
  echo
  echo "PSQL_DSN not set; skipping database verification. Run the SQL above against CNPG."
  exit 0
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "ERROR: PSQL_DSN is set but psql is not installed" >&2
  exit 2
fi

run_query() {
  psql -X -A -t -v ON_ERROR_STOP=1 -d "$PSQL_DSN" -c "$1" | tr -d '[:space:]'
}

echo
echo "Verifying against CNPG (up to ${VERIFY_ATTEMPTS} attempts, ${VERIFY_DELAY_SECS}s apart;"
echo "trace summaries refresh on a 2-minute cron)..."

attempt=1
failed_labels=""
while [ "$attempt" -le "$VERIFY_ATTEMPTS" ]; do
  failed_labels=""
  i=0
  while [ "$i" -lt "${#check_queries[@]}" ]; do
    count="$(run_query "${check_queries[$i]}")"
    if [ -n "$count" ] && [ "$count" != "0" ]; then
      echo "  [ok]      ${check_labels[$i]}: ${count}"
    else
      echo "  [pending] ${check_labels[$i]}: ${count:-<empty>}"
      failed_labels="${failed_labels}    - ${check_labels[$i]}"$'\n'
    fi
    i=$((i + 1))
  done
  if [ -z "$failed_labels" ]; then
    echo
    echo "PASS: all OTLP signals for service '${SERVICE_NAME}' landed in CNPG."
    exit 0
  fi
  if [ "$attempt" -lt "$VERIFY_ATTEMPTS" ]; then
    echo "  attempt ${attempt}/${VERIFY_ATTEMPTS} incomplete; retrying in ${VERIFY_DELAY_SECS}s..."
    sleep "$VERIFY_DELAY_SECS"
  fi
  attempt=$((attempt + 1))
done

echo
echo "FAIL: the following checks were still zero after ${VERIFY_ATTEMPTS} attempts:" >&2
printf '%s' "$failed_labels" >&2
exit 1
