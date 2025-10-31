#!/usr/bin/env bash
set -euo pipefail

# This helper reconfigures the generated poller configuration so the edge
# deployment can talk to the primary SPIRE/Core services running in the
# Kubernetes cluster.
#
# Preconditions:
#   1. Run the config-updater job (from poller-stack.compose.yml) so certs and
#      baseline configs are generated in the compose_poller-generated-config volume.
#   2. Populate docker/compose/spire/ with upstream credentials
#      (upstream-join-token, upstream-bundle.pem).
#
# Usage:
#   CORE_ADDRESS=23.138.124.18:50052 ./setup-edge-poller.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

: "${CORE_ADDRESS:?Set CORE_ADDRESS to the primary Core gRPC endpoint (host:port)}"
KV_ADDRESS="${KV_ADDRESS:-}"
CONFIG_VOLUME="${CONFIG_VOLUME:-compose_poller-generated-config}"
POLLERS_AGENT_ADDRESS="${POLLERS_AGENT_ADDRESS:-agent:50051}"
AGENT_CONFIG_SOURCE="${AGENT_CONFIG_SOURCE:-${REPO_ROOT}/docker/compose/agent.docker.json}"
UPSTREAM_ADDRESS="${SPIRE_UPSTREAM_ADDRESS:-${POLLERS_SPIRE_UPSTREAM_ADDRESS:-host.docker.internal}}"
UPSTREAM_PORT="${SPIRE_UPSTREAM_PORT:-${POLLERS_SPIRE_UPSTREAM_PORT:-18081}}"
TRUST_DOMAIN="${POLLERS_TRUST_DOMAIN:-carverauto.dev}"
POLLERS_SPIRE_PARENT_ID="${POLLERS_SPIRE_PARENT_ID:-spiffe://carverauto.dev/ns/edge/poller-nested-spire}"
CORE_SPIFFE_ID="${CORE_SPIFFE_ID:-${POLLERS_CORE_SPIFFE_ID:-spiffe://carverauto.dev/ns/demo/sa/serviceradar-core}}"
WORKLOAD_SOCKET_RAW="${NESTED_SPIRE_WORKLOAD_SOCKET:-/run/spire/nested/workload/agent.sock}"
if [[ "${WORKLOAD_SOCKET_RAW}" == unix:* ]]; then
  WORKLOAD_SOCKET="${WORKLOAD_SOCKET_RAW}"
else
  WORKLOAD_SOCKET="unix:${WORKLOAD_SOCKET_RAW}"
fi
KV_SPIFFE_ID="${KV_SPIFFE_ID:-spiffe://carverauto.dev/ns/demo/sa/serviceradar-datasvc}"
if [ -z "${AGENT_SPIFFE_ID:-}" ] && [ -n "${NESTED_SPIRE_AGENT_SPIFFE_ID:-}" ]; then
  AGENT_SPIFFE_ID="${NESTED_SPIRE_AGENT_SPIFFE_ID}"
fi
AGENT_SPIFFE_ID="${AGENT_SPIFFE_ID:-spiffe://carverauto.dev/services/agent}"
if [ -z "${POLLERS_SPIRE_DOWNSTREAM_SPIFFE_ID:-}" ] && [ -n "${NESTED_SPIRE_DOWNSTREAM_SPIFFE_ID:-}" ]; then
  POLLERS_SPIRE_DOWNSTREAM_SPIFFE_ID="${NESTED_SPIRE_DOWNSTREAM_SPIFFE_ID}"
fi
POLLER_ID="${POLLERS_POLLER_ID:-${EDGE_PACKAGE_ID:-}}"

echo "Using config volume: ${CONFIG_VOLUME}"
echo "Setting Core gRPC address to: ${CORE_ADDRESS}"
echo "Setting agent address to: ${POLLERS_AGENT_ADDRESS}"
if [ -n "${KV_ADDRESS}" ]; then
  echo "Setting KV gRPC address to: ${KV_ADDRESS}"
else
  echo "KV_ADDRESS not provided; skipping KV gRPC rewrite and leaving KV disabled"
