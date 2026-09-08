# Change: Add configurable sysmon payload size limit

## Why
The sysmon payload limit is currently a fixed gateway constant, which makes it hard to tune for tenants with different metric volumes. A configurable limit with a documented default improves reliability and allows controlled scaling without global reconfiguration.

## What Changes
- Add a tenant-configurable sysmon payload size limit with a documented default value (15MB).
- Update the agent gateway to read the per-tenant limit and enforce it for sysmon payloads.
- Document the configuration key, default, and enforcement behavior.

## Impact
- Affected specs: edge-architecture
- Affected code: agent gateway status handling, config storage/propagation, admin config documentation
