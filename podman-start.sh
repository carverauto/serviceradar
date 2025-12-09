#!/bin/bash
# ServiceRadar Podman Startup Script
# Handles dependency ordering that podman-compose doesn't support well

set -e

PC="/usr/local/bin/podman-compose"
COMPOSE_FILE="docker-compose.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARNING:${NC} $1"; }
error() { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $1"; }

wait_for_container_exit() {
    local container=$1
    local timeout=${2:-60}
    local count=0
    log "Waiting for $container to complete..."
    while [ $count -lt $timeout ]; do
        # Try exact name first, then pattern match
        status=$(podman inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "not_found")
        if [ "$status" = "not_found" ]; then
            # Try to find container by pattern
            actual_name=$(podman ps -a --format "{{.Names}}" | grep -E "${container}|${container//-/_}" | head -1)
            if [ -n "$actual_name" ]; then
                container="$actual_name"
                status=$(podman inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "not_found")
            fi
        fi
        if [ "$status" = "exited" ]; then
            exit_code=$(podman inspect --format '{{.State.ExitCode}}' "$container" 2>/dev/null || echo "1")
            if [ "$exit_code" = "0" ]; then
                log "$container completed successfully"
                return 0
            else
                error "$container failed with exit code $exit_code"
                podman logs "$container" 2>&1 | tail -20
                return 1
            fi
        elif [ "$status" = "not_found" ]; then
            sleep 1
            ((count++))
            continue
        fi
        sleep 1
        ((count++))
    done
    error "$container timed out after ${timeout}s"
    # Show what containers exist for debugging
    log "Available containers:"
    podman ps -a --format "{{.Names}} {{.Status}}" | head -10
    return 1
}

wait_for_container_healthy() {
    local container=$1
    local timeout=${2:-120}
    local count=0
    log "Waiting for $container to be healthy..."
    while [ $count -lt $timeout ]; do
        health=$(podman inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")
        status=$(podman inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "not_found")
        if [ "$health" = "healthy" ]; then
            log "$container is healthy"
            return 0
        elif [ "$status" = "exited" ]; then
            error "$container exited unexpectedly"
            podman logs "$container" | tail -20
            return 1
        fi
        sleep 2
        ((count+=2))
    done
    warn "$container health check timed out, continuing anyway..."
    return 0
}

wait_for_container_running() {
    local container=$1
    local timeout=${2:-30}
    local count=0
    log "Waiting for $container to start..."
    while [ $count -lt $timeout ]; do
        status=$(podman inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "not_found")
        if [ "$status" = "running" ]; then
            log "$container is running"
            return 0
        elif [ "$status" = "exited" ]; then
            exit_code=$(podman inspect --format '{{.State.ExitCode}}' "$container" 2>/dev/null || echo "1")
            if [ "$exit_code" = "0" ]; then
                log "$container completed (one-shot)"
                return 0
            else
                error "$container failed"
                podman logs "$container" | tail -20
                return 1
            fi
        fi
        sleep 1
        ((count++))
    done
    error "$container failed to start within ${timeout}s"
    return 1
}

start_service() {
    local service=$1
    log "Starting $service..."
    $PC up -d "$service" 2>/dev/null || true
}

# Main startup sequence
main() {
    log "ServiceRadar Podman Startup"
    log "==========================="

    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        error "Please run as root (sudo $0)"
        exit 1
    fi

    cd "$(dirname "$0")"

    # Phase 0: Cleanup if requested
    if [ "$1" = "--clean" ] || [ "$1" = "-c" ]; then
        log "Cleaning up existing containers and volumes..."
        $PC down -v 2>/dev/null || true
        podman rm -af 2>/dev/null || true
        podman volume prune -f 2>/dev/null || true
        log "Cleanup complete"
    fi

    # Phase 1: Certificate Generation
    log ""
    log "Phase 1: Certificate Generation"
    log "--------------------------------"
    start_service cert-generator
    wait_for_container_exit serviceradar-cert-generator-mtls 120

    # Phase 2: Database
    log ""
    log "Phase 2: Database Startup"
    log "-------------------------"
    start_service cnpg
    wait_for_container_healthy serviceradar-cnpg-mtls 120

    # Phase 3: Config Generation
    log ""
    log "Phase 3: Configuration"
    log "----------------------"
    start_service config-updater
    wait_for_container_exit serviceradar-config-updater-mtls 60

    start_service core-jwks-init
    wait_for_container_exit serviceradar-core-jwks-init-mtls 30

    start_service cert-permissions-fixer
    wait_for_container_exit serviceradar-cert-permissions-fixer-mtls 30

    # Phase 4: Messaging
    log ""
    log "Phase 4: Messaging Layer"
    log "------------------------"
    start_service nats
    wait_for_container_running serviceradar-nats-mtls 30
    sleep 3  # Give NATS time to initialize

    # Phase 5: Data Services
    log ""
    log "Phase 5: Data Services"
    log "----------------------"
    start_service datasvc
    wait_for_container_healthy serviceradar-datasvc-mtls 60

    start_service poller-kv-seed
    wait_for_container_exit serviceradar-poller-kv-seed-mtls 60

    # Phase 6: Core Services
    log ""
    log "Phase 6: Core Services"
    log "----------------------"
    start_service core
    wait_for_container_running serviceradar-core-mtls 30
    sleep 5  # Give core time to initialize

    start_service srql
    wait_for_container_running serviceradar-srql-mtls 30

    # Phase 7: API Gateway
    log ""
    log "Phase 7: API Gateway"
    log "--------------------"
    start_service kong-config
    wait_for_container_exit serviceradar-kong-config-mtls 60

    start_service kong
    wait_for_container_healthy serviceradar-kong-mtls 60

    # Phase 8: Remaining Services (can start in parallel)
    log ""
    log "Phase 8: Remaining Services"
    log "---------------------------"

    # Monitoring services
    for svc in agent poller sync otel flowgger trapd zen db-event-writer mapper; do
        start_service $svc
    done
    sleep 5

    # Checkers
    for svc in snmp-checker rperf-client; do
        start_service $svc
    done
    sleep 3

    # Frontend
    log ""
    log "Phase 9: Frontend"
    log "-----------------"
    start_service web
    wait_for_container_running serviceradar-web-mtls 30

    start_service nginx
    wait_for_container_running serviceradar-nginx-mtls 30

    # Done
    log ""
    log "==========================="
    log "Startup Complete!"
    log "==========================="
    log ""
    log "Getting admin credentials..."
    sleep 2
    podman logs serviceradar-config-updater-mtls 2>&1 | grep -E "(Username|Password)" || warn "Could not retrieve credentials"
    log ""
    log "Access ServiceRadar at: http://localhost"
    log ""
    log "Check status with: sudo podman ps"
}

main "$@"
