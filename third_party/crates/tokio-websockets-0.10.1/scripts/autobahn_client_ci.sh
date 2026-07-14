#!/usr/bin/bash
set -euo pipefail
set -x

function cleanup() {
    podman stop autobahn -i
}

trap cleanup TERM EXIT

podman run -d --rm \
    -v "${PWD}/autobahn/config:/config" \
    -v "${PWD}/autobahn/reports:/reports" \
    -p 9001:9001 \
    --security-opt label=disable \
    --name autobahn \
    crossbario/autobahn-testsuite

sleep 3

target/x86_64-unknown-linux-gnu/release/examples/autobahn_client
target/x86_64-unknown-linux-gnu/release/examples/autobahn_client_simd
tokio-tungstenite/target/x86_64-unknown-linux-gnu/release/examples/autobahn-client
