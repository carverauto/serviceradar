# Sysmon Migration Guide

This runbook covers migrating from the standalone sysmon checkers to the embedded sysmon in the ServiceRadar agent.

## Overview

ServiceRadar previously provided two standalone system monitoring checkers:
- **sysmon** (Rust): For Linux systems
- **sysmon-osx** (Go): For macOS systems

These have been consolidated into a single **embedded sysmon** implementation that runs directly inside the ServiceRadar agent. The embedded version offers:

- Centralized profile management via the web UI
- Tag-based configuration for scalable deployments
- No separate process or gRPC overhead
- Cross-platform support in a single implementation
- Identical metrics output (no backend changes needed)

## Pre-Migration Checklist

Before migrating, verify:

- [ ] Agent version is 1.0.53 or later (includes embedded sysmon)
- [ ] You have access to the ServiceRadar web UI (for profile management)
- [ ] You know which hosts are running standalone sysmon checkers
- [ ] You have the current sysmon configurations (if using custom settings)

## Migration Steps

### Step 1: Identify Current Sysmon Hosts

Find hosts running standalone checkers:

```bash
# Linux - Check for standalone sysmon
systemctl status serviceradar-sysmon-checker 2>/dev/null && echo "Found Linux sysmon checker"

# macOS - Check for sysmon-osx
sudo launchctl list | grep sysmonosx && echo "Found macOS sysmon-osx checker"
```

### Step 2: Export Current Configuration (Optional)

If you have custom sysmon settings, export them:

```bash
# Linux
cat /etc/serviceradar/checkers/sysmon.json

# macOS
cat /usr/local/etc/serviceradar/sysmon-osx.json
```

Save these for reference when creating your profile or local config file.

### Step 3: Create Sysmon Profile or Local Config

Choose one of these approaches:

#### Option A: Centralized Profile (Recommended)

1. Navigate to **Settings > Sysmon Profiles** in the web UI
2. Click **Create Profile**
3. Configure your monitoring settings:
   - Sample interval (e.g., "10s")
   - Which metrics to collect
   - Disk paths to monitor
   - Alert thresholds
4. Save the profile
5. Assign the profile to devices or tags

#### Option B: Local Config File

Create `/etc/serviceradar/sysmon.json` (Linux) or `/usr/local/etc/serviceradar/sysmon.json` (macOS):

```json
{
  "enabled": true,
  "sample_interval": "10s",
  "collect_cpu": true,
  "collect_memory": true,
  "collect_disk": true,
  "collect_network": false,
  "collect_processes": false,
  "disk_paths": ["/"]
}
```

### Step 4: Stop the Standalone Checker

#### Linux

```bash
# Stop and disable the standalone checker
sudo systemctl stop serviceradar-sysmon-checker
sudo systemctl disable serviceradar-sysmon-checker

# Remove from agent's checker config (if applicable)
# Edit /etc/serviceradar/agent.json and remove the sysmon checker entry
```

#### macOS

```bash
# Stop and unload the launchd service
sudo launchctl bootout system/com.serviceradar.sysmonosx

# Remove the plist
sudo rm /Library/LaunchDaemons/com.serviceradar.sysmonosx.plist
```

### Step 5: Remove Checker from Agent Configuration

Edit your agent configuration to remove the standalone checker:

```bash
# View current config
cat /etc/serviceradar/agent.json
```

Remove entries like:

```json
{
  "name": "sysmon",
  "type": "grpc",
  "details": "localhost:50083"
}
```

or:

```json
{
  "name": "sysmon-osx",
  "type": "grpc",
  "details": "localhost:50110"
}
```

### Step 6: Restart the Agent

```bash
# Linux
sudo systemctl restart serviceradar-agent

# macOS
sudo launchctl kickstart -k system/com.serviceradar.agent
```

### Step 7: Verify Migration

Check that embedded sysmon is working:

