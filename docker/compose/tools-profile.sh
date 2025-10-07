# ServiceRadar tools shell customizations

export PS1='\u@serviceradar-tools:\w\$ '
export TERM=${TERM:-xterm-256color}

alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

alias nats-info='nats server info'
alias nats-streams='nats stream ls'
alias nats-consumers='nats consumer ls'
alias nats-events='nats stream info events'
alias nats-kv='nats stream info KV_serviceradar-kv'

alias grpc-core='grpcurl -cacert /etc/serviceradar/certs/root.pem -cert /etc/serviceradar/certs/client.pem -key /etc/serviceradar/certs/client-key.pem serviceradar-core:50052'
alias grpc-agent='grpcurl -cacert /etc/serviceradar/certs/root.pem -cert /etc/serviceradar/certs/client.pem -key /etc/serviceradar/certs/client-key.pem serviceradar-agent:50051'
alias grpc-poller='grpcurl -cacert /etc/serviceradar/certs/root.pem -cert /etc/serviceradar/certs/client.pem -key /etc/serviceradar/certs/client-key.pem serviceradar-poller:50053'
alias grpc-kv='grpcurl -cacert /etc/serviceradar/certs/root.pem -cert /etc/serviceradar/certs/client.pem -key /etc/serviceradar/certs/client-key.pem serviceradar-kv:50057'
alias grpc-mapper='grpcurl -cacert /etc/serviceradar/certs/root.pem -cert /etc/serviceradar/certs/client.pem -key /etc/serviceradar/certs/client-key.pem serviceradar-mapper:50056'
alias grpc-trapd='grpcurl -cacert /etc/serviceradar/certs/root.pem -cert /etc/serviceradar/certs/client.pem -key /etc/serviceradar/certs/client-key.pem serviceradar-trapd:50043'

alias sr='serviceradar-cli'
alias sr-devices='serviceradar-cli devices list'
alias sr-events='serviceradar-cli events list'

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
