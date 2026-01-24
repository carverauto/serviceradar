# Change: Add Wasm Plugin System for Custom Checkers

## Why
ServiceRadar needs a safe, portable way for users and first-party teams to ship custom checks without deploying new binaries. A Wasm-based plugin system lets us sandbox untrusted code, distribute it through the control plane, and produce consistent, Nagios/Zabbix-style results that map cleanly into existing status pipelines.

## What Changes
- Define a plugin package format (manifest YAML + Wasm blob) with validation, metadata, and capability declarations.
- Add control-plane workflows to upload, store, and assign plugins to agents.
- Extend agent config distribution to deliver plugin assignments and package references.
- Embed a Wasm runtime in the agent (wazero) with a capability-based host function ABI.
- Standardize plugin result output (status, summary, perfdata, structured metrics) and map it into `GatewayServiceStatus`.
- Add resource budgeting: per-agent engine limits configured in admin/agent settings plus per-plugin requested resources in the manifest, with admission control.
- Add a Settings UI view for agent plugin capacity planning and resource usage tracking.
- Add runtime telemetry: agent reports Wasm engine health, resource usage, and execution stats to the control plane.
- Support package storage backends: filesystem (default) and NATS JetStream object storage (optional).
- Establish integrity checks (hash + signature) and resource limits (CPU, memory, timeout).

## Impact
- Affected specs: `agent-config` (config delivery), `wasm-plugin-system` (new capability)
- Affected code: `pkg/agent`, `proto/monitoring.proto`, `web-ng/` (Ash resources + API + UI), object storage integration, Helm/Docker deployment values
- External dependencies: `wazero` for the agent runtime; optional NATS JetStream object store usage in web-ng
