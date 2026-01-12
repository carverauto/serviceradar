---
sidebar_position: 14
title: Network Sweeps
---

# Network Sweeps

Network sweeps let you define scheduled scans against device inventories and
explicit IP targets. Sweeps are configured in the Web UI under Settings > Networks.

## Sweep Groups

Sweep groups are the primary unit of configuration. Each group includes:

- **Name and description**: Human-friendly identifiers.
- **Schedule**: Interval (e.g., `15m`, `1h`) or cron expression.
- **Targets**:
  - **Target criteria** (matches devices from inventory)
  - **Static targets** (CIDR, IP, or IP range strings)
- **Scanner profile** (optional): Base ports/modes/timeouts.
- **Overrides**: Group-specific settings that override the profile.
- **Partition / agent**: Scope the sweep to a specific partition or agent.
- **Enabled toggle**: Disable a group without deleting it.

## Scanner Profiles

Profiles define reusable scan settings:

- **Ports**: List of TCP ports to scan.
- **Sweep modes**: `icmp`, `tcp`, `tcp_connect` (as supported by the agent).
- **Concurrency**: Parallel scan worker count.
- **Timeouts**: Per-target scan timeout.

Groups can either reference a profile or define settings inline.

## Target Criteria Syntax

Target criteria is a DSL that matches device fields. Criteria are expressed as a map
of `field -> operator`.

Supported operators include:

- `eq`, `neq`
- `in`, `not_in`
- `contains`, `not_contains`
- `starts_with`, `ends_with`
- `in_cidr`, `not_in_cidr`
- `in_range` (IPv4 ranges like `10.0.0.1-10.0.0.50`)
- `has_any`, `has_all` (tag operators)
- `gt`, `gte`, `lt`, `lte`
- `is_null`, `is_not_null`

### Examples

Match devices by tags:

```json
{
  "tags": {"has_any": ["critical", "env=prod"]}
}
```

Match devices by IP range:

```json
{
  "ip": {"in_cidr": "10.0.0.0/8"}
}
```

Match devices by discovery source and hostname prefix:

```json
{
  "discovery_sources": {"contains": "sweep"},
  "hostname": {"starts_with": "edge-"}
}
```

Combine criteria (all conditions must match):

```json
{
  "tags": {"has_all": ["env=prod", "tier=edge"]},
  "ip": {"in_range": "10.0.1.1-10.0.1.50"}
}
```

### Static Targets

Static targets are always included in the sweep, regardless of criteria matches:

```json
["10.0.0.0/24", "192.168.1.10", "10.0.2.1-10.0.2.25"]
```

## Execution Notes

- Target criteria are evaluated when configs are compiled.
- Sweep results update device availability and discovery metadata.
- Large result sets are chunked by the agent and streamed to the gateway.

