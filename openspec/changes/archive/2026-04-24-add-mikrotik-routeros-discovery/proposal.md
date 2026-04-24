# Change: Add MikroTik RouterOS API discovery

## Why

Issue `#2793` asks for MikroTik API support. The current codebase has MikroTik-aware enrichment rules and test fixtures, but no controller/API discovery path comparable to the existing UniFi integration. That leaves RouterOS/CHR deployments dependent on SNMP alone even when the platform can expose richer identity, interface, bridge, and topology data directly.

We already have a live MikroTik CHR target in the `demo` environment, so this is a practical feature to validate end to end instead of a speculative integration.

## What Changes

- Add a read-only MikroTik RouterOS discovery source for mapper jobs.
- Extend mapper job configuration with encrypted RouterOS API credentials and endpoint settings.
- Add a Go RouterOS poller in the mapper/agent path, parallel to the existing UniFi poller.
- Ingest RouterOS identity, interface, bridge, VLAN, IP address, and neighbor/topology evidence into the existing mapper result pipeline.
- Enrich device inventory with RouterOS-derived vendor, model, version, serial, and hardware metadata when available.
- Document demo validation against the live MikroTik CHR target in the `demo` namespace.

## Impact

- Affected specs:
  - `network-discovery`
  - `device-inventory`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/`
  - `elixir/serviceradar_core/lib/serviceradar/agent_config/compilers/mapper_compiler.ex`
  - `elixir/serviceradar_core/priv/repo/migrations/`
  - `go/pkg/mapper/`
  - `proto/discovery/discovery.proto`
  - `docs/docs/discovery.md`

## Non-Goals

- RouterOS configuration changes, command execution, or policy management.
- CAPsMAN or WiFi analytics.
- BGP, firewall rule, or traffic-analysis parity beyond discovery metadata needed for inventory and topology.
- A generic multi-controller abstraction that rewrites the current UniFi config model before MikroTik support can land.
- Socket tunneling or proxying RouterOS sessions from the agent back to core-elx for Elixir-side collection.
