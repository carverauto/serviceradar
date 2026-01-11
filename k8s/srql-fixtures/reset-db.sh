#!/usr/bin/env bash
set -euo pipefail

namespace="${SRQL_FIXTURES_NAMESPACE:-srql-fixtures}"
cluster="${SRQL_FIXTURES_CLUSTER:-srql-fixture}"
database="${SRQL_FIXTURES_DATABASE:-srql_fixture}"
owner="${SRQL_FIXTURES_OWNER:-srql}"
admin_secret="${SRQL_FIXTURES_ADMIN_SECRET:-srql-test-admin-credentials}"

primary_pod="$(kubectl get pods -n "${namespace}" \
  -l "cnpg.io/cluster=${cluster},cnpg.io/instanceRole=primary" \
  -o jsonpath='{.items[0].metadata.name}')"

if [ -z "${primary_pod}" ]; then
  echo "No primary pod found for cluster ${cluster} in ${namespace}" >&2
  exit 1
fi

admin_user="$(kubectl get secret -n "${namespace}" "${admin_secret}" \
  -o jsonpath='{.data.username}' | base64 --decode)"
admin_password="$(kubectl get secret -n "${namespace}" "${admin_secret}" \
  -o jsonpath='{.data.password}' | base64 --decode)"

kubectl exec -n "${namespace}" "${primary_pod}" -- bash -lc \
  "PGSSLMODE=require PGPASSWORD='${admin_password}' \
   psql -h 127.0.0.1 -U '${admin_user}' -d postgres -v ON_ERROR_STOP=1 \
   -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${database}';\" \
   -c \"DROP DATABASE IF EXISTS ${database};\" \
   -c \"CREATE DATABASE ${database} OWNER ${owner};\""

kubectl exec -n "${namespace}" "${primary_pod}" -- bash -lc \
  "PGSSLMODE=require PGPASSWORD='${admin_password}' \
   psql -h 127.0.0.1 -U '${admin_user}' -d '${database}' -v ON_ERROR_STOP=1 \
   -c \"CREATE EXTENSION IF NOT EXISTS timescaledb;\" \
   -c \"CREATE EXTENSION IF NOT EXISTS age;\""

echo "Reset ${database} on ${cluster} (${namespace}) complete."
