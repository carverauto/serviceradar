# Change: Remove KV-backed configuration for edge collectors

## Why
Edge collectors do not need dynamic configuration updates via the KV system, and keeping KV support in these services increases complexity in config compilers and bootstrap logic. Removing KV integration for edge collectors simplifies config ownership, reduces dependencies on NATS/kvutil, and clarifies which services are KV-managed.

## What Changes
- Remove KV config seeding, watching, and merging from all services; there will be no KV-managed service configuration.
- Make edge collectors rely on static JSON/YAML config files or gRPC-delivered config (serviceradar-agent managed) instead of KV.
- Simplify `pkg/config` by removing KV configuration code paths.
- Remove `rust/kvutil` if no remaining consumers after cleanup.
- Update Compose/bootstrap docs to remove KV config seeding expectations.
- **BREAKING**: Services will no longer accept KV-backed configuration for service config; deployments must provide file or gRPC config.

## Impact
- Affected specs: `kv-configuration`.
- Affected code: `pkg/config`, edge collector services in `cmd/` and `rust/` (flowgger, trapd, netflow, zen, otel), potential removal of `rust/kvutil`, Docker Compose/bootstrap scripts, and docs under `docs/docs/`.
