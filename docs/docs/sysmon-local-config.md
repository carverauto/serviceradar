---
sidebar_position: 17
title: Sysmon Local Configuration
---

# Sysmon Local Configuration (Admin Guide)

This guide covers how to configure system monitoring (sysmon) using local configuration files instead of or alongside the centralized profile management system.

## When to Use Local Configuration

Local configuration files are appropriate for:

- **Air-gapped environments**: Networks without connectivity to ServiceRadar Core
- **Automation-driven deployments**: Ansible, Puppet, Chef, or other configuration management
- **Compliance requirements**: When configuration must be auditable via version control
- **Development and testing**: Quick iteration without UI changes
- **Hybrid deployments**: Specific hosts that need custom settings not available in profiles

## Configuration File Locations

The agent looks for local configuration in platform-specific paths:

| Platform | Primary Path | Fallback Path |
|----------|--------------|---------------|
| Linux | `/etc/serviceradar/sysmon.json` | - |
| macOS | `/etc/serviceradar/sysmon.json` | `/usr/local/etc/serviceradar/sysmon.json` |

On macOS, the agent checks the Linux path first for compatibility, then falls back to the macOS-specific path.

## Configuration Format

Create a JSON file with the following structure:

```json
{
  "enabled": true,
  "sample_interval": "10s",
  "collect_cpu": true,
  "collect_memory": true,
  "collect_disk": true,
  "collect_network": false,
  "collect_processes": false,
  "disk_paths": ["/", "/var", "/data"],
  "thresholds": {
    "cpu_warning": "75",
    "cpu_critical": "90",
    "memory_warning": "80",
    "memory_critical": "95",
    "disk_warning": "80",
    "disk_critical": "90"
  }
}
```

### Field Reference

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `enabled` | boolean | No | `true` | Enable/disable sysmon collection |
| `sample_interval` | string | No | `"10s"` | Collection interval (e.g., "5s", "30s", "1m") |
| `collect_cpu` | boolean | No | `true` | Collect CPU metrics |
| `collect_memory` | boolean | No | `true` | Collect memory metrics |
| `collect_disk` | boolean | No | `true` | Collect disk usage metrics |
| `collect_network` | boolean | No | `false` | Collect network interface metrics |
| `collect_processes` | boolean | No | `false` | Collect process list |
| `disk_paths` | string[] | No | `["/"]` | Mount points to monitor |
| `thresholds` | object | No | `{}` | Alert thresholds (see below) |

### Threshold Keys

| Key | Description | Default |
|-----|-------------|---------|
| `cpu_warning` | CPU usage warning threshold (%) | 75 |
| `cpu_critical` | CPU usage critical threshold (%) | 90 |
| `memory_warning` | Memory usage warning threshold (%) | 80 |
| `memory_critical` | Memory usage critical threshold (%) | 95 |
| `disk_warning` | Disk usage warning threshold (%) | 80 |
| `disk_critical` | Disk usage critical threshold (%) | 90 |

## Configuration Resolution Order

When the agent starts, it resolves configuration in this order:

1. **Local file** (highest priority) - If a local `sysmon.json` exists and is valid
2. **Cached config** - Previously fetched remote config stored locally
3. **Remote profile** - Fetched from ServiceRadar Core via gRPC
4. **Default config** - Built-in defaults if all else fails

Local configuration **always takes precedence** over remote profiles. This is by design to support:
- Offline operation
- Emergency overrides
- Automation workflows

## Deployment Examples

### Ansible Deployment

```yaml
# roles/serviceradar-agent/tasks/main.yml
- name: Deploy sysmon configuration
  ansible.builtin.template:
    src: sysmon.json.j2
    dest: /etc/serviceradar/sysmon.json
    owner: root
    group: root
    mode: '0644'
  notify: Restart serviceradar-agent

# roles/serviceradar-agent/templates/sysmon.json.j2
{
  "enabled": true,
  "sample_interval": "{{ sysmon_interval | default('10s') }}",
  "collect_cpu": true,
  "collect_memory": true,
  "collect_disk": true,
  "collect_network": {{ sysmon_collect_network | default(false) | lower }},
  "collect_processes": {{ sysmon_collect_processes | default(false) | lower }},
  "disk_paths": {{ sysmon_disk_paths | default(['/']) | to_json }},
  "thresholds": {
    "cpu_warning": "{{ sysmon_cpu_warning | default('75') }}",
    "cpu_critical": "{{ sysmon_cpu_critical | default('90') }}"
  }
}

# inventory/group_vars/database_servers.yml
sysmon_interval: "5s"
sysmon_collect_processes: true
sysmon_disk_paths:
  - "/"
  - "/var/lib/postgresql"
  - "/var/log"
```

### Puppet Deployment

