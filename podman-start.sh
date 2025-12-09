#!/bin/bash
# ServiceRadar Podman Startup Script
# Uses podman directly to avoid podman-compose dependency handling issues

set -e

log() { echo "[$(date '+%H:%M:%S')] $1"; }

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo $0"
    exit 1
fi

cd "$(dirname "$0")"

# Configuration
NETWORK="serviceradar-net"
APP_TAG="${APP_TAG:-v1.0.65}"
CNPG_USER="${CNPG_USERNAME:-serviceradar}"
CNPG_PASS="${CNPG_PASSWORD:-serviceradar}"
CNPG_DB="${CNPG_DATABASE:-serviceradar}"

# Clean if requested
if [ "$1" = "--clean" ] || [ "$1" = "-c" ]; then
    log "Cleaning up..."
    podman stop -a 2>/dev/null || true
    podman rm -af 2>/dev/null || true
    podman volume prune -f 2>/dev/null || true
    podman network rm "$NETWORK" 2>/dev/null || true
    log "Cleanup complete"
fi

# Create network if needed
if ! podman network exists "$NETWORK" 2>/dev/null; then
    log "Creating network $NETWORK..."
    podman network create "$NETWORK"
fi

# Helper to run container
run_container() {
    local name=$1
    shift
    if podman ps -a --format "{{.Names}}" | grep -q "^${name}$"; then
        podman rm -f "$name" 2>/dev/null || true
    fi
    # --name and --network must come BEFORE other args
    podman run --name "$name" --network "$NETWORK" "$@"
}

log "=== Phase 1: Certificates ==="
run_container serviceradar-cert-generator \
    -v serviceradar_cert-data:/certs \
    -v "$(pwd)/docker/compose/generate-certs.sh:/generate-certs.sh:ro,z" \
    docker.io/library/alpine:3.20 \
    sh -c "apk add --no-cache openssl bash && CERT_DIR=/certs bash /generate-certs.sh"
log "Certificates generated"

log "=== Phase 2: Database ==="
run_container serviceradar-cnpg -d \
    -e POSTGRES_USER="$CNPG_USER" \
    -e POSTGRES_PASSWORD="$CNPG_PASS" \
    -e POSTGRES_DB="$CNPG_DB" \
    -v serviceradar_cnpg-data:/var/lib/postgresql/data \
    -v "$(pwd)/docker/compose/cnpg-init.sql:/docker-entrypoint-initdb.d/001-init.sql:ro,z" \
    -v serviceradar_cert-data:/etc/serviceradar/certs:ro \
    ghcr.io/carverauto/serviceradar-cnpg:16.6.0-sr2 \
    postgres -c shared_preload_libraries=timescaledb,age

log "Waiting for PostgreSQL..."
for i in {1..60}; do
    if podman exec serviceradar-cnpg pg_isready -U "$CNPG_USER" -d "$CNPG_DB" 2>/dev/null; then
        log "PostgreSQL is ready"
        break
    fi
    if [ $i -eq 60 ]; then
        log "ERROR: PostgreSQL failed to start. Check logs:"
        podman logs serviceradar-cnpg 2>&1 | tail -20
        exit 1
    fi
    [ $((i % 10)) -eq 0 ] && log "Still waiting for PostgreSQL... ($i/60)"
    sleep 2
done

log "=== Phase 3: Configuration ==="
run_container serviceradar-config-updater \
    -v serviceradar_cert-data:/etc/serviceradar/certs \
    -v serviceradar_generated-config:/etc/serviceradar/config \
    -v "$(pwd)/packaging/core/config:/config:ro,z" \
    -v "$(pwd)/docker/compose:/templates:ro,z" \
    -v "$(pwd)/docker/compose/update-config.sh:/usr/local/bin/update-config.sh:ro,z" \
    -e POLLERS_SECURITY_MODE=mtls \
    -e CORE_SECURITY_MODE=mtls \
    -e CNPG_HOST=serviceradar-cnpg \
    -e CNPG_PORT=5432 \
    -e CNPG_DATABASE="$CNPG_DB" \
    -e CNPG_USERNAME="$CNPG_USER" \
    -e CNPG_PASSWORD="$CNPG_PASS" \
    -e CNPG_SSL_MODE=disable \
    ghcr.io/carverauto/serviceradar-config-updater:${APP_TAG}
log "Config generated"

