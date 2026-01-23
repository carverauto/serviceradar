---
sidebar_position: 16
title: Sysmon Profiles
---

# Sysmon Profiles

Sysmon Profiles provide centralized management for system monitoring configuration across your ServiceRadar agents. Instead of manually configuring each agent, you can create profiles and assign them to devices or device groups using tags.

## Overview

The System Monitoring (sysmon) feature collects host metrics from your agents:
- **CPU**: Usage percentage, load averages, per-core statistics
- **Memory**: Total, used, available, swap usage
- **Disk**: Usage per mount point, read/write I/O
- **Network**: Interface statistics, bytes in/out
- **Processes**: Top processes by CPU/memory usage

Sysmon Profiles let you control:
- Which metrics are collected
- How frequently samples are taken
- Which disk paths to monitor
- Alert thresholds for each metric type

## Accessing Sysmon Profiles

Navigate to **Settings > Sysmon Profiles** in the web UI.

## Profile Management

### Creating a Profile

1. Click **Create Profile**
2. Fill in the profile settings:
   - **Name**: A descriptive name (e.g., "Production Servers", "Database Hosts")
   - **Sample Interval**: How often to collect metrics (e.g., "10s", "30s", "1m")
   - **Enabled Metrics**: Select which metrics to collect:
     - CPU metrics
     - Memory metrics
     - Disk metrics
     - Network metrics
     - Process list
   - **Disk Paths**: Specify which mount points to monitor (e.g., `/`, `/var`, `/data`)
   - **Thresholds**: Set warning and critical thresholds for alerts

3. Review the JSON preview to see the compiled configuration
4. Click **Save**

### Editing a Profile

1. Click on a profile name or the edit icon
2. Modify the settings
3. Review changes in the JSON preview
4. Click **Save**

### Deleting a Profile

1. Click the delete icon on the profile row
2. Confirm deletion

If a deleted profile was the only match for a device, that device becomes unassigned and sysmon collection is disabled until another profile matches.

## Profile Targeting (SRQL)

Profiles apply to devices based on their SRQL target query. When multiple profiles match, higher priority values win.

Example targeting queries:
- `in:devices tags.role:database` - Match devices with role=database tag
- `in:devices hostname:prod-*` - Match devices with hostname prefix "prod-"
- `in:devices type:Server` - Match devices of type Server

## Device Integration

### Viewing Effective Profile

On the device detail page, the **System Monitoring** section shows:
- **Effective Profile**: The profile currently in use
- **Assignment Source**: How the profile was applied (SRQL or unassigned)
- **Config Source**: Whether the agent is using remote config or local override

### Local Override Badge

If an agent is using a local configuration file instead of the centrally managed profile, a "Local Override" badge appears. This indicates:
- The agent has a `sysmon.json` file in its config directory
- Local configuration takes precedence over remote profiles
- The device is opted-out of centralized management

## SRQL Filtering

You can filter devices by sysmon profile and config source using SRQL:

```
# Find devices using a specific profile
sysmon_profile_id:abc123

# Find devices with local config override
config_source:local

# Find devices using remote config
config_source:remote

# Combine with other filters
type:Server AND config_source:local
```

## Configuration Resolution

When an agent requests its sysmon configuration, ServiceRadar resolves it in this order:

1. **Local config file** (highest priority)
   - Linux: `/etc/serviceradar/sysmon.json`
   - macOS: `/usr/local/etc/serviceradar/sysmon.json`

2. **SRQL targeting**
   - Profiles with `target_query` evaluated by priority (highest first)

3. **No match**
   - Sysmon config is disabled until a profile matches

## Profile Settings Reference

| Setting | Description | Example |
|---------|-------------|---------|
| `enabled` | Whether sysmon collection is active | `true` |
| `sample_interval` | How often to collect metrics | `"10s"`, `"1m"` |
| `collect_cpu` | Collect CPU metrics | `true` |
| `collect_memory` | Collect memory metrics | `true` |
| `collect_disk` | Collect disk metrics | `true` |
| `collect_network` | Collect network interface metrics | `false` |
| `collect_processes` | Collect process list | `false` |
| `disk_paths` | Mount points to monitor | `["/", "/var", "/data"]` |
| `thresholds.cpu_warning` | CPU warning threshold (%) | `"75"` |
| `thresholds.cpu_critical` | CPU critical threshold (%) | `"90"` |
| `thresholds.memory_warning` | Memory warning threshold (%) | `"80"` |
| `thresholds.memory_critical` | Memory critical threshold (%) | `"95"` |

## Best Practices

1. **Create a baseline profile** - Use a catch-all SRQL query (e.g., `in:devices`) if you want default monitoring

2. **Use tags for scalability** - Instead of assigning profiles to individual devices, use tags:
   - `environment:production` → High-frequency monitoring
   - `role:database` → Include disk I/O metrics
   - `tier:frontend` → Skip process collection

3. **Set appropriate intervals**:
   - Production critical systems: 5-10 seconds
   - Standard servers: 30 seconds
   - Development/staging: 60 seconds

4. **Monitor only what you need** - Disable unnecessary collectors:
   - Disable process collection if you don't need it (reduces payload size)
   - Disable network metrics if you're using dedicated network monitoring

5. **Use local override sparingly** - Local config files:
   - Are harder to audit and manage at scale
   - Should be reserved for air-gapped networks or compliance requirements
   - Take precedence over any centralized configuration

## Troubleshooting

### Profile Not Applied

1. Check the device's effective profile in the detail page
2. Verify the profile SRQL query matches the device
3. Check if a local config file exists (shows "Local Override" badge)
4. Verify the agent has the `sysmon` capability

### Metrics Not Appearing

1. Confirm the profile has `enabled: true`
2. Check that the specific collector is enabled (e.g., `collect_cpu: true`)
3. Verify the agent is connected and reporting status
4. Check agent logs for sysmon-related errors

### Config Changes Not Propagating

Agents check for configuration updates every 5 minutes (with jitter). To force an update:
1. Restart the agent
2. Or wait for the next refresh cycle (up to ~5.5 minutes)