fi
echo "Setting SPIRE upstream to: ${UPSTREAM_ADDRESS}:${UPSTREAM_PORT}"
echo "Trust domain: ${TRUST_DOMAIN}"
echo "Expecting Core SPIFFE ID: ${CORE_SPIFFE_ID}"
echo "Nested SPIRE parent: ${POLLERS_SPIRE_PARENT_ID}"
if [ -n "${POLLERS_SPIRE_DOWNSTREAM_SPIFFE_ID:-}" ]; then
  echo "Nested poller SPIFFE ID: ${POLLERS_SPIRE_DOWNSTREAM_SPIFFE_ID}"
fi
if [ -n "${AGENT_SPIFFE_ID:-}" ]; then
  echo "Nested agent SPIFFE ID: ${AGENT_SPIFFE_ID}"
fi

# Derive an agent identifier from configuration if one was not supplied.
AGENT_ID="${AGENT_ID:-}"
if [ -z "${AGENT_ID}" ] && [ -n "${POLLERS_SPIRE_DOWNSTREAM_SPIFFE_ID:-}" ]; then
  candidate="${POLLERS_SPIRE_DOWNSTREAM_SPIFFE_ID##*/}"
  candidate="${candidate%%\?*}"
  if [ -n "${candidate}" ]; then
    AGENT_ID="${candidate}"
  fi
fi
if [ -n "${AGENT_ID}" ]; then
  echo "Setting agent ID to: ${AGENT_ID}"
else
  echo "Agent ID not provided; leaving template default"
fi

# Copy the SPIFFE poller template into the generated config volume.
docker run --rm \
  -v "${CONFIG_VOLUME}:/config" \
  -v "${SCRIPT_DIR}/poller.spiffe.json:/tmp/poller.json:ro" \
  alpine:3.20 sh -c 'cp /tmp/poller.json /config/poller.json'

# Update the core address and agent endpoint.
docker run --rm \
  -v "${CONFIG_VOLUME}:/config" \
  alpine:3.20 sh -c "apk add --no-cache jq >/dev/null && \
    cat <<'EOS' >/tmp/update.jq
