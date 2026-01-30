---
sidebar_position: 17
title: Dusk Monitoring
---

# Dusk Monitoring

ServiceRadar provides monitoring for Dusk blockchain nodes through a WASM plugin. The dusk-checker plugin connects to Dusk nodes via their WebSocket API and reports node health status.

## Overview

The Dusk monitoring feature collects:
- **Block height**: Current chain height and sync status
- **Node status**: Connection state, peer count
- **Chain metrics**: Block production, finalization status

## Architecture

The dusk-checker runs as a WebAssembly (WASM) plugin within the ServiceRadar agent's plugin runtime. This provides:

- **Sandboxed execution**: Plugin runs in isolated WASM environment
- **Consistent deployment**: Same plugin binary across all platforms
- **Secure networking**: Host-mediated WebSocket connections with permission controls
- **Hot reloading**: Plugin updates without agent restart

## Configuration

Dusk monitoring is configured through **Plugin Assignments** in the ServiceRadar control plane.

### Creating a Plugin Assignment

1. Navigate to **Plugins > Assignments** in the web UI
2. Click **Create Assignment**
3. Select the **dusk-checker** plugin package
4. Configure the assignment:
   - **Target Agent**: Select the agent(s) to run this check
   - **Enabled**: Whether this assignment is active
   - **Interval**: How often to run the check (e.g., 60 seconds)
   - **Timeout**: Maximum time for each check execution

### Plugin Parameters

The dusk-checker accepts the following parameters:

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

### Plugin Permissions

The dusk-checker requires the following capabilities:
- `websocket_connect`: Connect to WebSocket endpoints
- `websocket_send`: Send messages over WebSocket
- `websocket_recv`: Receive messages over WebSocket
- `websocket_close`: Close WebSocket connections
- `http_request`: Make HTTP requests (for node info endpoints)
- `log`: Write to agent logs
- `get_config`: Retrieve configuration
- `submit_result`: Report check results

Default permissions allow:
- **Allowed domains**: `*` (all domains)
- **Allowed ports**: Port from node_address (e.g., 8080)

You can restrict permissions in the plugin assignment or package approval settings.

## Monitoring Results

Check results are reported in the standard ServiceRadar plugin result format:

```json
{
  "status": "OK",
  "summary": "Block height: 1234567, peers: 8",
  "timestamp": "2024-01-15T10:30:00Z",
  "labels": {
    "block_height": "1234567",
    "peer_count": "8"
  }
}
```

### Status Values

| Status | Description |
|--------|-------------|
| `OK` | Node is healthy and reachable |
| `WARNING` | Node is reachable but may have issues (e.g., syncing) |
| `CRITICAL` | Cannot connect to node or node is unhealthy |
| `UNKNOWN` | Configuration error or unexpected state |

## Migration from Previous Versions

### From Embedded Agent Monitoring (pre-1.0.88)

If you previously used the embedded dusk monitoring in the agent:

1. **Create a plugin assignment** for the dusk-checker plugin
2. **Configure parameters** (node_address, timeout)
3. **Assign to agents** that need dusk monitoring
4. **Remove old dusk profiles** (optional, they're no longer used)

### From Standalone dusk-checker Binary

If you previously ran the standalone `dusk-checker` binary:

1. **Stop the standalone service**:
   ```bash
   systemctl stop serviceradar-dusk
   systemctl disable serviceradar-dusk
   ```

2. **Create a plugin assignment** in the web UI

3. **Verify monitoring** by checking agent status

4. **Remove old artifacts** (optional):
   ```bash
   rm /etc/serviceradar/dusk-checker.json
   rm /usr/local/bin/dusk-checker
   ```

## Troubleshooting

### Plugin Not Running

1. **Verify plugin assignment exists** and is enabled
2. **Check plugin package status** is "approved"
3. **Review agent logs** for plugin loading errors:
   ```bash
   journalctl -u serviceradar-agent -f | grep -i plugin
   ```

### Connection Failures

1. **Verify node address** is reachable from the agent:
   ```bash
   curl -I http://node-address:port/
   ```

2. **Check timeout settings** - increase if the node is slow to respond

3. **Review firewall rules** - ensure WebSocket connections are allowed on the target port

4. **Check plugin permissions** - verify allowed_ports includes your node's port

### Check Always Reports CRITICAL

1. **Verify the Dusk node is running** and accepting WebSocket connections
2. **Test connectivity manually**:
   ```bash
   wscat -c ws://localhost:8080/ws
   ```
3. **Check the node_address format** - should be `host:port` without protocol prefix (the plugin adds `ws://` automatically)

## API Reference

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

### Querying Results

Check results are available through the standard monitoring APIs and will appear in dashboards configured to display plugin results.