run_container serviceradar-cert-permissions-fixer \
    -v serviceradar_cert-data:/etc/serviceradar/certs \
    -v "$(pwd)/docker/compose/fix-cert-permissions.sh:/fix-cert-permissions.sh:ro,z" \
    docker.io/library/alpine:3.20 \
    sh /fix-cert-permissions.sh
log "Cert permissions fixed"

# JWKS generation - may fail due to CLI bug, Kong JWT validation optional
if ! run_container serviceradar-core-jwks-init \
    -v serviceradar_generated-config:/etc/serviceradar/config \
    ghcr.io/carverauto/serviceradar-kong-config:${APP_TAG} \
    /usr/local/bin/serviceradar-cli generate-jwt-keys -file /etc/serviceradar/config/core.json -bits 2048; then
    log "WARNING: JWKS generation failed (known CLI bug). Kong JWT validation will use HS256 fallback."
fi
log "JWKS step complete"

log "=== Phase 4: Messaging ==="
run_container serviceradar-nats -d \
    -p 4222:4222 -p 8222:8222 -p 6222:6222 \
    -v serviceradar_nats-data:/data \
    -v serviceradar_cert-data:/etc/serviceradar/certs:ro \
    -v "$(pwd)/docker/compose/nats.docker.conf:/etc/nats/nats-server.conf:ro,z" \
    docker.io/library/nats:latest \
    --config /etc/nats/nats-server.conf
sleep 3
log "NATS started"

log "=== Phase 5: Data Services ==="
run_container serviceradar-datasvc -d \
    -p 50057:50057 \
    -v "$(pwd)/docker/compose/datasvc.mtls.json:/etc/serviceradar/datasvc.json:ro,z" \
    -v serviceradar_cert-data:/etc/serviceradar/certs:ro \
    -v serviceradar_datasvc-data:/var/lib/serviceradar \
    -e CONFIG_PATH=/etc/serviceradar/datasvc.json \
    -e LOG_LEVEL=info \
    ghcr.io/carverauto/serviceradar-datasvc:${APP_TAG}
sleep 5
log "DataSvc started"

log "=== Phase 6: Core ==="
run_container serviceradar-core -d \
    -p 8090:8090 -p 50052:50052 -p 9090:9090 \
    -v serviceradar_generated-config:/etc/serviceradar/config:ro \
    -v serviceradar_cert-data:/etc/serviceradar/certs:ro \
    -v serviceradar_core-data:/var/lib/serviceradar \
    -e CONFIG_SOURCE=file \
    -e CONFIG_PATH=/etc/serviceradar/config/core.json \
    -e CNPG_HOST=serviceradar-cnpg \
    -e CNPG_PORT=5432 \
    -e CNPG_DATABASE="$CNPG_DB" \
    -e CNPG_USERNAME="$CNPG_USER" \
    -e CNPG_PASSWORD="$CNPG_PASS" \
    -e CNPG_SSL_MODE=disable \
    -e KV_ADDRESS=serviceradar-datasvc:50057 \
    -e KV_SEC_MODE=mtls \
    -e KV_CERT_DIR=/etc/serviceradar/certs \
    ghcr.io/carverauto/serviceradar-core:${APP_TAG}
sleep 8
log "Core started"

run_container serviceradar-srql -d \
    -v serviceradar_cert-data:/etc/serviceradar/certs:ro \
    -e SRQL_LISTEN_HOST=0.0.0.0 \
    -e SRQL_LISTEN_PORT=8080 \
    -e CNPG_HOST=serviceradar-cnpg \
    -e CNPG_PORT=5432 \
    -e CNPG_DATABASE="$CNPG_DB" \
    -e CNPG_USERNAME="$CNPG_USER" \
    -e CNPG_PASSWORD="$CNPG_PASS" \
    -e CNPG_SSLMODE=disable \
    ghcr.io/carverauto/serviceradar-srql:${APP_TAG}
sleep 3
log "SRQL started"

log "=== Phase 7: API Gateway ==="
run_container serviceradar-kong-config \
    -v serviceradar_kong-config:/out \
    ghcr.io/carverauto/serviceradar-kong-config:${APP_TAG} \
    /usr/local/bin/serviceradar-cli render-kong \
    --jwks http://serviceradar-core:8090/auth/jwks.json \
    --service http://serviceradar-core:8090 \
    --path /api \
    --srql-service http://serviceradar-srql:8080 \
    --srql-path /api/query \
    --out /out/kong.yml
log "Kong config generated"

