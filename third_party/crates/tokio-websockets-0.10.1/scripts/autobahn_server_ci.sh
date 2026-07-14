#!/usr/bin/bash
set -euo pipefail
set -x

function cleanup() {
    kill -9 ${WSSERVER1_PID} || true
    kill -9 ${WSSERVER2_PID} || true
    kill -9 ${WSSERVER3_PID} || true
}

trap cleanup TERM EXIT

target/x86_64-unknown-linux-gnu/release/examples/autobahn_server & WSSERVER1_PID=$!
target/x86_64-unknown-linux-gnu/release/examples/autobahn_server_simd & WSSERVER2_PID=$!
tokio-tungstenite/target/x86_64-unknown-linux-gnu/release/examples/autobahn-server & WSSERVER3_PID=$!

sleep 3

podman run --rm -it \
    -v "${PWD}/autobahn/config:/config" \
    -v "${PWD}/autobahn/reports:/reports" \
    --net host \
    --security-opt label=disable \
    --name autobahn \
    crossbario/autobahn-testsuite \
    wstest -m fuzzingclient -s /config/fuzzingclient.json
