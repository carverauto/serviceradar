# ServiceRadar tools shell customizations

export PS1='\u@serviceradar-tools:\w\$ '
export TERM=${TERM:-xterm-256color}
if [ -d /usr/glibc-compat/lib ]; then
    export LD_LIBRARY_PATH="/usr/glibc-compat/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
if [ -d /usr/glibc-compat/lib64 ]; then
    export LD_LIBRARY_PATH="/usr/glibc-compat/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
export PROTON_HOST=${PROTON_HOST:-serviceradar-proton}
export PROTON_PORT=${PROTON_PORT:-9440}
export PROTON_DATABASE=${PROTON_DATABASE:-default}
export PROTON_SECURE=${PROTON_SECURE:-1}
if [ -f /etc/serviceradar/credentials/proton-password ]; then
    export PROTON_PASSWORD_FILE=${PROTON_PASSWORD_FILE:-/etc/serviceradar/credentials/proton-password}
fi
export NATS_HOST=${NATS_HOST:-serviceradar-nats}
export NATS_CA=${NATS_CA:-/etc/serviceradar/certs/root.pem}
export NATS_CERT=${NATS_CERT:-/etc/serviceradar/certs/client.pem}
export NATS_KEY=${NATS_KEY:-/etc/serviceradar/certs/client-key.pem}
export NATS_CONTEXT=${NATS_CONTEXT:-serviceradar}
unset NATS_URL

alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

alias nats-info='nats server info'
alias nats-streams='nats stream ls'
alias nats-consumers='nats consumer ls'
alias nats-events='nats stream info events'
alias nats-kv='nats stream info KV_serviceradar-datasvc'
alias nats-kv='nats stream info KV_serviceradar-datasvc'
alias nats-datasvc='nats stream info KV_serviceradar-datasvc'
alias nats-cert-check='echo "=== NATS Certificate Check ==="; echo "1. Client certificate:"; openssl x509 -in /etc/serviceradar/certs/client.pem -subject -issuer -noout; echo ""; echo "2. Root CA:"; openssl x509 -in /etc/serviceradar/certs/root.pem -subject -issuer -noout; echo ""; echo "3. Testing NATS without client cert:"; timeout 5 openssl s_client -connect serviceradar-nats:4222 -CAfile /etc/serviceradar/certs/root.pem -verify_return_error </dev/null 2>/dev/null || echo "  ✗ Server cert verification failed"; echo ""; echo "4. Testing NATS with client cert:"; timeout 5 openssl s_client -connect serviceradar-nats:4222 -CAfile /etc/serviceradar/certs/root.pem -cert /etc/serviceradar/certs/client.pem -key /etc/serviceradar/certs/client-key.pem -verify_return_error </dev/null 2>/dev/null || echo "  ✗ mTLS verification failed"'

alias grpc-core='grpcurl -cacert /etc/serviceradar/certs/root.pem -cert /etc/serviceradar/certs/client.pem -key /etc/serviceradar/certs/client-key.pem serviceradar-core:50052'
alias grpc-agent='grpcurl -cacert /etc/serviceradar/certs/root.pem -cert /etc/serviceradar/certs/client.pem -key /etc/serviceradar/certs/client-key.pem serviceradar-agent:50051'
alias grpc-poller='grpcurl -cacert /etc/serviceradar/certs/root.pem -cert /etc/serviceradar/certs/client.pem -key /etc/serviceradar/certs/client-key.pem serviceradar-poller:50053'
alias grpc-datasvc='grpcurl -cacert /etc/serviceradar/certs/root.pem -cert /etc/serviceradar/certs/client.pem -key /etc/serviceradar/certs/client-key.pem serviceradar-datasvc:50057'
alias grpc-mapper='grpcurl -cacert /etc/serviceradar/certs/root.pem -cert /etc/serviceradar/certs/client.pem -key /etc/serviceradar/certs/client-key.pem serviceradar-mapper:50056'
alias grpc-trapd='grpcurl -cacert /etc/serviceradar/certs/root.pem -cert /etc/serviceradar/certs/client.pem -key /etc/serviceradar/certs/client-key.pem serviceradar-trapd:50043'

alias sr='serviceradar-cli'
alias sr-devices='serviceradar-cli devices list'
alias sr-events='serviceradar-cli events list'

alias proton-cli='proton-client'
alias proton-cli-tls='PROTON_SECURE=1 PROTON_CONFIG=/etc/serviceradar/proton-client/config.xml proton-client'
alias proton-bin='/usr/local/bin/proton.bin'
alias proton-version='proton-client --query "SELECT version()"'
alias proton-shell='proton-client'

proton_info() {
    echo "Proton target:"
    echo "  host: ${PROTON_HOST:-serviceradar-proton}"
    echo "  port: ${PROTON_PORT:-9440}"
    echo "  database: ${PROTON_DATABASE:-default}"
    if [ -n "${PROTON_PASSWORD_FILE:-}" ]; then
        echo "  password file: ${PROTON_PASSWORD_FILE}"
    elif [ -n "${PROTON_PASSWORD:-}" ]; then
        echo "  password: (set via PROTON_PASSWORD env)"
    else
        echo "  password: <not set>"
    fi
}

proton_sql() {
    # Usage: proton_sql SELECT count() FROM table(unified_devices)
    query="$*"
    if [ -z "$query" ]; then
        echo "Usage: proton_sql <SQL...>" >&2
        return 1
    fi
    PROTON_SECURE=${PROTON_SECURE:-1} \
    PROTON_CONFIG=${PROTON_CONFIG:-/etc/serviceradar/proton-client/config.xml} \
    proton-client --query "$query"
}

alias ping-nats='ping -c 3 serviceradar-nats'
alias ping-core='ping -c 3 serviceradar-core'
alias telnet-nats='telnet serviceradar-nats 4222'
alias nc-nats='nc -zv serviceradar-nats 4222'

test_connectivity() {
    echo "=== ServiceRadar Service Connectivity Test ==="
    echo "Testing NATS..."
    nc -zv serviceradar-nats 4222 || echo "  NATS connection failed"
    echo "Testing Core API..."
    nc -zv serviceradar-core 8090 || echo "  Core API connection failed"
    echo "Testing Core gRPC..."
    nc -zv serviceradar-core 50052 || echo "  Core gRPC connection failed"
    echo "Testing Proton..."
    nc -zv serviceradar-proton 9440 || echo "  Proton TLS connection failed"
    nc -zv serviceradar-proton 8123 || echo "  Proton HTTP connection failed"
}

nats_js_status() {
    echo "=== NATS JetStream Status ==="
    nats server info --json | jq '.jetstream // "JetStream not available"'
    echo
    echo "=== Streams ==="
    nats stream ls
    echo
    echo "=== Events Stream Info ==="
    nats stream info events 2>/dev/null || echo "Events stream not found"
}

test_grpc() {
    echo "=== gRPC Service Health Checks ==="
    for service in core:50052 agent:50051 poller:50053 kv:50057 mapper:50056 trapd:50043; do
        host="${service%%:*}"
        port="${service##*:}"
        echo "Testing serviceradar-${service}..."
        if grpcurl -cacert /etc/serviceradar/certs/root.pem \
                -cert /etc/serviceradar/certs/client.pem \
                -key /etc/serviceradar/certs/client-key.pem \
                "serviceradar-${service}" grpc.health.v1.Health/Check >/dev/null 2>&1; then
            echo "  ✓ Healthy"
        else
            echo "  ✗ Unhealthy"
        fi
    done
}
