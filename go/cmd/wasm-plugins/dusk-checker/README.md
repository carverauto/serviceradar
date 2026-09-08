# Dusk Checker Plugin

ServiceRadar WASM plugin for monitoring Dusk blockchain nodes via the RUES accepted-block stream.

## Overview

The dusk-checker monitors:
- **Block height**: Current chain height and sync status
- **Block hash and timestamp**: Latest accepted block details and age

## Building

```bash
./build.sh
```

Output:
- `bazel-bin/build/wasm_plugins/dusk_checker_bundle.zip`
- `bazel-bin/build/wasm_plugins/dusk_checker_bundle.sha256`
- `bazel-bin/build/wasm_plugins/dusk_checker_bundle.metadata.json`

## Configuration

### Plugin Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `node_address` | Dusk node RUES endpoint | `localhost:8080` or `ws://node.example.com:8080` |
| `timeout` | Connection and operation timeout | `30s`, `1m`, `5m` |
| `websocket_path` | RUES WebSocket path | `/on` |
| `subscription_path` | RUES accepted-block subscription path | `/on/blocks/accepted` |

Example params JSON:
```json
{
  "node_address": "localhost:8080",
  "timeout": "30s"
}
```

### Required Capabilities

- `websocket_connect`: Connect to WebSocket endpoints
- `websocket_send`: Send messages over WebSocket
- `websocket_recv`: Receive messages over WebSocket
- `websocket_close`: Close WebSocket connections
- `http_request`: Subscribe to the accepted-block stream
- `log`: Write to agent logs
- `get_config`: Retrieve configuration
- `submit_result`: Report check results

### Default Permissions

- **Allowed domains**: `localhost`, `127.0.0.1` (the local RUES node on the same VM)
- **Allowed ports**: `8080` (the RUES http/ws port)

Pointing the plugin at a remote Dusk node (a non-loopback host or a different
port such as a `wss://host:9000` endpoint) requires an operator to widen these
scopes when approving the package (`approved_permissions`) or on the assignment
(`permissions_override`). The manifest ships minimal for the default local case.

## Result Format

```json
{
  "status": "OK",
  "summary": "Block height: 1234567, hash: abcdef123456, timestamp: 2026-05-08T19:40:54Z, age: 2s"
}
```

### Status Values

| Status | Description |
|--------|-------------|
| `OK` | Node is healthy and reachable |
| `WARNING` | Node is reachable but the latest accepted block is stale |
| `CRITICAL` | Cannot connect to node or node is unhealthy |
| `UNKNOWN` | Configuration error or unexpected state |

## Deployment

1. Extract `plugin.yaml` and `plugin.wasm` from the bundle, then upload the plugin package to ServiceRadar
2. Create a plugin assignment targeting your agent(s)
3. Configure the `node_address` parameter

### Creating Assignment via API

```bash
curl -X POST /api/plugins/assignments \
  -H "Content-Type: application/json" \
  -d '{
    "plugin_id": "dusk-checker",
    "agent_uid": "agent-001",
    "enabled": true,
    "interval_seconds": 60,
    "timeout_seconds": 30,
    "params": {
      "node_address": "localhost:8080",
      "timeout": "30s"
    }
  }'
```

## Troubleshooting

### Plugin Not Running

1. Verify plugin assignment exists and is enabled
2. Check plugin package status is "approved"
3. Review agent logs: `journalctl -u serviceradar-agent -f | grep -i plugin`

### Connection Failures

1. Verify node address is reachable from the agent
2. Check timeout settings - increase if the node is slow
3. Review firewall rules for WebSocket connections
4. Verify allowed_ports includes your node's port

### Always Reports CRITICAL

1. Verify the Dusk node is running and accepting WebSocket connections
2. Test connectivity: `wscat -c ws://localhost:8080/on`
3. Check node_address format - use `host:port` without protocol prefix