run_container serviceradar-kong -d \
    -p 8000:8000 -p 8001:8001 \
    -v serviceradar_kong-config:/opt/kong \
    -v "$(pwd)/docker/kong/kong.yaml:/default-kong.yml:ro,z" \
    -e KONG_DATABASE=off \
    -e KONG_DECLARATIVE_CONFIG=/opt/kong/kong.yml \
    -e KONG_PROXY_LISTEN="0.0.0.0:8000, 0.0.0.0:8443 ssl" \
    -e KONG_ADMIN_LISTEN=0.0.0.0:8001 \
    -e KONG_NGINX_DAEMON=off \
    docker.io/library/kong:latest \
    sh -lc "until [ -f /opt/kong/kong.yml ]; do sleep 2; done; kong start"
sleep 5
log "Kong started"

log "=== Phase 8: Services ==="
run_container serviceradar-agent -d \
    --privileged \
    -v "$(pwd)/docker/compose/agent.mtls.json:/etc/serviceradar/agent.json:ro,z" \
    -v serviceradar_cert-data:/etc/serviceradar/certs:ro \
    -v serviceradar_agent-data:/var/lib/serviceradar \
    -e CONFIG_SOURCE=file \
    -e CONFIG_PATH=/etc/serviceradar/agent.json \
    ghcr.io/carverauto/serviceradar-agent:${APP_TAG}

run_container serviceradar-poller -d \
    -v serviceradar_cert-data:/etc/serviceradar/certs:ro \
    -v serviceradar_generated-config:/etc/serviceradar/config:ro \
    -v serviceradar_poller-data:/var/lib/serviceradar \
    -e CONFIG_SOURCE=file \
    -e CONFIG_PATH=/etc/serviceradar/config/poller.json \
    -e CORE_ADDRESS=serviceradar-core:50052 \
    -e CORE_SEC_MODE=mtls \
    -e CORE_CERT_DIR=/etc/serviceradar/certs \
    -e KV_ADDRESS=serviceradar-datasvc:50057 \
    -e KV_SEC_MODE=mtls \
    -e KV_CERT_DIR=/etc/serviceradar/certs \
    -e POLLERS_SECURITY_MODE=mtls \
    ghcr.io/carverauto/serviceradar-poller:${APP_TAG}

run_container serviceradar-sync -d \
    -p 50058:50058 \
    -v "$(pwd)/docker/compose/sync.mtls.json:/etc/serviceradar/sync.json:ro,z" \
    -v serviceradar_cert-data:/etc/serviceradar/certs:ro \
    -e CONFIG_SOURCE=file \
    -e CONFIG_PATH=/etc/serviceradar/sync.json \
    ghcr.io/carverauto/serviceradar-sync:${APP_TAG}

sleep 5
log "Core services started"

log "=== Phase 9: Frontend ==="
run_container serviceradar-web -d \
    -v serviceradar_cert-data:/etc/serviceradar/certs:ro \
    -v serviceradar_generated-config:/etc/serviceradar/config:ro \
    -e NODE_ENV=production \
    -e NEXT_PUBLIC_API_URL=http://localhost/api \
    -e NEXT_INTERNAL_API_URL=http://serviceradar-core:8090 \
    -e NEXT_INTERNAL_SRQL_URL=http://serviceradar-kong:8000 \
    -e AUTH_ENABLED=true \
    ghcr.io/carverauto/serviceradar-web:${APP_TAG}
sleep 3

run_container serviceradar-nginx -d \
    -p 80:80 \
    -v serviceradar_cert-data:/etc/serviceradar/certs:ro \
    -v "$(pwd)/docker/compose/nginx.conf.template:/etc/nginx/templates/default.conf.template:ro,z" \
    -v "$(pwd)/docker/compose/entrypoint-nginx.sh:/docker-entrypoint.d/50-serviceradar.sh:ro,z" \
    -e API_UPSTREAM=http://serviceradar-kong:8000 \
    ghcr.io/carverauto/serviceradar-nginx:latest
sleep 2
log "Frontend started"

log ""
log "=== Startup Complete ==="
log ""
log "Container Status:"
podman ps --format "table {{.Names}}\t{{.Status}}" | grep serviceradar | head -20
log ""
log "Admin Credentials:"
podman logs serviceradar-config-updater 2>&1 | grep -E "(Username|Password)" || echo "Check: sudo podman logs serviceradar-config-updater"
log ""
log "Access ServiceRadar at: http://localhost"
