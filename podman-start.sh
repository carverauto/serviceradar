#!/bin/bash
# ServiceRadar Podman Startup Script
# Simple sequential startup to handle podman-compose dependency limitations

set -e

# Use podman-specific compose file without condition requirements
COMPOSE_FILE="docker-compose.podman.yml"
PC="/usr/local/bin/podman-compose -f $COMPOSE_FILE"

log() { echo "[$(date '+%H:%M:%S')] $1"; }

# Check root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo $0"
    exit 1
fi

cd "$(dirname "$0")"

# Generate podman-compatible compose file (removes condition requirements)
log "Generating Podman-compatible compose file..."
grep -v "condition:" docker-compose.yml > "$COMPOSE_FILE"

# Clean if requested
if [ "$1" = "--clean" ] || [ "$1" = "-c" ]; then
    log "Cleaning up..."
    $PC down -v 2>/dev/null || true
    podman rm -af 2>/dev/null || true
    podman volume prune -f 2>/dev/null || true
    log "Cleanup complete"
fi

log "=== Phase 1: Certificates ==="
$PC up -d cert-generator
log "Waiting for cert generation..."
sleep 10
# Wait for it to exit
for i in {1..30}; do
    if ! podman ps --format "{{.Names}}" | grep -q cert-generator; then
        log "Cert generator completed"
        break
    fi
    sleep 2
done

log "=== Phase 2: Database ==="
$PC up -d cnpg
log "Waiting for PostgreSQL to initialize..."
sleep 20
# Wait for healthy
for i in {1..30}; do
    if podman exec serviceradar-cnpg-mtls pg_isready -U serviceradar 2>/dev/null; then
        log "PostgreSQL is ready"
        break
    fi
    sleep 3
done

log "=== Phase 3: Configuration ==="
$PC up -d config-updater
sleep 8
$PC up -d core-jwks-init
sleep 5
$PC up -d cert-permissions-fixer
sleep 3

log "=== Phase 4: Messaging ==="
$PC up -d nats
sleep 5

log "=== Phase 5: Data Services ==="
$PC up -d datasvc
sleep 10
$PC up -d poller-kv-seed
sleep 5

log "=== Phase 6: Core ==="
$PC up -d core
sleep 10
$PC up -d srql
sleep 5

log "=== Phase 7: API Gateway ==="
$PC up -d kong-config
sleep 10
$PC up -d kong
sleep 10

log "=== Phase 8: Services ==="
$PC up -d agent poller sync otel flowgger trapd zen db-event-writer mapper
sleep 10
$PC up -d snmp-checker rperf-client
sleep 5

log "=== Phase 9: Frontend ==="
$PC up -d web
sleep 5
$PC up -d nginx
sleep 3

log "=== Startup Complete ==="
log ""
log "Container Status:"
podman ps --format "table {{.Names}}\t{{.Status}}" | head -30
log ""
log "Admin Credentials:"
podman logs serviceradar-config-updater-mtls 2>&1 | grep -E "(Username|Password)" || echo "Check: sudo podman logs serviceradar-config-updater-mtls"
log ""
log "Access ServiceRadar at: http://localhost"