```bash
# Check agent logs for sysmon startup
journalctl -u serviceradar-agent | grep -i sysmon

# Expected output:
# INFO  Sysmon service started  source=local:/etc/serviceradar/sysmon.json
# or
# INFO  Sysmon service started  source=default
```

In the web UI:
1. Navigate to **Inventory > Devices**
2. Select the migrated device
3. Verify the **System Monitoring** section shows metrics

## Configuration Mapping

Map your old settings to the new format:

| Old (Rust sysmon) | Old (sysmon-osx) | New (embedded) |
|-------------------|------------------|----------------|
| `listen_addr` | `listen_addr` | (not needed) |
| N/A | `sample_interval` | `sample_interval` |
| `filesystems[].name` | N/A | `disk_paths[]` |
| `zfs.enabled` | N/A | (ZFS support coming) |

### Example: Rust Sysmon to Embedded

Old `/etc/serviceradar/checkers/sysmon.json`:
```json
{
  "listen_addr": "0.0.0.0:50083",
  "filesystems": [
    {"name": "/", "type": "ext4", "monitor": true},
    {"name": "/data", "type": "xfs", "monitor": true}
  ]
}
```

New `/etc/serviceradar/sysmon.json`:
```json
{
  "enabled": true,
  "sample_interval": "10s",
  "collect_cpu": true,
  "collect_memory": true,
  "collect_disk": true,
  "disk_paths": ["/", "/data"]
}
```

### Example: sysmon-osx to Embedded

Old `/usr/local/etc/serviceradar/sysmon-osx.json`:
```json
{
  "listen_addr": "0.0.0.0:50110",
  "sample_interval": "250ms"
}
```

New `/usr/local/etc/serviceradar/sysmon.json`:
```json
{
  "enabled": true,
  "sample_interval": "1s",
  "collect_cpu": true,
  "collect_memory": true,
  "collect_disk": true
}
```

Note: The embedded sysmon supports a minimum sample interval of 1 second.

## Cleanup (After Verification)

Once you've verified the migration is successful across all hosts:

### Remove Standalone Packages

```bash
# Debian/Ubuntu
sudo apt remove serviceradar-sysmon-checker

# RHEL/Oracle Linux
sudo dnf remove serviceradar-sysmon-checker

# macOS - remove binary and config
sudo rm -f /usr/local/libexec/serviceradar/serviceradar-sysmon-osx
sudo rm -f /usr/local/etc/serviceradar/sysmon-osx.json
```

### Remove Old Config Files

```bash
# Linux
sudo rm -f /etc/serviceradar/checkers/sysmon.json

# macOS
sudo rm -f /usr/local/etc/serviceradar/sysmon-osx.json
```

## Rollback

If you need to revert to the standalone checker:

1. Re-install the standalone checker package
2. Restore the old configuration
3. Add the checker back to agent config
4. Restart services

```bash
# Linux example
sudo dpkg -i serviceradar-sysmon-checker_<version>.deb
sudo systemctl enable --now serviceradar-sysmon-checker

# Remove the embedded sysmon config to prevent conflicts
sudo rm -f /etc/serviceradar/sysmon.json
sudo systemctl restart serviceradar-agent
```

## Troubleshooting

### Metrics Not Appearing After Migration

1. Check agent logs for errors:
   ```bash
   journalctl -u serviceradar-agent | grep -i sysmon
   ```

2. Verify the agent has the `sysmon` capability enabled

3. Check if a profile is assigned (in web UI, Device detail > System Monitoring)

### Config Changes Not Taking Effect

The agent refreshes configuration every 5 minutes. To force an immediate update:
```bash
sudo systemctl restart serviceradar-agent
```

### Duplicate Metrics

If you see duplicate sysmon metrics, the standalone checker may still be running:
```bash
# Check for running checkers
ps aux | grep sysmon
systemctl status serviceradar-sysmon-checker
```

Stop any running standalone checkers before using embedded sysmon.
