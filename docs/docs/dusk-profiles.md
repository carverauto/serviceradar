---
sidebar_position: 17
title: Dusk Profiles
---

# Dusk Profiles

Dusk Profiles provide centralized management for Dusk blockchain node monitoring configuration across your ServiceRadar agents. The dusk monitoring service is now embedded directly in the agent, eliminating the need for a separate dusk-checker binary.

## Overview

The Dusk monitoring feature connects to Dusk blockchain nodes via their WebSocket API and collects:
- **Block height**: Current chain height and sync status
- **Node status**: Connection state, peer count
- **Chain metrics**: Block production, finalization status

Dusk Profiles let you control:
- Which Dusk node to monitor (WebSocket address)
- Connection timeout settings
- Whether monitoring is enabled/disabled

## Key Concepts

### Embedded Monitoring

Unlike previous versions where dusk-checker ran as a standalone binary, Dusk monitoring is now embedded directly in the ServiceRadar agent. This provides:
- Simplified deployment (no extra binaries)
- Unified configuration delivery
- Automatic config hot-reload
- Consistent lifecycle management

### Disabled by Default

Dusk monitoring is **disabled by default**. An agent without a dusk profile assigned will not attempt to connect to any Dusk node. This ensures:
- No unnecessary connection attempts
- Clean startup for agents not monitoring Dusk
- Explicit opt-in for blockchain monitoring

## Accessing Dusk Profiles

Navigate to **Settings > Dusk Profiles** in the web UI (when available).

## Profile Management

### Creating a Profile

1. Click **Create Profile**
2. Fill in the profile settings:
   - **Name**: A descriptive name (e.g., "Production Dusk Node", "Testnet Monitor")
   - **Node Address**: WebSocket address of the Dusk node (e.g., `localhost:8080`, `dusk-node.example.com:8080`)
   - **Timeout**: Connection and operation timeout (e.g., "5m", "30s", "10m")
   - **Enabled**: Whether this profile should activate monitoring
3. Click **Save**

### Profile Fields

| Field | Description | Default |
|-------|-------------|---------|
| `name` | Human-readable profile name | (required) |
| `node_address` | WebSocket address of the Dusk node | (required when enabled) |
| `timeout` | Connection timeout as duration string | `5m` |
| `enabled` | Whether monitoring is active | `true` |
| `is_default` | Fallback profile for unassigned agents | `false` |
| `target_query` | SRQL query for device targeting | `nil` |
| `priority` | Resolution order (higher = first) | `0` |

### Default Profile

Each deployment can have a default dusk profile:
- Applies to agents without specific profile assignments
- Cannot be deleted while marked as default
- Provides a fallback configuration

To set a profile as default:
1. Open the profile
2. Click **Set as Default**
3. Any previous default profile is automatically unset

## Profile Assignments via SRQL

Profiles can target specific devices using SRQL (ServiceRadar Query Language) queries. This allows dynamic assignment based on device attributes.

### How SRQL Targeting Works

1. Create a profile with a `target_query`
2. Set a `priority` (higher values evaluated first)
3. When an agent requests config, profiles are checked in priority order
4. The first profile whose query matches the agent's device is used

### Example Target Queries

| Query | Matches |
|-------|---------|
| `in:devices tags.role:dusk-node` | Devices with tag `role=dusk-node` |
| `in:devices hostname:dusk-*` | Devices with hostnames starting with "dusk-" |
| `in:devices tags.env:production` | Devices tagged as production |

### Resolution Priority

When an agent requests its dusk configuration:

1. **SRQL targeting profiles**: Evaluated by priority (highest first)
2. **Default profile**: Fallback when no targeting profile matches
3. **No profile**: Returns disabled config (dusk monitoring off)

## Local Configuration

Agents can also use local configuration files for dusk monitoring:

### Configuration File Locations

| Platform | Primary Path | Alternative |
|----------|-------------|-------------|
| Linux | `/etc/serviceradar/dusk.json` | - |
| macOS | `/etc/serviceradar/dusk.json` | `/usr/local/etc/serviceradar/dusk.json` |

### Example Configuration

```json
{
  "enabled": true,
  "node_address": "localhost:8080",
  "timeout": "5m"
}
```

### Configuration Priority

1. Local configuration file (highest priority)
2. Remote profile from ConfigServer
3. Cached configuration
4. Default disabled config

## Monitoring Status

Once configured, dusk monitoring status appears in the agent's service reports:

```json
{
  "service_name": "dusk",
  "service_type": "dusk",
  "available": true,
  "message": {
    "available": true,
    "response_time": 12345678,
    "status": {
      "block_height": 1234567,
      "sync_status": "synced"
    }
  }
}
```

## Migration from Standalone dusk-checker

If you previously ran the standalone `dusk-checker` binary:

1. **Stop the standalone service**:
   ```bash
   systemctl stop serviceradar-dusk
   systemctl disable serviceradar-dusk
   ```

2. **Create a dusk profile** in the web UI or via API

3. **Assign the profile** to your dusk-monitoring agents via:
   - SRQL targeting (recommended)
   - Default profile
   - Local configuration file

4. **Verify monitoring** by checking agent status:
   ```bash
   curl -s localhost:8080/api/status | jq '.services[] | select(.service_name == "dusk")'
   ```

5. **Remove old artifacts** (optional):
   ```bash
   rm /etc/serviceradar/dusk-checker.json
   rm /usr/local/bin/dusk-checker
   ```

## Troubleshooting

### Dusk Not Monitoring

1. **Check profile assignment**:
   - Verify a profile exists and is enabled
   - Confirm the profile matches the agent's device (if using SRQL targeting)
   - Check if a default profile exists

2. **Check agent logs**:
   ```bash
   journalctl -u serviceradar-agent -f | grep -i dusk
   ```

3. **Verify configuration delivery**:
   - Agent logs should show "Applied dusk config from gateway" or "Loaded dusk config from local file"

### Connection Failures

1. **Verify node address** is reachable from the agent
2. **Check timeout settings** - increase if the node is slow to respond
3. **Review firewall rules** - ensure WebSocket connections are allowed

### Config Not Updating

1. **Wait for refresh interval** (default: 5 minutes)
2. **Check config hash** - agent only reconfigures when config changes
3. **Force reload** by restarting the agent