.core_address = \$core
| (.agents[]? |= (.address = \$agent | .security.mode = \"spiffe\"
    | .security.server_spiffe_id = \$agent_spiffe
    | .checks[]? |= (if .service_name == \"kv\" then .details = \$kv else . end)))
| .security.mode = \"spiffe\"
| .security.server_spiffe_id = \$core_spiffe
| (if \$poller_id != \"\" then .poller_id = \$poller_id else . end)
EOS
    jq --arg core '${CORE_ADDRESS}' \
      --arg agent '${POLLERS_AGENT_ADDRESS}' \
      --arg kv '${KV_ADDRESS}' \
      --arg core_spiffe '${CORE_SPIFFE_ID}' \
      --arg agent_spiffe '${AGENT_SPIFFE_ID}' \
      --arg poller_id '${POLLER_ID}' \
      -f /tmp/update.jq /config/poller.json > /config/poller.json.tmp && \
    mv /config/poller.json.tmp /config/poller.json"

# Copy the agent template into the generated config volume.
docker run --rm \
  -v "${CONFIG_VOLUME}:/config" \
  -v "${AGENT_CONFIG_SOURCE}:/tmp/agent.json:ro" \
  alpine:3.20 sh -c 'cat /tmp/agent.json >/config/agent.json'

docker run --rm \
  -v "${CONFIG_VOLUME}:/config" \
  alpine:3.20 sh -c "apk add --no-cache jq >/dev/null && \
    cat <<'EOS' >/tmp/update-agent.jq
.security.mode = \"spiffe\"
| .security.trust_domain = \$trust
| .security.workload_socket = \$socket
| .security.server_spiffe_id = \$agent_spiffe
| (if \$agent_id != \"\" then .agent_id = \$agent_id else . end)
EOS
    jq --arg trust '${TRUST_DOMAIN}' \
      --arg socket '${WORKLOAD_SOCKET}' \
      --arg agent_spiffe '${AGENT_SPIFFE_ID}' \
      --arg agent_id '${AGENT_ID}' \
      -f /tmp/update-agent.jq /config/agent.json > /config/agent.json.tmp && \
    mv /config/agent.json.tmp /config/agent.json"

if [ -n "${KV_ADDRESS}" ]; then
  docker run --rm \
    -v "${CONFIG_VOLUME}:/config" \
    alpine:3.20 sh -c "apk add --no-cache jq >/dev/null && \
      cat <<'EOS' >/tmp/update-agent-kv.jq
.kv_address = \$kv
| .kv_security.mode = \"spiffe\"
| .kv_security.server_name = \"\"
| .kv_security.trust_domain = \$trust
| .kv_security.workload_socket = \$socket
| .kv_security.server_spiffe_id = \$kv_spiffe
EOS
      jq --arg kv '${KV_ADDRESS}' \
        --arg trust '${TRUST_DOMAIN}' \
        --arg socket '${WORKLOAD_SOCKET}' \
        --arg kv_spiffe '${KV_SPIFFE_ID}' \
        -f /tmp/update-agent-kv.jq /config/agent.json > /config/agent.json.tmp && \
      mv /config/agent.json.tmp /config/agent.json"
else
  docker run --rm \
    -v "${CONFIG_VOLUME}:/config" \
    alpine:3.20 sh -c "apk add --no-cache jq >/dev/null && \
      jq 'del(.kv_address, .kv_security)' /config/agent.json > /config/agent.json.tmp && \
      mv /config/agent.json.tmp /config/agent.json"
  echo "Pruning optional agent checkers for edge profile (KV disabled)"
  docker run --rm \
    -v "${CONFIG_VOLUME}:/config" \
    alpine:3.20 sh -c "rm -f /config/checkers/sysmon-vm.json /config/checkers/sweep/sweep.json && \
      if [ -d /config/checkers/sweep ]; then find /config/checkers/sweep -mindepth 1 -delete && rmdir /config/checkers/sweep 2>/dev/null || true; fi"
fi

# Copy the nested SPIRE configuration template into the volume.
docker run --rm \
  -v "${CONFIG_VOLUME}:/config" \
  -v "${SCRIPT_DIR}/edge/poller-spire:/templates/poller-spire:ro" \
  alpine:3.20 sh -c 'mkdir -p /config/poller-spire && cp -RL /templates/poller-spire/. /config/poller-spire/'

# Refresh the nested SPIRE environment overrides so entrypoint aligns with package SVIDs.
docker run --rm \
  -e TRUST_DOMAIN="${TRUST_DOMAIN}" \
  -e PARENT_ID="${POLLERS_SPIRE_PARENT_ID}" \
  -e DOWNSTREAM_ID="${POLLERS_SPIRE_DOWNSTREAM_SPIFFE_ID}" \
  -e AGENT_ID="${AGENT_SPIFFE_ID}" \
  -v "${CONFIG_VOLUME}:/config" \
  alpine:3.20 sh -c 'set -eu
tmp_env="/config/poller-spire/env.tmp"
{
  printf "POLLERS_TRUST_DOMAIN=\"%s\"\n" "${TRUST_DOMAIN}"
  printf "NESTED_SPIRE_PARENT_ID=\"%s\"\n" "${PARENT_ID}"
  if [ -n "${DOWNSTREAM_ID}" ]; then
    printf "NESTED_SPIRE_DOWNSTREAM_SPIFFE_ID=\"%s\"\n" "${DOWNSTREAM_ID}"
  fi
  if [ -n "${AGENT_ID}" ]; then
    printf "NESTED_SPIRE_AGENT_SPIFFE_ID=\"%s\"\n" "${AGENT_ID}"
  fi
  printf "NESTED_SPIRE_SERVER_SOCKET=\"/run/spire/nested/server/api.sock\"\n"
} >"${tmp_env}"
mv "${tmp_env}" /config/poller-spire/env'

# Update upstream SPIRE connection details.
docker run --rm \
  -v "${CONFIG_VOLUME}:/config" \
  alpine:3.20 sh -c "sed -i \
      -e 's/server_address = \".*\"/server_address = \"${UPSTREAM_ADDRESS}\"/' \
      -e 's/server_port = \".*\"/server_port = \"${UPSTREAM_PORT}\"/' \
      /config/poller-spire/upstream-agent.conf && \
    sed -i \
      -e 's/server_address = \".*\"/server_address = \"${UPSTREAM_ADDRESS}\"/' \
      -e 's/server_port = \".*\"/server_port = \"${UPSTREAM_PORT}\"/' \
      /config/poller-spire/server.conf"

echo "Edge poller configuration updated."
