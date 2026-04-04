# Dusk Checker Plugin

ServiceRadar WASM plugin for monitoring Dusk blockchain nodes via their WebSocket API.

## Overview

The dusk-checker monitors:
- **Block height**: Current chain height and sync status
- **Peer count**: Number of connected peers

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
| `node_address` | WebSocket endpoint of the Dusk node | `localhost:8080` or `ws://node.example.com:8080` |
| `timeout` | Connection and operation timeout | `30s`, `1m`, `5m` |

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
- `log`: Write to agent logs
- `get_config`: Retrieve configuration
- `submit_result`: Report check results

### Default Permissions

- **Allowed domains**: `*` (all domains)
- **Allowed ports**: Port from node_address (e.g., 8080)

## Result Format

```json
{
  "status": "OK",
  "summary": "Block height: 1234567, peers: 8"
}
```

### Status Values

| Status | Description |
|--------|-------------|
| `OK` | Node is healthy and reachable |
| `WARNING` | Node is reachable but has issues (e.g., no peers) |
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
2. Test connectivity: `wscat -c ws://localhost:8080/ws`
3. Check node_address format - use `host:port` without protocol prefix
