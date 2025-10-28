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
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

: "${CORE_ADDRESS:?Set CORE_ADDRESS to the primary Core gRPC endpoint (host:port)}"
CONFIG_VOLUME="${CONFIG_VOLUME:-compose_poller-generated-config}"
POLLERS_AGENT_ADDRESS="${POLLERS_AGENT_ADDRESS:-agent:50051}"

echo "Using config volume: ${CONFIG_VOLUME}"
echo "Setting Core gRPC address to: ${CORE_ADDRESS}"
echo "Setting agent address to: ${POLLERS_AGENT_ADDRESS}"

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
| (.agents[]? |= (.address = \$agent | .security.mode = \"spiffe\"))
| .security.mode = \"spiffe\"
EOS
    jq --arg core '${CORE_ADDRESS}' --arg agent '${POLLERS_AGENT_ADDRESS}' \
      -f /tmp/update.jq /config/poller.json > /config/poller.json.tmp && \
    mv /config/poller.json.tmp /config/poller.json"

# Copy the nested SPIRE configuration template into the volume.
docker run --rm \
  -v "${CONFIG_VOLUME}:/config" \
  -v "${SCRIPT_DIR}/edge/poller-spire:/templates/poller-spire:ro" \
  alpine:3.20 sh -c 'mkdir -p /config/poller-spire && cp -RL /templates/poller-spire/. /config/poller-spire/'

echo "Edge poller configuration updated."