```puppet
# modules/serviceradar/manifests/sysmon.pp
class serviceradar::sysmon (
  Boolean $enabled = true,
  String $sample_interval = '10s',
  Boolean $collect_cpu = true,
  Boolean $collect_memory = true,
  Boolean $collect_disk = true,
  Boolean $collect_network = false,
  Boolean $collect_processes = false,
  Array[String] $disk_paths = ['/'],
) {
  file { '/etc/serviceradar/sysmon.json':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => template('serviceradar/sysmon.json.erb'),
    notify  => Service['serviceradar-agent'],
  }
}
```

### Shell Script

```bash
#!/bin/bash
# deploy-sysmon-config.sh

CONFIG_DIR="/etc/serviceradar"
CONFIG_FILE="${CONFIG_DIR}/sysmon.json"

# Ensure directory exists
mkdir -p "$CONFIG_DIR"

# Deploy configuration
cat > "$CONFIG_FILE" << 'EOF'
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
EOF

# Set permissions
chmod 644 "$CONFIG_FILE"

# Restart agent to pick up new config
systemctl restart serviceradar-agent
```

## Cache Management

The agent caches its active configuration for resilience:

| Platform | Cache Path |
|----------|------------|
| Linux | `/var/lib/serviceradar/cache/sysmon-config.json` |
| macOS | `/usr/local/var/serviceradar/cache/sysmon-config.json` |

The cache is used when:
- The remote backend is unavailable
- No local config file exists
- The agent is starting in offline mode

### Clearing the Cache

To force the agent to re-fetch configuration:

```bash
# Linux
rm -f /var/lib/serviceradar/cache/sysmon-config.json

# macOS
rm -f /usr/local/var/serviceradar/cache/sysmon-config.json

# Restart agent
systemctl restart serviceradar-agent
```

## Configuration Refresh

The agent checks for configuration updates periodically:

- **Default interval**: 5 minutes
- **Jitter**: Up to 30 seconds (prevents thundering herd)
- **On change**: Collector is reconfigured without restart

When using local configuration:
- Changes to the file are detected on the next refresh cycle
- The agent computes a hash of the config to detect changes
- No restart is required for config changes to take effect

To force an immediate refresh, restart the agent.

## Monitoring Config Source

You can verify which configuration source an agent is using:

### Via Logs

Agent logs show the configuration source at startup:

```
INFO  Loaded sysmon config from local file  path=/etc/serviceradar/sysmon.json
INFO  Sysmon service started  source=local:/etc/serviceradar/sysmon.json
```

Or for remote configuration:

```
INFO  Using default sysmon configuration
INFO  Sysmon service started  source=default
```

### Via UI

The device detail page shows:
- **Config Source**: `local`, `cache`, `remote`, or `default`
- A "Local Override" badge appears when using local config

### Via SRQL

Query devices by config source:

```
config_source:local
config_source:remote
```

## Disabling Sysmon

To completely disable sysmon collection on an agent:

### Option 1: Local Config File

```json
{
  "enabled": false
}
```

### Option 2: Remote Profile

Create a profile with `enabled: false` and assign it to the device.

### Option 3: Remove Capability

Remove the `sysmon` capability from the agent configuration (requires agent restart).

## Troubleshooting

### Config Not Being Applied

1. **Check file permissions**:
   ```bash
   ls -la /etc/serviceradar/sysmon.json
   # Should be readable by the agent user
   ```

2. **Validate JSON syntax**:
   ```bash
   python3 -m json.tool /etc/serviceradar/sysmon.json
   ```

3. **Check agent logs**:
   ```bash
   journalctl -u serviceradar-agent -f | grep sysmon
   ```

### Invalid Configuration

If the config file contains invalid values:
- The agent logs a warning
- Falls back to cached or default configuration
- Continues operating with the fallback config

Common issues:
- Invalid `sample_interval` format (use "10s", "1m", not "10")
- Non-existent disk paths (agent skips them gracefully)
- Invalid JSON syntax (entire file is ignored)

### Checking Active Configuration

To see the currently active configuration:

```bash
# Check agent status
curl -s http://localhost:8089/health | jq .

# Or check logs for config hash
journalctl -u serviceradar-agent | grep config_hash
```

## Security Considerations

1. **File permissions**: The config file should be readable by the agent process but not world-writable:
   ```bash
   chown root:root /etc/serviceradar/sysmon.json
   chmod 644 /etc/serviceradar/sysmon.json
   ```

2. **No secrets**: The sysmon config contains no sensitive information, but follow least-privilege principles.

3. **Audit trail**: When using local configs, use version control (git) to track changes:
   ```bash
   # Track config changes
   cd /etc/serviceradar
   git init
   git add sysmon.json
   git commit -m "Initial sysmon config"
   ```

## Migration from Standalone Sysmon

If you're migrating from the standalone sysmon checker to embedded sysmon:

1. **Remove old checker config** from the agent's checker list
2. **Deploy sysmon.json** to the local config path
3. **Restart the agent**

The embedded sysmon uses the same metrics format, so no backend changes are needed.
