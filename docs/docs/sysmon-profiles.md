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

**Note**: The default system profile cannot be deleted. If the profile is assigned to devices, you'll be prompted to reassign them first.

### Default Profile

Each deployment has a default sysmon profile that provides baseline monitoring:
- Sample interval: 10 seconds
- Enabled metrics: CPU, Memory, Disk
- Disk paths: `/` (root filesystem)

The default profile:
- Is marked with a "System" badge
- Cannot be deleted
- Can be modified to change default behavior
- Applies to all agents that don't have a specific profile assignment

## Profile Assignments

Profiles can be assigned in three ways, with the following priority (highest to lowest):

1. **Direct device assignment**: Profile assigned specifically to a device
2. **Tag-based assignment**: Profile assigned to a tag that the device has
3. **Default profile**: Fallback when no other assignments match

### Assigning to Tags

Tag assignments let you apply profiles to groups of devices:

1. Go to **Settings > Sysmon Profiles**
2. Click the **Tag Assignments** tab
3. Click **Add Assignment**
4. Select:
   - **Profile**: The sysmon profile to assign
   - **Tag Key**: The tag attribute (e.g., `environment`, `role`)
   - **Tag Value**: The tag value to match (e.g., `production`, `database`)
   - **Priority**: Higher values take precedence when multiple tags match
5. Click **Save**

Example assignments:
| Tag Key | Tag Value | Profile | Priority |
|---------|-----------|---------|----------|
| environment | production | High Performance | 100 |
| role | database | Database Monitoring | 90 |
| environment | staging | Standard Monitoring | 50 |

If a device has both `environment:production` and `role:database` tags, the "High Performance" profile applies because it has higher priority.

### Assigning to Individual Devices

For specific devices that need custom monitoring:

1. Navigate to **Inventory > Devices**
2. Select a device
3. In the device detail page, find the **System Monitoring** section
4. Use the **Assign Profile** dropdown to select a profile
5. The assignment takes effect immediately

You can also bulk-assign profiles:
1. In the Devices list, select multiple devices using checkboxes
2. Click **Actions > Assign Sysmon Profile**
3. Select the profile to apply
4. Confirm the assignment

## Device Integration

### Viewing Effective Profile

On the device detail page, the **System Monitoring** section shows:
- **Effective Profile**: The profile currently in use
- **Assignment Source**: How the profile was assigned (direct, tag, or default)
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

2. **Device-specific assignment**
   - Profile assigned directly to the device

3. **Tag-based assignment**
   - Profile assigned to a matching tag
   - Higher priority values win when multiple tags match

4. **Default profile** (lowest priority)
   - The deployment's default sysmon profile

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

1. **Start with the default profile** - Customize it for your baseline monitoring needs

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
2. Verify tag assignments match the device's tags
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
